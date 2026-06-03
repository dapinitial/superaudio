# SuperAudio — Project Brief

> Multi-room synchronized audio for the Mac. Captures system audio (any app) and streams it in sync to a heterogeneous mix of AirPlay 1 and Sonos endpoints. Think Airfoil, but ours, and tuned for the exact speakers in this house.

**This file is the architectural brief — the load-bearing principles, module layout, gotchas, and working norms. For "where are we, what's next," see [docs/ROADMAP.md](docs/ROADMAP.md). For "why we chose X over Y," see [docs/DECISIONS.md](docs/DECISIONS.md). For competitive context, see [website/COMPETITIVE_LANDSCAPE.html](website/COMPETITIVE_LANDSCAPE.html).**

---

## Progress snapshot — 2026-05-17

- ✅ **M1 — Foundation.** SPM scaffolding, capture probe (Plan A), menu bar app via `MenuBarExtra`, OSLog wired, `AudioSink`/`SinkRegistry`/`LicenseManager` contracts, reusable `SystemAudioCapture`, live Bonjour discovery (RAOP + Sonos) with A5/A7/Sonos Den in the menu bar.
- ✅ **M2 — RAOP control plane.** Full handshake to B&W A5 and A7: OPTIONS → ANNOUNCE → SETUP → RECORD → SET_PARAMETER volume → TEARDOWN. **NTP timing-channel replies via BSD sockets** were the gate that unblocked RECORD.
- ✅ **M3a — First audio from B&W A5 and A7** (2026-05-14). Three findings unblocked this — see DECISIONS.md 2026-05-14: (1) AirPlay 1 requires compressed ALAC; (2) sync packets must come from the BSD socket bound to our advertised local control port; (3) `et=0` is sufficient as default.
- ✅ **Menu UX as real control surface.** Per-sink toggle, ✓ marker, pulsing menu-bar icon, Play All / Stop All / Restart All group actions, Mute Mac toggle.
- ✅ **M3 hardening pass 1** (2026-05-14/15). `killall SuperAudio` now sends RTSP TEARDOWN + Sonos SOAP Stop cleanly via `DispatchSourceSignal` → `NSApp.terminate` → `applicationWillTerminate`.
- ✅ **M3c — Lossless Mode + bit-exact verification** (2026-05-15). Menu toggle forces Mac output to 44.1 kHz while a session is active. `probe/LosslessVerify` proves ALAC encode→decode is SHA-256-identical. Public "lossless" claim is defensible.
- ✅ **M4 — Sonos audio pipeline** (2026-05-15). `AACEncoder` + `SonosStreamServer` + `SonosSession` with **pump-before-SOAP** ordering. All three speakers confirmed audible from one Play All click.
- ✅ **M5 — Multi-sink fan-out + sync + per-sink controls** (2026-05-15 night). Shared `AudioBroadcaster` (one capture, fan-out to N subscribers). Per-chunk wall-time NTP for sample-accurate cross-AP1 sync. Per-sink volume slider (live mid-stream). Per-sink Δ offset slider. **A7 cold-start root cause fixed** — `Client-Instance` / `DACP-ID` headers per-RTSPClient instance. 2-attempt RTSP handshake retry + 4-min OPTIONS keepalive (idle sinks) + failure UI.
- ✅ **M6 — Multi-sink sync + reliability arc** (2026-05-17). Sender-side broadcaster delay (sidesteps AP1 receivers' silent NTP-clamping behavior — see gotcha #16). Handshake barrier (cross-AP1 first-audio within **1 ms** despite handshake variance — see gotcha #18). Sonos start-align defer + auto-align default. Supervisor exit-reason enum + retry cap (kills retry storms on un-acceptable receivers — see gotcha #19). Session-race nonce guard. Idempotent Play All + Restart All. 1.5 s TEARDOWN timeout. 250 ms volume debounce. UDP timing-packet-presence health monitor (replaced OPTIONS-over-TCP). Audio-gap telemetry. Mac mute default-mismatch fix. Sonos Δ slider rip (Sonos timing encrypted at UPnP — see gotcha #17). Quiet Mode removed; replaced with `defaultVolumePercent = 15`. Slider range bumped to 0–6000 ms. **User empirically dialed in `slider=3085 ms`** with all three speakers audibly in sync. See DECISIONS.md 2026-05-17.
- 🟡 **M3 hardening pass 2.** 30-min soak test + `et=1` compressed ALAC verification — still pending. Now trivially passive thanks to M6 reliability.
- 🟡 **M6.3 — Sync UX** (NEXT). Mac-mic auto-calibration (M11 Path A precursor), real-time slider drag, rotary knob UI, "Re-sync now" button, in-app diagnostics panel. The Calibrate-Now button becomes the M8 launch demo alongside the Claude Skill.
- 🟡 **M5.5 — Device Profile System substrate.** JSON schema + loader + public MIT-licensed `superaudio-device-profiles` GitHub repo. Foundation for the M6.5 Claude Skill onboarding which becomes the M8 launch hook.

Full milestones in [docs/ROADMAP.md](docs/ROADMAP.md).

---

## Goal

Build a macOS menu bar app that streams any Mac audio source (Spotify, Safari, Music, system) to multiple network speakers simultaneously, in sync, across protocols. MVP must work end-to-end on:

- **2× Bowers & Wilkins** A5 and A7, AirPlay 1 only (RAOP)
- **1× Sonos Playbar** gen 1 (no AirPlay support — UPnP/SOAP only)

Success = press play in Spotify, hear it in all three rooms, within ~30ms of each other (acknowledging the Sonos floor — see gotchas).

### POC mindset (revised 2026-05-11)

This is an experimental prototype, **but written as if it could grow into a commercial product**. The planned monetization model is a base app (~$15–20 with AirPlay 1 + Sonos) plus per-protocol addons (~$5 each: AirPlay 2, Chromecast, Bluetooth, etc.). That makes module boundaries and the `AudioSink` abstraction first-class concerns from day one — not v2 cleanup tasks.

**What we still punt on for the POC:**

- Polished UI, full preferences pane, onboarding (Phase 4 has a basic version)
- Comprehensive test coverage — logging + real-device testing is the v1 verification layer
- Deep error handling and retry logic — simple failure model is enough (see below)
- Implementing v2 protocols themselves (AP2, Chromecast, Bluetooth) — but **the seams to add them are pre-built** (see Extensibility model below)

**What we DO NOT punt on:**

- Clean module separation per the SPM layout (Core, AirPlay1, Sonos, Discovery, App)
- The `AudioSink` protocol and `SinkRegistry` as the stable contracts
- Public APIs only, MIT-clean codebase, attribution discipline
- `String(localized:)` for all user-facing strings
- A `LicenseManager` stub from day one so addon-gating wiring already exists

Phase gates remain binary (audio out the speaker, no drops). We don't ship a half-working sink, even in the POC.

---

## Non-goals

- **AirPlay 2.** None of the target hardware supports it. Adding it would mean wrapping `pyatv` via XPC subprocess, implementing the HomeKit-style pairing flow (SRP + Curve25519), and managing a Python runtime dependency. Not worth it for this scope. If we ever add a HomePod, we revisit.
- Cross-platform — Mac only, Swift + AppKit.
- DRM-protected content. We capture system audio; if Apple Music or whatever refuses to play to virtual outputs, that's their problem.
- A polished consumer UI. Menu bar + a single preferences window. Function over form for v1.
- **App Store distribution.** Sandbox restricts system audio capture in ways that would break this app — Airfoil itself sells direct, not via the App Store, for the same reason. We do not target App Store review.

  However, **direct-sale commercial distribution is an open option** (notarized Developer ID build, sold through a website at ~$15–20). The AP1-only / older-Sonos audience is real and underserved. To keep that door open without slowing the POC, we adopt cheap practices now — see "Commercial-track practices" below. Local build, ad-hoc signed for personal use during the POC.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  SuperAudio.app (menu bar)                                 │
│                                                            │
│  ┌──────────────┐    ┌──────────────────┐                 │
│  │ Capture      │───▶│ Mixer / Timeline │                 │
│  │ (CoreAudio   │    │ - Master clock   │                 │
│  │  Process Tap)│    │ - Ring buffer    │                 │
│  └──────────────┘    │ - Per-out offset │                 │
│                      └────────┬─────────┘                 │
│                               │                            │
│                  ┌────────────┴────────────┐              │
│                  ▼                         ▼              │
│          ┌──────────────┐          ┌──────────────┐       │
│          │ AirPlay1     │          │ Sonos        │       │
│          │ Sender       │          │ Sender       │       │
│          │ (RAOP/ALAC)  │          │ (UPnP+HTTP)  │       │
│          └──────────────┘          └──────────────┘       │
│                  │                         │              │
│                  ▼                         ▼              │
│             B&W A5/A7                  Playbar            │
└────────────────────────────────────────────────────────────┘
```

### Core abstractions

```swift
enum ProtocolKind {
    case airplay1
    case sonos
}

protocol AudioSink {
    var id: SinkID { get }
    var displayName: String { get }
    var protocolKind: ProtocolKind { get }
    var measuredLatencyMs: Int { get }       // round-trip + receiver buffer
    var manualOffsetMs: Int { get set }      // user fine-tune

    func connect() async throws
    func enqueue(_ chunk: AudioChunk, scheduledHostTime: UInt64) async throws
    func disconnect() async
}

struct AudioChunk {
    let pcm: AVAudioPCMBuffer        // 44.1kHz / 16-bit / stereo, canonical internal format
    let sequence: UInt32
    let presentationHostTime: UInt64 // mach_absolute_time when first sample should hit DAC
}
```

The mixer feeds **every active sink** the same chunk with the same `presentationHostTime`. Each sink adapter translates that host time into its protocol's clock domain and schedules delivery so the receiver plays at that moment.

---

## Extensibility model

The architecture is designed so that **adding AirPlay 2, Chromecast, Bluetooth, or any future protocol is a new SPM module — no edits to Core, App, or any existing protocol module**. This is load-bearing because the planned commercial model sells protocol support as $5 addons.

### Per-protocol module pattern

Each protocol family lives in its own SPM module (`SuperAudioAirPlay1`, `SuperAudioSonos`, future: `SuperAudioAirPlay2`, `SuperAudioChromecast`, `SuperAudioBluetooth`). Every module implements `AudioSink` for its devices and registers a `SinkDiscoverer` with the central registry in `SuperAudioCore`.

```swift
// In SuperAudioCore — stable public contract every protocol module conforms to

public protocol SinkDiscoverer: AnyObject {
    var protocolKind: ProtocolKind { get }
    func start() async
    func stop() async
    var sinks: AsyncStream<SinkDescriptor> { get }      // emits as devices appear / change
}

public struct SinkDescriptor: Identifiable, Hashable {
    public let id: SinkID
    public let displayName: String
    public let protocolKind: ProtocolKind
    public let endpoint: SinkEndpoint                    // host/port + opaque per-protocol blob
}

public final class SinkRegistry {
    public static let shared = SinkRegistry()
    public func register(_ discoverer: SinkDiscoverer)
    public func allDiscoverers() -> [SinkDiscoverer]
    public func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink
}
```

In `SuperAudioApp` startup, every linked protocol module registers itself:

```swift
SinkRegistry.shared.register(AirPlay1Discoverer())
SinkRegistry.shared.register(SonosDiscoverer())
// Future addons drop in here, gated by LicenseManager:
// if LicenseManager.isEnabled(.airplay2) {
//     SinkRegistry.shared.register(AirPlay2Discoverer())
// }
```

### License-gating stub (v1 placeholder for future addon model)

```swift
// In SuperAudioCore — trivial stub in v1, real in commercialization phase
public enum Addon: String, CaseIterable {
    case airplay2, chromecast, bluetooth, eq, multizone
}

public enum LicenseManager {
    public static func isEnabled(_ addon: Addon) -> Bool {
        true   // v1: everything on. Replaced when commercial track is greenlit.
    }
}
```

The stub keeps the call sites in `SuperAudioApp` shaped correctly from day one. Swapping the implementation later is a one-file change, not an architectural refactor.

### Module dependency rules (enforced by `Package.swift`)

- `SuperAudioCore` depends on **nothing project-internal** — pure Swift + Apple frameworks. It defines the contracts.
- `SuperAudioDiscovery` depends on `SuperAudioCore` only. Provides shared Bonjour / SSDP primitives used by protocol modules.
- Per-protocol modules (`SuperAudioAirPlay1`, `SuperAudioSonos`, ...) depend on `SuperAudioCore` and `SuperAudioDiscovery` only. **They never import each other.**
- `SuperAudioApp` depends on everything and wires it together at startup.

Anyone proposing a dependency edge that violates these rules has to update CLAUDE.md and DECISIONS.md first. The rules exist so future addons can be added (or removed, for a free-tier build) without breaking the rest.

### Adding a new protocol — checklist

When AP2 or Chromecast lands, the recipe is:

1. Create `Sources/SuperAudioAirPlay2/` with a `Package.swift` product line.
2. Implement `AudioSink` for AP2 devices and `SinkDiscoverer` for AP2 discovery (mDNS for AP2 uses `_airplay._tcp`).
3. Add the `SinkRegistry.shared.register(...)` call in `SuperAudioApp` startup, gated by `LicenseManager.isEnabled(.airplay2)`.
4. No edits to Core, no edits to other protocol modules.

If any of those steps requires touching code outside the new module, the abstractions are wrong and we revisit Core.

---

## Tech stack (locked for v1)

These are committed for the POC. Revisit only if a phase gate exposes a real blocker.

| Layer | Choice | Reason |
|---|---|---|
| Language | Swift 5.10+ | Native, async/await, modern CoreAudio bindings |
| UI | SwiftUI + AppKit (menu bar via `NSStatusItem`) | Standard for menu bar apps |
| Min target | macOS 14.4 | CoreAudio process tap API requires this |
| Audio capture | `CATapDescription` / process taps (Plan A); BlackHole virtual device (Plan B) | Apple's blessed replacement for kexts; BlackHole is the documented fallback if Personal Team signing blocks the tap |
| AirPlay 1 | Fresh Swift impl, written from scratch | Owned MIT-clean code; libraop & shairport-sync are reference reading only |
| Sonos | Custom UPnP/SOAP client + local HTTP audio server | Standard approach; lift SOAP envelopes from SoCo (MIT) |
| Discovery | `NWBrowser` (Bonjour) + custom SSDP for Sonos | Native, no deps |
| Encoding | Apple ALAC encoder (Apache 2.0) for AirPlay; `AVAudioConverter` AAC-LC for Sonos | Built-in / permissively licensed |
| Build | SPM workspace, no CocoaPods | Keep it clean |
| Signing | Ad-hoc local signing under Free Apple ID / Personal Team | Cheapest path; upgrade only if entitlements force it |
| Tests | Deferred to v2. Logging is the only verification layer for v1. | POC; "audio out the speaker" is the test |

### License hygiene (decided 2026-05-11)

SuperAudio stays **MIT-clean** so we retain the option to share or open-source later under permissive terms.

- **Do not copy code** from GPL sources: libraop (effectively GPLv2 via chevil/raop2_play), shairport-sync (GPLv3), OwnTone (GPLv2).
- **Reading is fine.** Read those projects to understand wire formats and protocol sequencing. The wire format itself is a fact and cannot be copyrighted.
- **Fresh Swift implementations only** for RAOP/RTSP/RTP/AES handshake.

**Vendor allowlist** — dependencies pre-blessed for use:

- Apple's open-source ALAC encoder (Apache 2.0)
- `AVAudioConverter` (built-in)
- AudioCap by Gui Rambo (MIT) — adapt process-tap code with attribution
- SoCo's SOAP envelope strings (MIT) — lift verbatim, they're effectively API definitions
- BlackHole (MIT) — only if Plan B is needed

### Module layout

```
SuperAudio/
├── Package.swift
├── Sources/
│   ├── SuperAudioApp/           # UI, AppDelegate, menu bar
│   ├── SuperAudioCore/          # Capture, mixer, timeline, sink protocol
│   ├── SuperAudioAirPlay1/      # RAOP sender, ALAC, RTSP
│   ├── SuperAudioSonos/         # UPnP client, local HTTP streamer
│   └── SuperAudioDiscovery/     # Bonjour + SSDP, device registry
└── Tests/
    ├── SuperAudioCoreTests/
    ├── SuperAudioAirPlay1Tests/
    └── SuperAudioSonosTests/
```

---

## Build phases (POC summary)

The detailed linear plan with current status, sub-tasks, and demo gates lives in [docs/ROADMAP.md](docs/ROADMAP.md). What follows is the **POC summary** that grounds the rest of this brief — the four phases that constitute the v1 Mac app, plus what we've actually shipped against them.

Each phase has a **demo gate** — a thing you can actually do at the end. We don't move to the next phase until the gate works.

### Phase 1 — Capture + single AirPlay 1 sink

Foundation + control plane + audio pipeline to one B&W speaker. Gate is binary: audio comes out the speaker for 30 minutes straight, or it doesn't. No partial credit.

- [x] **Day 0 capture probe** — `CATapDescription` + `AudioHardwareCreateProcessTap`, 48 kHz f32, 234 callbacks/5 s. Plan A confirmed. BlackHole fallback not needed.
- [x] SPM workspace + 5-module layout, menu bar app via `MenuBarExtra`
- [x] OSLog subsystems wired (`com.davidpuerto.SuperAudio.{app,core,discovery,airplay1,sonos}`)
- [x] System audio capture as reusable class (`SystemAudioCapture`), 48 kHz f32 native; 44.1k/16 conversion lives in M3
- [x] Bonjour discovery for `_raop._tcp` and `_sonos._tcp` — both B&W speakers and Sonos Den live in menu bar
- [x] RAOP control plane to A5/A7: OPTIONS → ANNOUNCE (`et=1`) → SETUP → **NTP timing reply** → RECORD → SET_PARAMETER volume → TEARDOWN. `Audio-Latency: 4096`.
- [ ] Audio pipeline (M3 in ROADMAP.md):
  - [ ] `AVAudioConverter`: 48 kHz f32 → 44.1 kHz int16 stereo
  - [ ] Vendor Apple's open-source ALAC encoder (Apache 2.0)
  - [ ] RTP packetization with RAOP sequence/timestamp scheme, AES-128-CBC encrypt of the payload (IV reset per packet, whole 16-byte blocks)
  - [ ] Click A7 in menu bar → audio plays
- [ ] **Gate**: pick a B&W speaker from the menu, hear Spotify in that speaker. No drops over 30 min soak test.

### Phase 2 — Multi-device sync within AirPlay 1

Mixer fan-out, latency probes, manual offset. (M5 in ROADMAP.md.)

- [ ] One capture → N active sinks via shared `presentationHostTime`
- [ ] Master clock = `mach_absolute_time`
- [ ] Per-sink latency probe at connect (RTSP RTT + receiver's reported buffer depth, ~88 ms typical for B&W)
- [ ] **Gate**: A5 and A7 within 30 ms of each other. Manual offset slider works.

### Phase 3 — Sonos sink

Replace SomaFM test URL with our own live audio. (M4 in ROADMAP.md — moved up since Sonos control plane is already done.)

- [x] SSDP discovery via `NWBrowser` for `_sonos._tcp` (Sonos advertises both _sonos._tcp and SSDP; Bonjour is cleaner)
- [x] UPnP/SOAP client: `GetTransportInfo`, `SetAVTransportURI`, `Play`, `Stop`
- [x] Test URL: SomaFM via `x-rincon-mp3radio://` — confirmed audible
- [ ] Local HTTP audio server (`Network.framework`, single chunked endpoint, LAN-bound)
- [ ] AAC-LC encoder via `AVAudioConverter`, low-latency mode
- [ ] `SetAVTransportURI` → our own `http://<mac-lan-ip>:7331/stream.m4a`
- [ ] **Gate**: Playbar plays what the Mac plays. Accept ~200–500 ms Sonos floor as default offset.

### Phase 4 — Polish + persistence (M6 in ROADMAP.md)

- [ ] Speaker groups (saved presets)
- [ ] Per-source app selection (process tap supports this)
- [ ] Persist offsets and groups in `UserDefaults`
- [ ] Auto-reconnect on network blips
- [ ] **Gate**: relaunch app, last group resumes automatically.

That's the Mac-app POC. **What used to be "ship it" is now M8 (public beta) in `docs/ROADMAP.md`.** The expanded product — Apple TV companion, iOS companion, Room Tuning, Hub Stick, Hub Pro — is laid out in [docs/ROADMAP.md](docs/ROADMAP.md) milestones M9–M15.

---

## Working norms

- **Real device testing every phase.** No "the unit tests pass, ship it." This is a network audio app. Sync bugs are invisible to unit tests.
- **POC test discipline.** For v1, "audio comes out the speaker" is the test. No XCTest harness, no `MockSink` recording timing. Add proper test infrastructure when there's a second use case to validate against, or before any public sharing.
- **Commit per sub-task and per gate.** Tag `v0.1-phase1`, `v0.2-phase2`, etc. so we can bisect later.
- **Logs are first-class.** Every sink logs scheduled vs actual play time. Use OSLog with subsystems per module. We will be staring at these logs.
- **License hygiene (see Tech stack).** No copying from GPL sources. Fresh Swift implementations only.
- **No external HTTP servers running unless we need them.** The Sonos HTTP streamer only runs when at least one Sonos sink is active. Bind to the LAN interface, not `0.0.0.0`.
- **Network privacy.** All discovery is LAN-only. No telemetry, no analytics, no cloud anything.
- **Asset names use the Super* convention** for consistency with the rest of the toolkit.
- **Stop and ask** when you hit a POC tripwire (see below). Don't invent workarounds that compromise the architecture.

---

## Failure model

Keep recovery simple for v1. Don't pre-build retry frameworks.

- **Network blip to a sink** → disconnect, log, drop from active set. User re-adds manually. Phase 4 adds auto-reconnect.
- **Sink falls behind master clock by >500ms** → drop frames, do not stretch. Audible glitch is acceptable; permanent desync is not.
- **Receiver buffer underrun** → log it, keep streaming. Receivers handle their own recovery.
- **Capture stream stops** (user paused Spotify, etc.) → keep sinks connected but emit silence. Reconnect when audio resumes.
- **Sink rejects a packet** → log, skip, continue. No retransmit in v1.

---

## Commercial-track practices (decided 2026-05-11)

We don't pursue distribution during the POC. But the AP1-only / older-Sonos audience is real, Airfoil's $35 leaves a budget niche at $15–20, and the cost of keeping the door open is near zero **if** we adopt these practices on day one rather than retrofitting them.

**Distribution path if pursued:** direct sale, notarized Developer ID build, **not App Store** (Airfoil's model — sandbox incompatible with system audio capture).

**Pricing model anticipated:** base app (~$15–20) with AirPlay 1 + Sonos, plus **per-protocol $5 addons** (AirPlay 2, Chromecast, Bluetooth, etc.). The `Extensibility model` section above is built for exactly this — each protocol is its own SPM module, gated by `LicenseManager.isEnabled(.airplay2)` etc. In v1 the LicenseManager stub returns `true` for everything; commercial track swaps in real validation.

Practices to follow from the first commit:

- **Public APIs only.** No private framework calls, no SPI. Required for notarization and good practice anyway.
- **User-facing strings via `String(localized:)`** so the app is i18n-ready. Trivial cost now, painful to retrofit.
- **`UserDefaults` for persistence**, no writes outside sandbox-allowed locations. Already standard.
- **`Network.framework` for sockets**, not POSIX. Already in the brief.
- **`THIRD_PARTY_NOTICES.md` maintained from day one.** Add an entry every time a dependency lands.
- **MIT license header on every file we author.** Trivial to start, annoying to add to 200 files later.
- **Module boundaries that allow swapping implementations.** Capture-via-tap should be swappable for capture-via-BlackHole without rewriting consumers. Already implied by the module layout.
- **Privacy stance baked in.** LAN-only discovery, no telemetry, no analytics. Already in the brief.

Explicitly deferred until the POC succeeds and commercial track is greenlit:

- Paid Apple Developer cert ($99/yr) and notarization
- Sandbox entitlement engineering (we run unsandboxed during POC since process tap may require it)
- License key system, Stripe integration, marketing site
- App icon design, onboarding flow, polished preferences UI
- App Store Connect setup (probably never — direct sale is the path)

If POC succeeds and the commercial track is greenlit, a new "commercialization phase" is added after Phase 4. Until then, ship the POC.

---

## Reference reading (skim these before building each component)

- **shairport-sync** (https://github.com/mikebrady/shairport-sync) — the canonical AirPlay 1 receiver. Mirror the protocol on the sender side. Read `rtsp.c` and `player.c` carefully.
- **Snapcast** (https://github.com/badaix/snapcast) — read `time_provider.cpp` and the README on sync strategy. Best open reference for multi-room timing.
- **AudioCap** by Gui Rambo (https://github.com/insidegui/AudioCap) — clean Swift reference for the process tap API.
- **SoCo** (https://github.com/SoCo/SoCo) — Python Sonos library. Useful for cribbing the exact SOAP envelopes.
- **Apple Tech Note TN3163** — process audio tap API reference.

---

## Known gotchas

The numbered list of hard-won lessons lives in **[docs/GOTCHAS.md](docs/GOTCHAS.md)** (22 entries as of 2026-05-21). Referenced as **gotcha #N** throughout the codebase, in `docs/DECISIONS.md`, and in PR descriptions. Add new entries there — do not retire numbers; they are stable references.

Skim it before doing protocol-level work, debugging silent failures, or making changes to session lifecycle / supervisor / calibration code.

---

## POC tripwires (STOP and ask if any of these happen)

Don't invent workarounds — pause and surface:

1. **Process tap returns `kAudioHardwareUnsupportedOperationError` even on Plan B (BlackHole).** Capture chain is broken in a non-standard way. Likely macOS version mismatch or driver conflict.
2. **RAOP handshake to B&W A5/A7 fails with a non-standard error code.** B&W firmware may have quirks not documented in shairport-sync. Get a packet capture from a working sender (Music app fanout) to compare.
3. **Sonos `SetAVTransportURI` returns 200 but Playbar plays nothing.** Likely firewall, interface binding (HTTP server on wrong NIC), or codec issue. Check the Playbar's `GetTransportInfo` response to see what state it's in.
4. **Sync drift between sinks >100ms** despite latency probes. Latency math is wrong, not the protocol. Re-derive from the receiver's RTCP timing reports.
5. **The hand-rolled RTSP/RAOP code seems to need GPL-style features (FEC, complex retransmit) just to be audible.** Means the wire format reading was incomplete or the receiver is stricter than shairport-sync suggests. Surface before falling back to any vendoring decision.

