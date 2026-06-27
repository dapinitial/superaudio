# SuperAudio

Multi-room synchronized audio for the Mac. Captures system audio (any app) and streams it to a heterogeneous mix of network speakers: AirPlay 1, Sonos, and — eventually — AirPlay 2, Chromecast, Bluetooth.

The wedge: cross-ecosystem fan-out at consumer prices, with cross-protocol room tuning. Everyone else picks one ecosystem (Sonos, AirPlay 2, BluOS, HEOS) and defends it. We're the door between them.

## Repository layout

```
superaudio/
├── CLAUDE.md, README.md, LICENSE.md   ← repository root (anchor docs)
├── docs/                              ← engineering & decision docs
│   ├── ROADMAP.md
│   ├── DECISIONS.md
│   ├── STYLE.md
│   └── THIRD_PARTY_NOTICES.md
├── website/                           ← public-facing site + strategy artifacts
│   ├── _shared.css
│   ├── index.html
│   ├── CASE_STUDY.html
│   ├── COMPETITIVE_LANDSCAPE.html
│   ├── PRICING.html
│   ├── POSITIONING.html
│   ├── HUB_DESIGN.html
│   ├── RISK_REGISTER.html
│   └── REACTIVE_DISCOVERY.html
├── Package.swift
├── Sources/                           ← Swift modules (see below)
└── probe/                             ← single-file diagnostic programs
```

## Documentation map

**Engineering** (in `docs/`):
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — where we are, what's next, the linear path from POC to product. Read this first.
- **[CLAUDE.md](CLAUDE.md)** — architectural brief: module layout, contracts, gotchas, working norms.
- **[docs/DECISIONS.md](docs/DECISIONS.md)** — append-only record of why we chose X over Y.
- **[docs/STYLE.md](docs/STYLE.md)** — house style guide for the strategic HTML docs (palette, components, when to add a new doc).
- **[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)** — attribution for everything we use or read.

**Strategy &amp; public** (in `website/`):
- **[website/index.html](website/index.html)** — product landing page.
- **[website/CASE_STUDY.html](website/CASE_STUDY.html)** — full strategy: positioning, TAM, personas, SKUs, demographics.
- **[website/COMPETITIVE_LANDSCAPE.html](website/COMPETITIVE_LANDSCAPE.html)** — competitor analysis + patents + legal hurdles.
- **[website/PRICING.html](website/PRICING.html)** — every price defended against competitor anchors, BOM, and sensitivity ranges.
- **[website/POSITIONING.html](website/POSITIONING.html)** — voice, message pillars, brand antithesis test. Binding for marketing surfaces. Also includes the technical-framing section for non-consumer surfaces (investors, partners, DevRel).
- **[website/HUB_DESIGN.html](website/HUB_DESIGN.html)** — forward-looking Hub Stick (M13) + Hub Pro (M14) design vision, hardware sizing, design gaps, manufacturing strategy. Not a committed BOM; architectural framework.
- **[website/RISK_REGISTER.html](website/RISK_REGISTER.html)** — what could kill this project, with mitigations and trigger-to-act per risk.
- **[website/REACTIVE_DISCOVERY.html](website/REACTIVE_DISCOVERY.html)** — build log artifact for the discovery milestone.

## Status — 2026-06-03

- ✅ **M1 — Foundation.** Scaffolding, capture, discovery, menu bar app.
- ✅ **M2 — RAOP control plane.** Full RTSP handshake to B&W A5 and A7 with NTP timing-channel replies.
- ✅ **M3a — First audio from B&W A5 and A7** (2026-05-14). Captured Mac audio → compressed ALAC → RTP → speakers audibly playing. Three findings unlocked this: AirPlay 1 requires real compressed ALAC (not verbatim/escape mode), sync packets must come from the advertised source port (BSD socket), and `et=0` is sufficient.
- ✅ **M3 hardening — SIGTERM teardown + Sonos quit cleanup** (2026-05-14). `killall SuperAudio` fires TEARDOWN cleanly. Sonos `Stop` on app quit.
- ✅ **M3c — Lossless Mode + bit-exact verification** (2026-05-15). Menu toggle forces Mac output to 44.1 kHz while a session is active. `probe/LosslessVerify` proves ALAC encode→decode is SHA-256 match.
- ✅ **M4 — Sonos audio pipeline** (2026-05-15). `AACEncoder` + `SonosStreamServer` + `SonosSession` with pump-before-SOAP ordering.
- ✅ **M5 — Multi-sink fan-out + sync + per-sink controls** (2026-05-15 night). Shared `AudioBroadcaster` (one capture, fan-out to N subscribers). Per-chunk wall-time NTP for cross-sink sync. Per-sink volume + offset sliders.
- ✅ **M6 — Multi-sink sync + reliability arc** (2026-05-17). The big architecture push: sender-side broadcaster delay (sidesteps AP1 receivers' NTP-clamping behavior), handshake barrier (cross-AP1 first-audio within 1 ms regardless of handshake variance), Sonos start-align defer, supervisor retry cap (kills retry storms on un-acceptable receivers), session-race nonce guard, idempotent Play All, Restart All, audio-gap telemetry. **A user empirically dialed in `slider=3085 ms` and said "wow, perfect" with all three speakers audibly in sync.** See [docs/DECISIONS.md](docs/DECISIONS.md) 2026-05-17 entry for the three core architectural decisions.
- ✅ **M6.3 — Mac-mic auto-calibration shipped (M11 Path A precursor)** (2026-05-18). The marquee win: chirp injection + Accelerate vDSP FFT cross-correlation + per-speaker sequential measurement + auto-applied offsets. Real-room test converged 3 passes from 1000ms residual → "playing in sync it's beautiful" (~12ms, within mic correlation noise). _(2026-06-05 caveat: that convergence ran while the AP1 receiver restarted each pass, and the mic target was ~1.2s off the by-ear value — the ~12ms is mic-correlation self-consistency, not audible alignment at the listening seat. See the cross-protocol bullet below.)_ Three load-bearing bugs documented as CLAUDE.md gotchas 20–22 (ambient music can't be reference → use chirps; AVAudioEngine 3-sec first-init quirk → 500ms warmup; persisted offsets live in UserDefaults not the in-memory dict). See [docs/DECISIONS.md](docs/DECISIONS.md) 2026-05-18 entry.
- ✅ **M6.4 — Painless auto-trigger Phase 1** (2026-05-18). Mic Calibrate (auto) button now runs automatically ~5 sec after Sonos's SOAP Play succeeds. `autoCalibrateOnPlayAll` pref toggleable. _**Superseded 2026-06-05:** this auto-trigger is the corrector that restarts the AP1 receiver on every adjustment (~13s reconnect loop), so it's best left OFF — the stable path is a static by-ear offset (see the cross-protocol bullet below). Hands-free retiming awaits AP2 (M12)._
- ✅ **Cross-protocol sync is real and audibly achievable** (2026-06-03; caveat 2026-06-05). Mic Calibrate (auto) brought a B&W A5 (AirPlay 1) into audible sync with a Sonos Playbar **and** a Sonos One SL — first confirmed cross-ecosystem harmonization on real speakers. Direction is AirPlay → Sonos: you can only ever *add* delay, so the slowest sink is the reference and the controllable AirPlay sink slides onto it. **Caveat (2026-06-05):** the *auto* path is unstable — each offset adjustment restarts the AP1 receiver (TEARDOWN + re-RECORD), so corrector churn shows up as a ~13s A5 reconnect loop (the speaker is healthy — it pings, advertises RAOP, RECORDs 200 OK). The mic also disagreed with the ear by ~1.2s (mic position ≠ listening position). **Stable config today:** a static by-ear manual offset (~3050ms for the test A5) with auto-correctors OFF — no corrector touches the offset, so the A5 stays connected and in sync. Sonos buffer latency drifts session-to-session, so the static offset needs occasional manual re-tuning. Hands-free continuous retiming is the AP2 (M12) goal, not shipping yet.
- ✅ **`PassiveSyncMonitor` — passive content-based continuous sync.** Chirp-anchor once, then track each speaker's lag continuously from live music (mic vs. broadcaster reference, no repeated test tone). _Observe-mode measurement works; **armed correction restarts the AP1 sink on apply (2026-06-05), so it's not production-ready until AP2 (M12)** provides smooth in-place retiming._ Next lever is **GCC-PHAT** (phase-transform correlation); interim fallback is periodic chirp re-anchor; silent endgame is a per-speaker ultrasonic pilot. See [docs/DECISIONS.md](docs/DECISIONS.md) 2026-06-03 entries.
- ✅ **M6.6 — Sonos group awareness, read + write** (2026-06-25/26). Reads zone-group topology (`ZoneGroupTopology`) and feeds only the group **coordinator** — SonosNet keeps the rest sample-locked, so a grouped pair can't be double-streamed (the cause of an audible drift bug). Plus one-tap **Group / Ungroup Sonos** from the menu (local `x-rincon:` SOAP, no cloud). Verified on real hardware. See gotcha #24.
- ✅ **Zombie-silence auto-recovery** (2026-06-26). The process tap can detach and deliver silent buffers while the pipeline looks healthy (every speaker quiet, no errors). The broadcaster now detects sustained silent capture and re-attaches the tap — preserving subscribers + sync, so AP1 sessions don't even reconnect. Verified: no false positives, recovers a silent-but-flowing source. See gotcha #26.
- ✅ **M5.5 — device profiles consumed (slice 1)** (2026-06-26). The JSON device-profile substrate (schema + loader) is now *used*, not just present: a `ProfileStore` resolves a discovered sink → profile, and AirPlay 1 volume scale reads from the profile's `volumeScale` (verified: the A5 matches `bowers-wilkins-a5`, volume driven from JSON). The seam for community-crowdsourced device support. Remaining slices: codec params, Sonos volume.
- 🟡 **M12 — AirPlay 2 sender (committed V1 hero).** AP2 is now in V1 scope, not a non-goal. **Foundation built + verified offline (2026-06-26):** the `SuperAudioAirPlay2` module, `_airplay._tcp` discovery, TLV8 codec, and SRP-6a pairing crypto (CryptoKit + BigInt, RFC-5054-verified); the control transport reaches a real device (`GET /info` → 200). **Blocked on a HomeKit AP2 device to finish/verify pairing** — there is **no Apple TV 4K or HomePod on the test LAN**; the only AP2 device here is a Sonos One SL, which uses the MFi/FairPlay path rather than the HomeKit `pair-setup` we built (it 403s). Decision: vendor nothing for crypto — fresh Swift on CryptoKit (see DECISIONS.md 2026-06-25). Next: verify against an Apple TV/HomePod, then PTP/RTSP/RTP/Opus.
- 🟡 **M3 hardening (2/N).** 30-min soak still owed. **et=1 verification DONE (2026-06-26): result — encrypted AirPlay plays SILENT on B&W A5/A7** (handshake fine, audio decodes to nothing); et=0 cleartext is the working/shipping path. Not pursued further — A5/A7 don't need encryption. See gotcha #27.
- 🟡 **M6 polish remaining.** Per-source app picker, preferences window, real menu bar icon. Independent of sync — can land any time before M8.
- 🟡 **M6.3 / M6.4 remaining polish.** Inaudible test signals (M11 polish). In-app diagnostics panel (#102) **shipped + upgraded (2026-06-26)** — surfaces pipeline state, silence-recovery + capture-gap counts, live Sonos group topology, encryption mode, per-sink status, and a Copy-bundle button. The rotary knob UI (#100) was **removed** — the linear slider (25 ms steps) plus auto-calibration covers tuning.

Full milestone map (M12 AP2 + passive-sync/GCC-PHAT → M5.5 → M6.5 → M7 → M8 → M9–M15) in [docs/ROADMAP.md](docs/ROADMAP.md).

## Build & run

```sh
swift build
swift run SuperAudio
```

Look for the speaker icon in the menu bar. Click it to see discovered speakers. Click any speaker name to start a session (AirPlay 1 runs the full RAOP handshake; Sonos toggles Play/Stop with a test stream). Logs stream to the unified logging system:

```sh
log stream --predicate 'subsystem == "com.davidpuerto.SuperAudio"' --level debug
```

## Project layout

```
SuperAudio/
├── Package.swift
├── Sources/
│   ├── SuperAudio/              # Menu bar app, AppDelegate, wiring
│   ├── SuperAudioCore/          # AudioSink, SinkRegistry, LicenseManager — contracts
│   ├── SuperAudioDiscovery/     # Bonjour / SSDP primitives
│   ├── SuperAudioAirPlay1/      # AirPlay 1 (RAOP) sink + RTSPClient + AppleAirPortRSA
│   └── SuperAudioSonos/         # Sonos (UPnP/SOAP) sink + SonosClient
└── probe/                       # Single-file diagnostics, not part of the SPM workspace
```

Future protocol modules (`SuperAudioAirPlay2`, `SuperAudioChromecast`, `SuperAudioBluetooth`) drop in as siblings under `Sources/` per the Extensibility model in CLAUDE.md. The dependency rule: per-protocol modules never import each other, only `SuperAudioCore` and `SuperAudioDiscovery`.

## Product vision

| SKU | Price | Role |
|---|---|---|
| **SuperAudio for Mac** | $19 | The current build. Captures any Mac audio, fans out to AirPlay 1 + AirPlay 2 (V1 hero, M12) + Sonos. Addons: Cast, BT, Room Tuning, Multi-zone — $5 each. |
| **Apple TV companion** | $5 addon | tvOS app — same fan-out from an Apple TV. Removes the "Mac must stay on" requirement. |
| **Hub Stick** | $59 | Pi Zero 2 W in a case. For households with no Mac and no Apple TV. |
| **Hub Pro (HDMI ARC)** | $249 | Sits between TV and soundbar. Every TV → every wireless speaker, regardless of source app. |

Direct sale (notarized, not App Store). Privacy: LAN-only discovery, no telemetry, no cloud anything.

## License

Proprietary — all rights reserved; see [LICENSE.md](LICENSE.md). The codebase keeps **no-GPL-copying hygiene** (no GPL code copied into the binary; in-binary deps are permissive — MIT/BSD/Apache — or runtime-only carve-outs; GPL projects are read-only protocol references). The separate `superaudio-device-profiles` repo is intentionally MIT. See [docs/DECISIONS.md](docs/DECISIONS.md) 2026-06-03 on the license flip and the kept hygiene rule.
