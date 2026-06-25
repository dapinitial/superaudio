# SuperAudio — Decisions Log

Append-only record of architecturally significant decisions. Each entry: date (absolute), decision, rationale, alternatives considered.

If a decision turns out wrong, **don't edit history** — add a new entry that supersedes it and note "supersedes 2026-MM-DD" in the new one.

---

## 2026-05-11 — Language: Swift, not Rust

**Decision:** Swift 5.10+ for the entire project.

**Rationale:** Every framework dependency is Apple-native — CoreAudio process taps (`CATapDescription`), `AVAudioConverter`, `AVAudioPCMBuffer`, `NWBrowser`, `NSStatusItem`. Rust would require C-interop shims for all of them with no benefit.

**Alternatives considered:** Rust (rejected — interop tax, no cross-platform requirement); Objective-C (rejected — Swift is the modern path).

---

## 2026-05-11 — Scope: AP1 + Sonos only for v1

**Decision:** Target only the user's existing hardware (B&W A5/A7 over AirPlay 1, gen 1 Sonos Playbar over UPnP). AirPlay 2 and Chromecast are explicitly deferred to a future expansion phase.

**Rationale:** No AP2 hardware on the LAN. AP2's HomeKit-style pairing flow (SRP + Curve25519) is the single most expensive part of a sender implementation. Skipping it cuts weeks of work with zero loss to the user's setup.

**Alternatives considered:** Broad scope matching Airfoil (AP1+AP2+Sonos+Chromecast) — rejected as months of work; bridging to Snapcast as the sync engine — rejected, prefer owned code.

---

## 2026-05-11 — Mindset: POC over polish

**Decision:** Treat SuperAudio as an experimental prototype. Ship the three-speaker setup first; clean up, test, harden, and expand later.

**Rationale:** User stated intent. Polish before a working POC is wasted effort if the architecture turns out wrong.

**How it applies:** No pre-built abstractions for hypothetical future use. No XCTest harness for v1. Real-device testing is the only verification. Code quality is a v2 concern. Phase gates are the only hard constraints.

---

## 2026-05-11 — License hygiene: MIT-clean codebase

**Decision:** SuperAudio is written to be MIT-licensable. No code is copied from GPL sources.

**Rationale:** User wants the option to share or open-source SuperAudio later under permissive terms. The closest functional library (`philippe44/libraop`) is effectively GPLv2 via its upstream `chevil/raop2_play` — confirmed in libraop issue #36 where the author acknowledged he cannot relicense it. Reading GPL code as a reference is fine; copying is not.

**How it applies:** RAOP/RTSP/RTP/AES is written fresh in Swift, using libraop and shairport-sync as reference *reading*. Vendor allowlist is in CLAUDE.md (Apple ALAC encoder, AVAudioConverter, AudioCap, SoCo SOAP envelopes, BlackHole).

**Alternatives considered:**
- Vendor libraop, accept GPLv2 for SuperAudio — rejected as it constrains future sharing.
- Vendor libraop now, rewrite before public release — rejected as adding the rewrite as future debt.

---

## 2026-05-11 — Capture: Plan A confirmed (process tap works, no BlackHole fallback needed)

**Decision:** Phase 1 uses Plan A — the macOS 14.4+ `CATapDescription` + `AudioHardwareCreateProcessTap` system audio capture path. BlackHole (Plan B) is not needed.

**Rationale:** The Day 0 probe (`probe/Day0Capture.swift`) ran cleanly on this machine (macOS 26.4.1, Swift 6.0.3, arm64). The tap was created at 48 kHz stereo float32 (`mFormatID=0x6c70636d`/'lpcm', `mFormatFlags=0x9`/float+packed), and 234 IO callbacks fired in 5 seconds with non-zero sample values while `say` played speech through the default output. Sub-buffer size: 512 frames per callback (~10.7 ms at 48 kHz).

**Signing context:** The probe is a plain `swiftc`-compiled Mach-O CLI binary, no `.app` bundle, no entitlements file, no codesigning step. TCC attributed the permission to Apple's Terminal.app (the parent process), and Terminal triggered the standard "would like to record audio from other applications" prompt on first run. The eventual SuperAudio menu bar app will need its own `.app` bundle, `NSAudioCaptureUsageDescription` in Info.plist, and `com.apple.security.device.audio-input` entitlement — but for the probe, none of that was necessary.

**Implication for Phase 1 internal format:** the canonical internal PCM format in CLAUDE.md (44.1 kHz / 16-bit / stereo, for the AirPlay 1 wire format) requires an `AVAudioConverter` sample-rate-conversion step from native 48 kHz float32 → 44.1 kHz int16. Already noted in CLAUDE.md Phase 1 sub-tasks ("SRC step if the system clock runs at 48k"). No change needed.

**Tooling note:** The Command Line Tools install had a stale `/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` duplicating the newer `bridging.modulemap` (both declaring the same `SwiftBridging` module). Until this was renamed aside, all swift compilation failed with "redefinition of module 'SwiftBridging'". If a future contributor hits the same on fresh CLT install on macOS 26.x, the fix is `sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled`.

---

## 2026-05-11 — Signing: ad-hoc Personal Team, Plan A → Plan B capture

**Decision:** Build under Free Apple ID / Personal Team signing. Plan A is `com.apple.security.device.audio-input` ad-hoc signed; Plan B (if the process tap returns `kAudioHardwareUnsupportedOperationError`) is BlackHole as a virtual audio device feeding capture as a regular input.

**Rationale:** No paid Apple Developer cert. Personal Team is cheapest; if it works for process tap we're set. BlackHole (MIT-licensed) is the documented fallback used by Airfoil and others before they shipped system extensions.

**How it applies:** Day 0 capture probe decides Plan A vs Plan B within the first day. If Plan B becomes the answer, update CLAUDE.md and add a follow-up DECISIONS.md entry.

**Alternatives considered:** Paid Apple Developer ($99/yr) — rejected for a POC; unsigned — too restrictive for the entitlement we need.

---

## 2026-05-11 — Clean architecture + addon model is v1 first-class, not v2 cleanup

**Decision:** Code structure, module boundaries, and the `AudioSink` / `SinkRegistry` / `LicenseManager` abstractions are first-class v1 concerns. The POC ships fast, but it ships *with* the seams in place to add AirPlay 2, Chromecast, Bluetooth, and other future protocols as drop-in SPM modules — no retrofitting.

**Rationale:** User raised the planned monetization model: base app (~$15–20) with AirPlay 1 + Sonos, plus **per-protocol $5 addons**. That model requires that adding a new protocol is a new module + one registration line + a license-gate, not an architectural refactor. The cost of getting this right at v1 scaffolding time is small; the cost of retrofitting later is large.

**How it applies:**
- `SuperAudioCore` defines the contracts (`AudioSink`, `SinkDiscoverer`, `SinkRegistry`, `LicenseManager`) from day one.
- Per-protocol modules never import each other; they all depend on `SuperAudioCore` only.
- `LicenseManager.isEnabled(.foo)` stub returns `true` in v1 but exists at every addon registration site.
- Phase 1 scaffolding includes these abstractions even though only AirPlay 1 implements them.
- Adding a new protocol later must follow the checklist in CLAUDE.md's "Extensibility model" section. If a new protocol requires touching Core or other protocol modules, the abstractions are wrong — fix them, don't paper over it.

**Supersedes earlier framing** ("Pre-built abstractions get added when the second use case appears, not before"). The second use case is already known and planned (Sonos in Phase 3, addons after POC), so the abstractions land in Phase 1.

**Alternatives considered:**
- Ship POC with hardcoded sink list, refactor before commercialization — rejected, retrofit cost is real and the user explicitly asked for clean/maintainable/extensible code.
- Build a full plugin loading system (dynamically loaded `.bundle`s) — rejected as overkill; compile-time module separation + license gating gives the same external behavior at a fraction of the complexity.

---

## 2026-05-11 — Distribution: direct-sale option preserved, App Store rejected

**Decision:** SuperAudio is not targeting App Store distribution. We keep open the option to sell direct (notarized Developer ID build, website checkout, ~$15–20 price point) once the POC proves the architecture. To preserve that option cheaply, we adopt a small set of commercial-track practices from day one (public APIs only, `String(localized:)`, attribution file, MIT headers, module swap-ability, privacy stance).

**Rationale:**
- The macOS App Store sandbox is incompatible with system audio capture as practiced by Airfoil and similar apps. Airfoil itself sells direct for this reason.
- AP1-only and gen-1-Sonos owners are a real underserved audience. Airfoil's $35 leaves a budget niche at $15–20 with a tight feature set.
- The clean-code practices that keep the door open cost ~zero if started now and a lot to retrofit.
- We avoid the paid Apple Developer cert ($99/yr) until the POC proves there's something worth selling.

**How it applies:**
- Author code as though it might ship someday. No private APIs. No GPL copying (already decided).
- Maintain `THIRD_PARTY_NOTICES.md` from the first dependency.
- Wrap all user-facing strings with `String(localized:)`.
- Keep module boundaries swappable (e.g., capture-via-tap ↔ capture-via-BlackHole).

**Explicitly deferred to a future "commercialization phase":** notarization, sandbox engineering, license key system, payment integration, marketing site, app icon, onboarding UI.

**Alternatives considered:**
- Hard-target App Store from day one — rejected, sandbox incompatibility likely.
- Hard-target paid-only commercial from day one — rejected as premature for a POC.
- Open-source-only forever — viable but doesn't preclude the others; "MIT-clean codebase" decision already covers this base.

---

## 2026-05-12 — UI framework: SwiftUI `MenuBarExtra`, not `NSStatusItem`

**Decision:** The menu bar UI uses SwiftUI's `MenuBarExtra` Scene (macOS 13+ API) via `@main App` and `@NSApplicationDelegateAdaptor` for non-UI startup work. We do not use the older `NSStatusItem` API.

**Rationale:** Initial scaffold used `NSStatusItem` from `NSStatusBar.system`. The status item created cleanly, OSLog reported `visible=true` and a 140×22 button frame, but the item never rendered visually on this Mac (macOS 26.4.1, Apple Silicon, ad-hoc-signed agent app). Switching to `MenuBarExtra` did not initially fix it either, but a session refresh (logout/login or restart-equivalent) cleared whatever stale state was blocking menu bar registration — likely WindowServer/SystemUIServer cache left over from the same-session CLT reinstall.

**How it applies:**
- `Sources/SuperAudioApp/SuperAudioApp.swift` is the `@main App` entry point. It declares a single `MenuBarExtra` Scene.
- Non-UI startup (sink discoverer registration, log lifecycle) lives in `AppDelegate.swift` via `@NSApplicationDelegateAdaptor`.
- `MenuBarView.swift` holds the menu contents.

**Gotcha to remember:** if menu bar items mysteriously fail to render despite the OS thinking the app is healthy (process alive, signature valid, AX confirms identity), the first thing to try is a session logout/login or `sudo killall WindowServer`. Soft refreshes (`killall Dock`, `killall SystemUIServer`, `killall ControlCenter`) are insufficient. Worth adding to CLAUDE.md's POC tripwires if it recurs.

**Alternatives considered:** Continue debugging `NSStatusItem` — abandoned after a minimal 6-line MenuBarExtra app *also* failed to render under the same conditions, proving the issue was systemic, not code-specific.

---

## 2026-05-13 — RAOP control plane cleared: NTP timing reply was the gate

**Decision:** After full-night debugging session, RAOP RECORD against AirTunes/103.2 receivers (B&W A5 and A7) is unblocked by **answering the speaker's NTP-style timing requests on the timing UDP channel**. Without it, RECORD hangs silently — the speaker is waiting for our timing-handshake response, not for audio. We now reply to PT `0xD2` packets with PT `0xD3` NTP-format responses; RECORD ACKs in <2 seconds with `Audio-Latency: 4096`.

**Confirmed working against:** B&W A7 (`Spacelab Forever Main Audio`, 192.168.1.105) and B&W A5 (`Spacelab Audio`, 192.168.1.82). Full session: OPTIONS → ANNOUNCE → SETUP → RECORD → SET_PARAMETER volume → TEARDOWN. Cross-device proven (same code, different IPs/ports).

**Encryption posture: `et=1` retained as default.** Both `et=0` (no SDP crypto) and `et=1` (with `a=rsaaeskey` + `a=aesiv`) get RECORD `200 OK` once the timing channel is alive. We keep `et=1` as the default for broader receiver compatibility — older AirPort Express models and some third-party AP1 hardware require it. `AppleAirPortRSA.swift` owns the 2048-bit public key constant; encrypt path is one call. Cost: ~110 bytes per ANNOUNCE + one RSA op per session.

**Three sub-decisions made tonight:**

1. **BSD sockets over `NWListener` for UDP receive.** `NWListener` with `NWParameters.udp` silently failed to deliver inbound datagrams — `newConnectionHandler` did not fire even when the kernel was demonstrably delivering 32-byte packets to the bound port (pcap-proven). Switched to `socket()` + `bind()` + `recvfrom()` in a background thread. See `UDPSocket` class in `Sources/SuperAudioAirPlay1/RTSPClient.swift`.

2. **OSLog is not authoritative; pcap is.** Our `RTSPClient.receiveAll` reported "RTSP timed out" multiple times while tcpdump showed the server had actually replied with `500 Internal Server Error` (just after our 30 s timeout fired). Recommendation when client-side logs say "timed out": always capture the wire before assuming the server is silent.

3. **The audio path needs to encrypt RTP payloads with the same AES key.** Since we default to `et=1`, RTP audio packets must be AES-128-CBC encrypted with `aesKey`/`aesIV` (IV reset per packet; only whole 16-byte blocks; ALAC header bytes left unencrypted). Sized correctly: 352-frame ALAC frames × 2 ch × 2 bytes = 1408-byte payload + ~3-byte ALAC header.

**Alternatives considered:**
- **`et=0` unencrypted everything.** Cleaner audio path, but at the cost of receiver compatibility. Worth revisiting if we ever want to drop ~150 lines of crypto code.
- **GPT's "send RTP audio before RECORD ACK" hypothesis.** Tested implicitly by Phase A wire capture; the speaker is NOT waiting for media — it's waiting for timing. Hypothesis was wrong (correctly noted in plan as `medium` confidence).
- **MFi (`et=4`).** Permanently out of scope.

**Supersedes earlier framing** that "RECORD 500 means we need encryption" and "the speaker is silent on RECORD." Both were wrong. The speaker was *busy* waiting for our timing reply.

---

## 2026-05-13 — Product scope expanded from "Mac POC" to "multi-SKU product line"

**Decision:** SuperAudio is no longer a Mac-app-only project. The architecture and roadmap now cover three hardware SKUs (Mac, Apple TV companion, Hub Stick/Pro), two software companions (iOS, tvOS), and a la carte protocol/feature addons. The Mac app is still M8 in the roadmap — the *first* product to ship — but it is positioned as the entry point to a larger product line, not the destination.

**Rationale:** Two facts converged:

1. **The wedge is broader than "Mac fan-out."** The TV-anchored household (the user's own current setup, and arguably the bigger market) needs a non-Mac entry point. Apple TV companion at $5 + Hub Pro at $249 cover this without forcing a Mac purchase. Competitive analysis (COMPETITIVE_LANDSCAPE.html) confirmed no competitor offers cross-ecosystem TV → wireless-speaker fan-out at consumer prices.
2. **The architecture already supports it.** The `AudioSink` / `SinkRegistry` / `LicenseManager` abstractions from CLAUDE.md were designed for addon protocols. Extending them to addon *form factors* (tvOS, Pi, hardware Hubs) is a natural extension, not a refactor.

**How it applies:**

- **CLAUDE.md** remains the architectural brief for the Mac POC. The detailed roadmap (M1–M15) lives in `ROADMAP.md` so CLAUDE.md doesn't bloat with non-Mac milestones.
- **No new code is added to support M9+ until M8 (Mac public beta) ships.** This is a planning artifact, not a green-light to start porting to tvOS/iOS/Linux. POC discipline holds.
- **`SuperAudioCore` must remain pure Swift + Apple frameworks** so that porting to Linux (Hub Stick) and tvOS (companion) is a Package.swift edit + Foundation-version checks, not a rewrite. This was already the rule for addon protocols; extending it to addon platforms is the same constraint.
- **Patent FTO search ($3–5K) becomes a real budget item before M13 (Hub Stick hardware), not before M8.** All M1–M12 milestones use public protocols with 15+ years of prior-art precedent.

**Specifically NOT decided yet:**

- Manufacturer/ODM for hardware SKUs (M13+).
- Whether to do hardware certification (FCC/CE/IC) in-house or via test lab.
- Pricing for non-US markets (currently US-centric; need at-launch local pricing).
- Whether Room Tuning addon (M11) is iOS-only or also macOS-mic-capable.

**Alternatives considered:**

- **Stay Mac-only forever.** Rejected after looking at the TV/household audience — biggest underserved segment is exactly the one without a dedicated Mac for audio routing.
- **Build the Hub before the Mac app ships.** Rejected — hardware certification and ODM cycles are 6+ months. Ship the Mac app first to validate audience and architecture; hardware comes after revenue.
- **License the protocol stack to existing hub vendors (WiiM, Bluesound).** Rejected — gives away the wedge. The cross-ecosystem fan-out is the moat, not the underlying protocol implementations.

**Supersedes earlier framing** in CLAUDE.md that "Phase 4 is v1. Ship it. Anything beyond this is a separate project." Phase 4 is still the v1 Mac app, but "anything beyond this" is now a documented product line in ROADMAP.md, not a separate project.

---

## 2026-05-14 — M3 audio gate cleared: first audio from B&W A7. Three load-bearing findings.

**Decision:** M3a (RAOP audio pipeline) is functionally working. Music played from Mac → captured via process tap → encoded to compressed ALAC → AES-(optional)-encrypted → RTP packetized → sent to B&W A7 → audible from the speaker for the first time. Three findings made this happen, each non-obvious enough to deserve a permanent record so we don't relearn them later or in the wrong order.

### Finding 1 — AirPlay 1 requires real compressed ALAC. Verbatim/escape mode is silently rejected by real hardware.

The ALAC spec includes an "uncompressed verbatim" path (`escape=1` flag, fixed ~1412 bytes per 352-frame stereo 16-bit packet) intended as the encoder's fallback when compression fails. We initially shipped this as **M3a**, planning to swap in real compression as **M3b**. The thinking was: simpler bit layout, no encoder integration, faster to first audio.

**The reality:** B&W A7 firmware (AirTunes/103.2) silently drops verbatim packets. They're structurally valid per the spec — verified byte-for-byte against Apple's open-source ALAC encoder source — but the receiver's decoder either doesn't implement the escape path or only accepts it from specific senders. **We will not chase this further.** Real compressed ALAC is the only mode that produces audio.

Definitive ground truth: tcpdump capture of Music.app → A7 session showed variable-size 642–1117 byte audio packets — unmistakable compressed-ALAC signature. Our verbatim packets were fixed 1412 bytes.

**How it applies:** `RTPSender.swift` uses two chained `AVAudioConverter` instances — (a) capture's 48 kHz f32 → 44.1 kHz int16 stereo PCM, (b) PCM → ALAC. The second converter's output is variable-length compressed ALAC packets, written as-is into RTP payloads. **No vendored C-interop ALAC encoder needed** — `AVAudioConverter` produces compatible bit streams natively, with parameters (pb=40, mb=10, kb=14) that match our SDP `a=fmtp:` line exactly (verified via the encoder's magic cookie).

### Finding 2 — AirPlay 1 sync packets must originate from the SOURCE PORT we advertised in SETUP's Transport header. The receiver `connect()`s its control UDP socket to that exact port.

After handshake, the speaker `connect()`s its three UDP sockets (audio, control, timing) to source addresses derived from the SETUP request — specifically, it binds the **control socket** to the local source port we advertised in the `control_port=NNN` part of our Transport header. Any UDP packet sent to the speaker's control port from a DIFFERENT source port is kernel-rejected at the receiver with ICMP "port unreachable" before the speaker's app code ever sees it.

We discovered this with `probe/PortProbe.swift` — a small Swift diagnostic that probes UDP ports and classifies them by ICMP response. During a live session, probing the speaker's control port from an *ephemeral* source returned `CLOSED — ICMP port unreachable`, but the same port was *open|filtered* when probed from any source while no session was active. The asymmetry was the smoking gun.

**Our pre-fix code** opened a separate `NWConnection.udp` for sync packets — which uses an ephemeral source port — so every sync packet we sent was dropped by the speaker's kernel before reaching the playback scheduler. The receiver buffered audio packets indefinitely without ever scheduling playback because no sync reference arrived. **Silent failure mode.**

**How it applies:** sync packets are now dispatched via `RTSPClient.sendOnControlSocket(_:toHost:port:)`, which calls `sendto()` on the existing BSD socket bound to the advertised local control port. The audio packets continue to use `NWConnection.udp` (audio doesn't require source-port matching — the receiver accepts audio from any source, presumably to tolerate NAT/routing variations).

### Finding 3 — `et=0` (cleartext audio) is fully sufficient. `et=1` AES path is unverified with compressed ALAC and stays optional.

We had been defaulting to `et=1` for "broader receiver compatibility." Tonight's working configuration is `et=0` — SDP omits `a=rsaaeskey:` / `a=aesiv:`, audio packets are cleartext compressed ALAC. The receiver accepted this without complaint and played audio normally.

**`et=1` was tested with verbatim ALAC and produced no audio.** That was definitively the verbatim-mode issue (Finding 1), not encryption. We have NOT yet tested `et=1` with compressed ALAC; could work, could not. Until verified, `useEncryption: Bool` in `RTSPClient` defaults to `false`.

**How it applies:** `Sources/SuperAudio/AirPlay1Session.swift` carries the constant `useEncryption = false`. Test the `et=1 + compressed` path in a follow-on cycle; if it works, flip the default back to `true` per the broader-receiver-compatibility rationale.

### Other tonight that didn't fit a numbered finding

- **`probe/PortProbe.swift`** is a permanent diagnostic. Build with `swiftc -O probe/PortProbe.swift -o probe/PortProbe`. Usage: `probe/PortProbe <host> <ports...>`. Future use cases: validating any RAOP receiver's port model, debugging Sonos, debugging Chromecast.
- **`--auto-click=<displayName>` CLI flag on `SuperAudio.app`** turns the app into a one-shot test driver: discover the named sink, run the full RAOP session, terminate. Lets external orchestration (debug scripts, CI) drive end-to-end tests without GUI interaction. Kept as a debug affordance; not gated behind `DEBUG` because the cost is trivial.
- **Each `Scripts/build_app.sh` rebuild changes the binary hash and invalidates TCC audio-recording permission.** Re-launching the *same* `.app` bundle (without rebuild) preserves the grant. Workflow note for the dev loop: prefer `open SuperAudio.app` over `Scripts/build_app.sh && open …` when only re-running, not changing code.
- **Stuck-session recovery:** if `SuperAudio` is killed mid-stream (no TEARDOWN), the speaker holds its RTSP TCP port closed for 1–5 minutes before its internal session timeout fires. Workaround: physical power-cycle. Permanent fix is a signal handler that fires TEARDOWN on `SIGTERM` / `SIGINT` — not yet implemented; minor.

**Supersedes** the M3a/M3b/M3c staging in `ROADMAP.md`: M3a (verbatim) was a dead end. We jumped straight to the M3b-equivalent (real ALAC), and Lossless Mode (M3c) is the remaining engineering work to claim "lossless" in marketing.

**Alternatives considered:**
- **Vendor Apple's open-source ALAC encoder (Apache 2.0) via C interop.** Rejected as unnecessary — `AVAudioConverter` produces a bit-identical ALAC stream with no C/Swift bridging overhead.
- **Implement RTCP-style retransmit-response handler.** Receiver expects this on its control port when packets are lost; we ignore inbound RTCP. Acceptable for v1 (LAN reliability is high); add when soak testing exposes audible drops.

---

## 2026-05-14 evening — Menu UX promoted to a real control surface: toggle, multi-sink, mute-while-playing

**Decision:** The menu bar is no longer a "click to fire a 60-second test session" diagnostic harness. It's the real product surface. Clicking a sink toggles its session; an explicit "Play All AirPlay" group action starts every AirPlay 1 sink simultaneously; "Stop All" tears everything down cleanly; a persistent "Mute Mac speakers while playing" toggle eliminates the inherent ~93 ms echo between Mac-direct playback and AirPlay-buffered remote playback. The menu now reflects state in real time (checkmark next to active sinks; menu-bar icon pulses while any session is active).

This shipped after first-audio (M3a) on the same day. M3a got *audible*; this commit makes the surface usable.

### What changed

- **`SessionState`** (new, `Sources/SuperAudio/SessionState.swift`) — `@MainActor @Observable` singleton that owns the live "what's playing" state: a `Set<SinkID>` of active sinks plus a dictionary of in-flight `Task` handles keyed by sink id, each tagged with a `UUID` nonce. The nonce prevents a finished session's continuation from clobbering a freshly-restarted session's dict entry during rapid off→on toggles. The race was caught early.
- **`AirPlay1Session.run(descriptor:duration:)`** — picks up an optional `duration: TimeInterval?` parameter. `nil` = run until the wrapping Task is cancelled (menu toggle behavior); a number = run for that long then TEARDOWN (auto-click test-driver behavior). Internally the wait loop is `Task.sleep` in either mode; cancellation rolls into the existing TEARDOWN path via `defer`.
- **Group actions** — `SessionState.startAll([SinkDescriptor])` iterates and toggles every idle sink in the list. `stopAll()` cancels every running session synchronously. Used by the "▶ Play All AirPlay" / "■ Stop All" menu items. Starting both speakers within milliseconds of each other gets noticeably tighter sync than two manual clicks 1-2 seconds apart, even though we still lack proper M5 multi-sink fan-out — NTP wall-clock anchoring carries most of the weight.
- **`MacAudioMute`** (new, `Sources/SuperAudio/MacAudioMute.swift`) — wraps the CoreAudio `kAudioDevicePropertyMute` property on the default output device. Tracks whether *we* muted it so cleanup doesn't disturb a user-initiated mute. Driven by `SessionState.muteMacWhilePlaying` (UserDefaults-persisted); applied on every session start/stop transition.
- **Menu-bar icon** (`Sources/SuperAudio/SuperAudio.swift`) — switched from a static `Label` to a custom `MenuBarIcon` view that applies `.symbolEffect(.pulse, options: .repeating, isActive: session.isAnyActive)`. Built-in SF Symbols animation; no Timer, no extra threads.
- **Menu rows** (`Sources/SuperAudio/MenuBarView.swift`) — each sink shows `checkmark.circle.fill` (active) or `circle` (idle) as its leading icon. Click goes through `SessionState.shared.toggle(descriptor)` rather than spawning a raw Task. Quit menu item now calls `session.stopAll()` before `NSApp.terminate(nil)` — explicit cleanup instead of trusting `defer`-on-process-exit.

### Toggle race (caught and fixed before it shipped to the user)

Rapid off→on→off cycles created this race:

1. Click 1: start. Task A registered in dict[A7].
2. Click 2 (≤ a few s later): toggle off. We cancel Task A. Task A starts running its TEARDOWN sequence (takes ~1 s to send the RTSP TEARDOWN and close sockets).
3. Click 3 (during Task A's teardown): no entry in dict → start Task B. dict[A7] = Task B.
4. Task A's continuation finally runs. It removes dict[A7] — but dict[A7] is now Task B's entry. Task B is orphaned: its session is running, but the dict says no session exists, so the UI shows the speaker as idle.
5. Next click sees idle state, starts Task C. Two sessions running for the same speaker. ANNOUNCE returns 453 Not Enough Bandwidth.

The fix is a per-task UUID nonce. Task A's continuation checks "is the current dict[id]'s nonce still mine?" before removing. If not (Task B replaced it), the continuation is a no-op. Simple, deterministic, no locks beyond the implicit `@MainActor` serialization.

### Sonos toggle on shutdown — known small gap

Quit now calls `session.stopAll()` which cancels AirPlay 1 sessions. **Sonos doesn't follow this path** because Sonos sessions aren't managed by `SessionState` — they're one-shot SOAP commands. Clicking a Sonos in the menu sends `SetAVTransportURI` + `Play`; the Sonos then streams independently of our app and keeps playing after we quit. Discovered when the user found their Sonos Den still streaming SomaFM Groove Salad hours after our last session. Documented as a TODO; fix is straightforward (add a SOAP `Stop` to the menu's Sonos handler when its state is "PLAYING", which is already what the existing handler does — but we don't fire it on app quit).

### Other small wins

- Volume defaulted to `-5 dB` (was `0 dB` max, briefly `-15 dB` which turned out to be near-inaudible on B&W's curve). Audible but not loud. Will become a per-sink slider with M5.
- `AirPlay1Session` logs `◆ Audio pipeline live until cancelled — ...` (toggle mode) or `◆ Audio pipeline live for Ns — ...` (auto-click mode) so the log reflects the actual session model.

### What this doesn't change

- M3c Lossless Mode is still pending. The "lossless" claim doesn't ship to the public site until the source-rate-matching + bit-exact verification test pass.
- M5 (sample-accurate multi-sink fan-out) is still pending. Today's "Play All AirPlay" starts sessions simultaneously, which gives *approximate* sync via NTP anchoring; not sample-accurate.
- 30-minute soak test still pending.
- SIGTERM/SIGINT TEARDOWN handler still pending. Quit-via-menu is graceful now; `killall` from the shell still leaves speakers stuck.

---

## 2026-05-15 — M3c shipped: Lossless Mode + bit-exact verification

**Decision:** The "lossless to AirPlay 1" marketing claim is now mathematically defensible. The bit-exact ALAC round-trip verification tool (`probe/LosslessVerify`) passes — same SHA-256 over input PCM and encoder-output→decoder-output PCM, with zero divergence across 44100 stereo 16-bit frames. The "Lossless Mode" feature switches the macOS default output sample rate to 44.1 kHz while a session is active so 44.1/16 source material (Apple Music Lossless standard) reaches the speaker with **zero intermediate resampling**.

### What landed

- **`LosslessMode.swift`** (new) — wraps the CoreAudio `kAudioDevicePropertyNominalSampleRate` property on the default output device. `forceMacOutputTo44100()` saves the original rate before switching; `restore()` sets it back. Idempotent; tracks whether *we* changed it so a user-initiated rate change isn't disturbed. Same defensive-restore pattern as `MacAudioMute`.
- **`SessionState.losslessMode: Bool`** (UserDefaults-persisted) — drives `applyLosslessIfNeeded()` on every active/inactive transition. The toggle is in the menu next to "Mute Mac speakers while playing."
- **`RTPSender` log line** — now prints `◆ LOSSLESS PASS-THROUGH — capture is already 44.1 kHz; no rate conversion before ALAC` when the capture format matches 44.1 (Lossless Mode on or system happens to be there); otherwise warns about the rate conversion path.
- **`probe/LosslessVerify.swift`** (new) — standalone CLI tool that:
  1. Synthesizes 1 second of 1 kHz sine at 44.1/16/stereo
  2. Encodes through our exact production `AVAudioConverter` config (`kAudioFormatAppleLossless` + `kAppleLosslessFormatFlag_16BitSourceData`, 352 frames per packet)
  3. Decodes the resulting ALAC packets via `AudioConverterFillComplexBuffer` (raw C API, see below)
  4. Compares SHA-256 of input vs decoded — must match exactly, no divergent samples
  Reports a `✅ BIT-EXACT` or `❌ FAIL` verdict with first-divergence diagnostic. **Run before any release whose marketing copy uses the word "lossless."**

### Two non-obvious findings from building the verification tool

1. **`AVAudioConverter.magicCookie` is read-only on the Obj-C bridge.** `decoder.setValue(cookie, forKey: "magicCookie")` silently fails — confirmed by reading the cookie back after setting (returns nil). The decoder cannot be configured for ALAC via `AVAudioConverter` alone. Workaround: drop the decoder to the underlying `AudioConverter` C API and use `AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, ...)`. The encoder side works fine with `AVAudioConverter` because the encoder *generates* its own cookie and exposes it for reading.

2. **`.noDataNow` vs `.endOfStream` in `AVAudioConverterInputBlock` matters.** When encoding a fixed-length buffer (like a 44100-frame test), signaling `.noDataNow` after the last input chunk causes the encoder to hold any partial last packet in its internal buffer forever — we lose the trailing 100 frames. Signal `.endOfStream` instead and the encoder flushes. In **production code (`RTPSender`)** we still use `.noDataNow` because we DO have more data later (audio capture is continuous); we only need `.endOfStream` for fixed-length flush scenarios. The verification tool needs `.endOfStream`; the production audio pipeline does not.

### What this means for the public site

`website/index.html` and `website/CASE_STUDY.html` currently do not claim "lossless." After M3 hardening is complete (soak test + et=1 verification), we can ship lossless copy. The verification tool is the gate: it goes in CI / pre-release checks; if it ever stops passing, we don't ship.

### Verification target environment

Built and verified on:
- macOS 26.4.1, Apple Silicon (M4 Max)
- Swift 6.3.2 from `/Library/Developer/CommandLineTools` (no full Xcode required)
- No external dependencies — pure Foundation + AVFoundation + AudioToolbox + CryptoKit

XCTest-based unit test version was attempted but abandoned because the CommandLineTools toolchain doesn't ship `XCTest`. The CLI-tool path is also better aligned with the existing `probe/` pattern (`PortProbe`, `Day0Capture`) and runnable from any terminal without test-runner orchestration.

---

## 2026-05-15 — M4 implemented: Sonos plays real Mac audio (replaces SomaFM placeholder)

**Decision:** Clicking a Sonos sink in our menu no longer triggers the SomaFM Groove Salad test URL. It now spins up a complete Mac-audio-to-Sonos pipeline that mirrors the AirPlay 1 path: system audio capture → AAC-LC encode → local HTTP server → SOAP `SetAVTransportURI(http://<mac-ip>:7331/stream.aac)` + `Play`. Toggle off sends SOAP `Stop` and tears the server down.

### Components

- **`AACEncoder`** in `Sources/SuperAudioSonos/AACEncoder.swift` — wraps `AVAudioConverter` for PCM (48 kHz f32 stereo, the capture native format) → AAC-LC (48 kHz, stereo, 192 kbit/s). Each output AAC packet is prepended with a 7-byte **ADTS header** (computed per ISO/IEC 13818-7) so the receiver can sync to frame boundaries without out-of-band config. ADTS over a continuous HTTP body is what OwnTone and AirConnect both use; M4A container wrapping would require a `moov` atom up front that streaming can't produce cleanly.

- **`SonosStreamServer`** in `Sources/SuperAudioSonos/SonosStreamServer.swift` — Network.framework `NWListener` on TCP port 7331 (configurable). Binds to the LAN interface IP (NOT `0.0.0.0`) per CLAUDE.md working norm — `LocalNetwork.primaryLocalIPv4()` finds it, skipping loopback / AWDL / VPN / Thunderbolt-bridge interfaces. Endpoint `/stream.aac`. HTTP/1.0 response with `Content-Type: audio/aac`, no `Content-Length`, no `Transfer-Encoding` — Sonos treats this as a continuous live stream that ends when the TCP connection closes. Multiple concurrent connections allowed (e.g., if M5 ever fans out to multiple Sonos sinks, each gets its own subscription against the same server).

- **`SonosSession`** in `Sources/SuperAudio/SonosSession.swift` — orchestrator parallel to `AirPlay1Session`. Owns the capture + encoder + server + SOAP commands for one Sonos. Same `duration: TimeInterval?` lifecycle (`nil` = run until cancelled).

### Toggle model unification

`SessionState.toggle(_:)` now dispatches on `descriptor.protocolKind`: `.airplay1` runs `AirPlay1Session`, `.sonos` runs `SonosSession`. **The menu's per-sink click handler is now identical for both protocols** — single `SessionState.shared.toggle(descriptor)` call. The legacy "click Sonos to toggle SomaFM SOAP" path is gone.

The "▶ Play All" group action now starts every streamable sink (AirPlay 1 + Sonos). A second button "▶ Play All AirPlay (no Sonos)" is kept for users who specifically want AP1-only multi-room (e.g., to avoid the Sonos ~200–500 ms buffer floor when synchronization matters).

### `LocalNetwork.primaryLocalIPv4()` factored into Core

The LAN-IP-lookup helper, previously `private static` on `RTSPClient`, is now `public static` on `LocalNetwork` in `SuperAudioCore`. Used by both AirPlay 1 (SDP `c=` line) and Sonos (URL host). Filters out interfaces that won't reach the home WiFi (loopback, AWDL, llw, utun, bridge).

### Sonos floor — documented, not fixed

Sonos has 200–500 ms of internal HTTP-stream buffering you can't bypass via UPnP. With M4, audio plays through Sonos *and* AirPlay 1, but Sonos lags AP1 by that amount. Acceptable for v1; M5's per-sink offset slider gives users the manual fine-tune. The CLAUDE.md gotcha #1 ("Sonos sync is loose by design") remains the standing position.

### What's verified, what's not

Verified: build clean, no warnings, all toggle paths route correctly. ALAC bit-exact verification still passes (M3c is unaffected).

**Not yet verified** (requires real-hardware listening): the AAC stream is structurally valid for Sonos to decode. The ADTS header bit-packing has been written from spec; bit math is straightforward but a single wrong bit means the receiver rejects the stream. First real test: click Sonos Den in menu, listen for audio.

If audio fails on first listen, the diagnostic ladder:
1. `nc -v <mac-ip> 7331 && GET /stream.aac HTTP/1.0` — verify HTTP server responds
2. tcpdump from Mac side, see if Sonos opens a TCP connection
3. If yes, verify ADTS frames look right via byte dump
4. Compare against an actual Sonos-accepted stream (e.g., the SomaFM URL, captured)

---

## 2026-05-15 — M5 design intent (NOT yet implemented)

**Status:** This is a design note, not a decision-of-record. M5 is the next major implementation work after M3 hardening 2/N. Writing the architecture up so it can be implemented quickly and confidently next session without re-deriving it.

### Problem

Each menu click currently creates an independent session with its own `SystemAudioCapture`. Two clicks = two process taps running in parallel = two captures of the same Mac audio at slightly different start moments. They're approximately in sync because each speaker is NTP-anchored to wall-clock, but they're not *sample-accurate*. Standing equidistant between two speakers, you can hear faint phasing.

Wasteful too — N speakers means N taps consuming N× the CPU for the same source.

### Target architecture

One shared `AudioBroadcaster` in `SuperAudioCore`. Sessions subscribe; broadcaster forwards each captured chunk to every subscriber. **All sinks see identical `AudioChunk` instances with the same `presentationHostTime`**, so any per-sink latency offset is purely additive and tractable.

```
SystemAudioCapture (1 instance)
       │ AsyncStream<AudioChunk>
       ▼
AudioBroadcaster
       │ fan-out
   ┌───┴───────────────────┐
   ▼                       ▼
AirPlay1Session.A7    SonosSession.Den
   │                       │
   ▼                       ▼
RTPSender (ALAC+RTP)   AACEncoder + SonosStreamServer
   │                       │
   ▼                       ▼
B&W A7                 Sonos Den
```

### `AudioBroadcaster` API sketch

```swift
// In SuperAudioCore/AudioBroadcaster.swift
@MainActor
public final class AudioBroadcaster {
    public static let shared = AudioBroadcaster()

    /// Format of the broadcast stream. Available once at least one
    /// subscriber has triggered capture startup. Subscribers can read
    /// this to configure their own converters.
    public private(set) var streamFormat: AVAudioFormat?

    public struct Subscription {
        let id: UUID
        let stream: AsyncStream<AudioChunk>
    }

    /// Subscribe to the audio broadcast. Capture starts on first
    /// subscription; the format is available after `streamFormat`
    /// resolves (poll or use the returned `AsyncStream` to learn it
    /// from the first chunk).
    public func subscribe() -> Subscription

    /// Unsubscribe. Capture stops automatically when the last
    /// subscriber disconnects.
    public func unsubscribe(_ id: UUID)
}
```

### Implementation strategy

1. **Broadcaster**: holds a single `SystemAudioCapture`, started lazily on first subscribe and stopped on last unsubscribe. Maintains `[UUID: AsyncStream<AudioChunk>.Continuation]` of subscribers. A driver Task reads `capture.chunks` and yields each chunk to every continuation. Per-subscriber `bufferingPolicy: .bufferingNewest(N)` prevents one slow subscriber from blocking others — a backpressured subscriber simply drops old chunks (matches CLAUDE.md failure model "drop frames, do not stretch").

2. **AirPlay1Session refactor**: replace its private `SystemAudioCapture` with `AudioBroadcaster.shared.subscribe()`. Read `streamFormat` from the broadcaster for `RTPSender` init. On exit, `unsubscribe`.

3. **SonosSession refactor**: same swap. SonosSession's pump reads chunks from the broadcaster, feeds through `AACEncoder`, writes to `SonosStreamServer`.

4. **Per-sink offset**:
   - Add `manualOffsetMs: Int` to each session's preferences (UserDefaults-persisted per sink id).
   - For AP1: shift the sync packet's NTP timestamp by `-manualOffsetMs` (delays the speaker's perceived play time) or `+manualOffsetMs` (advances it). The Sonos floor (~200–500 ms) makes a positive offset on AP1 the right default to align with Sonos.
   - For Sonos: harder — Sonos schedules from its own buffer. Best we can do is delay our HTTP body writes by `manualOffsetMs` to push playback back.
   - Menu UI: tiny `Stepper` per active sink? Or a Preferences window. For v1, a global "Sonos delay offset" slider that's auto-applied per sink type might be enough.

5. **Auto latency probe**:
   - For AP1: parse `Audio-Latency:` from RECORD response (already done, `RTSPClient.negotiatedAudioLatency` exists).
   - For Sonos: empirical. Hard to measure without round-trip mic. Default to 350 ms (mid of 200–500 ms range) and let users tune.

### Risk

The session refactor touches two known-working audio paths (AP1 and Sonos). The migration must be done carefully:

- Migrate one session type at a time (AP1 first; Sonos second).
- Keep the old-architecture path available behind a feature flag for one commit — fall back if the new path breaks the audio test.
- Re-run `probe/LosslessVerify` after migration to confirm the audio data hasn't been corrupted by the broadcaster path.
- Real-hardware audible test after each migration step.

### Why this is being deferred from the autopilot session

Cannot validate sample-accurate sync without the user listening to both speakers. The autopilot risk/reward is poor: real chance of regressing the working state, no autonomous way to verify the gain. Better as a focused session with the user present to listen.

---

## 2026-05-15 (late evening) — M4 audible-test passes. All three speakers play.

**Decision:** Sonos Den audibly plays real Mac audio from SuperAudio. M4 is fully complete; the full three-speaker vision from CLAUDE.md ("press play in Spotify, hear it in all three rooms") is reachable in a single Play All click.

Four bugs were caught in the audible-test diagnostic loop after the M4 commit:

### 1. `NSLocalNetworkUsageDescription` missing from Info.plist

macOS 14+ has a separate TCC privacy gate for local-network access, distinct from microphone. The first time `URLSession.shared` tries to reach a `192.168.x.x` address, macOS prompts "Allow X to find devices on your local network." Without `NSLocalNetworkUsageDescription` in the bundle's Info.plist, the prompt never appears and the request fails with `NSURLErrorNWPathKey=unsatisfied (Local network prohibited)`. Same applies to `NSBonjourServices` for advertising which mDNS services we discover. Both added.

### 2. `NWListener` was binding to nothing

I'd written `params.requiredLocalEndpoint = .hostPort(...)` to constrain the listener to a specific LAN interface. **That property is for outbound `NWConnection`, not for `NWListener`** — it specifies the local endpoint a connection should use, not where a listener should bind. The listener silently went into `.ready` state without actually binding the port. Curl from the Mac to its own IP returned "connection refused." Fix: standard `NWListener(using: params, on: port)` which binds the port across all interfaces. We rely on the LAN being a trusted segment; the binding-to-specific-interface refinement is a separate future concern.

### 3. DIDL-Lite metadata produced UPnP error 714

I'd dutifully built a DIDL-Lite XML envelope with `protocolInfo="http-get:*:audio/aacp:*"` and passed it as `CurrentURIMetaData` in the `SetAVTransportURI` SOAP call. Sonos rejected with UPnP error 714 ("Illegal MIME type"). Tried `audio/aac`, `audio/mp4` — same error. Lifted to the user's intuition: yesterday's SomaFM SOAP call had **empty** metadata, and worked. Restored empty metadata. The `x-rincon-mp3radio://` URL scheme is Sonos's "continuous radio stream" hint and supplants the need for explicit DIDL-Lite for our use case.

### 4. Chicken-and-egg: pump-before-SOAP

**The load-bearing fix.** Sonos's `SetAVTransportURI` handler performs a **live stream validation** — it opens the HTTP URL we just gave it and expects to see real audio bytes within ~5 seconds. If no audio arrives, the SOAP call times out from the Sonos side with `NSURLErrorTimedOut` (-1001) on our side.

Our pre-fix order was: SOAP call → wait for SOAP success → start audio pump. That deadlocks because:
1. We call `setAVTransportURI(url)` and `await` the response
2. Sonos opens TCP to our HTTP server, receives our 200 OK headers, waits for audio
3. Our pump task hasn't started yet (we're still inside the `await`)
4. After 5 seconds, Sonos times out the SOAP response
5. We see "timeout" on our side and tear everything down

The fix: **start the pump task before the SOAP call.** Audio bytes are queued in the server immediately. When Sonos opens its validation connection and gets registered, the next `append()` (within ~21 ms = one AAC frame) pushes bytes to it. Validation succeeds, SOAP returns, music plays.

Order now in `SonosSession.run`:
1. Start capture
2. Start encoder
3. Start HTTP server
4. **Start pump task** (encoded AAC bytes flow into server immediately; no-op for empty connection list)
5. `setAVTransportURI` SOAP call
6. `Play` SOAP call
7. Wait until cancelled
8. Teardown

### Side-finding: stale TCC entries from prior rebuilds

The Local Network privacy panel showed **two** `SuperAudio` entries, both toggled on. macOS TCC tracks bundles by code-signing identity, and ad-hoc-signed builds get a per-binary-hash identity. Every `Scripts/build_app.sh` produces a new hash → a new TCC entry. Both being "on" works because the OS uses the current-hash entry. `tccutil reset All com.davidpuerto.SuperAudio` cleans up the stale ones. Long-term solution: paid Apple Developer cert with stable code-signing identity, which lands with M7 pre-launch hardening.

### What's verified now

- ✅ AirPlay 1 → B&W A5 audible
- ✅ AirPlay 1 → B&W A7 audible
- ✅ **Sonos → Den audible (this commit)**
- ✅ Play All button starts all three simultaneously
- ✅ TCP RTSP teardown via SIGTERM handler
- ✅ Sonos SOAP `Stop` on app quit
- ✅ Lossless Mode bit-exact verification passes
- ✅ Menu UX: checkmark + pulsing icon + per-sink toggle

### What remains for M3 hardening 2/N

- 30-minute soak test on all three speakers
- `et=1` (AES) compressed-ALAC verification on B&W
- Sonos floor offset slider (M5 work — addresses the ~200–500 ms Sonos lag vs B&W)

---

## 2026-05-15 — Room Tuning (M11) architecture — decisions captured ahead of build

Captured tonight in a wind-down discussion so the architecture isn't re-derived from scratch when M11 starts. None of this is code yet; all of it is committed direction.

### 1. The moat is **cross-protocol** tuning, not the tuning itself

Sonos Trueplay only tunes Sonos. Apple's "Audio Calibration" only tunes HomePods. Every existing room-correction product is locked to one ecosystem because the vendor only controls one audio pipeline. **We own the pipeline pre-encoder for every protocol we support** — so one calibration sweep can produce a different EQ for each speaker in the room (A5, A7, Sonos Den) and apply it transparently before ALAC/AAC encoding. Nobody else can do this without abandoning their walled garden.

This is the load-bearing reason Room Tuning is a flagship feature and not a nice-to-have: it's the one capability that is **structurally impossible** for incumbents to ship without rebuilding their business.

### 2. Mic source: iPhone primary, Mac mic deferred

**Decision:** iPhone-as-mic is the primary M11 path. Mac-mic-only is dropped from M11 scope (re-evaluate post-M11 if users ask).

**Why:** the iPhone has a known ADC profile, a known mic frequency response (Apple publishes a calibration curve for the bottom mic), and reasonably consistent DSP latency. MacBook internal mics vary wildly by model (M1 Air vs M4 Max have different mic arrays and different DSP) — calibration would need a per-model correction table we can't realistically maintain. **Resolves the "Open questions" entry below.**

**How to apply:** M11 begins with the iOS companion (M10) already in place. The iOS app captures the sweep, ships frequency-response data to the Mac over the same Bonjour+WebSocket channel M10 uses for transport control, the Mac computes the EQ filters and stores them per-sink.

### 3. EQ topology: parametric, not FIR

**Decision:** 5–7-band parametric EQ per sink (peaking filters + low/high shelves). Not FIR convolution.

**Why:**
- **Latency.** A 4096-tap FIR at 44.1 kHz is ~93 ms of group delay. That adds on top of the protocol latency (B&W ~88 ms, Sonos ~200–500 ms) and the system-tap → encoder pipeline (~40 ms). Parametric biquads are zero-added-latency.
- **CPU.** A 7-band parametric chain is ~25 multiplies per sample per channel. FIR is ~4000. We're running N parallel pipelines (one per active sink); parametric scales linearly, FIR doesn't.
- **Quality is sufficient.** Below ~500 Hz, the room dominates and parametric correction with a few well-placed peaking filters handles 90% of the problem. Above 500 Hz, the speaker's own DSP has already shaped the sound and we don't want to fight it. Parametric is the right tool for what we're actually trying to fix.
- **Editable.** A user (or a future "advanced mode") can hand-tune parametric bands; FIR coefficients are opaque.

**How to apply:** filter coefficients live as `[Biquad]` per sink, computed on the Mac after the sweep. Applied in the mixer slot (next decision) before the per-sink encoder.

### 4. Test signal: log-frequency sweep, not MLS or pink noise

**Decision:** ~20-second log sweep, 20 Hz → 20 kHz, single channel at a time per speaker. Two sweeps per speaker (one L, one R), so a 3-speaker calibration is ~2 minutes total.

**Why:** log sweep + deconvolution (Farina method) gives the cleanest impulse response in a noisy real-world room. MLS is more compact but assumes a quiet, anechoic-ish space we won't have. Pink noise is too coarse for the high-Q corrections we need to identify. Log sweep is what REW, ARTA, and every serious acoustic-measurement tool uses; we don't need to invent.

**How to apply:** the sweep is generated on the iPhone (or pre-baked as a WAV in the iOS app bundle), played through each target speaker via the existing protocol path (this is critical — we measure the **full pipeline**, not the speaker in isolation), recorded by the iPhone mic, sent to the Mac for deconvolution.

### 5. Where the EQ slot lives: in the mixer (M5), not in any protocol module

**Decision:** the per-sink EQ stage lives in `SuperAudioCore.Mixer`, applied between the shared capture and the per-sink encoder. Protocol modules (`SuperAudioAirPlay1`, `SuperAudioSonos`) **do not know that EQ exists.**

**Why:** EQ is a property of the **listener position relative to a specific speaker**, not a property of the transport. If a user puts the A5 in a different room next year, the EQ travels with the A5, not with AirPlay 1. Putting EQ in the protocol module would couple unrelated concerns and break the addon model (every new $5 protocol addon would need to re-implement EQ).

**How to apply:** the mixer's per-sink slot has the signature `(AudioChunk) -> AudioChunk`. Today it's the identity function. M5 ships it as identity. M11 lands the parametric filter chain in that exact slot, no other code changes. **This is the architectural reason M5 must precede M11** — the slot doesn't exist until the mixer does.

### 6. Deferred to post-M11

These came up in the discussion but are explicitly **not** in M11 scope:
- **Real-time recalibration** (continuously listen and adjust). Too complex; sweep-and-store is enough.
- **Multi-listener mode** (calibrate for a couch, not a single point). Would need multiple sweeps from different positions and averaging. Useful, but a v2 of Room Tuning.
- **Subwoofer crossover management.** None of the M11 target speakers (A5, A7, Sonos Den, future B&W Zeppelin) have separate subs. Re-evaluate when a household with discrete subs is in scope.
- **Sharing calibrations between households** (cloud-stored EQ profiles for known speaker models in known room sizes). Privacy stance says no cloud; a manual export/import is the most we'd add.

### 7. Engineering scope (rough)

~2 weeks of M11 work, gated on M5 (mixer slot) and M10 (iOS companion as mic surface). Breakdown:
- 3 days: sweep generation + deconvolution + impulse response → frequency response math
- 3 days: parametric filter optimizer (least-squares fit of N peaking filters to the inverse magnitude response, with a max-gain limiter so we don't blow tweeters)
- 2 days: iOS calibration UI (countdown, "stand at the listening position", sweep visualization)
- 2 days: Mac side storage + apply UI (per-sink EQ on/off toggle, "recalibrate", visualization)
- 2 days: real-world testing in actual rooms with all three speakers

### Open question removed

The M11 mic-source question above is now answered. The Hub Stick OS-image question remains open and unchanged.

---

## 2026-05-15 — Device Profile System + Claude Skill onboarding (a third moat-grade capability)

Captured in a wind-down conversation right after the M3+M4 audible-test passed on all three speakers. The framing emerged from the user asking the right question: "there's so many brands and types of speakers — how are we going to support all this? Claude Skill crowdsource to the community and upload to a DB when it works?"

The instinct was correct. The framing below resolves it without breaking the privacy stance.

### The problem this solves

The audio-device universe is enormous and our engineering does not scale. AirPlay 1 alone is 30+ models from 12 brands across 10 years of firmware revisions, each with quirks (B&W A7 silently drops verbatim ALAC — that finding took a full night). Sonos has 20+ generations. Chromecast / Cast-licensed soundbars are in the hundreds. DLNA is thousands. **We cannot reverse-engineer every speaker.** Any plan that depends on us doing so caps SuperAudio's supported-hardware list at whatever our engineering can clear, which is the same scaling failure every walled-garden incumbent has — just sized down.

### The solution: two layers

The naive idea ("upload device profiles to a cloud DB") **violates CLAUDE.md's privacy stance** ("no telemetry, no cloud anything"). Splitting the idea into two independent layers resolves the tension.

#### Layer 1 — Device Profile System (the substrate; ~M9.5 / M10.5)

A JSON schema describing per-device specifics:
- Protocol family (AP1 / AP2 / Cast / UPnP / DLNA / Bluetooth)
- Codec parameters (ALAC mode: compressed-required vs verbatim-allowed, AAC profile, etc.)
- Handshake quirks (e.g., "B&W A7 needs Content-Length on ANNOUNCE", "Sonos Playbar gen 1 rejects DIDL-Lite metadata, use empty metadata + x-rincon-mp3radio")
- Timing tolerances (RTP sync packet cadence, RTSP keepalive interval)
- Volume scale + protocol-to-percent mapping
- Known firmware gotchas in free-text form (string field, not interpreted)

**The "database" is a public MIT-licensed GitHub repo** — working name `superaudio-device-profiles`. Same pattern as Homebrew formulae, CUPS PPDs, mpv configs, yt-dlp extractors. Profiles are **pure data**, JSON-schema-validated, **no executable code**. This is load-bearing for security: a malicious profile cannot pwn the user because the loader is a JSON parser, not an interpreter. The app pulls updates via git on demand (or bundles a snapshot for first launch and offline use). **No server. No telemetry. No DB. Just git.**

Built-in profiles ship with the app for our explicitly-tested speakers (B&W A5, B&W A7, Sonos Playbar gen 1, Apple AirPort Express). The app also loads any profile from `~/Library/Application Support/SuperAudio/Profiles/`, so power users can hand-edit and test before submitting upstream.

#### Layer 2 — Claude Skill onboarding wrapper (the UX multiplier; ~M14)

A `/onboard-speaker` skill (distributed via Anthropic's Skill surface if/when that's the right channel; or shipped as a local skill in the app's bundle) that:
- Probes the user's LAN for unknown devices (`dns-sd -B`, SSDP `M-SEARCH`)
- Captures a clean handshake against the discovered device via `tcpdump` (with user consent for the elevated privilege)
- Pattern-matches the wire traffic against known protocols (AP1 / AP2 / Cast / UPnP / DLNA)
- Drafts a `DeviceProfile` JSON
- Walks the user through testing each capability (play, stop, volume, sync)
- If everything passes, **opens a GitHub PR via `gh` CLI** with the profile pre-filled, asking the user to confirm before pressing submit

**The skill runs entirely on the user's machine.** Nothing leaves their LAN until they explicitly choose to upload the PR. The Claude inference is local-assistance, not a phone-home channel. This is the line that preserves the privacy stance: a Claude Skill is a tool the user invokes; it is not a telemetry agent.

### Why this is moat-grade (a third structural advantage)

This belongs in §6 of `COMPETITIVE_LANDSCAPE.html` (the Moat section) as a third structural-tier capability, alongside cross-protocol fan-out and cross-protocol Room Tuning. **The walled-garden incumbents structurally cannot crowdsource device support** — Sonos, Apple, Google sell the "we control the ecosystem" promise, and accepting community profiles for competitor devices contradicts that promise. They could pivot, but only by repudiating their business model.

We have no such constraint. **Our supported-hardware growth is not gated by our headcount.** That's a property of our architecture (per-protocol modules + data-driven profiles) that emerges naturally from being protocol-agnostic from day one.

There is also a **marketing-story** angle that's genuinely novel: "use an AI skill to widen device support without scaling the engineering team" is the kind of pitch that lands on Hacker News or The Verge. It's secondary to the structural moat but is worth being honest about — when Layer 2 ships, it becomes a quotable hook.

### Why this order (Layer 1 first, Layer 2 later)

Layer 1 is **high-value on its own** even without Layer 2:
- It's a refactor of things we currently hard-code into protocol modules into swappable data.
- A community member with Wireshark and patience can submit profiles by hand from day one.
- It unblocks "I bought a $30 used B&W Zeppelin Air, does SuperAudio support it?" with "Probably — drop the profile in this directory."

Layer 2 depends on the Layer 1 schema being stable, so it slots later. Layer 2 is also the **flashier** layer, and shipping it without the substrate makes it look like a demo rather than a system.

### Roadmap impact

A new milestone needs to land between M11 (Room Tuning) and M13 (Hub Stick), or between M9 (Apple TV companion) and M10 (iOS companion):

- **M9.5 / M10.5 — Device Profile System.** Refactor `SuperAudioAirPlay1` and `SuperAudioSonos` to read protocol specifics from a `DeviceProfile` JSON loaded by `SinkRegistry`. Define the JSON schema. Seed the repo with the four profiles we have engineering-verified hardware for. Public repo lives at `github.com/davidpuerto/superaudio-device-profiles` (or similar; final naming when shipped). Add a `superaudio profiles update` CLI command + an in-app "refresh device support" menu item.
- **M14 — Claude Skill onboarding.** Build the `/onboard-speaker` skill. Distribute via Anthropic's Skill surface if available; otherwise ship as a bundled skill in the app's resources. Default UX: user clicks "I have a speaker SuperAudio doesn't recognize," walks through the skill, and ends with either a working profile in their local override directory + an open PR.

ROADMAP.md should be updated to insert these. Not done in this pass — flagging here.

### Open questions (resolve before the affected sub-task)

- **Profile signing model.** Do we sign every merged profile (Ed25519, key in the app bundle, profiles validate against signature)? Or trust the GitHub-PR-review process and ship unsigned? Signing protects against repo compromise; unsigned is simpler. Lean signed but it adds a key-management surface. Decide before M9.5 ships.
- **Schema strictness.** How tightly does the JSON schema lock down each protocol's field set? Too loose and contributors can submit profiles that crash the loader; too strict and we have to ship schema migrations every time a new protocol quirk surfaces. Lean medium-strict + version field + non-breaking-additive evolution.
- **Anonymization of submitted captures.** When Layer 2's skill auto-fills a PR, does it strip user-identifying fields from the wire capture (Apple ID device names, Bonjour advertised hostnames, MAC addresses)? **Yes, by default. Always.** Mention this explicitly in the skill prompt + PR template so users see we're treating their data with the care the privacy stance demands.
- **Bootstrap.** How do we seed the repo with profiles for popular speakers we don't own? Two paths: (a) ask the beta community to contribute via the skill itself once it ships; (b) lift wire-format insights from existing reverse-engineering writeups (shairport-sync issue tracker, SoCo, OwnTone, AirConnect — all permissively licensed sources we're already allowed to read). Both. (a) scales; (b) bootstraps.

---

## 2026-05-15 — Strategy threads, decisions deferred (Device Profile System + Claude Skill)

Recorded immediately after the "let's talk strategy" conversation that followed the M3+M4 audible test. These are **strategic threads worth pulling on**, not yet committed decisions. Captured here so they don't decay. Each thread names its leverage, the counter-argument, and the decision trigger.

### Thread 1 — Resequence: ship the Device Profile System earlier, make the Claude Skill the launch hook

**Today's slot:** Layer 1 at ~M9.5/M10.5 (after iOS companion), Layer 2 at ~M14.

**The thread:** the Claude Skill is the strongest *novel* marketing story we have. "**Your AirPort Express still works. Your $1500 B&W from 2013 still works. Use Claude Skill to onboard any speaker.**" is a Hacker News / Verge headline in a way that "lossless AP1 renaissance + cross-protocol fan-out" technically is but emotionally isn't. Being first matters — the press window for "consumer-facing app uses AI Skills to onboard hardware" is real but finite.

**Proposed resequence:** Layer 1 substrate lands at M5–M6 (refactor we'd benefit from internally anyway). Layer 2 Skill becomes the **M8 public-beta launch hook** instead of an M14 polish feature.

**Counter-argument:** Layer 2 without ~20 seed profiles in the repo will look like a demo. We need substrate + bootstrapped profile coverage *before* the Skill earns its press cycle. Lifting from shairport-sync / SoCo / OwnTone / AirConnect (permissively licensed sources we're already allowed to read) is the bootstrap path; could plausibly seed 15–20 profiles in 2 weeks of focused work.

**Decision trigger:** revisit during M5 architecture. If the mixer-slot work surfaces a clean place for `DeviceProfile` to plug in, resequence formally; if it'd require fighting the architecture, leave at M9.5.

### Thread 2 — Partner with second-tier audiophile brands

**The thread:** the walled-garden incumbents (Sonos, Apple, Google) can't partner with us — accepting our cross-protocol pitch contradicts their lock-in. But there's a **second tier** that has no walled-garden incentive because they don't sell software platforms:

- **B&W, Naim, Marantz, McIntosh, KEF, Pioneer (audiophile line), NAD, Bluesound's older S1-frozen kit.**
- All of them sold premium AP1 / older-Sonos hardware between 2008–2017.
- All discontinued those product lines.
- All have aging install bases they cannot serve anymore.
- All have emotional, expensive customer bases whose hardware Apple has effectively obsoleted.

**The play:** each brand is a potential partner who wants their install base alive. They give us profile validation + co-marketing; we give them "your customers' $4000 speakers still work, here's the app." Marketing co-op: "B&W recommends SuperAudio for legacy AP1 speakers."

**Why this is unusual:** $19 indie apps don't usually get this kind of partnership availability. It's available because the walled-garden incumbents have abandoned this segment and the second-tier brands have no defensive reason to refuse.

**Decision trigger:** post-M8 public beta, when we have a working app to demo. Outreach order: B&W first (we're already using their hardware as reference; cleanest narrative), then Naim, then KEF. If first contact lands well, expand. If it doesn't, drop it — the strategy doesn't depend on partnerships landing.

### Thread 3 — Anthropic Skills as a discovery channel

**The thread:** SuperAudio has zero brand awareness, zero marketing budget. The Claude Skill (Layer 2) creates a discovery surface that didn't exist before:

- If/when Anthropic ships a public Skills marketplace, "speaker onboarding" is a real, useful, searchable skill.
- Anyone with an unsupported AirPlay speaker searching for help finds us.
- Free top-of-funnel that costs us nothing.
- For Anthropic: we're a real-world demo of Skills doing something hardware-adjacent and consumer-facing — they want those case studies.

**The play:** when Layer 2 ships, reach out to Anthropic DevRel directly. Offer to be a launch-partner case study for whatever Skills surface ships next. Mutual benefit; costs us nothing.

**Risk:** dependency on Anthropic's roadmap and policies. If they decide tcpdump-via-skill is too sensitive a surface, the Skill stops working or has to ship without the network-capture feature.

**Mitigation:** ship the Skill as an in-app feature first (bundled with the Mac app's resources, runs locally via Claude Code if installed, or in-process if not). Marketplace distribution is **bonus, not load-bearing**.

**Decision trigger:** when Layer 2 is ~2 weeks from shipping. Until then, design with marketplace distribution in mind but don't depend on it.

### Thread 4 — Substrate-open / app-paid (Tailscale pattern)

**The thread:** make the **device-profiles repo fully open MIT**. Keep the **app itself paid** at $19. Same model as:

- **Tailscale**: free WireGuard open-source, paid coordinator + UX
- **Mozilla VPN**: free Mullvad open-source backend, paid app
- **Plex**: paid app over open ffmpeg
- **1Password**: paid app over open cryptography

**Why this works for us:**

- **Open repo = community engagement.** GitHub stars as social proof. Contributors as evangelists. Public press surface (HN, /r/audiophile, audiophile blogs all amplify open repos more than closed apps).
- **Paid app = revenue + the UX that monetizes.** People pay for the menu bar, per-sink volume, Room Tuning, Lossless Mode — not for JSON parsing.
- **Defensible against forks.** Someone forks the repo? Great, they're improving our substrate. Someone forks the *app*? They have to rebuild everything around the substrate that already exists.

**Subtle moat-deepening effect:** an acquirer inherits the community asset, not just the codebase. Sonos / Apple buying us means inheriting a community that cares about *non-Sonos / non-Apple* devices — that's worth more than the engineering team.

**Counter-argument:** open-source maintenance has its own cost (issue triage, PR review, contributor relations). If the repo gets popular, that's a real time sink. Mitigation: heavy reliance on JSON-schema validation + CI to auto-reject malformed PRs; CODEOWNERS file routing PRs to whoever owns the relevant protocol.

**Decision trigger:** **before Layer 1 ships.** This affects how the schema and loader are designed (license headers, attribution discipline, contributor sign-off). Decide alongside the M5–M6 substrate work.

### Threads recorded but not led on yet

- **Hub Stick + profile repo synergy (M13).** Same profile system → Hub Stick gets device-support updates by pulling from the same git repo on each boot. Effectively "device support updates" without firmware bumps.
- **Contributor flywheel mechanics.** Hall of Fame / profile attribution in the app's About box / "Profile contributed by @username" footer in the menu when an unfamiliar device is in use. Cheap, high-signal community engagement.
- **Long-tail support strategy.** ~10 first-class hardware-verified devices + a medium-quality long tail (mpv / yt-dlp / Homebrew model). Best-in-aggregate beats best-per-device for niche hardware.
- **"Verified by SuperAudio" certification badge.** Counter-FUD move if Sonos/Apple ever publicly question third-party profile reliability. Profile metadata field `verified_by: superaudio | community | unverified`. Surfaced in the app's device picker so users see which devices we've personally tested.

### How to use this entry

These threads were **scaffolding for future decisions, not decisions themselves**, when first written. As of the next entry below, **all four threads are now committed direction** — promoted into the roadmap.

---

## 2026-05-15 (later) — Strategy threads PROMOTED: all four committed direction

User confirmed, immediately after writing the strategy-threads entry above: *"let's keep on keeping on … document everything add to roadmap"* and *"carry out everything as you recommended with crowdsourcing the repo the download calling B&W and Sonos and Anthropic, etc."*

This entry promotes all four threads from "deferred" to **committed roadmap direction.** The deferred entry above is preserved for the reasoning trail; do not delete it.

### What's committed

**Thread 1 (resequence) — COMMITTED.** Device Profile System lands at **M5.5** (between Multi-sink M5 and Polish M6). Claude Skill ships at **M6.5** (before pre-launch hardening M7). M8 public beta launches with the Skill as the headline. Concrete plan in `docs/ROADMAP.md` M5.5 and M6.5 entries.

**Thread 2 (audiophile-brand partnerships) — COMMITTED as a parallel track.** Engineering does not depend on it landing. Outreach starts during M7 with B&W (cleanest narrative — we use their hardware as primary test platform), then Naim, then KEF/Marantz/McIntosh/NAD staggered. Abandonment trigger: no response within 4 weeks of first three contacts. Tracked in `docs/ROADMAP.md` "Parallel tracks → Partnership outreach."

**Thread 3 (Anthropic Skills outreach) — COMMITTED as a parallel track.** DevRel outreach starts when M6.5 ships (Skill alpha is testable). Risk hedge: ship the Skill as a bundled in-app feature first; marketplace distribution is bonus, not load-bearing. Abandonment trigger: no Anthropic response within 6 weeks OR no Skills marketplace within 12 months of M8 launch — Skill still works without the marketplace, we just lose the discovery channel. Tracked in `docs/ROADMAP.md` "Parallel tracks → Anthropic Skills outreach."

**Thread 4 (substrate-open / app-paid, Tailscale pattern) — COMMITTED.** Device-profiles repo is **fully open MIT** on GitHub. App stays **paid at $19**. Decision is binding for M5.5 architecture (license headers, attribution discipline, contributor sign-off). Tracked in `docs/ROADMAP.md` M5.5 entry.

### Why these commitments don't break the privacy stance

The privacy stance (CLAUDE.md: "no telemetry, no cloud anything") was the hardest constraint to honor while still shipping a crowdsourced device-support system. Both committed designs honor it:

1. The "database" is a **public git repo**, not a server we operate. Public-PRs-to-an-MIT-repo is **publishing**, not telemetry. Users contribute by opening a PR with their consent; the app pulls updates via git on the user's explicit action.
2. The Claude Skill **runs entirely on the user's machine**. Nothing leaves their LAN until the user clicks "submit" on the PR. The Claude inference is local-assistance, not a phone-home channel.

The bar for any future addition is the same: if it can't honor "nothing leaves the user's LAN without their explicit consent," it does not ship.

### Roadmap impact summary

| Old slot | New slot | Notes |
|---|---|---|
| Device Profile System: ~M9.5 / M10.5 | **M5.5** | Substrate becomes a launch-blocking milestone, not a post-launch addition. |
| Claude Skill: ~M14 | **M6.5** | Skill becomes the M8 launch headline. |
| Substrate license: undecided | **Open MIT** | Affects M5.5 architecture (license headers, contributor model). Decided. |
| Partnerships: not on roadmap | **Parallel track during M7** | New section in ROADMAP.md. |
| Anthropic outreach: not on roadmap | **Parallel track starting at M6.5 ship** | New section in ROADMAP.md. |

### What's still deferred (the four "threads recorded but not led on yet" from the prior entry)

The four bullets in the "Threads recorded but not led on yet" section of the previous entry — Hub Stick + profile repo synergy, contributor flywheel mechanics, long-tail support strategy, "verified by SuperAudio" badge — remain captured but are NOT yet promoted. Most will land naturally during M5.5 / M6.5 implementation (the contributor recognition is already in the M5.5 milestone, for example). Revisit at the end of M6.5.

---

## 2026-05-15 (night) — M5 completion: per-sink offset slider, A7 cold-start root cause, mid-stream auto-reconnect

Three wins from a focused evening session, captured here so the lessons don't decay. The corresponding code is in commits `bee2a4e` and `7869299`.

### 1. M5d — per-sink manual offset slider (0–500 ms)

**The problem.** M5c gave us sample-accurate sync *within* AirPlay 1 (A5 + A7 lock to the same wall-clock anchor via per-chunk NTP). But Sonos's intrinsic 200–500 ms buffer-floor lag is unfixable from the sender side — its protocol has no per-packet timing channel. To get all three speakers in *audible* sync, AP1 sinks need to be delayed to match Sonos.

**The solution.** Per-sink user-tunable delay (0–500 ms, 5 ms step) added on top of the existing chunk-anchored sync NTP. `SessionState.sinkOffsetsMs` dict, `setOffset(_:, for:)` writes to UserDefaults + dispatches to a live setter parallel to volume. `RTPSender` gains `public var manualOffsetSeconds: Double` — sync packet NTP pre-roll becomes `0.2 + manualOffsetSeconds`. Live slider drags propagate to active sessions within ~1 s (next sync emission).

**Sonos slider is disabled, intentionally.** No protocol mechanism to shift Sonos earlier. The tooltip explains: "Sonos's timing is fixed by its protocol — push AP1 sliders UP to match Sonos's natural lag instead." Sonos's slider stays visible (so the UI has consistent shape) but greyed out.

**Verified live.** User reached audible sync at A7=+160 ms, A5=+250 ms with Sonos at 0. Slight per-room variance is normal — different speaker positions/firmware revisions have slightly different internal latency. The slider lets the user tune empirically.

**Future work (M5e? deferred):** an "auto-align" mode that measures actual playback latency via mic feedback and sets the offsets automatically. Could overlap with the M11 Room Tuning iPhone-mic infrastructure.

### 2. A7 cold-start RTSP timeout — root cause was a shared Client-Instance, not firmware

**The bug.** B&W A7 consistently dropped the first RTSP connection attempt when launched alongside A5 via Play All. A5 always connected first try; A7 only succeeded on a second click. Three "RTSP timed out" failures captured in OSLog over a 50-minute window with zero for A5 in the same window.

**My initial hypothesis (wrong).** I spent 30+ minutes speculating about "B&W firmware cold-start quirks," planned a retry-with-200ms-backoff mitigation, and was about to ship it as a workaround.

**The user's hypothesis (correct).** They asked: *"could it be dropping because it THINKS it's already connected (a7) when A5 picks up?"* — pointing at protocol-level identifier collision rather than firmware lottery.

**The actual cause.** `RTSPClient.staticClientInstance` was declared `private static let`. Every `RTSPClient` in the app process shared the *same* random 8-byte hex identifier as both `Client-Instance` and `DACP-ID` headers. When A5 and A7 sessions connected simultaneously with the same controller ID, the receivers' firmware tracked them as a single controller's state — and one of them (consistently A7 in our test bench) refused to fully wake on the cold attempt because it thought a stale prior session with the same identifier was still active.

**The fix** — one-line: `private static let` → `private let`. Each `RTSPClient` instance now gets its own random ID. A5 and A7 sessions are seen as fully independent controllers by their respective speakers. Confirmed working on the very next test attempt.

**The lesson** — saved to memory + reinforced in the working norms: when the user proposes a hypothesis grounded in protocol semantics, **check the code immediately**. Don't dismiss with "each speaker is independent." The grep that revealed the bug took 30 seconds; my speculation cost ~30 minutes. See `memory/feedback_check_logs_first.md` for the broader rule.

**Implication for future protocol work.** Any protocol that uses per-controller identifiers (RAOP `Client-Instance`/`DACP-ID`, AP2 `Active-Remote`, anything that names "the controller") **must be scoped per-RTSPClient/per-session, not per-process**. Apple's iTunes is one controller with many speakers (single Client-Instance is correct there). SuperAudio's model is each session = independent controller; sharing identifiers across sessions confuses receivers.

### 3. AP1 mid-stream auto-reconnect — health monitor pattern

**The gap.** With Client-Instance fixed + 2-attempt retry + 4-min keepalive, *cold-start* connection failures are well-mitigated. But *mid-stream* network blips (Wi-Fi router reboot, speaker temporarily off, etc.) silently produce dead-air playback: RTP UDP is fire-and-forget so we don't notice the receiver stopped getting packets, and the idle RTSP TCP socket has no traffic to fail on.

**The pattern.** Detached health-monitor `Task` inside `AirPlay1Session.run` sends `OPTIONS` over the existing RTSP TCP socket every 10 s with a 3 s timeout. On failure or non-OK response, it sets a shared `HealthFlag.lost = true` and exits. The main wait loop's while condition includes `&& !healthFlag.lost`, so the session unwinds cleanly the moment the flag flips.

**`run()` returns `Bool`** — true means "caller should auto-reconnect," false means clean exit (user-cancelled, duration expired, or handshake exhausted retries). `SessionState.toggle`'s AirPlay1 case loops `run()` up to 2 attempts; failure beyond that surfaces via the existing red ❌ failure UI.

**Why `HealthFlag` as a class** — the flag is mutated from a detached `Task` and read from the parent run() body. A class lets both reference the same storage. Bool writes are word-sized and atomic in practice on Apple silicon; eventual visibility (no strict happens-before required) is sufficient for our 10 s polling cadence.

**Verification deferred** — clean network = nothing to test. The next time a real-world Wi-Fi blip hits a live session, logs will show `Health check failed on <speaker> — flagging network loss` → `◆ Network loss detected on <speaker> — exiting session for auto-reconnect` → `Auto-reconnect for <speaker> — attempt 2/2 after mid-stream network loss` → fresh handshake → audio resumes. If it doesn't work, that's the iteration cycle.

### What's now closed on the M5/M6 fronts

- ✅ M5 — shared `AudioBroadcaster`, sample-accurate cross-sink sync via per-chunk wall-time NTP, A7 cold-start root cause fixed, failure UI, per-sink volume + offset sliders, Quiet Mode, 2-attempt handshake retry, 4-min OPTIONS keepalive
- ✅ M6 (partial) — speaker groups (save/play/delete named presets, JSON persisted), AP1 mid-stream auto-reconnect via OPTIONS health monitor
- 🟡 M6 remaining — per-source app picker (deferred — invasive `SystemAudioCapture` refactor saved for fresh session), preferences window, real menu bar icon, UserDefaults persistence for offsets (sub-task already implicitly done)
- 🟡 M3 hardening — 30-min soak test still pending (set up for tomorrow when household isn't asleep), et=1 compressed ALAC verification still pending

---

## 2026-05-15 (night) — Cross-platform stance re-evaluated, staying Mac-only through M8

ChatGPT-driven strategic prompt asked whether SuperAudio should be Mac + Windows + iOS rather than Mac-only. Followed up with a GitHub competitor landscape scan and a re-read of the AP1-buyer demographic. Re-affirming the Mac-only commitment in CLAUDE.md and ROADMAP.md's "What we explicitly punt on" list. Logging the reasoning so this isn't re-litigated next time the question comes up.

### The case for going cross-platform (taken seriously)

- Windows is ~70% of desktop market share. Mac-only caps our TAM at ~30%.
- ChatGPT framed "software-defined distributed audio" as the strongest narrative — that frame implies platform-neutral.
- WiiM and Bluesound NODE bridge appliances are platform-neutral by design (network hardware, no host OS lock-in). We compete with them at M13 Hub Stick anyway.
- An eventual SDK / licensing play (Anthropic-Skills-adjacent, distributed-audio-fabric) would benefit from cross-platform credibility.

### The case for staying Mac-only (the winning side)

1. **Premium AP1 install base is heavily Apple-leaning.** B&W A5/A7, Naim Mu-so 1st gen, AirPort Express, Marantz/McIntosh AP1-era kit — these were bought by people who also own MacBooks. The "lossless AP1 renaissance" narrative resonates with the audience that already lives on Mac. Windows expansion broadens TAM but the marginal Windows user has materially different speakers — not the people we're optimized for.

2. **Engineering cost is 2–3× for cross-platform.** Audio capture is platform-specific regardless of UI choice — macOS process tap, Windows WASAPI loopback, Linux PulseAudio/PipeWire. Each path is its own non-trivial integration. The UI layer has three credible options: Swift on Win (limited; no AppKit), shared C++/Rust core + per-platform native UIs (most maintainable; highest effort), or a cross-platform framework (Flutter/Tauri/Electron — loses native feel, larger binaries, weird on Mac). All three multiply maintenance burden permanently.

3. **M8 launch timeline.** Windows expansion adds months minimum to ship. M8 (public beta) is the milestone that proves any of the strategic threads. Better to ship Mac-only and have revenue data than to ship 6 months later with twice the platform coverage and no data.

4. **The Pi Hub Stick (M13) handles the no-Mac case differently — via hardware, not software porting.** Households without a Mac OR an Apple TV buy a $59 Pi Zero 2 W in a case. That's a different distribution problem (hardware fulfillment, certifications) but it's already in the roadmap and doesn't require porting our app.

5. **GitHub competitor research (2026-05-15 evening) confirms no open-source project does our shape on any platform.** Even if a Windows port existed, it wouldn't be competing against a similar open-source equivalent. We're occupying empty space; the question is which empty space to occupy first.

### Decision

**Stay Mac-only through M8 launch.** Re-evaluate post-M8 with three data points:

- Revenue mix: what fraction of inbound interest is from Windows users? If <20%, deprioritize. If >40%, accelerate.
- Hub Stick (M13) adoption rate among non-Mac households — if it sells well, that's evidence the hardware-not-software answer works.
- Competitive pressure: does anyone else (open-source or commercial) ship a Windows-supporting cross-protocol fan-out tool? If yes, our window for staying Mac-only narrows.

**No changes needed to CLAUDE.md or ROADMAP.md non-goals.** Stance is re-affirmed, not changed.

### The "what about iOS?" sub-question

ChatGPT bundled iOS with Windows in the cross-platform pitch. **iOS is different** — already explicitly in our roadmap as M10 iOS companion (free with base app) + M11 Room Tuning (uses iPhone mic). It's not cross-platform in the same sense; it's a companion device that the Mac/Apple TV orchestrator drives. M10/M11 stay where they are in the roadmap.

---

## 2026-05-16 — Platform boundary: consumer app first, SDK/OEM/integration layer deferred to post-M8

Strategic option surfaced by a follow-up ChatGPT exchange + reinforced by the 2026-05-15 GitHub competitor sweep that confirmed our shape doesn't exist anywhere as a unified product. The framing crystallized: SuperAudio's technical value is the **synchronization model + device abstraction layer + latency correction system + interoperability framework** — not the user-facing app. The app is the consumer surface; the layer underneath is potentially platform-shaped.

This entry captures that framing as a deferred decision so we don't lose the optionality, and names the triggers that would resume the conversation.

### The three potential "platform" paths

These are not commitments — they're options that exist because the underlying layer is novel. Each has a different audience, different distribution shape, different revenue model.

**1. OEM ship-pre-installed.** B&W, Naim, KEF, Marantz/McIntosh (the same second-tier-audiophile-brand cohort named in `docs/DECISIONS.md` 2026-05-15 strategy thread 2 partnership outreach) license SuperAudio's sync + protocol-translation engine to ship pre-loaded on their next-gen networked products. They sell hardware; we provide the cross-ecosystem glue that their walled-garden competitors structurally can't. License terms TBD — could be per-unit royalty, per-quarter flat fee, or a co-marketing structure.

**2. Home Assistant / smart-home integration.** Home Assistant's audio integrations are currently fragmented (separate Snapcast, Sonos, AirPlay integrations, each independently maintained). SuperAudio's engine, exposed as a single HA integration or add-on, would unify the audio side of a smart home. Distribution via the HA community store. Revenue model is unclear — HA itself is open-source / nonprofit-anchored; a paid commercial add-on is feasible but unusual in that ecosystem. Worth a conversation with Nabu Casa post-M8.

**3. SDK for other apps.** Other Mac/iOS/desktop apps that want cross-protocol audio fan-out (music players, video editors, podcast tools, broadcast/streaming software) could link a SuperAudio SDK rather than reinventing. Closest analog: Spotify's libspotify era, or the way third-party DAWs license audio engines (e.g., RNNoise, FabFilter). Revenue model: per-seat license or revenue-share. Most speculative path — depends on us identifying ≥2 named integration partners before it's worth building the SDK extraction work.

### Decision

**Stay a consumer app through M8 launch.** No platform work before the consumer product has user data and revenue.

The reason isn't that the platform options aren't real — they are, and the GitHub sweep confirms the technical layer is genuinely novel. The reason is **sequencing risk**: building an SDK / OEM-licensable engine before the consumer product validates the core hypothesis would burn cycles on an interface design we can't yet justify. M8 (public beta + revenue) is the smallest commit that proves "people actually want this." Until that proves out, every hour spent designing license terms / SDK boundaries / Home Assistant integrations is hours not spent shipping the thing that earns those conversations.

### Triggers to resume the platform conversation

Each trigger should reopen this entry with a real decision, not just speculation:

- **M8 revenue clears $X/month for Y months in a row.** Number TBD when M8 ships (we'd want enough to justify a one-person side conversation, probably ~$5K/month sustained). Concrete revenue floor proves the consumer product earned its place.
- **Inbound from a named OEM.** B&W, Naim, KEF, McIntosh, or anyone with a real install base reaches out asking "how can we ship this in our products?" Even one credible inbound is signal worth a meeting.
- **Home Assistant community engagement.** Someone in the HA ecosystem builds an unofficial SuperAudio integration. Proves the demand. We help them upstream it.
- **A serious technical-press article uses "compositional stacks" or equivalent framing** to describe what we do. Means the technical-layer narrative has landed; reasonable to invest in formalizing it.
- **A competitor positions against us at the platform layer.** If Sonos / Apple / a startup explicitly markets a "universal audio fabric" type pitch, we need to respond fast.

### What to capture now (no platform work yet, but cheap option-preservation)

- **Document the layer boundary** in `POSITIONING.html § Technical framing` so the language is ready when an investor or partner asks. Done 2026-05-16.
- **Tag the parts of the codebase that are layer-shaped** (sync model, device abstraction, latency correction, interoperability framework) so we know what we'd extract if SDK extraction becomes the work. Mostly already true via our SPM module structure (`SuperAudioCore` is the layer; `SuperAudioApp` is the consumer surface; `SuperAudioAirPlay1` / `SuperAudioSonos` are the protocol-translation slices). Continue treating Core as the public stable surface.
- **Don't promise the platform externally** until at least one trigger has fired. No "we're a platform" copy on the website; no SDK teasers; no "OEM partners welcome" before we have one. The consumer app is the message until M8.

### What we explicitly DON'T do

- File patents on the sync architecture. Cost is high, cultural fit with our MIT-clean / open-substrate stance is bad, and the actual defensibility of audio-protocol-translation patents is dubious (the wire formats are public, the timing math is published in RTP/NTP RFCs, prior art exists in shairport-sync and Snapcast). Defensive patenting is wrong for our position.
- Build an SDK extraction pass before M8. Same sequencing logic — premature.
- Talk to investors about platform optionality. Even if it's real, leading with "we might one day license to OEMs" pre-revenue is a tell. M8 launch + revenue earns those conversations.

---

## 2026-05-16 — Hub Pro UX vision: HDMI-CEC auto-trigger + remote passthrough + per-source profiles

Drafted during the same night session that produced `website/HUB_DESIGN.html`. Captures the three load-bearing UX elements that make Hub Pro (M14) the "press TV power, audio everywhere" magic-moment product.

### 1. HDMI-CEC + ARC audio-activity dual auto-trigger

Single-trigger approaches fail in real households: HDMI-CEC is notoriously flaky across TV brands (manufacturer-specific flavors — Anynet+, Bravia Sync, Simplink, Viera Link — each implement CEC slightly differently, and some TVs disable it by default). Single-trigger via ARC audio activity is more reliable but misses the rich TV-identification CEC provides.

**Decision: dual-trigger.** CEC for fast trigger + TV identification (lets us auto-pick the right saved profile); ARC audio-activity detection as the redundant backup. If CEC works → richer experience. If CEC fails (or the TV's CEC is disabled) → still auto-trigger via audio bytes arriving, fall back to "last-used profile" until the user manually re-confirms.

### 2. CEC user-control-pressed remote passthrough

The killer feature. Hub Pro registers as the TV's "Audio System" on the HDMI bus. CEC commands the TV sends — `User Control Pressed (Volume Up / Down / Mute / Pause)` — route to us by default. We fan the command out to every active sink in the mesh, **preserving relative balance** (multiplicative scaling, +5% per click of TV remote → A5×1.05, A7×1.05, Sonos×1.05).

**Nobody else does this for a heterogeneous mesh.** Sonos Beam controls only Sonos speakers via TV remote. Apple TV controls only HomePods. WiiM bridges one source to one output. Hub Pro is the only product that makes a TV remote the universal volume control for B&W AP1 + Sonos + HomePod + Cast simultaneously, in sync.

Implementation requires libCEC on Pi CM4. ~2–3 days of focused work once M13 hardware exists.

### 3. Per-source / per-TV profiles

Each TV + HDMI input combination saves its own profile: which speakers to use, what EQ, default volume, per-sink offsets, surround behavior. Auto-detected via CEC's `Set Stream Path` + EDID Vendor Specific Data Block (TV announces make/model). Fallback "what TV is this?" picker on first connection if CEC EDID doesn't resolve.

Profile format reuses our existing JSON-on-UserDefaults pattern from the Mac app's `SessionState` + `SpeakerGroups` (already shipped 2026-05-15 night). Hub Pro firmware extends the same persistence layer; iOS companion (M10) reads/writes the same JSON via the planned Bonjour + WebSocket control channel.

**Decision deferred:** the exact JSON schema for source-profiles. Will land in M5.5 Device Profile System substrate alongside the sink-side profile schema. Single coherent profile language for both sides.

### Decision triggers (when to resume detailed design)

- **M11 Room Tuning ships** — gives us the iPhone-mic infrastructure that surfaces the per-source-profile UX naturally
- **M13 Hub Stick prototype hardware exists** — CEC integration becomes testable on real hardware, not theoretical
- **First inbound from a TV manufacturer** — would change our priority (e.g., Sony or LG asking about a partnership pre-installation deal)

Status: framework captured in `website/HUB_DESIGN.html` §3. Implementation deferred until M14 build phase. No code shipped tonight.

---

## 2026-05-16 — Hardware sizing decisions: Pi Zero 2 W for Hub Stick, Pi CM4 for Hub Pro

Captured here so the analysis isn't re-derived next time the question comes up. Full tables + per-board reasoning in `website/HUB_DESIGN.html` §4.

### Hub Stick (M13, $59 retail): Pi Zero 2 W with accepted sizing risk

**Pick:** Pi Zero 2 W (quad ARM A53 @ 1 GHz, 512 MB RAM, 2.4 GHz Wi-Fi 4, ~$15). Total BOM $35–45. Fits the $59 retail with healthy margin.

**Accepted risk:** 2.4 GHz Wi-Fi 4 is tight for 5+ sink households on congested networks. Median 3–4 sink household: comfortable. 6+ sinks: glitches likely.

**Hedge:** "Hub Stick Plus" at $99 retail on Pi 5 (2 GB) as a planned post-M13 upsell SKU if real-world testing surfaces glitches at 4+ sinks. Decision deferred until benchmarking against actual user setups.

**Why not Pi 4 (2 GB) at $35:** would blow the $59 retail by ~$5–10. Could absorb by raising retail to $69, but the $59 round number has marketing value and the median household doesn't need Pi 4's headroom.

### Hub Pro (M14, $249 retail): Pi CM4 (4 GB Lite)

**Pick:** Pi Compute Module 4 with 4 GB RAM, Lite (no eMMC — we add our own 32 GB eMMC on the carrier board). $25–30 module + ~$40 carrier board = ~$70. Plus HDMI receiver chipset (Realtek RTD2173, ~$15), TOSLINK input (CS8416 + CS5341 ADC, ~$3), 32 GB eMMC (~$8), antennas + connectors + case (~$10–15). **Total BOM ~$100–115.** Leaves $130–150 margin at $249 retail.

**Why CM4 over CM5:** CM5's A76 cores are nice but our workload (audio fan-out + protocol translation + lightweight DSP) doesn't need them. The $30–45 BOM premium burns margin we'd rather keep. Revisit if/when M14 v2 ships Atmos passthrough — that's CPU-heavier (real-time DD/DTS-HD decode + multi-channel routing).

**Why not Pi 5 (2 GB) at $50:** uses a non-CM form factor; the SBC form factor isn't designed for industrial-mount carrier-board integration. CM4 + custom carrier is the standard pattern for embedded products in this category.

**Why not Adafruit's own hardware:** Adafruit's Feather / ItsyBitsy / Metro lines are microcontroller-class (ESP32, RP2350, ARM M0/M4). Wrong tier — we need a Linux-running SBC for our Swift + audio-encoding workload, not a microcontroller. Adafruit *resells* Pi which is fine; their own boards don't fit.

**Why not Allwinner / Rockchip generic SBCs:** Swift-on-Linux support is meaningfully worse off-Pi (the Swift team's first-class Linux target is Ubuntu on x86; ARM Pi is well-supported community-tier; everything else is community-experimental). FCC/CE cert reuse from the Pi chipset is also a real efficiency we lose going off-Pi.

### Decision triggers to revisit

- **Stress-test M13 firmware against real 4+ sink households** (post-M13 prototype). If audio glitches at 4 sinks consistently → activate Hub Stick Plus on Pi 5.
- **M14 v2 Atmos passthrough planning** → revisit CM5 vs CM4 if real-time DD/DTS-HD decode benchmarks show A72 saturation.
- **Pi supply constraints** (Pi Zero 2 W has had stock issues since 2021). If we can't reliably source Pi Zero 2 W at production volume, fall back to Pi 4 (2 GB) and accept the higher BOM with $69 retail.

---

## 2026-05-16 — Manufacturing strategy: Latin America hybrid, leveraging founder's dual-citizenship + family network

The founder is a US/Colombia dual citizen with family in Mexico (dual-citizen cousin), Panama, and Dominican Republic. That's strategic optionality most indie hardware founders don't have. Captured here as the directional framework — the actual factory pick happens after sample units + factory visits closer to M13 ship date.

Full table + reasoning in `website/HUB_DESIGN.html` §6.

### The trade-agreement reality across all four countries

All four have **zero-tariff** agreements with the USA — USMCA (Mexico), CTPA (Colombia), DR-CAFTA (DR), Panama TPA. That means the China-vs-elsewhere math becomes "is the BOM savings worth the IP risk + 25–30% US tariff exposure on Chinese consumer electronics" — and at current tariff posture, the answer is mostly no.

### Recommended function-by-country mapping

- **Software / firmware engineering:** Colombia (Medellín or Bogotá) once we hire beyond the founder. Tech-talent arbitrage (~30–50% of comparable US salaries) + founder's dual citizenship enables direct hiring. Marketing story: "Designed in Latin America" is intriguing in audiophile press, not negative.
- **Hardware design (PCB schematic, mechanical, firmware):** USA contract design firm OR Colombia-hired engineer. ~$5–15K total for a PCB layout from a US firm; comparable in Colombia with the right hire.
- **Component sourcing:** Shenzhen via Alibaba. Most chips are made in Asia regardless — sourcing ≠ assembling. Use verified suppliers (Seeed Studio for Pi-related, established chipmakers for the rest).
- **PCB assembly + final box assembly:** Mexico (Guadalajara or Monterrey) via cousin's network. Best LATAM contract-mfg ecosystem + USMCA zero tariff + IP protection better than China + direct trust via family relationship.
- **Lower-cost assembly hedge / backup:** Dominican Republic for batch 2+ if Mexico costs creep. Family connection enables relationship.
- **Logistics / LATAM regional distribution hub:** Panama (Colón Free Trade Zone) when we eventually distribute regionally. For US-only distribution: US 3PL (ShipBob, Amazon FBA, specialty audio fulfillment).
- **Certification (FCC / CE / IC):** US third-party labs, $8–14K per market, one-time per design. Geography-neutral.

### The marketing-story angle

"Designed in Latin America, assembled in Mexico, engineered for the world." Genuine cultural roots across the Americas + US tech expertise + an indie story competing against corporate walled-garden incumbents (Sonos, Apple, Google). Latin American market — Colombia + Mexico + DR have growing middle-class audio buyers underserved by Sonos/Bose mainstream — would respond to a brand of and from the region post-M8 expansion.

### Honest caveats

- This is **months out**. M13 ships after M5.5 + M6.5 + M7 + M8 + M9 + M10 + M11 + M12. Realistic timeline: 2027. Manufacturing outreach starts ~6 months before ship date. Plenty of time to vet factories.
- **Get a US international tax accountant + a lawyer familiar with US/LATAM hardware imports** before committing to a holding-company structure. $1–3K of advice money pays for itself if it surfaces tax benefits early.
- **MOQ realities:** most CMs in any of these countries want 250–500-unit minimums. At 100 units we'd be limited to small US CMs or specialty Chinese factories. Acceptable for a first run while validating demand.
- **The factory pick happens after sample units + factory visits**, not after this document. This is the directional framework, not the contract.

### Decision triggers to start real factory outreach

- **M8 public-beta revenue clears the validation bar** (revenue floor TBD; probably ~$5K/month sustained for 3 months). Real consumer demand evidence justifies hardware investment.
- **6 months before planned M13 ship.** Reverse-engineer from desired ship date (probably 2027 Q1 or Q2).
- **Inbound from any of the named LATAM CMs.** Real outreach can shift timing.

---

## 2026-05-16 (same night, expansion) — Heterogeneous-household reality + M5.5 schema gains dual roles

Captured immediately after the prior "Hub Pro UX vision" entry. The Sonos-centric assumptions in that entry were wrong; this entry corrects them and expands the M5.5 Device Profile schema to handle real-world heterogeneity.

### The wrong assumption

Earlier entries implicitly assumed users have a Sonos Playbar (or another API-exposing soundbar) as the TV-audio control point. This is a minority case. The actual median household has:

- **TV**: LG OLED, Samsung QLED, Sony Bravia, TCL, Vizio — wildly varying CEC implementations and audio output paths
- **Soundbar (or AVR)**: Sony HT-A7000, Samsung HW-Q990, LG SP9YA, Bose Soundbar 900, Sonos Playbar/Beam, WiiM Pro Plus, Bluesound Pulse Soundbar, or generic optical bars with no app at all
- **Other speakers**: B&W AP1 stranded receivers, Apple HomePods, Google Cast speakers, Bluetooth speakers, an Audio-Technica turntable plugged into an ancient stereo, etc.

The TV-remote → soundbar volume control already works in most households via the soundbar's existing IR receiver, HDMI-CEC adoption, or proprietary remote-control protocol. Asking the user to *replace* that working chain is the wrong product story.

### Decision: don't replace the existing soundbar. Extend it via M6.5 Claude Skill.

The corrected pitch: **leverage the user's existing TV-remote → soundbar volume-control chain**. SuperAudio software extends what the soundbar can already do to the rest of the user's speakers.

For households where the soundbar exposes an API (Sonos, WiiM, BluOS, HEOS, MusicCast, HomeKit-integrated, SmartThings-integrated), the Claude Skill onboards the soundbar's volume-event stream — no new hardware needed. When the user's TV remote bumps the soundbar's volume, our software propagates the change to the rest of the mesh.

For closed / IR-only soundbars (older B&W, generic optical bars), the Skill notes the limitation and offers fallbacks: phone-app master-volume control today, or Audio Bridge / Optical Hub for IR-based remote learning.

### M5.5 schema gains "sink role" + "control role"

The Device Profile substrate originally specced ONE role per profile (how to send audio to this device). Schema expansion captures the real-world distinction:

```
{
  "device_id": "sonos-playbar-gen-1",
  "make": "Sonos",
  "model": "Playbar (gen 1)",
  "roles": {
    "sink": {
      "protocol": "sonos-upnp",
      "transport": "x-rincon-mp3radio:",
      "codec_preference": ["aac-lc"],
      "quirks": ["empty-metadata-required", "pump-before-soap"]
    },
    "control": {
      "volume_event_source": "upnp_eventing",
      "service": "RenderingControl",
      "subscription_url": "/MediaRenderer/RenderingControl/Event",
      "ir_codes_learned": false
    }
  },
  "verified_by": "superaudio",
  "contributed_by": "@founder"
}
```

A Sonos Playbar has both roles. A B&W A5 has only the sink role. A generic IR-only Bose Soundbar paired with an Audio Bridge would have only the control role (the user keeps the soundbar for TV audio playback; the Audio Bridge captures audio for the rest of the mesh).

### M6.5 Claude Skill scope expands

Originally specced as "onboard unsupported speakers." Now: **onboard any audio device — speakers, soundbars, AVRs, smart-TV-as-audio-source.** The Skill is the universal adapter, not just the speaker-specific onboarder. This is a bigger marketing story (AI-driven device adaptation works across any audio gear) AND a more honest description of what the skill actually does.

The Skill's per-soundbar onboarding flow:

1. **Identify** — web-search the soundbar's make/model, check known APIs / Bonjour signatures / SmartThings device registry / HomeKit accessory list
2. **Probe** — scan the LAN for whatever services the soundbar exposes
3. **Test** — walk the user through volume-up / volume-down / mute tests, confirming the event subscription captures real changes
4. **Submit** — draft a Device Profile JSON and open a GitHub PR against `superaudio-device-profiles` with the user's explicit consent. Anonymize household-identifying fields.

### Decision triggers to ship this

- **M5.5 implementation phase** — schema decision is made here. Dual-role profiles cost ~1 extra week of M5.5 scope vs. single-role.
- **M6.5 Skill alpha** — soundbar onboarding becomes a flagship Skill demo path. Show one new well-known soundbar onboarded live during the Skill demo video for M8 launch.

---

## 2026-05-16 (same night) — 5-SKU lineup expansion + Audio Bridge as new minimal SKU

Captured after the heterogeneity reveal made me realize the 2-SKU lineup (Hub Stick + Hub Pro) is wrong shape. Five SKUs map to five distinct household scenarios; each transition is a real upgrade with real cost justification.

### The five SKUs

1. **Audio Bridge** ($29–39) — tiny TOSLINK dongle, no IR receiver, no HDMI. Just captures optical audio and broadcasts to LAN. Pure software handles volume control (leverages existing soundbar via Claude Skill, or phone-app fallback). The **cheapest entry point for mixed-speaker households**.
2. **Hub Stick Mini** ($39–45) — USB-A dongle, TV-USB-A powered (no wall wart). Phone audio (AirPlay 2 receive) → LAN fan-out. Impulse-buy entry point. Doesn't capture TV audio.
3. **Hub Stick** ($59) — router-plug box, own USB-C wall wart. All connectivity (Ethernet option). Phone audio → LAN fan-out. The original M13 spec.
4. **Optical Hub** ($79) — small box, TOSLINK in + **own IR receiver** for TV-remote learning (Sonos Beam optical-mode pattern). Mass-market sweet spot for 2014–2018 TVs with optical out + no HDMI ARC reliability. Replaces the existing soundbar's role entirely.
5. **Hub Pro Dongle** ($249) / **Hub Pro Box** ($279) — Chromecast-style HDMI eARC dongle (Dongle) or set-top box (Box). HDMI-CEC remote passthrough. Magic-moment flagship for modern TVs.

### Why this matters strategically

Each SKU addresses a distinct decision the household has already made. The Audio Bridge ($29) sells to users invested in their Sonos/WiiM/Bose soundbar who don't want replacement. The Optical Hub ($79) sells to users open to replacing the soundbar entirely with TV-remote integration. The Hub Pro ($249–279) sells to users with modern eARC TVs who want the full magic moment.

Five products is more than ideal at launch — we'll likely ship just one or two SKUs first and add others over time. But the lineup design ensures we won't paint ourselves into a corner: each SKU has a clear customer, and the price ladder ($29 → $39 → $59 → $79 → $249 → $279) creates natural upsell stories.

### Decision: ship order

**Most likely ship order based on engineering complexity + audience size:**

1. **Audio Bridge first** — simplest hardware (no IR receiver, no HDMI chipset). Validates the manufacturing pipeline. Lowest BOM risk.
2. **Hub Stick Mini second** — same hardware family as Audio Bridge minus the TOSLINK input. Trivial variant.
3. **Hub Stick third** — adds case + wall wart + Ethernet variant. Mature variant.
4. **Optical Hub fourth** — adds IR receiver hardware + remote-learning UX. Real engineering for the IR layer.
5. **Hub Pro Dongle + Box fifth** — HDMI receiver chipset + CEC + eARC certification. Most complex.

This means: **Audio Bridge becomes the first hardware ship (M13a?), not Hub Stick.** Hub Pro becomes the M14 flagship after M13 validates the manufacturing chain.

### M14/M15 reorder question

ROADMAP.md currently has M14 = Hub Pro and M15 = Optical Hub. The Optical Hub is *simpler* hardware than Hub Pro (no HDMI receiver chipset, no eARC complexity) and serves the **bigger audience** (2014–2018 TV cohort).

**Tentative call: reorder M14 ↔ M15.** Ship Optical Hub before Hub Pro. Reasons:
- Easier to manufacture, validates the IR-receiver hardware path
- Bigger immediate audience (median US household has a pre-2018 TV with optical out)
- Hub Pro's eARC + Atmos passthrough adds complexity worth tackling after Optical Hub revenue justifies the engineering investment

**Caveat:** Hub Pro is the headline / press / demo product. Optical Hub is less marketable. Marketing argument FOR keeping Hub Pro as M14 (despite the engineering being harder): the Press TV Power Audio Everywhere demo is what wins press at M8 launch. Optical Hub's "IR remote learning" demo is more incremental.

**Final decision deferred** — depends on M13 manufacturing experience + M8 revenue trajectory. Document the analysis here so future-us can make an informed call.

### Decision triggers

- **M13 first manufacturing run** — Audio Bridge (or whichever SKU we ship first) teaches us about LATAM assembly realities. Adjust SKU 2–5 ship order based on what we learn.
- **M8 launch press strategy** — if reviewers want a "magic moment" demo, Hub Pro stays as M14. If they want a "compatibility breakthrough" demo, Optical Hub leads.
- **Inbound demand signal** — pre-orders / waitlist signups for specific SKUs reveal real demand distribution.

---

## 2026-05-17 (Sunday) — M6 multi-sink sync + reliability arc: sender-side delay, handshake barrier, supervisor cap

Single-day push that flipped the entire sync story for the Mac app. Going in: A5/A7/Sonos were "approximately synced with manual fiddling and unpredictable drift." Coming out: A5 and A7 first-audio within **1 ms** of each other regardless of handshake variance; Sonos within ~200 ms of AP1 with a deterministic defer formula; user empirically dialed in `slider=3085ms` and said "wow, perfect." See commit `8a8849c`.

### The three core architectural decisions

**1. Sender-side broadcaster delay (vs. receiver-side NTP scheduling)**

The M5 architecture relied on shifting the sync NTP timestamp to delay AP1 playback. Discovery 2026-05-17: **B&W A5/A7 receivers clamp far-future NTP requests to their internal buffer depth (~93 ms)**. Setting `manualOffsetSeconds=5.0` on the NTP path produced ZERO audible delay — the speaker treated our `play at NTP=now+5s` request as "play ASAP" because it can't buffer 5 seconds.

Decision: shift audio at the **sender** instead. `AudioBroadcaster` gains per-subscriber `delaySeconds`. Each delayed subscriber gets chunks via `Task.detached { sleep(delay); yield(chunk) }`. Defensive `AudioChunk.makeCopy()` so PCM memory survives the sleep. `presentationHostTime` rewritten to `original + delayHostUnits` so downstream sync NTP math lands in the present (RTPSender's `sendInitialSync` gains `seedingFirstChunkHostTime` for this).

Net effect: AP1 receives RTP packets `delay` seconds after capture. Receiver plays them as they arrive (the only path the firmware actually honors). Audio content lag = `delay` seconds, fully sender-controlled.

**Why this matters generally:** any AirPlay-receiver-clamping behavior is now sidestepped. The same architecture would work for AirPlay 2, Chromecast, Bluetooth — any receiver that doesn't honor far-future timestamps will still respect the moment of packet arrival. This is the M5d architecture *plus* the receiver-clamp escape hatch.

**2. Handshake barrier (vs. per-session independent start)**

Observed under TCP contention with 3+ simultaneous handshakes: A5 finished handshake in 750 ms; A7 took 5 seconds (its TCP responses queued behind A5's). They then subscribed to the broadcaster 4 sec apart → first-audio 4 sec apart. Cross-AP1 sync was demolished by handshake variance.

Decision: introduce a barrier. `SessionState.armStartBarrier(forAP1Sinks:)` records the expected set at `startAll` time. Each AP1 session calls `markHandshakeComplete` after RTSP RECORD success **and** after SET_PARAMETER volume (initially we marked after RECORD only — A7's slow SET_PARAMETER still caused 2.2 sec post-barrier slip — so we moved the mark to AFTER all RTSP-over-TCP work). Sessions then `await awaitStartBarrier()` before subscribing to the broadcaster. When the pending set empties, all waiters resume simultaneously. 10 s fallback timeout so a stalled/dead sink doesn't block the rest.

Sonos sessions wait the same barrier, then apply their start-defer. So all sinks cross the line together; Sonos's defer takes Sonos's natural setup time (~2.5 s) into account.

**Result:** A5 and A7 broadcaster subscribes within microseconds of each other; first-audio within 1 ms. This is sample-accurate for practical purposes.

**3. Supervisor exit-reason enum + retry cap (vs. infinite retry)**

The original supervisor would retry any failed session indefinitely with exponential backoff. Symptom observed 2026-05-17: Derek's MacBook Air was discovered via mDNS, swept into `wantedActive` via Play All, never accepted by the brother (no user prompt), and the supervisor retried it forever — 2s, 5s, 15s, 30s, 60s, 60s, 60s... Each retry opened a fresh TCP handshake against his Mac, consuming Wi-Fi bandwidth and slowing our real speakers (A7's 5-sec handshake was a downstream effect of this contention).

Decision: distinguish failure types. `AirPlay1Session.run` and `SonosSession.run` now return `SessionExitReason`: `.cleanExit`, `.networkLost`, `.failedBeforeAudio`, `.failedAfterAudio`. Supervisor counts consecutive `failedBeforeAudio`; after 3, removes sink from `wantedActive` and exits the loop. `.networkLost` and `.failedAfterAudio` retry indefinitely (those represent transient blips, not "this device will never work").

**Heuristic for the threshold:** 3 attempts × ~5s handshake budget = ~15 seconds of "give the network a chance to settle" before declaring the sink unreachable. Empirically sufficient for cold-start variance without blocking the user for unaccepted receivers.

### Smaller wins documented in the same commit

- **Session-race nonce guard** — old session's slow async cleanup was wiping new session's setters/active-flag when sessions overlapped (rapid off→on cycle). `AirPlay1Session` now captures a session nonce and asks `SessionState.endSessionIfStillCurrent` before wiping shared state in its defer block.
- **Idempotent Play All** — filters on `sessionTasks` (real source of truth) rather than `activeSinks` (transiently empty during defer cleanup).
- **1.5 s TEARDOWN timeout** — was stalling 4+ seconds on cancelled sockets, blocking the next session start.
- **250 ms volume slider debounce** — rapid drags were saturating the RTSP TCP control plane and triggering spurious "RTSP timed out" cascades.
- **Mac mute toggle default-mismatch fix** — `@AppStorage` defaulted to true, `SessionState`'s `UserDefaults.bool` defaulted to false; they silently disagreed until first user click. Both now default to true on first launch.
- **Sonos Δ slider rip** — the disabled-but-visible slider was confusing. Replaced with informational caption explaining Sonos's timing is encrypted-at-UPnP (see 2026-05-16 entry).
- **Audio-gap telemetry** — capture-side inter-chunk gap detection (>100 ms), logged with running count + worst-observed.

### What this unlocks

M6.3 Sync UX (next milestone in ROADMAP). The architecture is now strong enough that the **user-facing UX is the limiting factor** for tuning sync — the slider works correctly, but tuning by ear is finicky. M6.3 adds Mac-mic auto-calibration, real-time slider drag, rotary knob UI, and an in-app diagnostics panel. Auto-calibration is also M11 Path A, so M6.3 ships the algorithm engine that iOS Companion will drive in M11 Path B.

### The empirical headline

User dialed in `slider=3085 ms` by ear, reported "wow, perfect" with audible Sonos and AP1 alignment, after about 10 minutes of nudging. The next-mile feature is killing the manual nudge with one Calibrate button.

---

## 2026-05-18 — M6.3 #105–#109: chirp-based mic calibration converges sync (M11 Path A precursor shipped)

### Context

M6 brought multi-sink sync to ±1 ms across AirPlay 1 receivers and ±200 ms across protocols (AP1 vs Sonos). M6.3 was supposed to add UI polish on top. The manual slider worked but was finicky.

This session shipped Mac-mic auto-calibration. ~8 hours of testing across 25+ measurement runs revealed three structural insights that the prior plan didn't anticipate.

### Three structural insights

**1. Sonos's UPnP `RelTime` is unreliable for sync math.** First attempt was `#104 Sonos-position auto-align` — query `AVTransport::GetPositionInfo`, derive Sonos's hidden buffer as `(now - playStartedAt) - relTime`, push into AP1 broadcaster delay. Worked in some sessions, off by 500+ ms in others. Across 8 sessions of empirical data, measured `sonos_lag` ranged from 3.59 sec to 4.62 sec for the **same hardware**. `RelTime` reports the renderer queue position, not the DAC. The hidden buffer between them varies ~600 ms session-to-session. Software-only fix is fundamentally limited; need a physical measurement.

**2. Ambient music can't be a cross-correlation reference signal.** Built `MicCapture` + Accelerate vDSP FFT correlation engine (committed earlier in `420391d`). Tested with ambient music as reference. SNR locked at 20+ (statistically rock-solid) but lag values were inconsistent with what the math said they should be. Reason: music has rhythmic and harmonic structure that creates spurious correlation peaks every beat / chord interval. The "true" peak was sometimes weaker than spurious ones. Pro audio measurement (Smaart, REW, ARTA) uses chirps — flat autocorrelation, one unambiguous peak — for exactly this reason. Decision: chirp injection via `ChirpGenerator.linearSweep(200 Hz → 8 kHz, 1 sec)`.

**3. The chirp-based system converges iteratively.** Each calibration pass reduces residual error by ~80%. Pass 1 leaves ~200–1000 ms residual; pass 2 reduces to ~100–200 ms; pass 3 locks in sub-perceptual (<50 ms, within mic correlation noise). The remaining variance is Sonos's renderer buffer drifting between calibration and listening; consecutive passes anchor to the same drift state.

### Architectural decisions

**Chirp injection at the broadcaster layer** — `AudioBroadcaster.injectChirp(samples:)` queues mono float chirp samples. `applyChirpIfActive` in the capture-task overwrites each incoming chunk's PCM data with the next slice of chirp samples (duplicated to all channels) while keeping the chunk's `presentationHostTime` intact — per-subscriber broadcaster-delay queues continue to apply normally. All subscribers (RTP pump for AP1, Sonos pump, reference tap) receive the chirp as if captured normally. Drains after the chirp's duration, normal capture resumes.

**Sequential per-speaker isolation, not simultaneous multi-peak detection** — with multiple speakers playing the same chirp at different lags, mic correlation has multiple peaks; reliably assigning them to speakers (without secondary info) is hard. Decision: mute all but one speaker per measurement. AP1 via SET_PARAMETER volume=0; Sonos via SOAP SetVolume(0). After measurement, restore. Iterate. Sonos measured last as the alignment reference (slowest sink can't be shifted, AP1 sinks shift to match).

**Reference window 30 sec capacity** — for cross-correlation to find peaks at speaker lags up to ~4 sec (Sonos) within a 7.5 sec mic capture, the reference must span (`mic_duration + max_expected_lag`) ≈ 11 sec ending at mic-completion. Bumped `AudioBroadcaster.referenceTapCapacitySec` from 10 → 30 sec for headroom. `AudioCorrelation.maxLagSamples` default extended to `reference.count` (was `observed.count`).

### Three load-bearing bugs found + documented

**`offset(for:)` not `sinkOffsetsMs[id]`** — the in-memory dict is empty until the user touches a slider this session; persisted values live in UserDefaults. Reading the dict directly returned 0 for user-persisted 3085 ms values; the calibrator computed nonsensical offset adjustments (reset A5 from 3085 ms to 1543 ms in the first failing run). All offset reads in `MicCalibrator` now go through `SessionState.offset(for:)` which checks both sources.

**AVAudioEngine 3-second first-init quirk** — first `input.outputFormat(forBus: 0)` query on macOS takes ~3 seconds to spin up the audio subsystem. If the chirp gets injected during that 3-sec window, the mic misses most of it. The pattern in two consecutive failing runs was "first speaker's lag = near-zero" — diagnosed as the mic starting 3 sec late, capturing only the tail of the chirp arrival. Fix: 500 ms throwaway `MicCapture.capture(duration: 0.5)` at the start of `runFullCalibration` before any real measurement. Subsequent captures are instant because the audio subsystem stays warm.

**`setVolumeImmediate` for calibration mute/restore** — `SessionState.setVolume` is debounced at 250 ms AND persists to UserDefaults. For calibration's "mute this sink, measure, restore" pattern, both are wrong. Added `setVolumeImmediate(_:for:)` that cancels pending debounced tasks and calls the volume setter directly — no debounce, no persistence overwrite.

### Verification (real-room test that confirmed it works)

Configuration: B&W A5 + B&W A7 (AirPlay 1) + Sonos Playbar gen 1 (UPnP). Mac at listening position. Spotify playing.

Pre-calibration: persisted offsets A5=A7=3085 ms (user's empirically-tuned value from earlier session). Sonos reported behind by ~1000 ms (different hidden buffer state than the prior session — inter-session variance manifesting).

| Pass | Sonos behind by | Δ applied (A5 / A7) | User report |
|---|---|---|---|
| 0 | ~1000 ms | — | "Sonos behind ~1000ms" |
| 1 | ~200 ms | +51 / −73 | "Sonos still behind ~200ms" |
| 2 | <50 ms | +76 / −12 | **"they are playing in sync it's beautiful"** |

The system converged in ~90 seconds of total calibration time (3× ~30 sec passes), achieving sub-perceptual cross-protocol sync that ~10 minutes of manual slider nudging only approximated.

### What this unlocks

**M6.4 (Painless Auto-Calibrate)** — hide the button. Auto-trigger on Play All when Sonos is in the active set. Sonos already takes ~30 sec to settle into steady-state after SOAP Play; run the 3-chirp calibration during that already-bad window. By the time Sonos hits steady-state, AP1 is re-tuned to match. UX: click Play All, hear music start, sync locks in within ~15 sec, no further action.

**M11 Path A iOS Room Tuning** is now the same algorithm with iPhone's mic instead of Mac's. Better positioning (user can walk around the room), same math.

**The marketing demo is in reach.** Two-tap experience — click app icon, click Play All — and audio is in sync. Three taps if user wants to recalibrate (Mic Calibrate button).

---

## 2026-05-29 — Sonos cross-protocol sync: single-shot calibration insufficient; closed-loop tracking is the actual moat; v1 ships AP1-only

**Decision:** Three load-bearing strategic calls coming out of the 2026-05-28/29 real-room test with 4 speakers (3 B&W AirPlay 1 + Sonos Playbar gen 1):

1. **Single-shot mic calibration cannot reliably deliver cross-protocol sync.** Documented failure modes need addressing in M6.6 before single-shot is trustworthy at all.
2. **Continuous closed-loop tracking (ultrasonic + always-on mic + smooth offset interpolation) is the only path to "always perfect" cross-protocol sync.** Logged as M6.7.
3. **Mac app v1 ships AP1 (+ AP2 addon when M12 lands) as the headline; Sonos becomes a clearly-labeled best-effort $5 addon** until M6.7 closes the loop. Reframes the launch story honestly without abandoning the wedge.

### The real-room data that drove this

4-speaker config: 3× B&W (A7 "Spacelab Forever Main", A5 "Spacelab Audio", A5 "Spacelab Audio Dos") + Sonos Playbar gen 1 ("Den"). Three load-bearing structural weaknesses surfaced that the original 3-speaker tests (2026-05-18) didn't:

| Issue | Observed | Root cause |
|---|---|---|
| Same-room A5s measured 3 sec apart | A5#1=3.473s, A5#2=0.445s in the same room | One measurement was a noise lock at SNR=7.7. Cross-speaker consistency check absent — no algorithm to reject "physically impossible." Two A5s in same room should agree within ~150ms positional delta. |
| Sonos sample variance unbounded | 3 samples spanned 3.110s (0.6s → 3.7s) | Sonos's hidden buffer drifts second-to-second. Median picked 3.549s, but median is statistically meaningless when range exceeds signal value. No upstream variance gate. |
| Bad calibrations corrupt saved state | Profile auto-saves *every* completed pass regardless of quality | One bad pass overwrote a previously-good profile. Next launch primed from bad state → worse-than-fresh sync. Compounding. |

### Sonos developer API research (the same day)

Confirmed by reviewing official docs (`docs.sonos.com/reference/create-authorization-code`, `connected-home-get-started`, `how-sonos-works`, `llms.txt`) that the **official Sonos Cloud Control API has the same timing limitations as the UPnP/SOAP we currently use**:

- ✗ No millisecond playback position (same coarse `GetPositionInfo`)
- ✗ No buffer / renderer timing access
- ✗ No audio rendering latency metrics
- ✗ No cross-protocol sync — `createGroup`/`modifyGroupMembers` only work on Sonos players
- ✓ `loadLineIn` for Sonos units with line-in (not Playbar gen 1) — interesting for hardware-bridged path
- ✓ Event-driven playback subscriptions (cleaner than UPnP polling) — worth migrating for code hygiene, doesn't help sync

**Strategic implication:** Sonos has deliberately not exposed the primitives required for external-app sync — that precision is their internal moat (SonosNet sync between Sonos devices). External controllers structurally cannot access it via any public API. This isn't a reverse-engineering gap; it's a published-policy gap. Means closed-loop mic tracking (M6.7) and AP2-for-newer-Sonos (M12) are the *only* software paths to deterministic cross-protocol sync.

### Why closed-loop tracking is the actual moat

Single-shot measures once and assumes stability. Sonos's buffer drifts inside a single session (2.7s observed across 5 min on same hardware on 2026-05-21; 3.1s observed across 30 sec on 2026-05-29). No matter how clean a single measurement, the answer goes stale in seconds.

Closed-loop accepts the variability and tracks it. Mic continuously listens (inaudible ultrasonic, ~18-19 kHz so user can't hear it), measures Sonos's current lag every 5-10 sec, AP1 broadcaster delay shifts in micro-increments to track. Sonos drift +0.4s → AP1 delays +0.4s within seconds. This is what Smaart, REW, ARTA, and every pro audio measurement rig does — applying it to consumer multi-protocol streaming is genuinely novel.

**Sonos cannot ship this themselves** because their own external API doesn't expose the precision required. The moat is unattackable from inside their ecosystem.

### V1 product reframe

Original M8 framing: *"Multi-protocol multi-room sync — AirPlay 1 + Sonos."* That promise can't be honestly kept on legacy Sonos with single-shot calibration (per the data above), and we've now confirmed no API path exists to fix it.

Honest reframe:

| What ships | When | Framing |
|---|---|---|
| Mac app v1 ($19) | M8 | "Perfect multi-room AirPlay 1 sync" (proven). AP2 addon $5 when M12 ships. |
| Sonos $5 addon (beta) | M8 | "Best-effort Sonos sync. Always-perfect coming with M6.7." Clear labeling, no promise. |
| Sonos $5 addon (production) | After M6.7 | "Always-perfect cross-protocol sync, even on legacy Sonos." The moat realized. |

This is a *stronger* product story than launching with a hero feature that glitches. AP1 + AP2 alone is a bigger universe than Airfoil's niche (HomePods, modern AVRs, Bluesound, Marantz, ...); rock-solid sync at $19 is already a real product. Sonos becomes a "we ship the impossible later" narrative beat instead of a launch-day commitment we can't keep.

### Alternatives considered + rejected

- **Push harder on single-shot tuning** — rejected. The 2026-05-29 data shows the variance Sonos exhibits is unbounded within a single session. No single-shot algorithm can compensate for a drift target that moves 3 sec while you're measuring it.
- **Drop Sonos entirely from the roadmap** — rejected. Sonos is too common in target households to abandon; the closed-loop path genuinely solves it and becomes the moat. Defer, not delete.
- **Use Sonos Cloud Control API as a control surface** — useful for code cleanup (event-driven > polling) but doesn't help timing. Logged as M6.6 spike; defer the migration decision to M6.5 / M8 readiness.
- **Pre-buffer Sonos before SOAP Play (low effort)** — kept in M6.6 as a cheap experiment. Theory: a fuller renderer buffer at `Play` start might reduce inter-session variance. If it cuts variance from 3.1s to <500ms, single-shot becomes viable. If not, M6.7 is the only path.

### What this means for the next two weeks

1. **AP1-only path is the current shipping state.** Three B&Ws synced cleanly in tonight's test with Sonos out of the mix. M5/M6 architecture validated for 3 AP1 sinks (was previously only proven for 2).
2. **Today's M6.4 code stays but auto-trigger is disabled by default** until M6.6 ships the safety nets. Manual "Mic Calibrate (auto)" button remains for opt-in single-shot experiments.
3. **M6.6 and M6.7 are now the priority path** for unlocking Sonos sync. AP1 + AP2 polish (M3 hardening, M9 Apple TV companion, M5.5 device profiles, M12 AP2 addon design) runs in parallel as the v1 shippable surface.

---

## 2026-05-29 (afternoon) — Revert MLS → chirp; reorder M6.7 closed-loop before M6.6 safety nets

**Decision:** Two linked decisions following M6.6 real-room test data + UX reflection:

1. **Revert the default calibration signal from MLS back to chirp** (linear sine sweep, 200 Hz → 8 kHz, 1 sec). Supersedes the M6.4 Phase 2b decision (2026-05-21) to default MLS.
2. **Reorder the M6.x sequence: M6.7 closed-loop continuous tracking takes priority over M6.6 single-shot safety nets.** Supersedes the implied "M6.6 before M6.7" ordering from this morning's [DECISIONS.md 2026-05-29 entry](#2026-05-29--sonos-cross-protocol-sync-single-shot-calibration-insufficient-closed-loop-tracking-is-the-actual-moat-v1-ships-ap1-only).

### Why revert MLS → chirp

The M6.4 Phase 2b decision (2026-05-21) was driven by *theory* (MLS autocorrelation is mathematically a true delta function within the sequence period) and *UX* (MLS sounds like brief static, less alarming than the chirp's alarm-tone sweep). It was rejected by *empirical data* on 2026-05-29:

| Test | Signal | Speakers | SNR | Outcome |
|---|---|---|---|---|
| 2026-05-18 (single-room) | Chirp | A5 + A7 + Sonos | 20+ | Converged 1000ms → 12ms in 3 passes ✓ |
| 2026-05-29 (afternoon, single-room 3 B&W) | MLS | 3 B&W (Sonos off) | 7.8 – 9.7 | All measurements SKIPPED below SNR=10 gate |
| 2026-05-29 (afternoon, 4 speakers with Sonos) | MLS | 3 B&W + Sonos | 7.7 – 13.7 AP1; 4.8 – 9.0 Sonos | Inconsistent lags; Sonos variance 3.110s; one A5 mis-locked at 0.445s when other A5 same-room measured 3.473s |

**Root cause:** at normal listening volumes (40-70% slider), MLS's spread-spectrum energy is too thin per frequency to lift the correlation above the noise floor. The chirp's concentrated energy at the swept frequency punches through. **In an SNR-limited regime — which is the regime real users will be in — concentrated-energy beats flat-spectrum, even though the chirp's autocorrelation is only approximately flat.** Pretty math loses to physics.

The `useChirpForCalibration` UserDefaults pref already existed (shipped 2026-05-21 as the back-channel for the MLS rollout). Code change: default-when-unset from `false` (MLS) to `true` (chirp). One line. Users who specifically prefer the MLS sound can still opt in via `defaults write`.

### Why reorder M6.7 before M6.6

User observation that became load-bearing: *"even when calibration works, it's a long tedious and not user-friendly process."*

The original sequencing assumed M6.6 (safety nets: cross-speaker consistency rejection, Sonos variance gate, save-on-confirm) was the cheap next step that made single-shot reliable enough to ship. That assumption was *correctness-shaped* — make the calibration produce the right numbers. But the calibration UX is also broken regardless of correctness:

- 30-45 seconds of audible test bursts cycling through speakers
- Requires user click on Mic Calibrate (auto), or auto-trigger that surprises them
- Re-runs needed every time room state changes (sink added/removed/moved)
- Sonos drift means even a perfect single-shot goes stale in minutes

**"Press Play. Hear sync." cannot include 45 seconds of audible noise.** M6.6 safety nets would deliver "Press Play. Hear 45 seconds of correctly-tuned noise. Then sync that drifts." M6.7 closed-loop delivers the actual product premise:

| Concern | M6.6 single-shot hardening | M6.7 closed-loop continuous tracking |
|---|---|---|
| User-audible test signal | 30-45 sec audible burst cycle on each calibration | Inaudible 18-19 kHz; user never hears it |
| User interaction | "Click Mic Calibrate" or wait through auto-trigger | None — runs continuously while music plays |
| Sonos drift handling | Re-run calibration manually when sync degrades | Tracked in real time; auto-corrects within seconds |
| First-touch latency | ~30-45 sec to converge | ~5-10 sec to first lock, refines continuously |
| Risk of cascade/state corruption | Pass-by-pass, profile overwrites | Continuous smoothing; no discrete state mutations |

The 2026-05-29 morning sequencing was "ship M6.6 to make single-shot work, M6.7 as moat polish later." The corrected sequencing is **M6.7 ships first as the actual product**; M6.6 only gets built if M6.7's hardware validation fails (mic can't capture 18-19 kHz cleanly, or speakers can't reproduce it at distance — both real risks).

### Hardware-validation gate for M6.7

Before any M6.7 implementation work, validate three load-bearing assumptions:

1. **Mac built-in mic captures 18-19 kHz cleanly.** FFT a known 19 kHz tone, check magnitude response. If the mic dies above 17 kHz, we either need user-external-mic support or accept audible test signal.
2. **B&W A5/A7 and Sonos Playbar gen 1 reproduce 18-19 kHz audibly at typical listening distances.** Speakers vary; Sonos especially may EQ aggressively at high frequencies for music optimization.
3. **The mic-at-listening-position can hear 18-19 kHz at typical user distance.** Ultrasonic absorbs much faster in air than mid-range; range ~10-15 ft in normal rooms.

If any of these fail on the test bed (Playbar gen 1 — our hardest case), the closed-loop premise is broken and M6.6 becomes the fallback. Validation should be ~half a day of FFT measurements before committing to the 3-week implementation.

### What this means for tomorrow

1. Test the chirp default once with the cleaned profile + the 4-speaker setup. Validates that the previously-working signal still works on the expanded test bed.
2. Spend a half-day on the M6.7 hardware-validation gate (FFT response of mic + speakers at 18-19 kHz).
3. If validation passes, M6.7 is the implementation thread for the next 3 weeks.
4. If validation fails, M6.6 becomes the implementation thread (~2 weeks) and M6.7 deferred to M11 polish or after-launch.

### Alternatives considered + rejected

- **Keep MLS, just lower the SNR gate further** — rejected. We already lowered 10.0 → 7.0 and it produced one good measurement, one borderline measurement, one outright-wrong measurement (the 0.445s A5 locked at SNR=7.7). Lowering the gate further keeps shipping wrong answers, not fixing the underlying signal weakness.
- **Hybrid: chirp for first lock, MLS for subsequent confirmation passes** — rejected as premature optimization. If chirp works, ship chirp. If neither single-shot signal is reliable enough at user volumes, M6.7 is the answer anyway.
- **Continue M6.6 in parallel with M6.7** — rejected. Two parallel sync threads competing for the same code paths (calibrator orchestration, profile semantics, broadcaster injection) burn cycles on contradictory designs. Pick one architecture, ship it, only build the other as a real fallback.

---

## 2026-05-29 (evening) — M12 AirPlay 2 sender: estimate revised down 4-6 weeks → 3-4 weeks after GitHub scout

**Decision:** Revise the M12 AirPlay 2 sender effort estimate from 4-6 weeks to 3-4 weeks, and lock in the bootstrap stack: **vendor `pair_ap` (MIT) for pairing, use `swift-opus` (Swift Package) for the codec, write fresh Swift for PTP / RTSP / RTP using shairport-sync + airplay2-rs as read-only references**.

### What the scout found

Hunted GitHub on 2026-05-29 afternoon/evening for AP2-relevant code. The find that moved the estimate:

- **`ejurgensen/pair_ap`** — standalone C library implementing SRP + Curve25519 + ChaCha20-Poly1305 + HomeKit transient pairing for AirPlay 2. **MIT licensed**, designed for vendoring (already done by shairport-sync). Dependencies: libsodium, libgcrypt/libopenssl, libplist — all available on macOS via Homebrew or system frameworks.

Pairing was the most expensive single piece projected for M12 (~2 weeks of fresh Swift implementation of SRP-6a + Curve25519 + ChaCha20-Poly1305 + Ed25519 + the HomeKit-specific message exchange grammar). With `pair_ap` MIT, we vendor the C library, write a Swift wrapper (~3 days), and we're done. That alone cuts ~10 working days from the M12 estimate.

The other relevant finds (all logged in ROADMAP.md M12 section with URLs + license):

- **`alta/swift-opus`** — MIT, Opus codec via Swift Package Manager, encodes/decodes straight to/from `AVAudioPCMBuffer`. Already targets macOS.
- **`mikebrady/nqptp`** — GPLv2, PTP daemon. Can't vendor, but **read** as protocol reference and implement our own Swift PTP-monitor (the subset AP2 needs is small).
- **`mikebrady/shairport-sync`** — GPLv3, receiver-only. Well-organized C code (`rtsp.c`, `rtp.c`, `ap2_*_processor.c`, `pair_ap/`). Read for protocol mechanics, write fresh Swift.
- **`lmcgartland/airplay2-rs`** — Rust sender, alpha 2026, PTP confirmed working with HomePod Mini + Samsung TV. The most modern actively-developed sender reference; useful for sender-side architecture decisions where shairport-sync's receiver-side perspective doesn't help.
- **`openairplay/ap2-sender`** — Objective-C, NO LICENSE file (effectively all-rights-reserved, unusable). Architecture-shape reference only.
- **`emanuelecozzi.net/docs/airplay2`** (blog) — multi-part AirPlay 2 internals deep dive. Not fetched yet, prioritized as next-week reading before M12 implementation starts.
- **`FDH2/UxPlay` wiki on AirPlay2 protocol** — community-maintained protocol notes, updated 2025.
- **`openairplay/airplay-spec`** — high-level unofficial spec. Useful orientation; thin on implementation details (e.g., the pairing/hkp.html page describes the overall flow but stops short of message-level grammar — need shairport-sync code reading to fill in).

### What did NOT change

- **License hygiene holds.** pair_ap (vendored) is MIT. swift-opus is MIT. shairport-sync and nqptp are read-only protocol reference, no code copied. Fresh Swift impl for PTP/RTSP/RTP. The MIT-clean codebase discipline from 2026-05-11 is preserved.
- **Fresh-Swift discipline for the wire format.** Same rule as RAOP — wire format is a fact, not copyrightable. We read shairport-sync to understand the bytes; we write Swift to produce them.
- **Per-protocol SPM module pattern.** `SuperAudioAirPlay2` module sits alongside `SuperAudioAirPlay1`, implements the same `AudioSink` + `SinkDiscoverer` contracts. No edits to Core, no edits to other protocol modules. The extensibility model in CLAUDE.md was designed for exactly this; the scout validates the model.

### Strategic consequence — V1 launch story strengthens

The earlier 2026-05-29 morning entry reframed v1 as "AP1 + AP2 addon + Sonos best-effort beta." With M12 dropping from 4-6 weeks to 3-4 weeks, that AP2 addon goes from "ambitious next-quarter feature" to "M8 launch-week shippable." Concrete implications:

- **AP2 unlocks every HomePod, every modern Sonos (Beam gen 1+, Arc, Era, Roam, Move), Bluesound, modern Marantz/Denon/Yamaha network players, modern soundbars with AirPlay 2 receivers.** A meaningfully bigger AirPlay-capable hardware universe than the legacy AP1-only path.
- **Strengthens the case for keeping Sonos as a clearly-labeled "best-effort beta" $5 addon at M8** rather than blocking the launch on Sonos sync correctness. Users with AP2-capable Sonos get deterministic sync via the AP2 path automatically; users with legacy Sonos (Playbar gen 1 specifically) get honest "best-effort, M6.7 closed-loop coming" framing.
- **Validates the "upgrade Sonos hardware as the easy fix" intuition.** Users facing legacy-Sonos sync issues can buy a Beam gen 2 (~$499) and get deterministic AP2 sync immediately via M12. The closed-loop ultrasonic moat (M6.7) remains relevant for users who don't or won't upgrade — that's the test-bed we should keep validating against (see 2026-05-29 afternoon decision to keep Playbar gen 1 as the moat-validation hardware).

### Alternatives considered + rejected

- **Vendor shairport-sync as a runtime AP2 component on macOS** — rejected. shairport-sync is GPLv3; static-linking would force GPL on the entire app, which we explicitly preserve permissive licensing on (see 2026-05-11 entry). Running it as a separate subprocess is gray-area FSF guidance and adds runtime complexity (and shairport-sync is a *receiver*, not a sender — wrong direction anyway).
- **Wait for AP2 protocol to stabilize / open up further** — rejected. The protocol has been stable enough for reverse-engineering for years; the scout confirms multiple active independent implementations. Risk that Apple changes the protocol is real but bounded — even if they introduce AP3, AP2 hardware (HomePods etc.) will keep accepting AP2 for years for backwards compatibility.
- **Use the official Apple AirPlay APIs (private SPI)** — rejected. The relevant APIs (`AVAudioSession` extensions, `MediaPlayer` AirPlay routing) are designed for *receiving* on iOS or for App Store apps that delegate to system AirPlay UI. None of them expose direct sender control at the level required for multi-sink fan-out + per-sink offset control + manual handshake. We'd hit the wall of "system AirPlay routing is one-sink-at-a-time" within hours.

### What this means for sequencing

- **M6.7 closed-loop continuous tracking** remains the priority work between now and the v1 launch (see 2026-05-29 afternoon decision). That's the moat.
- **M12 AP2 sender** is now scoped for an explicit ~3-4 week thread that can start in parallel with M6.7 hardware validation (different code paths, different test surface).
- **`pair_ap` integration** is the lowest-risk first sub-task in M12 — pull the library, get it building under SPM (or as a system dependency), write the Swift wrapper, run the pair-setup / pair-verify dance against a HomePod or Sonos Beam. Once that's green, the rest of M12 unblocks.

---

## 2026-05-30 — V1 scope tightening: legacy (non-AP2) Sonos deferred to post-v1; AP1 + AP2 is the v1 hero

**Decision:** Cut **legacy Sonos sync from the M8 v1 launch scope**. M6.6 + M6.7 (the single-shot hardening + closed-loop continuous tracking work that was prioritized 2026-05-29) move to **post-v1.1** as the "perfect legacy Sonos sync" moat play, but no longer block the v1 ship.

V1 scope becomes: **AirPlay 1 multi-sink sync (shipped, proven) + AirPlay 2 sender via M12 (3-4 weeks per the 2026-05-29 evening scout)**. Modern Sonos hardware (Beam gen 1+, Arc, Era, One, Move, Roam, post-2018 line) receives AP2 and slots into the AP2 path automatically — deterministic, sample-accurate, no closed-loop calibration needed.

**Supersedes the 2026-05-29 (afternoon) decision** ordering M6.7 ahead of M6.6 — both are now post-v1.

### What drove the call

Real-room testing across 2026-05-28/29/30 revealed that single-shot calibration for legacy Sonos (Playbar gen 1 specifically) is fragile and slow even when working, and the M6.7 closed-loop fix is real engineering work that doesn't ship overnight. The 2026-05-30 ultrasonic-validation gate proved M6.7 is hardware-feasible (all four speakers reach at least MARGINAL at their preferred carrier frequency), but "feasible" is not "shipped." Meanwhile, the GitHub scout from 2026-05-29 evening dropped M12 (AirPlay 2 sender) from 4-6 weeks to 3-4 weeks via the `pair_ap` MIT discovery.

So the resource-allocation question became: **3-4 weeks of M12 (AP1+AP2 ships, 10× larger addressable market) vs 5-6 weeks of M6.6+M6.7 chasing a Playbar-gen-1-shaped corner case.**

### Market sizing — the napkin math

The legacy-Sonos addressable market is small enough to defer:

| Funnel stage | Estimate |
|---|---|
| Total Sonos households worldwide (~2024-2025 figures) | ~17M |
| Households with AT LEAST one legacy (non-AP2) speaker | ~25% → ~4M |
| Of those, multi-protocol-mix users (Sonos + AirPlay/Cast/etc.) | ~10-15% → ~400-600K |
| Of those, would consider a Mac app for cross-protocol sync | ~5-10% → ~20-60K |
| Of those, would download + pay $5 for a legacy-Sonos addon | ~20% → **~4-12K** total |

vs the AP1 + AP2 path's market:

| Funnel stage | Estimate |
|---|---|
| Mac users with multi-room AirPlay setups | ~5-10M |
| Multi-protocol-mix interest | ~10% → ~500K-1M |
| Realistic v1 paid downloads | ~5% → **~25-50K** total |

**~10× more addressable market for AP1+AP2 than for legacy-Sonos sync**, for *less* dev time. And M12 unlocks modern Sonos hardware (Beam, Arc, Era, One, Move, Roam, etc.) "for free" via AP2 — those are deterministic-sync receivers, no calibration needed.

### What v1 actually ships

- **AP1 multi-sink sync** — shipped. Proven (1-hour soak passed 2026-05-18; 3-speaker single-room real-room tests; ~1 ms cross-AP1 first-audio).
- **AP2 sender (M12)** — 3-4 weeks. Per-protocol module, vendoring `pair_ap` MIT + `swift-opus`, fresh Swift for PTP/RTSP/RTP.
- **Modern Sonos (Beam gen 1+, Arc, Era, One, Move, Roam, Era 100/300, Five gen 3, Era Pro)** — works automatically via AP2 path. No special engineering required.
- **Speaker groups**, **lossless mode**, **diagnostics panel**, **device-profile substrate (M5.5)**, **Claude Skill onboarding (M6.5)** — all proceed as planned.

### What v1 does NOT ship

- **Legacy Sonos sync** (Playbar gen 1, Play:1/3, Play:5 gen 1, Connect gen 1, Sub gen 1, Beam pre-2018, Sonos Bridge / BOOST). These devices show up in discovery but get a clear "Sonos sync — legacy hardware (best-effort, perfect sync coming in v1.1)" label in the menu. Users can play to them but should expect Sonos to drift ~1-3s from AP1.
- M6.6 single-shot calibration hardening — deferred. Useful only if we go back to the audible-burst single-shot model.
- M6.7 closed-loop continuous tracking — deferred to v1.1 as the "perfect legacy Sonos" moat play. The 2026-05-30 hardware-validation gate proved it's hardware-feasible; the implementation just isn't a v1 blocker.

### What v1.1 unlocks

When the Mac app v1 has shipped and there's user demand for legacy-Sonos sync (we'll know from sales / support requests / user research), M6.7 ships as a v1.1 hero feature:

> *"v1.1 — Perfect sync for every Sonos, including legacy hardware Sonos themselves abandoned. The only product that does it."*

That's a sharper narrative beat than mushing it into the v1 launch. And by then we have telemetry from real users about which legacy Sonos models matter most.

### Strategic implications for the launch story

- **M8 launch hero**: *"Perfect multi-room sync for every AirPlay speaker in your house, AP1 and AP2, at $19."* Crisp. No caveats. No "best-effort beta" labels.
- **AirPlay 2 makes us competitive with HomePods / Sonos S2 / modern AVRs / Bluesound** out of the box. Bigger universe than AP1-only.
- **Sonos becomes a Modern-Sonos-Just-Works story** instead of a we-tried-our-best-on-legacy story.
- **Legacy Sonos becomes a v1.1 "wow, they did the impossible" feature** instead of a v1 "their hero feature glitches" liability.
- **Cleaner reviews at launch.** The worst review for a sync product is "the sync doesn't work." We can credibly avoid that.

### Alternatives considered + rejected

- **Ship v1 with legacy Sonos as "best-effort beta" label** — rejected. Beta labels don't protect against reviews that say "the sync doesn't work." Users on launch day either get sync or they don't.
- **Push M8 ship 5-6 weeks later to include M6.7** — rejected. Time-to-market matters, and v1.1 is a real product update opportunity. Better to ship v1 in ~4 weeks (M12 alone) than v1+M6.7 in ~10.
- **Ship M6.7 only (skip M12)** — rejected. M12 has 10× the addressable market and ships in similar time. The Sonos-only story is too narrow for v1.
- **Hide legacy Sonos completely from v1 discovery** — rejected. Bonjour discovery is already running; hiding devices the user can see in the official Sonos app feels like a bug. Better: show them with clear labeling.

### What this means for next two weeks

1. **Stop spending engineering hours on Sonos calibration debugging.** The 2026-05-28/29/30 sprint surfaced enough to validate M6.7 is *possible*. Further iteration is post-v1.
2. **M12 AP2 sender becomes the priority engineering thread.** Start with vendoring `pair_ap` (~3 days), pair-setup/pair-verify against a HomePod or Beam gen 2, then build out PTP/RTSP/RTP fresh in Swift.
3. **M3 hardening remaining items** can run alongside M12 — 30-min soak + et=1 compressed-ALAC verification are passive, just need a recording session.
4. **M5.5 device-profile substrate + M6.5 Claude Skill alpha** continue on their existing track — independent of the Sonos question.
5. **Legacy Sonos user-facing label** — small UI change: when a Sonos device is detected and is NOT AP2-capable (no `_airplay._tcp` advertisement matching the same hardware), show a "(legacy — best effort)" tag in the menu. ~30 min of UI work, fits in M7 launch prep.

### Acknowledgment to the test bed

The Spacelab Playbar gen 1 was the test bed that surfaced this strategic clarity. Keeping it in the dev environment for M6.7 implementation work is still valuable (see 2026-05-29 afternoon decision — "add Beam, don't replace Playbar"). The strategic conclusion isn't "the Playbar gen 1 is unimportant." It's that **the engineering effort it requires is more valuable spent on AP2 first, and Sonos-legacy second**.

---

## 2026-05-31 — Sonos SonosNet group-piggyback technique: legacy Sonos sync becomes a v1 feature for mixed-Sonos households

**Decision:** Re-promote legacy Sonos sync to v1 scope **for the subset of users who own at least one AP2-capable Sonos in addition to their legacy Sonos** — via the **SonosNet group-piggyback technique** (programmatic group creation via the Sonos Cloud Control API). M6.7 closed-loop continuous tracking remains v1.1 territory for the smaller "ONLY legacy Sonos" cohort.

Partially supersedes the 2026-05-30 V1 scope tightening — that decision deferred ALL legacy Sonos sync to v1.1. With this new finding, **mixed-Sonos households get legacy sync in v1** without needing M6.7.

### The technique (discovered via GitHub research session on 2026-05-31)

Sonos's internal multi-room sync (SonosNet) is **sample-accurate within a Sonos group** — that precision is the literal core of Sonos's product. Sonos has zero documented external API for that precision (gotcha #17), but Sonos exposes it freely *to itself* via SonosNet whenever multiple Sonos devices are in a group.

**Therefore**: to sync legacy (non-AP2) Sonos like a Playbar gen 1 or Play:1 with AirPlay precisely, **piggyback on SonosNet via group membership**:

1. User has both an AP2-capable Sonos (Beam gen 1+, Arc, Era, One, Move, Roam, modern Five) and a legacy Sonos (Playbar gen 1, Play:1/3, Play:5 gen 1, Connect gen 1, etc.)
2. Group them via the Sonos app OR programmatically via the Sonos Cloud Control API's `modifyGroupMembers` endpoint
3. Stream via AirPlay 2 to the AP2-capable Sonos in the group (deterministic PTP timing)
4. **SonosNet internally relays the audio to the legacy Sonos with Sonos's own sample-accurate sync**
5. Result: legacy Sonos plays in PTP-synced time with the source — **the same precision modern Sonos achieves**, accessed indirectly via the group

This entirely bypasses gotcha #17 *for the mixed-Sonos cohort*. We never directly control the legacy Sonos's timing; Sonos itself does, internally, sample-accurately, because we made it a group member.

### Officially supported by Sonos (verified 2026-05-31)

[Sonos support article — "Stream AirPlay audio to Sonos"](https://support.sonos.com/en-us/article/stream-airplay-audio-to-sonos) explicitly documents this technique:

> *"When an AirPlay-compatible Sonos product is playing AirPlay audio, you can group it with any other Sonos product in your system for multi-room playback."*

This is not a hack or undocumented workaround — it's Sonos's officially supported integration pattern. Strengthens the case for shipping it in v1.

**Two caveats from the official doc that must be encoded in our implementation**:

1. **Surround-bonded Sonos cannot receive AirPlay.** *"AirPlay is not available on Sonos speakers that are set up as surround speakers."* Our auto-grouping feature must detect surround/home-theater bond config via Sonos Cloud Control API metadata and skip those speakers. Optional UX enhancement: prompt user to unbond if they want full AirPlay sync to those rears.

2. **AirPlay 1 from macOS may glitch.** *"you may experience a delay or audio interruptions"* — this is the gotcha #17 / AP1-from-Mac timing weirdness we already know. The v1 plan addresses this by streaming via **AP2** (M12) to the group leader, not AP1. Modern Sonos receives AP2 deterministically; SonosNet handles the rest.

### Why this wasn't on our radar before

None of the open-source projects we scouted (AirConnect, AirSonos, Music Assistant, home-service-music, etc.) implement this approach. They all treat each Sonos as an independent UPnP endpoint and stream to each directly with HTTP/RTP bridging — which is precisely what triggers gotcha #17. **Programmatic SonosNet grouping via the Cloud Control API to make Sonos's own sync do the work for us is, as far as we can tell, an unimplemented technique in the public space.**

The Sonos Cloud Control API surface map (logged 2026-05-29 morning in DECISIONS.md) flagged `createGroup` / `modifyGroupMembers` but noted them as "Sonos-internal only" — meaning we can't add NON-Sonos devices to a Sonos group, which is true. The piece I missed at the time: **adding legacy Sonos to a modern Sonos's group is exactly what we want** — Sonos players are exactly the devices these primitives operate on.

### What changes in the v1 plan

**V1 hero remains AirPlay 1 + AirPlay 2.** That part stays.

**New V1 feature: "Sonos auto-grouping for legacy support"**:
- Discover all Sonos devices on the LAN via existing `_sonos._tcp` Bonjour
- Identify which support AirPlay 2 (cross-check with `_airplay._tcp` advertisement) vs which are legacy (Sonos-only)
- When both are present, expose a UI option: "Group [Playbar gen 1] with [Beam gen 2] for AirPlay sync"
- Implementation: Sonos Cloud Control API integration — OAuth + `modifyGroupMembers` call
- Once grouped, stream via AP2 to the group leader; SonosNet handles legacy sync

**M6.6 partial re-promotion**: the Sonos Cloud Control API spike that was logged in M6.6 (post-v1.1) is **re-promoted to v1 priority** because we now need it for the auto-grouping feature. The other parts of M6.6 (single-shot safety nets, variance gate, save-on-confirm) stay deferred — those are only needed if we were going back to single-shot calibration, which we still aren't.

**M6.7 status unchanged**: still v1.1 for the "ONLY legacy Sonos, no modern Sonos anywhere" cohort. Smaller market than originally estimated but still real (early-adopter purists who never upgraded their fleet to S2).

### Market math re-evaluation

The 2026-05-30 napkin math assumed ALL legacy-Sonos households need M6.7. Re-segmenting:

| Cohort | Estimated % of legacy-Sonos households | V1 plan |
|---|---|---|
| Has legacy Sonos + at least one AP2-capable Sonos | **~70-85%** (most legacy-Sonos households have added an S2 product over the years) | **NEW: V1 auto-grouping feature → perfect sync** |
| Has ONLY legacy Sonos, no AP2 hardware anywhere on the LAN | ~15-30% | V1.1 M6.7 closed-loop |
| Single AP2 Sonos only, no legacy | Always works via AP2 (existing M12 plan) | V1 AP2 path |

So the **majority of legacy-Sonos owners now get perfect sync in v1**, not v1.1. The v1.1 M6.7 cohort shrinks but isn't zero — and serves as the "we did the impossible" hero feature for users who genuinely never upgraded.

This also strengthens the "add a Beam gen 2" personal recommendation we already gave: even users in our v1.1 M6.7 cohort can opt INTO v1's auto-grouping feature simply by adding any modern Sonos to their network — Beam gen 2, Era 100, Roam, whatever fits their budget and room.

### Implementation cost in v1

The Sonos Cloud Control API spike from M6.6 needs to land for this:
- **OAuth flow** integration (Sonos Cloud Control uses OAuth 2.0) — ~3 days
- **Discovery**: cross-reference `_sonos._tcp` and `_airplay._tcp` Bonjour to identify which Sonos players are AP2-capable — ~1 day
- **Auto-grouping UI**: detect mixed config, surface "Group legacy speakers with modern ones?" affordance in the menu — ~2 days
- **`modifyGroupMembers` integration**: programmatic group creation via Cloud Control API — ~2 days
- **Persistence**: remember user's group preference across launches — ~1 day
- **Testing**: requires a Beam gen 2 (or any modern Sonos) on the test bench alongside the Playbar gen 1 to validate. **Hardware acquisition**: ~$250-499.

Total: **~1.5 weeks of work + ~$250-499 in test hardware.** Adds to the v1 timeline but unlocks the larger legacy-Sonos market in v1.

### Alternatives considered + rejected

- **Skip the auto-grouping feature; tell users to group manually via Sonos app** — rejected. The whole product premise is "Press Play. Hear sync." If users have to open a separate app and manually group speakers each session, we're not solving the UX problem. Auto-grouping via Cloud Control API is the right execution.
- **Wait until v1.1 to ship this** — rejected. This is genuinely novel and competitively differentiating. Shipping it in v1 strengthens the "we sync everything modern Sonos does, AND legacy Sonos too" launch story for the mixed-Sonos majority.
- **Skip the Cloud Control API; use SonosNet protocol reverse-engineering for direct sync** — rejected. SonosNet's group-formation traffic is part of the encrypted UPnP layer (gotcha #17). The Cloud Control API is the official, supported, future-proof path to the same outcome.

### Risks

- **Cloud Control API requires user OAuth login** — adds friction at first run. Mitigation: make this a one-time setup, not a per-session login. Users who don't have Sonos can skip it entirely.
- **Cloud Control API requires internet connection** to authenticate (after auth, group commands themselves may work LAN-only — needs verification). Could be a problem for users on isolated networks. Mitigation: document the requirement clearly; manual-grouping fallback for offline users.
- **"Works with Sonos" certification** is invitation-only but using their public APIs without certification is allowed. We won't claim certified status until / unless we apply.
- **Sonos may deprecate or rate-limit the Cloud Control API** — out of our control. Mitigation: maintain UPnP fallback for direct control of individual Sonos (which we already have for play/stop). Auto-grouping just won't work, but everything else does.

### What this means for tomorrow

1. **Sonos Cloud Control API spike** becomes a priority engineering thread alongside M12 AP2 sender. ~1.5 weeks. Can run in parallel since the two domains barely touch.
2. **Buy a Beam gen 2 or Era 100** for the test bench — $250-499. Required hardware for testing the auto-grouping feature against Playbar gen 1.
3. **Update ROADMAP M8 scope** to include "legacy Sonos sync (mixed-Sonos config)" as a v1 feature.
4. **Update ROADMAP M6.6** to re-promote the Cloud Control API spike to v1 priority while keeping the other M6.6 items deferred.
5. **Marketing copy** flexes slightly: "Perfect sync for every AirPlay speaker + Sonos in your house, modern or legacy (when grouped with any AP2-capable Sonos)." A bit longer but honest and covers the actual product.

---

## 2026-06-03 — Passive content-based sync + the "slowest sink is the reference" model

**Decision:** Add a passive, continuous auto-corrector (`PassiveSyncMonitor`) that keeps speakers in sync **from the live music, with no calibration chirp**, and restructure correction around one rule: **the slowest sink is the reference, and every faster *controllable* sink is delayed up to match it.** Supersedes the implicit "always delay AirPlay to match a slower Sonos" assumption baked into the chirp calibration and Auto-Align paths.

**How it works:** SuperAudio already knows the exact waveform sent to each speaker (the broadcaster reference tap). Cross-correlating the Mac mic against that reference yields one peak per speaker, each at that speaker's true playback lag — recovered from ordinary content, no test tone. New primitives in `AudioCorrelation`: `topCorrelatedLags` (top-N peaks with non-max suppression) and `strongestPeak(in window)`. The controller medians the per-round error, gates on SNR, clamps the step, deadbands, and settles past the receiver's silent catch-up gap after a shift. Two modes via `passiveSyncArmed`: observe (logs geometry + "would apply") and armed (applies via `SessionState.setOffset`, which persists, retimes live, and snoozes the health monitor).

**Rationale — two empirical findings on 2026-06-03 (real-hardware test, AirPlay "Spacelab Audio" + Sonos Playbar):**
1. **Passive measurement works.** With domain-constrained search + median smoothing, the mic-vs-reference correlation tracks each speaker's lag from live YouTube audio (clean 10-round stretches; Sonos peak stable to ±10 ms). The chirp's only remaining justified role is a one-time coarse anchor on ambiguous/quiet content — not a repeated ritual.
2. **The control assumption was inverted for this hardware.** "Spacelab Audio" buffers ~3.4 s — it is *slower* than the Sonos (~2.4 s). Since every lever only **adds** delay (you cannot un-buffer a receiver; Sonos timing can't be pulled forward — see gotcha #17), a slow AirPlay sink can't be sped up to meet a faster Sonos. Hence the general rule: align everyone **up** to the slowest sink. Legacy Sonos's natural role is the immovable reference; it can only be made a *follower* once a continuous Sonos feed-delay exists (not yet built — when the slowest sink is AirPlay and Sonos is faster, the corrector now reports the limitation instead of mis-correcting).

**Identification by motion:** a heavy-buffering receiver's peak sits far from its commanded offset, so we don't assume where it is — we nudge the controllable sink's delay by a known amount and detect which peak moved by that amount. The mover is that sink; stationary peaks are reference-class. Makes the corrector hardware-agnostic to hidden receiver buffers.

**Why this is strategically significant:** passive, continuous, cross-protocol harmonization of consumer speakers across ecosystems doesn't exist as a product (see COMPETITIVE_LANDSCAPE). It's the consumer application of what Smaart/REW/ARTA do in pro audio. The AP2 path (M12) makes it shine — AP2 sinks (HomePod, Apple TV, modern Sonos) are low-latency *and* fully delay-controllable, so they slot into the "delay-to-slowest" model cleanly, with legacy Sonos as the anchor.

**Alternatives considered:** keep chirp-only calibration (rejected — single-shot goes stale as Sonos drifts 2.7–3.1 s within a session; audible; can't track continuously). Blind top-N peak picking without motion identification (rejected — mis-locks on beat-spaced false peaks; can't attribute peaks to sinks when a receiver's buffer is large). Reverse-engineer Sonos timing shift (rejected — gotcha #17, encrypted).

**Follow-ups:** (a) continuous Sonos feed-delay (prepend silence / hold HTTP writes) so legacy Sonos can be a follower, not only the reference; (b) generalize identification to multiple simultaneous controllable sinks once AP2 lands; (c) one-time coarse chirp anchor for ambiguous content; (d) once verified, prune the redundant repeated-calibration UI (keep chirp as the anchor). Status 2026-06-03: corrector rewritten + building; verified passively measuring; armed end-to-end correction not yet confirmed on hardware.

---

## 2026-06-03 (evening) — Cross-protocol sync confirmed on real hardware; GCC-PHAT is the next lever

**Result:** Mic Calibrate (auto) brought a B&W A5 (AirPlay 1) into sync with a Sonos Playbar **and** a newly-added Sonos One SL (two Sonos zones, "Den" + "Den 2") — from ~1.3 s out to a barely-perceptible residual ("a hair ahead"). First confirmed cross-ecosystem harmonization on real hardware. The two Sonos stay perfectly in sync with each other (Sonos's own SonosNet); the A5 is the controllable sink we slide onto them.

**Confirmed conclusions:**
- **Mic-based measurement >> Sonos UPnP self-report** for accuracy. The chirp anchor is reliable (SNR 10–15); passive measurement from music is accurate on good signal but marginal on quiet/periodic content.
- **Direction is AirPlay → Sonos.** You can only ever *add* delay; Sonos can't be sped up or precisely shifted, so it's the fixed reference and the AirPlay sink slides onto it. (A5 intrinsic buffer ≈ 0.31 s — it's the fast sink; the earlier "3.4 s / behind" readings were a stale 3359 ms offset + ambiguous-music noise, not the device.)
- **The residual is Sonos drift.** A one-shot calibration goes slightly stale within minutes as Sonos's hidden buffer drifts — which is the whole argument for *continuous* correction.

**Bug fixed:** the corrector treated an over-delayed (stale-offset) AirPlay sink as the immovable "floor" and refused to correct it. Now it judges the AirPlay sink by its *intrinsic buffer* (not its currently-offset position) and **reduces** the offset when overshot — reference is the slowest *other* sink.

**Next lever (decided):** **GCC-PHAT** (phase-transform cross-correlation) is the #1 next build — whitens the signal so peaks stay sharp on music/reverb, which is what's needed to make the continuous passive loop (`PassiveSyncMonitor`) hold reliably. Interim fallback: periodic chirp re-anchor (~60–90 s). Silent endgame: per-speaker inaudible ~18–19 kHz pilot (M6.7). AP2 (M12) makes all of this easier — AP2 sinks are low-latency and fully delay-controllable.

---

## 2026-06-03 (later) — License flip to PROPRIETARY; rotary-knob UI removed; AirPlay delay slider now 25 ms steps

**Decision (a) — license:** SuperAudio's app and source code are now **proprietary — all rights reserved** (see `LICENSE.md`). This **supersedes** the 2026-05-11 "MIT-clean codebase / option to open-source" framing: we are no longer reserving the option to release the app under permissive terms. What carries over unchanged is the **no-GPL-copying hygiene** — no GPL code is copied into the binary, in-binary deps stay permissive (MIT/BSD/Apache) or runtime-only carve-outs, and GPL projects remain read-only protocol references. The `superaudio-device-profiles` subrepo stays **MIT** (it is intentionally open, per the Tailscale substrate-open/app-paid model in the 2026-05-15 thread-4 entry). Every source header was swept from "MIT licensed" to "Proprietary"; README / CLAUDE.md / THIRD_PARTY_NOTICES.md updated to match.

**Decision (b) — sync UX:** The **rotary-knob UI (ROADMAP #100) is removed/cancelled** — the linear slider plus auto-calibration covers the tuning need; a bespoke knob isn't worth the build. The AirPlay delay slider now steps in **25 ms increments** (was 0–6000 ms at 5 ms steps); 25 ms is fine-grained enough for by-ear tuning without the finicky drag that motivated the abandoned knob.

---

## 2026-06-04 — tvOS companion blocked by platform; hardware hub is the TV path

**Decision:** Kill the **"Apple TV companion ($5, tvOS)"** SKU (ROADMAP M9). It was built on a false premise. The "TV → all speakers in sync" use case is delivered by a **hardware hub on the TV's audio output (HDMI ARC / optical)** — the existing Hub Stick / Optical Hub / Hub Pro concept — not by a tvOS app.

**Why the tvOS premise is invalid:**

- **tvOS cannot capture the audio you'd want to fan out.** There is no tvOS system-audio / process-tap API (the macOS `CATapDescription` path has no tvOS equivalent), and the platform forbids an app from capturing other apps' audio. **DRM/FairPlay content — Netflix, Apple TV+, Disney+, etc. — is untouchable.** A tvOS app could only fan out audio it plays *itself* (its own in-app media player), which is a non-starter for the streaming services people actually watch. The roadmap's "Apple TV companion — same fan-out from an Apple TV instead of a Mac" is therefore essentially not buildable for real-world TV content.
- The fallback "Mac sends to Apple TV over AP2, Apple TV re-fans-out" plan doesn't rescue it either — that only relays the Mac's audio; it does nothing for content the Apple TV itself is playing, which is the entire point of a TV-anchored household.

**Why hardware is the right path:**

- A hub sitting on the TV's HDMI ARC / optical output captures the **actual audio signal downstream of the sandbox + DRM**, then fans out + syncs across protocols. That's the technically-sound living-room/TV path. (ROADMAP M14 Hub Pro = HDMI ARC; M15 Optical Hub = TOSLINK.)
- **For all-AirPlay-2 setups, the Apple TV already fans its own audio to every AP2 speaker natively** — no third party needed. So even where a tvOS app *could* technically relay AP2, it adds nothing.
- **SuperAudio's value is the heterogeneous / legacy case** — old AirPlay 1 (e.g., a B&W A5) and legacy Sonos mixed with everything else. A tvOS app can't serve this anyway: it can't capture, and it can't drive AP1 / legacy receivers into AP2 groups. The hub can.

**The sync engine is not wasted.** The cross-protocol acoustic sync engine (the novel IP — see 2026-06-03 entries) is the **shared brain reused by both the Mac app and the hub.** The Mac app is its proving ground / dev kit; the hub is the consumer form factor for the TV use case. Cancelling the tvOS SKU removes a dead-end form factor, not the technology.

**Supersedes** the "Apple TV companion ($5, tvOS)" SKU framing from the 2026-05-13 "Product scope expanded to multi-SKU product line" entry. The "Mac must stay on" concern that motivated that SKU is answered instead by the Hub Stick (non-Mac sourcing) and the hubs (living-room TV). ROADMAP M9 is marked CANCELLED; the SKU table strikes the Apple TV companion row and points the TV use case at the hubs.

**Alternatives considered:**
- *Ship a tvOS app that fans out only its own in-app player audio.* Rejected — nobody wants a SuperAudio-branded media player; the value was supposed to be fanning out whatever's on the TV, which tvOS structurally prevents.
- *Wait for Apple to add a tvOS system-capture API.* Rejected as planning on a non-existent, unlikely API (system audio capture on tvOS would undermine FairPlay; Apple has no incentive to ship it).

---

## 2026-06-05 — Auto-correctors destabilize AirPlay 1; static by-ear offset is the stable path

**Decision:** For AirPlay 1 sinks, the **stable, shippable sync recipe is a static manual offset set by ear, with all automatic correctors off** (Passive Sync in observe-only mode, Mic Calibrate (auto) never run). Continuous hands-free correction of an AP1 sink is **not viable on this hardware** and is deferred to the AP2 path (M12). This refines — does not reverse — the 2026-06-03 "continuous passive correction is the moat" entries: the *measurement* is real, but *applying* corrections to a live AP1 receiver is the part that breaks.

**Root-cause finding (real-hardware test, B&W A5 "Spacelab Audio" + Sonos Playbar + Sonos One SL):** the "A5 keeps failing and reconnecting" symptom — a reconnect loop firing roughly every 13 s — is **not the speaker**. The A5 pings fine, advertises `_raop._tcp`, and answers RECORD with `200 OK` throughout. The loop is caused by the **automatic offset correctors** — `MicCalibrator` ("Mic Calibrate (auto)") and the **armed** `PassiveSyncMonitor` — each of which **restarts the AP1 receiver (TEARDOWN + re-RECORD) on every offset change.** Proven from live OSLog: every corrector apply lines up with a session restart.

**Mechanism (ties to gotcha #16):** the A5 clamps far-future NTP scheduling to its ~93 ms buffer, so an offset can't be honored receiver-side — it's applied **sender-side** as an `AudioBroadcaster` delay. A large retime momentarily starves/silences the receiver; the health monitor reads the dead-air as a dropped receiver and restarts the session. `MicCalibrator` compounds this by *explicitly* restarting the AP1 sink after it applies its delta. So any corrector that touches a live AP1 offset — even a "correct" one — pays a restart, and a continuous corrector pays one every cycle.

**Trust the ear, not the mic.** Mic-based auto-calibration disagreed with the by-ear-correct value by **~1.2 seconds** (the mic wanted ~4200 ms; the ear settled at ~3050 ms). The mic was right about *where the mic is* and wrong about *where the listener is* — mic position ≠ listening position, and the geometry difference is well over a second of acoustic travel + room effect. For a consumer sync product the listening position is the only one that matters, so the **ear is ground truth** and the mic is at best a coarse starting anchor.

**The stable recipe (what actually works today):** static manual AP1 offset by ear (~3050 ms for the A5 against these Sonos) + Passive Sync **OFF / observe-only** + **never** run Mic Calibrate (auto). With no corrector touching the offset, the A5 never restarts — it stays connected and in sync indefinitely. The cost is that **Sonos's hidden buffer drifts session-to-session**, so the static offset needs occasional manual re-tuning by ear. That re-tuning is cheap and infrequent; the reconnect loop was not.

**Reinforced conclusion — hands-free sync needs AP2 (M12).** The whole reason AP1 can't be continuously corrected is that it isn't smoothly retimable: every nudge is a restart. **AP2 is low-latency *and* fully delay-controllable**, so a continuous corrector can retime an AP2 sink in place without tearing the session down. The "delay-to-slowest-sink" model from 2026-06-03 only becomes hands-free once the controllable sinks are AP2. Until M12 lands, continuous auto-correction stays an observe-only research mode, and the product story for AP1 is "set it once by ear."

**Supporting code shipped this session (reduces churn but does NOT make armed AP1 correction safe):**
- **`PassiveSyncMonitor` runaway fix.** The passive corrector was over-correcting itself into oscillation. Fixed by (a) **trust-geometry** for locating the AP1 sink's position (judge by intrinsic buffer + observed motion, not the currently-commanded offset — same spirit as the 2026-06-03-evening bug fix), (b) a **hysteresis "converged" lock** so once the geometry settles the monitor stops nudging, and (c) widening the **deadband 40 ms → 120 ms**. Together these stop the self-induced churn — but an armed apply still restarts the A5, so the monitor stays observe-only for AP1.
- **Sonos auto-align default bumped 2000 ms → ~3025 ms** to match where the by-ear AP1 offset actually lands against these Sonos zones, so the starting point is close instead of a second-plus off.
- **Cross-protocol sink dedup.** A modern Sonos advertises both a Sonos face and a redundant AirPlay face; we now dedup so the same physical speaker doesn't appear twice and get driven over two protocols at once. (Hygiene cleanup surfaced while chasing the reconnect loop.)

**Alternatives considered:** keep armed continuous correction on AP1 and suppress the restart (rejected — the restart is the health monitor doing its job; defeating it to paper over corrector-induced silence risks masking real network drops, gotcha #15); trust the mic value and live with it (rejected — ~1.2 s wrong at the listening position is audibly bad); reverse-engineer Sonos timing to make Sonos the follower instead (rejected — gotcha #17, encrypted). The honest answer is: static-by-ear now, AP2-driven continuous later.

---

## 2026-06-09 — Soak test: corrector-off holds, but an AP1 reconnect breaks cross-sink sync; WiFi fragility is the remaining enemy

**Finding:** A ~3-hour real-hardware soak (B&W A5 + grouped Sonos, static offset ~3050 ms, all correctors off) **validated the corrector-off recipe — zero corrector events the entire run.** The 2026-06-05 fix holds: nothing self-inflicted a restart. But the soak exposed the *next* failure mode: **a single AP1 reconnect permanently breaks cross-sink sync, and nothing re-aligns it.**

**What happened:** the A5 suffered **real WiFi network drops** — genuine socket deaths (`Socket is not connected` → timing packets stale → health monitor "Network loss detected" → supervisor auto-reconnect). They clustered in the first ~35 min (reconnects at 16:43, 16:43, 17:02, 17:13), then the A5 stayed rock-solid for the final ~2.5 hours. These are honest AirPlay-1-over-WiFi drops, **not** corrector-induced (correctors were off).

**Why a reconnect desyncs:** on auto-reconnect the A5 re-subscribes at its **static offset** (`subscribe delay=3.000s`) — a stale point-in-time value. But the Sonos kept playing and **drifted through the gap**, so the A5 comes back aligned to where the Sonos *was*, not where it *is*. There is no re-alignment step after a reconnect, so once a drop happens the two stay out of sync for the rest of the session. The static-offset model survives a *quiet* session indefinitely but **cannot survive one WiFi blip.**

**Conclusion / next levers:**
1. **Ethernet the A5** is the highest-leverage reliability fix — it attacks the *trigger*. The drops were all real WiFi losses; the A5 has an RJ45 jack. No drops → no reconnects → the static offset holds. This is now the recommended deployment for the AP1 sink.
2. **Re-sync after reconnect** is the missing software feature, but on AP1 it's circular: re-aligning means another offset change, which means another restart. So robust mid-session re-sync really wants **AP2 (M12)** — smoothly retimable, reconnect-tolerant. Reinforces the 2026-06-05 conclusion from a new angle: AP1 is fragile both to *correction* and to *reconnection*; AP2 fixes both.

**Also confirmed this session (logged in ROADMAP M6.6a):** grouping the Sonos in the Sonos app and feeding **only the group coordinator** through SuperAudio gives sample-locked Sonos-to-Sonos sync (SonosNet) — the M6.6a premise, validated by hand. The gap: SuperAudio has no group-topology awareness, so activating *both* grouped members double-streams and fights the group.

---

## 2026-06-25 — Sonos group awareness shipped: feed the coordinator only (M6.6a precursor)

**Decision:** SuperAudio now reads Sonos zone-group topology and **feeds only the group coordinator**, hiding non-coordinator members from the menu and from Play All. This is the precursor half of M6.6a — read-only awareness of *existing* groups — and it closes the double-stream gap that bit twice (observed 2026-06-09, recurred under the 2026-06-16 soak as "even the grouped Sonos went out of sync"). The full M6.6a (programmatic auto-grouping via Sonos Cloud Control for users who haven't grouped in the Sonos app) remains ahead; coordinator-only feeding is its foundation.

**Why it was breaking (gotcha #24):** a Sonos group is sample-locked over SonosNet by one coordinator; the other members render the coordinator's relay, not an external stream. SuperAudio discovered each grouped speaker as a separate `_sonos._tcp` renderer and — via "Play All" — streamed an independent HTTP/AAC stream to *both*. Two competing streams into an already-synced group → the members fight → drift that no AP1 offset can fix (the two Sonos aren't even aligned with each other). The user's instinct was right: "set a GROUP device and omit the other cleanly" — that's exactly coordinator-only feeding, and it should be automatic, not a manual per-session deselect.

**Implementation:**
- **`SonosClient.getZoneGroupState()`** — one new SOAP call to `ZoneGroupTopology:1` (`GetZoneGroupState`). The `<ZoneGroupState>` field carries the group XML as an escaped string; we extract, unescape, and regex-parse `ZoneGroup`/`ZoneGroupMember` (Coordinator UUID, member UUID, member ZoneName). Satellite sub-elements of a stereo/surround member are ignored — they're sub-units of one logical member, not separate sinks. The service is **household-global**, so one online Sonos maps the whole house.
- **`SonosTopology`** (app module, `@Observable`) — polls every 10 s (group membership changes rarely) from the first reachable Sonos, plus exposes `hiddenMemberIDs(among:)` and `groupedMemberNames(forCoordinator:)`.
- **`MenuBarView`** — `visibleSinks` filters out hidden members (so rows, Play All, and saved-group capture all inherit it); the coordinator row gets a "group → +<members>" subtitle. "Show all devices" reveals members again for diagnostics.
- **Identity maps cleanly** because the Sonos discoverer already uses `RINCON_<UDN>` as the `SinkID`, which equals the topology member `UUID`; a room-name fallback covers any Bonjour-vs-topology format drift (room names are unique per household).

**Fail-open contract:** if topology is unknown — no Sonos discovered yet, or every poll failed — `groups` is empty and the helpers hide *nothing*. A transient SOAP timeout keeps the prior snapshot rather than flickering a member back into the menu. The app never hides a speaker the user wants because a poll failed.

**Verified on real hardware (2026-06-25):** the poller detected the live group `2×[Spacelab Den + Den]` and polls cleanly every 10 s; the A5 ("Spacelab Audio", a distinct name) is unaffected and still listed. Parser also unit-checked offline against a representative escaped `ZoneGroupState` payload incl. a stereo pair with satellites. **Note a naming subtlety this surfaced:** the A5's AirPlay name is "Spacelab **Audio**", while the two Sonos zones are "Spacelab **Den**" and "Den" — no collision with the A5, and the Sonos's own redundant AirPlay face ("Spacelab Den", `_raop`) was already cross-protocol-deduped (gotcha-adjacent existing behaviour). This is *Sonos network grouping*, distinct from SuperAudio's own saved Speaker Groups (`SpeakerGroups.swift`), which are unaffected.

**Alternatives considered:** keep the manual "activate only one Sonos of a group" workaround (rejected — the user explicitly wanted it automatic, and a per-session manual step is exactly the friction that produced the bug); hardcode coordinator detection by name (rejected — brittle; topology is the source of truth and handles regrouping live); block/disable non-coordinator rows instead of hiding (rejected — hiding is cleaner and matches "show the group as one device," with "Show all devices" as the escape hatch). See gotcha #24 + ROADMAP M6.6a.

---

## 2026-06-25 (M12 sprint) — AP2 pairing: CryptoKit-native fresh Swift, NOT vendored pair_ap; revises the 2026-05-29 plan

**Decision:** Implement AirPlay 2 pairing (pair-setup + pair-verify) in **fresh Swift on Apple CryptoKit**, NOT by vendoring the `pair_ap` C library. The one primitive CryptoKit lacks — big-integer modular arithmetic for SRP-6a — is supplied by a **pure-Swift MIT BigInt package** (attaswift/BigInt), which reintroduces none of the C-build cost that motivated the original vendoring decision. **This revises the 2026-05-29 (evening) decision** to "vendor pair_ap (MIT)"; that part of the plan is superseded. The rest of the 2026-05-29 stack stands (swift-opus for the codec is still on the table; fresh Swift for PTP/RTSP/RTP; shairport-sync/nqptp/pair_ap read-only as protocol references).

**Why revise:** the 2026-05-29 estimate picked `pair_ap` for *speed* (SRP-6a + the HomeKit message grammar was projected at ~2 weeks of fresh Swift; vendoring dropped it to ~3 days). Two facts seen at implementation time invert that math:
1. **CryptoKit already covers ~80% of the crypto natively** — Curve25519 (X25519 ECDH), ChaCha20-Poly1305, Ed25519 sign/verify, HKDF, SHA-512. None of these need to be written or vendored. What's actually left to write fresh is small: TLV8 encode/decode, SRP-6a (on top of a bignum), and the pairing state machine.
2. **Vendoring `pair_ap` drags in a C toolchain tax** — libsodium + libplist + libgcrypt, a mixed C/Swift SPM target, and ad-hoc-signing a mixed bundle that is currently pure-Swift. That plumbing is itself multi-day and is the most likely "M12 not done by day 14" failure mode. The path chosen for speed had become the slower, riskier one.

**Why this fits the codebase philosophy better than the original plan:** the project's stated norms are "fresh Swift implementations only" for protocol/wire code (same rule applied to RAOP), "no CocoaPods, keep SPM clean," ad-hoc local signing, and strict license hygiene. CryptoKit-native + one pure-Swift MIT dep honors all of these; the C-vendoring path strains the signing/build simplicity. License hygiene is *stronger* this way: pair_ap/shairport-sync are read **as protocol reference only** (the wire format is a fact, not copyrightable — identical stance to RAOP), so no third-party pairing code enters the binary at all. attaswift/BigInt (MIT) is the only added dependency; it gets a THIRD_PARTY_NOTICES entry.

**What gets built (fresh Swift, CryptoKit + BigInt):** TLV8 codec → SRP-6a (SHA-512, RFC 5054 3072-bit group), verified against RFC test vectors offline → pair-setup transient flow over RTSP POST → pair-verify (X25519 ECDH + Ed25519 + ChaCha20-Poly1305 + HKDF, all CryptoKit) → derived session keys. Receiver references read (not copied): shairport-sync `pair_ap/`, `lmcgartland/airplay2-rs` (sender-side).

**Risk acknowledged:** SRP-6a correctness and matching the exact HomeKit/AirPlay message grammar are fiddly and only fully verifiable against a real receiver (the One SL, `needsPairing=yes`, is the test bed; a woken Apple TV 4K is the second). Offline RFC-5054 test vectors de-risk the SRP math before we ever hit the device. If a receiver turns out to need a pairing variant that's materially harder than transient SRP, revisit vendoring for that piece only — but the primitives stay CryptoKit.

**Alternatives considered:** vendor pair_ap as committed (rejected — see "why revise"); write our own bignum/modexp instead of a dep (rejected — error-prone and slow; a vetted MIT pure-Swift BigInt is the right call and stays C-free); use Apple's `Security`/`Accelerate` for modexp (rejected — no public arbitrary-precision modexp API). See ROADMAP M12 + gotcha #25.

---

## Open questions (resolve before the affected sub-task)

- **Hub Stick OS image: Buildroot vs Raspberry Pi OS Lite (M13).** Buildroot is smaller and more reproducible; Raspberry Pi OS Lite is easier to maintain and gets security updates for free. Decide closer to M13.

(If the Day 0 capture probe forces Plan B, that resolution gets logged as a new entry above. — N/A as of 2026-05-13; Plan A confirmed.)
