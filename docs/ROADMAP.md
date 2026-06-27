# SuperAudio — Roadmap

> The linear path from POC to product. Each milestone has a demo gate. We don't move on until the gate works.

This file is the single source of truth for "where are we, what's next." [../CLAUDE.md](../CLAUDE.md) is the architectural brief (load-bearing principles, module layout, working norms). [DECISIONS.md](DECISIONS.md) is the append-only record of "why we chose X over Y."

Latest result: **Cross-protocol AirPlay-1 + Sonos sync is audibly ACHIEVABLE on real hardware — 2026-06-03, but the automatic correctors are UNSTABLE (2026-06-05).** Mic Calibrate (auto) first brought a B&W A5 (AirPlay 1) into audible sync with a Sonos Playbar **and** a Sonos One SL — first confirmed cross-ecosystem harmonization on real speakers. Direction is AirPlay → Sonos (you can only ever *add* delay, so the slowest sink is the reference). **2026-06-05 hardware testing then showed the AUTOMATIC correction path is unstable**: both "Mic Calibrate (auto)" and the armed `PassiveSyncMonitor` restart the AP1 receiver (TEARDOWN + re-RECORD) on every offset adjustment → ~13 s reconnect loop, and the mic-measured target disagreed with the by-ear correct value by ~1.2 s (mic position ≠ listening position). **The stable path today is a static by-ear offset (~3050 ms for the A5) with correctors OFF** (Passive Sync observe-only; never run Mic Calibrate auto). Observe-mode passive measurement works and proved the algorithm; armed correction is not production-ready pending AP2 (M12) smooth retiming. See DECISIONS.md 2026-06-03 + 2026-06-05 entries.
Currently working on: **M12 AirPlay 2 sender (committed V1 hero)** + the **passive-sync / GCC-PHAT thread** (make the continuous loop hold reliably). AP2 hardware (Sonos One SL, Apple TV 4K) is on the LAN; the AP2 sender is not built yet. GCC-PHAT is the #1 next lever for passive sync; interim is periodic chirp re-anchor; silent endgame is a per-speaker ultrasonic pilot. After this: M5.5 Device Profile System substrate → M6.5 Claude Skill alpha → M7 launch prep → M8.

> **2026-06-05:** stable AP1 + Sonos sync confirmed via a STATIC by-ear offset (~3050 ms for the B&W A5) with auto-correctors OFF. Armed auto-correction (Mic Calibrate auto + armed `PassiveSyncMonitor`) restarts the AP1 receiver on every adjustment, so hands-free continuous sync is **not shipping** — it's gated on AP2 (M12), where the receiver is smoothly retimable. The Sonos buffer drifts session-to-session, so the static offset needs occasional re-tuning by ear.

**Strategic resequence — 2026-05-15.** The roadmap is reshaped to make the **Device Profile System** and the **Claude Skill onboarding wrapper** committed milestones rather than open threads. The substrate (M5.5) lands before public beta; the Skill is the **M8 launch hook**, not an M14 polish feature. Partnership outreach (B&W, Naim, KEF) and Anthropic Skills outreach run as parallel tracks alongside M7. See `docs/DECISIONS.md` 2026-05-15 entries for the framing and the four strategy threads (now committed).

---

## Product vision (what we're building toward)

A multi-room audio system for the half of households whose speakers don't all speak the same protocol. **Three SKUs**, all interoperable:

| SKU | Price | Role |
|---|---|---|
| **SuperAudio for Mac** | $19 | Captures Mac audio (any app), fans out to AP1 + Sonos + (addons: AP2, Cast, BT). Phase-1 build target. |
| ~~**Apple TV companion**~~ | ~~$5~~ | **NOT VIABLE — tvOS capture restriction.** tvOS has no system-audio / process-tap API and forbids capturing other apps' / DRM (FairPlay) audio, so a tvOS app can only fan out the audio it plays *itself* — never Netflix/Apple TV+/Disney+/etc. The "TV → all speakers" use case is delivered by the **hardware hub** instead (Hub Stick / Optical Hub / Hub Pro, below), which captures the TV's actual audio output downstream of the sandbox + DRM. See DECISIONS.md 2026-06-04. |
| **Hub Stick** | $59 | Pi Zero 2 W in a preconfigured case. For households with no Mac. |
| **Optical Hub** | $79 | TOSLINK input version of Hub Stick. For older TVs. |
| **Hub Pro (HDMI ARC)** | $249 | Sits between TV and soundbar via HDMI ARC. Captures all TV audio and fans out to wireless speakers. The "every TV → every speaker" product — and the *real* path for the living-room/TV use case (an Apple TV companion app can't do this; see the struck-through row above). |

Plus **$5 protocol addons** sold a la carte: AirPlay 2, Chromecast, Bluetooth A2DP fan-out, Room Tuning, multi-zone groups.

> **Premise correction (2026-06-04).** An earlier version of this lineup listed an "Apple TV companion ($5, tvOS) — same fan-out from an Apple TV instead of a Mac." That premise is **invalid**: tvOS cannot capture system audio, other apps' audio, or DRM/FairPlay content (Netflix, Apple TV+, Disney+, etc.), so a tvOS app could only re-broadcast media it plays itself — a non-starter for the streaming services people actually use. For all-AirPlay-2 homes the Apple TV already fans its own audio to every AP2 speaker natively (no third party needed); SuperAudio's value is the **heterogeneous / legacy** case (old AirPlay 1 like a B&W A5, legacy Sonos), which a tvOS app can't serve either. **The TV → all-speakers job is done by hardware on the TV's audio output (HDMI ARC / optical), not by a tvOS app.** See DECISIONS.md 2026-06-04.

The wedge: cross-ecosystem fan-out at consumer prices, with cross-protocol room tuning. **Nobody else does this** — see [../website/COMPETITIVE_LANDSCAPE.html](../website/COMPETITIVE_LANDSCAPE.html).

---

## Progress snapshot — 2026-06-03

### Done
- **Cross-protocol sync audibly ACHIEVABLE on real hardware** (2026-06-03) — Mic Calibrate (auto) brought a B&W A5 (AirPlay 1) into audible sync with a Sonos Playbar **and** a Sonos One SL. First confirmed cross-ecosystem harmonization on real speakers. Direction is AirPlay → Sonos (slowest sink is the reference; you can only ADD delay). **2026-06-05 caveat:** the automatic correctors (Mic Calibrate auto + armed `PassiveSyncMonitor`) are unstable — each restarts the AP1 receiver on every adjustment (~13 s reconnect loop), and the mic disagreed with the ear by ~1.2 s. Stable path today = static by-ear offset (~3050 ms) with correctors off; observe-mode passive measurement works, armed correction awaits AP2. `PassiveSyncMonitor` built + passively measuring; GCC-PHAT is the #1 next lever. See M6.8 + DECISIONS.md 2026-06-03 + 2026-06-05.
- **M1 Foundation** — Day 0 capture probe (process tap, 48 kHz f32, 234 callbacks/5s on macOS 26.4.1); 5-module SPM workspace; menu bar app via `MenuBarExtra`; OSLog subsystems wired; `AudioSink` / `SinkRegistry` / `LicenseManager` contracts; reusable `SystemAudioCapture`; cross-protocol Bonjour discovery (RAOP + Sonos) live.
- **M2 RAOP control plane** — full handshake against A5 and A7 (OPTIONS → ANNOUNCE et=1 → SETUP → NTP timing reply → RECORD → SET_PARAMETER volume → TEARDOWN). `AppleAirPortRSA` session-key wrapper. **NTP timing channel via BSD sockets** was the gate that unblocked RECORD.
- **M3 RAOP audio pipeline + Lossless Mode** — compressed ALAC via `AVAudioConverter`, source-port-matched sync packets, audio out of A5/A7 (2026-05-14). Lossless Mode toggle + bit-exact verification (SHA-256 round-trip identical). SIGTERM/SIGINT handlers + Sonos `Stop` on app quit. **Open**: 30-min soak test, et=1 + compressed ALAC verification.
- **M4 Sonos audio pipeline** — `AACEncoder` + `SonosStreamServer` + `SonosSession` with pump-before-SOAP ordering.
- **M5 Multi-sink fan-out + sync + per-sink controls** — shared `AudioBroadcaster`; per-chunk wall-time NTP anchor for cross-AP1 sync; per-sink volume + offset sliders; A7 cold-start root cause (`Client-Instance` per-instance fix); 2-attempt handshake retry; OPTIONS keepalive; failure UI; speaker groups; auto-reconnect.
- **M6 multi-sink sync + reliability arc** (2026-05-17) — sender-side broadcaster delay (sidesteps AP1 receivers' silent NTP-clamping behavior); handshake barrier (cross-AP1 first-audio within **1 ms**); Sonos start-align defer + auto-align default; supervisor exit-reason enum + retry cap (kills retry storms on un-acceptable receivers); session-race nonce guard; idempotent Play All; Restart All; 1.5 s TEARDOWN timeout; 250 ms volume debounce; Mac mute default-mismatch fix; audio-gap telemetry; Sonos Δ slider rip; UDP timing-packet-presence health monitor (replaced OPTIONS-over-TCP). User empirically dialed in `slider=3085 ms`, all three speakers audibly in sync.
- **M6.3 Sync UX partial** (2026-05-18) — real-time slider drag (#99) via queue+drainer architecture in `AudioBroadcaster`; Sonos-position auto-align (#104) via UPnP `GetPositionInfo` (works but limited by Sonos's variable hidden buffer); **Mac-mic auto-calibration (#98 / #105–#109) shipped** — chirp injection + cross-correlation + per-speaker sequential measurement + auto-applied offsets. Verified converging in real-room test: 3 passes converge from 1000ms residual → ~12ms (within mic correlation noise). **Caveat (2026-06-05):** on hardware retest this convergence was found to occur *while the AP1 receiver was restarting on each pass*, and the mic-measured target disagreed with the by-ear correct value by ~1.2 s (mic position ≠ listening position) — so the ~12 ms figure reflects mic-correlation self-consistency, not audible alignment at the listening seat. Three load-bearing bugs found + documented: `offset(for:)` vs `sinkOffsetsMs[id]` source, AVAudioEngine 3-sec first-init quirk (warmup throwaway), ambient-music-as-reference fails (chirps required). See commits `74ce089`, `b9ca785`, `4fe40fd`.
- **M6.6 Sonos API research** (2026-05-29) — reviewed official Sonos developer docs (`docs.sonos.com`). Confirmed the Cloud Control API has the same timing limitations as the UPnP/SOAP path we already use: no millisecond playback position, no buffer/renderer access, no cross-protocol sync primitives. Sonos has deliberately not exposed the precision required for external-app sync — it's intentional moat. Validates that closed-loop mic tracking (M6.7) and AP2-for-newer-Sonos (M12) are the only paths to deterministic cross-protocol sync; legacy Sonos hardware (Playbar gen 1 specifically) has no software-only solution from outside the Sonos ecosystem.

### Currently up next (re-prioritized 2026-05-31 — see DECISIONS.md "SonosNet group-piggyback technique")

**V1 scope as of 2026-05-31**: AirPlay 1 + AirPlay 2 + **legacy Sonos sync via SonosNet group-piggyback** (for the mixed-Sonos cohort). Modern Sonos works via AP2 path automatically. **Pure-legacy-Sonos cohort** (no AP2 hardware on the LAN) is still v1.1 territory for M6.7. Detailed reasoning + market segmentation in DECISIONS.md 2026-05-31.

- **M12 AirPlay 2 sender** ← V1 priority. 3-4 weeks. Vendor `pair_ap` MIT + `swift-opus` + fresh Swift for PTP/RTSP/RTP. Unlocks HomePods + modern Sonos + Bluesound + modern AVRs.
- **M6.6a Sonos Cloud Control API + auto-grouping** ← **NEW V1 PRIORITY (2026-05-31).** Re-promoted from the deferred M6.6 entry — ~1.5 weeks. OAuth flow, AP2-vs-legacy Sonos discovery cross-referencing, `modifyGroupMembers` programmatic group creation, auto-grouping UI. Unlocks legacy Sonos sync for the mixed-Sonos cohort (estimated 70-85% of legacy-Sonos households) via SonosNet's own sample-accurate sync.
  - **Premise hardware-confirmed by hand (2026-06-09).** Manually grouped Den (Playbar) + Den 2 (One SL) in the Sonos app and fed **only the coordinator** through SuperAudio → the two Sonos played sample-locked (SonosNet) and the A5 stayed in sync to the group. This is exactly the experience M6.6a will automate.
  - **Load-bearing gap this surfaced:** SuperAudio has **no Sonos group-topology awareness** — it discovers/lists/feeds each grouped member independently. Activating *both* grouped members pushes two independent HTTP streams that fight the Sonos group → out-of-sync mess (observed 2026-06-09; recurred under soak 2026-06-16).
  - **✅ Precursor SHIPPED (2026-06-25) — read-only group awareness + coordinator-only feeding.** `SonosTopology` polls `ZoneGroupTopology` (household-global) every 10 s; the menu hides non-coordinator members of a multi-speaker group and feeds only the coordinator, so a grouped pair can no longer be double-streamed (incl. via Play All). The group shows as a single device with a "group → +<members>" annotation. Verified on real hardware: detected the live "Spacelab Den + Den" group; the A5 ("Spacelab Audio") is unaffected. Fail-open (unknown topology hides nothing). This closes the double-stream gap and removes the "activate only one Sonos manually" workaround. See gotcha #24 + DECISIONS.md 2026-06-25.
  - **✅ Write-side SHIPPED (2026-06-26) — programmatic grouping, LOCAL not cloud.** The roadmap assumed Cloud Control API + OAuth; turns out grouping is a **local SOAP call** (`SetAVTransportURI` → `x-rincon:<coordinator-UUID>` to join, `BecomeCoordinatorOfStandaloneGroup` to split — `SonosClient.joinGroup`/`becomeStandalone`, mirroring SoCo's `join()`), so no Sonos cloud account is needed (fits the LAN-only stance). `SonosGrouping.groupAll()/ungroupAll()` + a one-tap "Group Sonos / Ungroup Sonos" menu button group every discovered Sonos under one coordinator (or dissolve it); `SonosTopology` auto-detects the result and the menu collapses to the coordinator. **Verified on real hardware (2026-06-26):** grouped two standalone Sonos under coordinator "Den" via one SOAP call, topology confirmed `2 groups → 1 group` within a second, and it fixed a live double-feed drop (user had ungrouped them in the Sonos app → both fed → HTTP listener flapping 0↔2 → audible drops; regrouping restored coordinator-only feed). **Takeaway captured:** *ungrouping re-opens the double-feed* — the write-side is what lets the user fix that from inside SuperAudio. M6.6a (read) + M6.6 full (write) together close the Sonos-grouping story for v1.
- **M3 hardening (2/N)** — 30-min soak + et=1 compressed-ALAC verification. Passive.
- **M5.5 Device Profile substrate** — proceeds.
- **M6.5 Claude Skill alpha** — proceeds.
- **M7 pre-launch hardening** — including the small "Sonos auto-group" UI affordance.
- **M6.4 Painless auto-calibrate** — leave shipped as-is, default chirp, auto-trigger off. Hidden power-user fallback.
- **M6.6b (single-shot safety nets) + M6.7 (closed-loop continuous tracking)** — **DEFERRED TO V1.1**. M6.6b only relevant if going back to single-shot model (we won't). M6.7 serves the pure-legacy cohort in v1.1. Hardware-validation gate already PASSED on 2026-05-30.

**Hardware to acquire for v1 work**: one AP2-capable Sonos (Beam gen 2 ~$499 or Era 100 ~$250) for the test bench — required to validate the SonosNet auto-grouping feature against the existing Playbar gen 1.
- **M6.3 remaining** — in-app diagnostics panel (#102). Rotary knob UI (#100) **REMOVED/cancelled** — the linear slider (now 25 ms steps) plus auto-calibration covers tuning; the bespoke knob isn't worth the build. #101 Re-sync now mostly superseded by working `Mic Calibrate (auto)`.
- **M3 hardening (2/N)** — 30-min soak test (trivially passive now that M6 reliability holds) + et=1 + compressed ALAC verification. Can run alongside M6.4.
- **M6 polish remaining** — per-source app picker (#58), preferences window, real menu bar icon. Independent of sync.
- **M5.5 Device Profile System substrate** — after M6.4. JSON schema + public MIT repo for community-crowdsourced device support.
- **M6.5 Claude Skill alpha** — after M5.5. The M8 launch headline.

---

## Linear milestones

### M1 — Foundation (DONE, 2026-05-12)

Scaffolding, contracts, capture, discovery, menu bar.

- [x] Day 0 capture probe (process tap, 48 kHz f32, 234 callbacks/5s)
- [x] SPM workspace + 5-module layout
- [x] `MenuBarExtra` app with placeholder UI
- [x] OSLog subsystems
- [x] `AudioSink` / `SinkRegistry` / `LicenseManager` contracts in Core
- [x] `SystemAudioCapture` reusable class
- [x] Bonjour discovery — RAOP + Sonos, both flowing into menu bar live

**Gate:** menu bar lists every speaker on the LAN in real time, decorated by protocol. ✓ Met.

---

### M2 — RAOP control plane (DONE, 2026-05-13)

Full RTSP handshake against AirTunes/103.x receivers, encryption included.

- [x] OPTIONS handshake
- [x] ANNOUNCE with SDP body, `et=1` mode (`a=rsaaeskey`+`a=aesiv`)
- [x] SETUP with `interleaved=0-1` and server-allocated `audio/control/timing` ports
- [x] **NTP timing channel** — BSD socket bound on local timing port, replies to PT `0xD2` with PT `0xD3`
- [x] RECORD ACK with `Audio-Latency: 4096`
- [x] SET_PARAMETER volume
- [x] TEARDOWN
- [x] `AppleAirPortRSA` session-key wrapper

**Gate:** click A5 in menu, observe full handshake in OSLog ending with TEARDOWN; same against A7. ✓ Met. Single code path; works across both devices.

---

### M3 — RAOP audio pipeline (IN PROGRESS — audio playing 2026-05-14)

**The bar:** press play on the Mac, audible music from the B&W A7 for 30 minutes straight, no drops, bit-perfect when source is 44.1/16. **Audio is playing as of 2026-05-14** (M3a equivalent below). Soak test + et=1 verification + Lossless Mode remain.

Done:

- [x] `AVAudioConverter` step: 48 kHz f32 → 44.1 kHz int16 stereo
- [x] **Compressed ALAC via `AVAudioConverter` (2nd stage)** — no C-interop encoder vendoring needed; verbatim/escape mode is silently rejected by real hardware (see DECISIONS.md 2026-05-14)
- [x] AES-128-CBC encrypt — IV reset per packet, whole 16-byte blocks; tested but `useEncryption=false` (et=0) currently default until et=1 + compressed ALAC verified
- [x] RTP header (12 bytes): `0x80` / PT 96, big-endian seq/ts/SSRC; marker on first packet
- [x] `NWConnection.udp` to `server_port`; cadence ~125 packets/sec at 44.1k/352
- [x] **Sync packets on control port via BSD socket** (`RTSPClient.sendOnControlSocket`) — source-port must match advertised local control port or speaker silently drops (see DECISIONS.md 2026-05-14)
- [x] `RTSPClient.negotiatedAudioLatency` parsed from RECORD response (default 4096)
- [x] Initial sync burst (3 packets) at session start; periodic sync every ~1 second piggy-backed on audio heartbeat
- [x] Wire `RTPSender` into menu click + `--auto-click=NAME` CLI flag for orchestrated testing
- [x] First audible audio from B&W A7 — 2026-05-14 ~01:52 CDT

Still open for M3 to be called "done":

- [ ] 30-minute soak test — uninterrupted music with no drops, no glitches. Now trivially testable thanks to M6 reliability work: leave Play All running while doing dishes, check `Capture gap detected` log count at the end.
- [x] Verify et=1 (AES) works with compressed ALAC. **VERIFIED 2026-06-26 — result: et=1 audio does NOT work (et=0 is the shipping/working path).** With `useEncryptedAirPlay=true` the full handshake succeeds on the B&W A5 (ANNOUNCE et=1 with RSA-OAEP-wrapped key → SETUP → RECORD → RTP streaming real *varying-size* compressed ALAC, `encryption=et=1 AES`, no rejection, no reconnect) — but playback is **silent**. Classic "byte-correct on the wire but silent" failure (cf. gotcha #10). The code is correct by inspection (RSA-OAEP-SHA1 wrap; AES-128-CBC no-padding over whole 16-byte blocks, per-packet IV reset, cleartext tail) so the bug is subtle and needs a pcap diff vs a real et=1 sender to crack. **Not pursued now: et=1 is unnecessary for B&W A5/A7 (they accept et=0), so this is low-priority receiver-compat work, not a release gate.** See gotcha #27.
- [x] Volume: per-sink slider live since M5d (range 0–100%, default 15%, 250 ms debounce since M6 reliability).
- [x] Stale-session recovery: SIGTERM/SIGINT handlers send TEARDOWN + Sonos `Stop` before exit, plus 1.5 s TEARDOWN timeout so cleanup never stalls. See M5 reliability block and M6 sync arc.

**Lossless Mode (M3c — DONE, 2026-05-15):**

- [x] **Lossless Mode toggle** in the menu, persisted in UserDefaults. When active and any session is open, forces the macOS default output sample rate to 44.1 kHz via `AudioObjectSetPropertyData(kAudioDevicePropertyNominalSampleRate)` and restores on session end. `LosslessMode.swift` handles save/restore with the same defensive pattern as `MacAudioMute`.
- [x] **`RTPSender` log** prints `◆ LOSSLESS PASS-THROUGH` when the capture format is already 44.1, or warns about the rate conversion otherwise.
- [x] **Bit-exact verification CLI tool** at `probe/LosslessVerify.swift`. Build: `swiftc -O probe/LosslessVerify.swift -o probe/LosslessVerify`. Run: `probe/LosslessVerify`. Reports `✅ BIT-EXACT` if encoded ALAC round-trips back to identical PCM (SHA-256 match), or `❌ FAIL` with first-divergence diagnostic. **Run before any release whose marketing copy uses the word "lossless."**
- [x] Verified passing 2026-05-15 — SHA-256 `2f9f7c8387c5ecaa5b50c3b0cdd6d4ec0b5dce7835532e8eda1f3aac91bb47e1` matches across encode and decode.

**Gate:** (a) audio plays end-to-end on real hardware — **achieved 2026-05-14 (short play); 30-min soak test still pending**; (b) bit-exact verification passes — **achieved 2026-05-15**.

---

### M4 — Sonos audio pipeline (DONE, audible-test passes — 2026-05-15)

Replaced the SomaFM test URL with our own live audio.

- [x] Local HTTP server via `Network.framework` — `SonosStreamServer` binds `NWListener` via `NWListener(using:on:)` on port 7331
- [x] `AVAudioConverter` PCM → AAC-LC + ADTS framing — `AACEncoder` (192 kbit/s, 48 kHz stereo, ADTS 7-byte header per packet)
- [x] `SetAVTransportURI(x-rincon-mp3radio://<mac-ip>:7331/stream.aac)` + `Play` — orchestrated by `SonosSession`
- [x] Audio server lifecycle: starts when a session begins, tears down on cancel
- [x] Toggle off → SOAP `Stop` + server shutdown
- [x] Unified `SessionState.toggle` dispatches AP1 and Sonos through the same code path
- [x] `NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist (macOS 14+ TCC gate for LAN access)
- [x] **Audio pump starts BEFORE SOAP** — Sonos validates the stream by fetching bytes; if we start the pump after SOAP, we deadlock on Sonos waiting for bytes and us waiting for SOAP. See DECISIONS.md 2026-05-15 entry.
- [x] **Audible-test passes 2026-05-15** — Sonos Den plays Mac audio. Full three-speaker vision (A5 + A7 + Den from one Play All click) confirmed audible.

The Sonos floor is real and unfixed — empirically 2–4 sec behind real-time under typical LAN conditions (updated 2026-05-17 after M6 testing; the original 200–500 ms estimate was too optimistic). M6 sender-side broadcaster delay matches AP1's content lag to Sonos's instead of trying to shift Sonos timing. See DECISIONS.md 2026-05-17.

---

### M5 — Multi-sink fan-out + sync + per-sink controls — **DONE (2026-05-15 night)**

One capture, multiple speakers, sample-accurate (within protocol floor), with per-sink user controls. Sub-tasks shipped:

**Mixer / sync work (M5a + M5b + M5c):**
- [x] `AudioBroadcaster` singleton in `SuperAudioCore` — one shared `SystemAudioCapture` fanning out per-subscriber `AsyncStream<AudioChunk>` with `.bufferingNewest(20)`. Reference-counted lifecycle.
- [x] `PlaybackAnchor` (mach `referenceHostTime` + wall-clock `referenceWallTime` + `referenceRTPTimestamp=0`) set on the first chunk after capture starts. Shared across all subscribers.
- [x] `RTPSender` sync-packet NTP computed as `anchorWall + (lastChunkHostTime - anchorHost) * machToSeconds + 0.2 s` — **deterministic across sessions encoding the same chunk** AND always in the near future (the chunk's wall time is approximately "now"). Solves the past-anchor regression that a fixed-anchor approach hit.
- [x] All three speakers (A5 + A7 + Sonos Den) playing one shared capture via the broadcaster. AP1 sinks audibly in sync (~30 ms walking test); Sonos balanced via Δ offsets per M5d below.
- [ ] Per-sink latency probe at `connect()` time — currently using the receiver-reported `Audio-Latency: 4096` value (~93 ms). Probe-based refinement deferred; the per-chunk NTP plus user-tunable Δ slider covers practical cases.
- [ ] Drop frames if a sink falls >500 ms behind master clock — currently relies on `.bufferingNewest(20)` in the broadcaster to drop oldest chunks on slow subscribers. Explicit watchdog deferred.

**Per-sink user controls (M5d):**
- [x] **Per-sink volume slider.** AirPlay 1: `SET_PARAMETER volume` (range −30 → 0 dB, with -144 = mute, mapped to 0–100% with quiet-mode cap at 18%). Sonos: `RenderingControl::SetVolume` SOAP (native 0–100). Live mid-stream adjustments via registered setter closures.
- [x] **Per-sink offset slider (manual).** Original M5d: 0–500 ms in 5 ms steps via `RTPSender.manualOffsetSeconds` (sync NTP pre-roll). **Range expanded twice** as real-world Sonos lag emerged: → 2000 ms (2026-05-16) → 3000 ms (2026-05-16 night) → 6000 ms (2026-05-17). **Mechanism replaced 2026-05-17 in M6 sync arc**: slider value now drives broadcaster-side delay (sender-side audio shift) instead of NTP scheduling, because AP1 receivers were silently clamping far-future NTP. Sonos slider was originally visible-but-disabled with a tooltip; **ripped 2026-05-17** and replaced with informational caption (Sonos's timing is encrypted at UPnP; sliders on Sonos rows were misleading).
- [x] Per-sink volume + offset persisted in `UserDefaults` keyed by sink ID (survives quit).
- [x] Pre-mixer EQ slot reserved per-sink as identity function — **load-bearing for M11 Room Tuning**, which lands real biquad coefficients into this slot without further refactor. See DECISIONS.md 2026-05-15 Room Tuning architecture entry, section 5.

**Reliability (Client-Instance fix + retry + keepalive + failure UI):**
- [x] `RTSPClient.staticClientInstance` changed from `private static let` (shared per process) to `private let` (per instance) — root cause of A7's "drops first cold connection" behavior was identifier collision, NOT firmware quirks. One-line fix; immediately eliminated the cold-start failure. See DECISIONS.md 2026-05-15 (night) entry section 2.
- [x] 2-attempt RTSP handshake retry with 200 ms backoff in `AirPlay1Session.handshakeWithRetry` — catches the residual cold-start cases (router ARP cache miss, etc.). Logs per attempt.
- [x] `AirPlay1Keepalive` — 4-min OPTIONS pings to every discovered AP1 sink not currently in an active session. Prevents low-power-state induced cold-starts in the first place.
- [x] Mid-stream auto-reconnect via health monitor. **Originally** OPTIONS-over-TCP ping at 10 s cadence (M5 era). **Replaced 2026-05-16** with UDP timing-packet-presence detection — receivers send PT 0xD2 timing requests every ~1 s while actively playing; absence >15 s flips `HealthFlag.lost = true` and the session unwinds for supervisor retry. The OPTIONS approach produced false positives because the RTSP TCP socket is idle during active streaming (audio goes via UDP) and the kernel/router would silently drop it.
- [x] **Failure UI** — red ❌ for ~6 s on sinks that exited before reaching the live-stream phase. Clears on next user click or auto-expires.
- [x] **Default-low volume.** *Originally* a "Quiet Mode" 18% volume cap (M5d). **Reworked 2026-05-16** after user feedback: "we wanted default low so it's never blaring, but the slider should still go to 100%." Quiet Mode removed; replaced with `defaultVolumePercent = 15` (applied to any sink without a saved value). Slider's max stays at 100%. The stale `quietMode` UserDefaults key from prior installs is ignored harmlessly.

**Gate:** A5 and A7 audibly in sync via per-chunk wall-time NTP. Sonos balanced via user-tuned Δ offsets (user reached audible sync at A7=+160 ms, A5=+250 ms, Sonos=0). Volume + offset sliders adjust each speaker live. Settings persist across quits. ✓ MET.

---

### M5.5 — Device Profile System substrate (est. 1 week, +1 week for dual-role schema) **← new in 2026-05-15 resequence; schema expanded 2026-05-16**

Refactor "things we currently hard-code into protocol modules" (B&W's silently-drops-verbatim-ALAC quirk, Sonos's empty-metadata-required-for-x-rincon-mp3radio, et=0-default-until-et=1-verified, Audio-Latency negotiated value, etc.) into a swappable **JSON-defined `DeviceProfile`**. The structural foundation for the third moat-grade capability — community-crowdsourced device support — and the prerequisite for the Claude Skill that ships in M6.5.

**Schema expanded 2026-05-16:** profiles now describe **two distinct roles** (sink + control). The original single-role spec assumed every device just receives audio; tonight's heterogeneous-household reveal made clear that profiles need to also describe how a device (e.g., a Sonos Playbar) provides volume / power / pause events for the mesh to propagate. Some devices have both roles (Sonos Playbar = sink + control); some have only sink (B&W A5); some have only control (a generic IR-only soundbar paired with an Audio Bridge — user keeps the soundbar for TV audio, Audio Bridge captures audio for the rest of the mesh). See `docs/DECISIONS.md` 2026-05-16 (same night, expansion) entry for the schema design.

- [x] **`DeviceProfile` JSON schema** in `SuperAudioCore` (`DeviceProfile.swift`) — versioned (schemaVersion 1), non-breaking-additive. **Two roles** per profile:
  - **Sink role**: protocol family, codec parameters, handshake quirks, timing tolerances, volume scale, free-text known-firmware-gotchas
  - **Control role**: volume-event source (UPnP eventing, HomeKit, SmartThings, etc.), subscription endpoint, IR-codes-learned flag, fallback strategy when no API path exists
- [x] **Profile loader** (`DeviceProfileLoader.swift`) — loads built-in profiles from app bundle; overlays any from `~/Library/Application Support/SuperAudio/Profiles/`; per-file errors logged, never crashes. Plus `ProfileStore` (2026-06-26) — app-wide singleton that loads once and resolves a discovered `SinkDescriptor` → `DeviceProfile` (memoized), the seam protocol modules consume.
- [x] **No executable code in profiles** — `JSONDecoder` + filesystem scan only, never an interpreter.
- [ ] **Migrate hard-coded quirks**: rewrite `SuperAudioAirPlay1` and `SuperAudioSonos` to read protocol specifics from the profile rather than from compile-time constants. Ship four built-in profiles: `bowers-wilkins-a5.json`, `bowers-wilkins-a7.json`, `sonos-playbar-gen1.json`, `apple-airport-express.json`.
  - **✅ Slice 1 SHIPPED (2026-06-26) — AP1 volume scale.** `AirPlay1Session` resolves its profile via `ProfileStore` and drives the %→dB mapping (`SessionState.airplay1Volume`) from the profile's `volumeScale` (falls back to AirTunes −30…0/−144 when unmatched — identical to pre-M5.5). **Verified on hardware:** all 4 profiles load, the A5 matched `bowers-wilkins-a5` (via "Spacelab" model hint), volume set 200 OK from the profile scale. The substrate is now *consumed*, not just loaded.
  - **Remaining slices:** AP1 codec/SDP fmtp params (44100/16/2) + audio-latency fallback; Sonos codec + volume scale (percent). Each is the same pattern (resolve profile → read value → fallback).
- [ ] **Public MIT-licensed GitHub repo**: `superaudio-device-profiles` (Homebrew-formulae model — pure data, no DB). Seeded with the four built-ins. Repo includes JSON schema + CI that validates submitted PRs. CODEOWNERS routes PRs by protocol kind.
- [ ] **License + contribution model**: substrate is **fully open MIT**; app stays **paid at $19**. This is the Tailscale / Mozilla VPN pattern (open backend, paid UX). See DECISIONS.md 2026-05-15 "Strategy threads → Thread 4 (substrate-open / app-paid)" — committed direction.
- [ ] **In-app refresh**: menu item "Refresh device support" → `git pull` against the upstream repo into the local profile directory. Optional auto-update toggle (default off; respects the no-telemetry stance — pull only on user action or explicit opt-in).
- [ ] **Profile signing model decision**: ship M5.5 unsigned (trust the GitHub PR review process). Revisit signing if/when repo compromise becomes a credible threat.

**Gate:** the four currently-hard-coded protocol quirks (verbatim-ALAC rejection, empty-metadata-required, et=0-default, source-port-matching) all live in JSON profiles loaded at runtime. A user can drop a hand-authored profile into `~/Library/Application Support/SuperAudio/Profiles/` and have the app pick it up at next session start. The `superaudio-device-profiles` repo is public on GitHub with the four built-ins and a working CI.

---

### M6 — Polish + persistence + sync arc (DONE 2026-05-17 except per-source app picker + prefs window + menu bar icon)

Make it feel like a product instead of a demo. Plus the big multi-sink sync arc that landed 2026-05-17.

**Polish + persistence:**
- [x] **Speaker groups** — named presets save/play/delete from the menu ("Whole house", "Living room", "Bedroom"). `SpeakerGroups` singleton, JSON-persisted under `speakerGroups.v1` in UserDefaults. Inline TextField form for "Save current as group…" when sinks are active. Resolves stored sinkIDs against currently-discovered sinks at play-time; partial-group warning logged when some sinks are offline.
- [x] **`UserDefaults` persistence for groups + per-sink volume + per-sink offset + mute toggle.** All persisted, all survive quit + relaunch.
- [x] **Auto-reconnect on network blips** — UDP timing-packet-presence health monitor in `AirPlay1Session.run` detects mid-stream loss within 15 s; `SessionState.superviseSession` retries with backoff (2 → 5 → 15 → 30 → 60 s). See M5 reliability block + DECISIONS.md 2026-05-15 (night) entry section 3 + M6 sync arc block below.
- [ ] **Per-source app picker** — `CATapDescription` supports targeting specific PIDs instead of system-wide. Refactor `SystemAudioCapture` to accept a process list; UI: "Capture from: [System / Spotify / Music / Chrome / …]". **Deferred from 2026-05-15** — invasive change to shared capture infrastructure; saved for a fresh session.
- [ ] Preferences window (basic — single pane, key bindings)
- [ ] Real menu bar icon (not the placeholder)

**Sync architecture + reliability arc (DONE 2026-05-17, commit `8a8849c`):**

The single biggest engineering push since M3. Took multi-sink from "approximately synced with manual fiddling" to "user dials in 100 ms precision by ear, A5/A7 within 1 ms of each other regardless of handshake variance."

- [x] **Sender-side broadcaster delay (v2)** — `AudioBroadcaster.subscribe(id:delaySeconds:)` with defensive `AudioChunk.makeCopy()` + `presentationHostTime` rewrite. AP1 sinks subscribe with broadcaster-side delay so audio content is shifted at the sender. Receiver-side NTP scheduling clamps far-future requests; broadcaster delay sidesteps that entirely. RTPSender's `sendInitialSync` gains `seedingFirstChunkHostTime` so sync NTP lands in the present despite the delay queue. See `CLAUDE.md` gotcha (to add) for the receiver-clamping discovery.
- [x] **Handshake barrier** — `SessionState.armStartBarrier` / `markHandshakeComplete` / `awaitStartBarrier`. All AP1 sessions complete RTSP work (incl. `SET_PARAMETER` volume) before any sink subscribes to the broadcaster. Empirically: A5 and A7 first-audio within **1 ms** of each other despite A7's 4 s handshake under TCP contention vs A5's 1 s. 10 s fallback timeout absorbs stalled sinks.
- [x] **Sonos start-align defer** — `currentSonosStartDeferSec` computed as `max(0, max_AP1_offset - 2.5s)`. Sonos defers SOAP `Play` so its first audio lands ~200 ms within AP1's. Sonos also waits the same start barrier so all sinks cross the line together. Tunable constant (`estimatedSonosSetupSec`); M11 Room Tuning will eventually replace with measured value.
- [x] **Sonos auto-align default** — AP1 sinks default offset to 2000 ms when Sonos is active and user hasn't touched the slider. Bridges the cold-start case.
- [x] **Supervisor exit-reason enum + retry cap** — `AirPlay1Session.run` and `SonosSession.run` return `SessionExitReason` (`.cleanExit` / `.networkLost` / `.failedBeforeAudio` / `.failedAfterAudio`). Supervisor counts consecutive `failedBeforeAudio`; after 3, removes sink from `wantedActive`. Kills the retry-forever storm against un-acceptable AirPlay receivers (e.g., other people's Macs in mDNS who never accept the prompt).
- [x] **Session-race nonce guard** — `AirPlay1Session` captures `sessionNonce` at start; defer asks `SessionState.endSessionIfStillCurrent` before wiping setters/active flag. Fixes the stale-defer-clobbers-fresh-session bug where an old session's slow async cleanup wiped a new session's state ("speaker still playing but UI shows unchecked").
- [x] **Idempotent Play All** — filters on `sessionTasks` (real source of truth), not `activeSinks` (transiently empty during defer cleanup). Skips sinks already running. UI button stays clickable; logs `"N sink(s) already running — skipping"`.
- [x] **Restart All button** — snapshot wanted sinks, stop, 1.5 s wait, Play All. Affordance for "kick everything back in sync" now that Play All is idempotent.
- [x] **1.5 s TEARDOWN timeout** — off-on transitions don't stall 4 s+ on unresponsive RTSP socket.
- [x] **250 ms volume slider debounce** — rapid drags coalesce; only the settled value hits RTSP. Prevents control-plane saturation and spurious "session failed" cascades.
- [x] **Sonos Δ slider rip** — replaced with informational caption (Sonos's playback timing is encrypted at the UPnP layer; AP1 sliders are the only actionable lever). See DECISIONS.md 2026-05-16 "Sonos timing-shift: conclusive negative."
- [x] **Reconnecting badge** — supervisor retry state surfaces as orange "reconnecting (attempt N)…" in the menu, distinct from red ✗ failure.
- [x] **Mac mute toggle default-mismatch fix** — `SessionState` and `@AppStorage` were silently disagreeing on first launch (`UserDefaults.bool` defaults to false; `@AppStorage Bool = true` defaults to true). Both now default to true; diagnostic logging in `applyMuteIfNeeded` + `MacAudioMute` clarifies the success/no-op/fail path on every active-sinks change.
- [x] **Audio-gap telemetry** — `AudioBroadcaster` tracks inter-chunk arrival gaps, logs `⚠ Capture gap detected: N ms` when > 100 ms with running count + worst observed. Final tally on capture stop. Ground-truth instrumentation for "did audio actually drop" vs anecdote.

**Gate:** ✓ MET 2026-05-17. Multi-sink content alignment dial-able to ~100 ms by ear; cross-AP1 first-audio within 1 ms; supervised retries with cap; clean Mac-mute on session start. The remaining open items (per-source app picker, prefs window, menu bar icon) are independent polish, can land any time before M8 launch prep.

---

### M6.3 — Sync UX (est. 2 weeks) **← new 2026-05-17 from M6 testing experience**

M6 nailed the *architecture* of multi-sink sync. M6.3 nails the *UX of tuning it*. The single line of empirical data from 2026-05-17 that motivated this milestone: **a real user dialed in sync to ~100 ms manually, but said "this is too hard to dial in by ear — the slider is finicky."** That's the gap. Auto-calibration kills 90% of the manual work; the remaining 10% needs a slider that feels alive (not "applies on next play") and a knob that responds to fine input.

**This is also the right slot for #98 — the Mac-mic auto-calibration is what makes M11 Room Tuning's iOS-side Path B feel inevitable. We ship the algorithm on the Mac first, then port it to the iOS companion in M11.**

- [x] **Real-time slider drag** (#99) **— DONE 2026-05-18** — per-subscriber queue+drainer architecture in `AudioBroadcaster`, 250 ms debounce on slider, AP1 sinks accept mid-stream `setDelay` updates. Big-bump caveat (RTP discontinuity → receiver requests retransmits) handled via session restart for >300ms jumps. See commits `74ce089`, `4fe40fd`.
- [x] **Mac-mic auto-calibration** (#98 / #105–#109, Path A precursor to M11) **— DONE 2026-05-18** — full per-speaker chirp-based calibration:
  - Linear sine sweep (200 Hz → 8 kHz, 1 sec) injected into `AudioBroadcaster` via chunk PCM overwrite — all subscribers play the chirp.
  - Mic captures via `AVAudioEngine` input tap; sample rate matched via linear resample.
  - Cross-correlation via Accelerate vDSP FFT; reference-window expanded to 30 sec so peaks beyond mic recording (Sonos's ~3-4 sec lag) are findable.
  - Sequential per-speaker measurement: mute all but target via volume=0 (AP1 SET_PARAMETER + Sonos SOAP SetVolume), record + correlate, restore. Sonos measured last as the alignment reference.
  - Auto-apply: `new_offset = current_offset + (sonos_lag - speaker_lag)` per AP1, persisted to UserDefaults, AP1 sessions restarted to apply cleanly (same pattern as #104).
  - Verified converging in real-room test: pass 1 = 1000ms residual, pass 2 = 200ms, pass 3 = ~12ms (within mic correlation noise).
  - Three gotchas documented in code: (a) `offset(for:)` not `sinkOffsetsMs[id]` for current offset, (b) 500ms AVAudioEngine warmup throwaway prevents 3-sec first-measurement quirk, (c) chirps required — ambient music too periodic for clean correlation.
  - See commit `4fe40fd`.
- [~] **Rotary knob UI** (#100) — **REMOVED/cancelled 2026-06-03.** Was: replace the linear slider with a rotary knob (full revolution ≈ 500 ms; ⌥-rotate fine mode; double-click reset). Dropped — the linear AirPlay delay slider, now stepping in **25 ms increments** (was 5 ms over 0–6000 ms), plus auto-calibration covers tuning without a bespoke knob. The "drift meter" idea is folded into the passive-sync work and the in-app diagnostics panel (#102). See DECISIONS.md 2026-06-03.
- [ ] **"Re-sync now" button** (#101) — manual one-click stop-gap that runs auto-calibration without a full session restart. Lives in the menu. Used when something drifts mid-session. ~1 evening. **Partially superseded by the working `Mic Calibrate (auto)` button (#109) — keep #101 as a polish iteration if the auto path proves too heavy for routine use.**
- [ ] **In-app diagnostics panel** (#102) — promote the most diagnostic OSLog lines (handshake duration, barrier wait, first-audio delta per sink, capture gap count, supervisor retry count) into an in-app "Diagnostics" tab. Plus a "Copy diagnostic bundle to clipboard" button so support requests stop requiring `log show` over the shoulder. Replaces terminal-grep dependence. ~1.5 evenings.

**Gate:** new user opens app, presses Play All, presses Calibrate, hears sync within 5 seconds — without ever touching a slider. Fine-tuning by knob is responsive to live nudges. Diagnostics panel shows last 60 s of session activity in human-readable form.

**Strategic value:** the Calibrate button IS the demo for M8 launch alongside the Claude Skill. *"Press Play. Press Calibrate. Hear sync."* Three taps. That's quotable.

---

### M6.4 — Painless auto-calibrate (est. 1 week) **← new 2026-05-18 after M6.3 #105–#109 proved**

Mic calibration works. Now make it invisible. M6.3's `Mic Calibrate (auto)` button proves the engineering; M6.4 hides the button — calibration runs automatically as part of Play All, during Sonos's intrinsic 30-sec settling ramp, so users never know it happened.

**The premise:** Sonos's renderer buffer needs ~30 sec post-Play to settle into steady-state. During that window, sync between AP1 and Sonos is bad anyway (today's data). Run the 3-speaker chirp calibration during that already-bad window. By the time Sonos finishes settling, AP1 has been re-tuned to match. User clicks Play All, hears Sonos start, hears AP1 join in sync ~10 sec later. No buttons.

- [x] **Auto-trigger on Play All when Sonos is in the active set** (shipped 2026-05-18, commit `160ff54`) — hook into `SonosSession.run` right after `markSonosPlayStarted` fires. Wait ~5 sec, then call `MicCalibrator.runFullCalibration()`. Skip if pure-AP1 session. Skip if recent calibration (<2 min).
- [x] **Pulse the menu bar icon during calibration** — distinct blue ring overlay on `MenuBarIcon` while `SessionState.isCalibrating` is true; reverts to the steady orange dot when calibration ends. Separate from the always-on active-session pulse so the user has a passive cue without a modal.
- [x] **`autoCalibrateOnPlayAll` user pref (default ON)** (shipped 2026-05-18, commit `160ff54`) — Preferences toggle in the menu.
- [x] **Per-environment profile persistence** — `SessionState.saveCalibrationProfile(for:)` snapshots the freshly-calibrated offsets keyed on the sorted active sink ID set; `SessionState.primeOffsetsFromProfile(for:)` is called from `startAll` BEFORE any session runs, so AP1 sessions pick up the primed offset on first sync packet and audio is in approximate sync immediately. Calibration then refines silently.
- [x] **Mid-session sink-add auto-recalibrate** — `SessionState.toggle` detects "ON path with active sinks already present" and fires `scheduleMidSessionRecalibrate` (8-sec settle, then `runFullCalibration` if both AP1+Sonos active). Closes the demo-gate "re-runs invisibly if user adds a sink mid-session."
- [x] **Edge cases** — (a) Stop All mid-calibration: explicit `abortIfStopped` checks between iterations in `runFullCalibration` throw on empty `wantedActive`, the `catch` path restores saved volumes cleanly. (b) Mic-permission-denied: one-time NSAlert with "Open System Settings" deep link, gated by `hasShownMicPermissionAlert` UserDefaults so we never spam.
- [ ] **Real-device polish** — 1-2 hours iterating on the right wait-time, debounce semantics, and chirp volume scaling so it's neither too loud nor too quiet vs the music it interrupts. Eventually replace the audible chirp with an inaudible test signal — see M6.5 below or roll into M11.

**Gate:** open app, press Play All. Audio starts. Within ~10 seconds, all three speakers are in sync. Without any user input beyond the Play All click. Stays in sync across songs. Re-runs invisibly if user adds a sink mid-session.

**Strategic value:** This is the ACTUAL marketing demo. *"Press Play. Hear sync."* Two taps — one fewer than the M6.3 framing. The Calibrate button still exists as a manual override; the user just rarely needs it.

**What this doesn't fix:** the 1-sec audible chirp during startup is still mildly intrusive. Inaudible-signal calibration (ultrasonic sweep or pink noise masked under music) is M11 polish — only ship when it's reliably as accurate as the audible chirp.

---

### M6.6 — Cross-protocol sync hardening + Sonos API research **← DEFERRED TO POST-V1 (2026-05-30)**

> **DEFERRED TO POST-V1.1 (2026-05-30).** Per the V1 scope tightening (see DECISIONS.md 2026-05-30), legacy Sonos sync is out of v1 scope entirely; M6.6's safety nets are only relevant if we go back to the single-shot audible-burst model, which we won't. Sonos Cloud Control API research below stays logged regardless — strategic intel for future reference, not blocking work.

M6.4 made calibration auto-trigger and persist. M6.6 makes it *trustworthy*. Real-room testing across 2026-05-28/29 with 4 speakers (3 B&W + Sonos Playbar gen 1) exposed three structural weaknesses in single-shot calibration that the original 3-speaker tests didn't surface:

1. **Cross-speaker measurement inconsistency goes undetected.** One A5 measured 0.445s while the other A5 (same room) measured 3.473s — physically impossible (would require 3,000+ ft of acoustic distance). The system applied the delta anyway. Pro audio rigs use cross-speaker consistency to reject outliers; we don't.
2. **Sonos sample variance is brutal and unbounded.** Three Sonos samples spanned 3.110s (0.6s → 3.7s) on the same hardware. Median picked 3.549s, but the median is statistically meaningless when range exceeds the signal value. No upstream gate stops a high-variance pass from corrupting state.
3. **Profile auto-saves regardless of result quality.** Every completed calibration overwrites the saved profile — including the bad ones. A pass that produces worse sync than fresh defaults now persists and primes the next launch worse than starting clean. Compounding.

**Engine robustness (~1 week):**
- [ ] **Cross-speaker consistency rejection** — collect all in-room AP1 lag measurements first, compute median; reject any measurement deviating >X ms from cohort median (X tunable, start at 500ms). The two A5s same-room should agree within ~150ms based on positional distance; 3-sec disagreement is provably wrong, not noise.
- [ ] **Sonos variance gate** — if range across N samples exceeds threshold (1.0s?), abort the pass entirely. Better to keep prior offsets than apply a measurement from a Sonos buffer that's actively drifting unpredictably during measurement.
- [ ] **Save-on-confirm profile semantics** — instead of auto-saving every completed calibration, save only when (a) all measurements passed SNR + consistency + variance gates, OR (b) user explicitly confirms via "save this sync" affordance. Calibration in-session is allowed to APPLY questionable results (audible feedback to user); persistence requires the higher bar.
- [ ] **Stale-offset cleanup** — when calibration SKIPS a measurement, don't write the current value back to the profile. Leaving the offset unset lets `effectiveOffsetForAirPlay1` fall through to the Sonos auto-align default (2000ms) instead of being pinned at a stale 0ms.
- [ ] **Lower SNR gate (10.0 → 7.0)** — done 2026-05-29. Empirically validated against same-room measurements landing at SNR 7.8-9.7 with mutually-consistent lags. Safety nets above keep low-confidence measurements from corrupting state.

**Sonos Cloud Control API migration research (~1 week):**

Confirmed 2026-05-29 by reviewing the official Sonos developer docs (`docs.sonos.com/reference/create-authorization-code`, `docs.sonos.com/docs/connected-home-get-started`, `docs.sonos.com/docs/how-sonos-works`, `docs.sonos.com/llms.txt`) that the **official Cloud Control API has the same timing limitations as the UPnP/SOAP path we currently use**:

- ✗ No millisecond-precision playback position (same coarse `GetPositionInfo` as UPnP)
- ✗ No buffer / renderer timing access
- ✗ No audio rendering latency metrics
- ✗ No cross-protocol sync primitives — `createGroup` and `modifyGroupMembers` only operate on Sonos players
- ✓ Same `seek`/`seekRelative` we already use (no new precision)
- ✓ `loadLineIn` — interesting for Sonos units with line-in (NOT Playbar gen 1), unlocks a hardware-bridged deterministic path (analog wire bypasses Sonos's network buffer entirely)
- ✓ Event-driven playback subscriptions (cleaner than our UPnP eventing model)

**So the Sonos developer program does not solve the timing problem.** Sonos has deliberately not exposed the primitives required for external-app sync — Sonos sync is intentionally a Sonos-internal moat. This validates that closed-loop mic tracking (M6.7) and AP2-for-newer-Sonos (M12 addon) are the only paths to deterministic cross-protocol sync.

**Items worth doing despite that:**
- [ ] **Spike the Cloud Control API migration** — replace our SOAP/UPnP with the official OAuth-authenticated cloud API. Pros: event subscriptions (less polling), official + future-proof, opens "Works with Sonos" certification track (marketing channel). Cons: requires user OAuth into Sonos, depends on Sonos cloud (no LAN-only), more friction. Defer the decision until M6.5 / M8 — current SOAP path works fine and the timing improvement is zero.
- [ ] **Implement `loadLineIn` integration** for Sonos units that expose line-in — a future hardware-bridged path for users who CAN wire Mac→Sonos analog (Sonos Connect, Sonos Beam gen 2 via HDMI ARC inversion, etc.). Same architecture as M14/M15 Hub Pro. Not Playbar gen 1.

**Pre-buffer experiment (low effort, possibly high return):**
- [ ] **Pre-buffer Sonos before SOAP Play** — currently we pump audio briefly before `Play`. Try pumping ~3-5 sec into the SonosStreamServer before `Play` is issued. Theory: a fuller renderer buffer at `Play` start might reduce inter-session variance. Testable in 30 min. If it cuts variance from 3.1s to <500ms across samples, single-shot calibration becomes viable. If not, M6.7 closed-loop is the only path.

**Gate:** 4-speaker Mac+AP1+Sonos in one room, single Mic Calibrate click → all four within 200ms of perceived sync at the listening position, sync survives 5 min of playback without drift, profile persists correctly across app restart. If we can't hit that, the single-shot model has hit its limit and we move to M6.7.

**Strategic value:** the M8 launch story is "Press Play. Hear sync." Right now we can deliver that for AP1-only or with caveats for Sonos. M6.6 either pushes Sonos sync over the line at single-shot, or proves it needs continuous tracking — either outcome moves us decisively.

---

### M6.7 — Closed-loop continuous tracking **← DEFERRED TO V1.1 as the "perfect legacy Sonos sync" hero (2026-05-30)**

> **DEFERRED TO V1.1 (2026-05-30).** Per the V1 scope tightening (see DECISIONS.md 2026-05-30), legacy (non-AP2) Sonos sync moves out of v1 scope and becomes the v1.1 hero feature: *"v1.1 — Perfect sync for every Sonos, including legacy hardware Sonos themselves abandoned."* The 2026-05-30 ultrasonic hardware-validation gate **PASSED** (Spacelab Audio @ 19 kHz isolated SNR=14.5 dB VIABLE; all four speakers VIABLE or MARGINAL at their preferred carrier frequency; Sonos Playbar gen 1 reachable through walls at 3.4 dB SNR). The engineering thread is real and ships post-v1. The remainder of this section is preserved as the v1.1 implementation spec.

> **Hardware-validation gate results (2026-05-30)** — full numerical data from `UltrasonicValidator` real-room pass with mic in Spacelab room, A7+A5 Dos right side, Sonos+A5 left side, Playbar gen 1 in adjacent Den room:
>
> | Speaker | Best ultrasonic freq | Best SNR | Verdict |
> |---|---|---|---|
> | Spacelab Audio (A5) | 19 kHz | 14.5 dB | **VIABLE** |
> | Spacelab Forever Main (A7) | 18.5 kHz | 9.1 dB | MARGINAL |
> | Spacelab Audio Dos (A5) | 18.5 kHz | 9.4 dB | MARGINAL |
> | Den (Sonos Playbar gen 1, through walls) | 19 kHz | 3.4 dB | MARGINAL |
>
> **Key insight unlocked by the validation pass**: per-speaker frequency preference correlates with physical placement (same-side speakers cluster on the same best frequency — A7+Dos on the right both want 18.5 kHz, Spacelab Audio + Sonos on the left both want 19 kHz). This validates a **frequency-division-multiplexing carrier design** for v1.1 — each speaker gets its own ultrasonic carrier tuned to its room-acoustic transfer function. No mute-cycling required; all speakers can play simultaneously, the mic captures the whole mix, Goertzel pulls each speaker's contribution from its known carrier frequency.

Pro audio measurement rigs solve the cross-protocol sync problem the same way: continuous ultrasonic/inaudible test signal injected, mic continuously listens, system corrects in real time. Sonos cannot ship this themselves because their own external API doesn't expose the precision required — the moat is structurally unattackable from inside their ecosystem.

**The premise:** Sonos drift takes TIME. Within any 10-30 sec window, the drift delta is bounded. If we measure Sonos's lag every 5-10 sec and shift AP1's broadcaster delay in micro-increments, we track the drift dynamically. No single-shot accuracy required — the loop closes the error continuously.

**Engineering thread (load-bearing assumptions, all needing validation):**
- [ ] **Mac built-in mic captures 18-19 kHz cleanly.** Consumer mics typically roll off at 16-18 kHz. Easy validation: FFT a known 19 kHz tone, check the magnitude response. If the mic dies above 17 kHz, we either need user-external-mic support or accept audible test signal.
- [ ] **Speakers reproduce 18-19 kHz audibly at the mic distance.** B&W A5/A7 likely yes; varies by hardware. Ultrasonic absorbs faster than mid-range; range ~10-15 ft in typical rooms.
- [ ] **Ultrasonic chirp generator** — replace `MLSGenerator` with a sweep generator in the 18-19.5 kHz band. Reuses `AudioBroadcaster.injectChirp` infrastructure (already shipped).
- [ ] **Continuous tracking loop** — replace one-shot `MicCalibrator.runFullCalibration` with `MicCalibrator.startContinuousTracking()` that runs while music plays. Tunable interval (5s? 10s?).
- [ ] **Smooth offset interpolation** — AP1 broadcaster delay shifts gradually (e.g., 100 µs per call, 60 calls/sec) instead of stepping in one jump. Avoids the audible click on each adjustment.
- [ ] **Big-bump escape hatch** — if the measured drift exceeds the smoothing budget, fall back to a session restart with the new offset (current behavior). Should be rare in steady-state.
- [ ] **Drift activity detection** — pause tracking if nothing's changing (no need to burn cycles on a stable system).

**Cost / scope:** 3 weeks of focused work. Requires hardware validation BEFORE coding — if mic + speaker freq response fails, no DSP cleverness fixes it.

**Strategic value:** **THIS is the M8 + M11 moat together.** "SuperAudio: the only multi-protocol system that stays in sync forever, even with Sonos." Closed-loop continuous tracking is what Smaart, REW, ARTA, and pro audio measurement systems do — applying that to consumer multi-protocol streaming is genuinely novel. Sonos can't ship this themselves because they don't expose their renderer timing to their own external API.

**Gate (extended 2026-05-29 after Beam test-bed discussion):** Must pass on all three configurations:
1. **Legacy-only**: 3 B&W AP1 + Sonos Playbar gen 1 (current test bed; worst-case Sonos)
2. **Modern-only**: 3 B&W AP1 + Sonos Beam gen 2 / Arc (post-2018 AP2-capable Sonos)
3. **Mixed**: 3 B&W AP1 + Sonos Playbar gen 1 + Sonos Beam gen 2 (realistic household configuration)

For each: play music for 30 minutes, audible sync holds the entire time without user intervention, no detectable drift between protocols at any moment.

The legacy-only configuration is the moat-validation case — if M6.7 can sync Playbar gen 1 with AP1, no competitor can match it (their only options are buying new hardware or giving up). The Beam gen 2 should be added to the test bed alongside the Playbar (not as a replacement) so we have known-good AP2 path *and* known-hard legacy-Sonos path running in parallel during development.

---

### M6.8 — `PassiveSyncMonitor`: passive content-based continuous sync **← new 2026-06-03; observe-mode measurement PROVEN on hardware, armed correction NOT production-ready (2026-06-05)**

The bridge between M6.4's one-shot chirp calibration and M6.7's inaudible-pilot endgame. SuperAudio already knows the exact waveform sent to each speaker (the broadcaster reference tap), so cross-correlating the Mac mic against that reference recovers each speaker's true playback lag **from ordinary music — no repeated test tone.** Chirp-anchor once for a coarse fix, then track continuously from live content and nudge the controllable sink's delay to hold sync as receivers drift.

**Governing principle:** *you can only ever ADD delay.* You cannot un-buffer a receiver, and Sonos timing can't be pulled forward (gotcha #17). So **the slowest sink is the reference**, and every faster *controllable* sink (AirPlay) is delayed up to match it. Direction is **AirPlay → Sonos**: legacy Sonos is the immovable anchor; the AirPlay sink slides onto it.

**Cross-protocol sync PROVEN on real hardware (2026-06-03).** Mic Calibrate (auto) brought a B&W A5 (AirPlay 1) into audible sync with a Sonos Playbar **and** a Sonos One SL (two Sonos zones) — from ~1.3 s out to a barely-perceptible residual. First confirmed cross-ecosystem harmonization on real speakers. The two Sonos stay locked to each other via SonosNet; the A5 is the controllable sink. The residual is Sonos drift over minutes — which is exactly the argument for *continuous* correction. See DECISIONS.md 2026-06-03 (both entries).

- [x] **`PassiveSyncMonitor`** primitive built + passively measuring on hardware. New `AudioCorrelation` helpers: `topCorrelatedLags` (top-N peaks + non-max suppression), `strongestPeak(in:)`. Controller medians per-round error, gates on SNR, clamps the step, deadbands, and settles past the receiver's silent catch-up gap after a shift. Two modes via `passiveSyncArmed` (observe / armed-via-`SessionState.setOffset`). **2026-06-05 status:** observe-mode measurement is proven on hardware; the **ARMED** mode is NOT production-ready — each `setOffset` retimes the AP1 sink, which restarts the receiver (TEARDOWN + re-RECORD → ~13 s reconnect loop). AP1 clamps NTP to its ~93 ms buffer, so any retime restarts the receiver; smooth in-place retiming only arrives with AP2 (M12). Run armed correction only on AP2; keep AP1 on a static by-ear offset.
- [x] **Motion-based sink identification** — nudge a controllable sink's delay by a known amount, detect which correlation peak moved by that amount; stationary peaks are reference-class. Makes the corrector agnostic to hidden receiver buffers.
- [ ] **GCC-PHAT (phase-transform cross-correlation) — #1 next lever.** Whitens the signal so peaks stay sharp on music + reverb. This is what makes the continuous passive loop hold reliably on real content. Top priority.
- [ ] **Periodic chirp re-anchor (interim fallback)** — ~60–90 s re-anchor when passive confidence drops on quiet/periodic content. Bridges until GCC-PHAT is solid.
- [ ] **Continuous Sonos feed-delay** — prepend silence / hold HTTP writes so legacy Sonos can be a *follower*, not only the reference (needed when the slowest sink is AirPlay and Sonos is faster).
- [ ] **Silent endgame — per-speaker ultrasonic pilot** — folds into M6.7: each speaker gets its own inaudible ~18–19 kHz carrier (FDM design validated 2026-05-30), so tracking runs with zero audible test signal.
- [ ] **Gentle / marker-free acquisition (idea, 2026-06-05)** — the loud chirp gives sub-ms precision we may not need (ear tolerance ~30–50 ms). Alternatives to the screech: (a) **edge / "valley" timing** — isolate one sink, stop its feed, detect the silence *onset* in the mic to recover the delay; (b) **natural-transient marker** — correlate against a sharp event already in the music (kick drum, track boundary), nothing injected. Both trade precision for silence: reverb tail + receiver buffer drain (Sonos holds 2–3 s) smear the edge to ~±50–100 ms — possibly within ear tolerance. **Caveat:** this only makes *measurement* pleasant; it does not fix AP1 *actuation* (the A5 restarts whenever it's retimed — see DECISIONS.md 2026-06-05), which is the real blocker. Best paired with M12 AP2 (smoothly retimable).
- [ ] **Armed end-to-end correction confirmed on hardware** — passive measurement is verified; armed continuous correction holding over a long session is the remaining gate.

**Gate:** armed `PassiveSyncMonitor` holds AP1 + Sonos audibly in sync from live music for 30 min without a chirp re-anchor, tracking Sonos drift continuously. AP2 (M12) makes this shine — AP2 sinks are low-latency *and* fully delay-controllable, so they slot into the delay-to-slowest model cleanly with legacy Sonos as the anchor.

**Strategic value:** passive, continuous, cross-protocol harmonization of consumer speakers across ecosystems doesn't exist as a product — the consumer application of what Smaart / REW / ARTA do in pro audio.

---

### M6.5 — Seed device profiles + Claude Skill alpha (est. 2 weeks) **← new in 2026-05-15 resequence; scope expanded 2026-05-16**

Bootstrap the device-profile repo from public sources, then ship the AI-assisted onboarding skill so the M8 public-beta launch has both substrate AND the marketing hook.

**Scope expansion (2026-05-16):** the Claude Skill onboards not just speakers but **any audio device in the household — speakers, soundbars (acting as control-layer devices), AVRs, smart-TV-as-audio-source.** The heterogeneous-household reveal (most users have a Sony / Samsung / LG / Bose soundbar, NOT a Sonos) made clear that the Skill's universal-adapter value extends well beyond niche speakers. See `docs/DECISIONS.md` 2026-05-16 (same night, expansion) for the framing.

**Profile seeding (~1 week):**
- [ ] **Lift wire-format insights from permissively-licensed reverse-engineering sources** — shairport-sync issue tracker, SoCo (MIT), OwnTone (GPLv2 — wire format only, no code lifting), AirConnect (MIT). Wire format itself is a fact and cannot be copyrighted; the discipline is fresh Swift implementations + no GPL code copied.
- [ ] **Seed ~20 sink-role device profiles**: AirPort Express (gen 1 + gen 2), B&W A5/A7 (already done in M5.5), B&W Zeppelin Air, Naim Mu-so 1st gen, Marantz NA6005/NA8005, Pioneer N-50/N-70, Denon DNP-720AE, McIntosh MB50/MB100, Sonos Play:1 / Play:3 / Play:5 / Connect / Connect:Amp, Beam gen 1, Bluesound Powernode (S1), Yamaha WX-AD10, plus a generic "AirPlay 1 receiver (et=1, RFC-compliant)" fallback.
- [ ] **Seed ~10 control-role soundbar profiles**: Sonos Playbar / Beam / Beam gen 2 / Arc / Arc Ultra, WiiM Pro Plus, Bluesound Pulse Soundbar, Sony HT-A7000 (HomeKit/SmartThings), Samsung HW-Q990 (SmartThings), LG SP9YA, Bose Soundbar 900, plus generic "IR-only optical bar" with the phone-app-fallback profile shape.
- [ ] **Verified vs community status field** in each profile: `verified_by: superaudio` only for hardware we've directly tested. Everything else: `verified_by: community-best-effort`. Surface this in the app's device picker.

**Claude Skill alpha (~1 week) — `/onboard-audio-device` (renamed from `/onboard-speaker` to reflect expanded scope):**
- [ ] Bundled as a local skill in the app's resources (works without internet); also available as a standalone skill installable into the user's Claude Code if they have it.
- [ ] **Identify phase**: web-search the device's make/model, check known APIs / Bonjour signatures / SmartThings device registry / HomeKit accessory list. For soundbars: identify whether it exposes an API (Sonos/WiiM/BluOS/HEOS/MusicCast/HomeKit/SmartThings) or is closed/IR-only.
- [ ] **Probe phase**: `dns-sd -B _airplay._tcp _airplay2._tcp _googlecast._tcp _spotify-connect._tcp _sonos._tcp`, SSDP `M-SEARCH` for UPnP. Pattern-match results against known protocols.
- [ ] **Capture phase** (sink-role): prompt user to run `sudo tcpdump -i en0 -w /tmp/superaudio-onboard.pcap host <ip>` while clicking through SuperAudio's "test this device" flow. Parse the resulting pcap with `tshark -V`.
- [ ] **Subscribe phase** (control-role for soundbars): test volume-event subscription end-to-end. Press volume-up on TV remote → confirm we receive the event → confirm propagation to a test sink works.
- [ ] **Draft phase**: assemble a `DeviceProfile` JSON with sink role and/or control role populated. **Anonymize aggressively**: strip MAC addresses, Bonjour-advertised hostnames containing personal names ("Alice's MacBook"), Apple ID device names, IPv6 ULAs.
- [ ] **Test phase**: walk the user through capability tests — for sinks: play, stop, volume, sync; for controls: volume-up, volume-down, mute. Log pass/fail per capability into the profile.
- [ ] **Submit phase**: open a GitHub PR via `gh` CLI against `superaudio-device-profiles`. User confirms before submission.
- [ ] **Skill copy + privacy disclosures**: every step that touches the network, the filesystem, or external services is explicitly disclosed before it runs.

**Gates:**
- (a) An unfamiliar **speaker** on the LAN (e.g., a borrowed JBL Authentics) goes from "not in menu" → "drafted sink-role profile + open PR ready for review" in under 10 minutes.
- (b) An unfamiliar **soundbar** with API support (Sony HT-A7000 via SmartThings, Samsung HW-Q990, WiiM Pro Plus) goes from "TV remote controls it but our mesh doesn't know" → "drafted control-role profile + working volume-event subscription" in under 10 minutes.
- (c) An **IR-only closed soundbar** gets a clear "no API path — use phone-app master volume" profile recommendation, with optional Audio Bridge / Optical Hub upsell.

---

### M7 — Pre-launch hardening (est. 2 weeks)

Convert POC to shippable product.

- [ ] Paid Apple Developer cert ($99/yr) — only step that costs money outside infra
- [ ] Notarization pipeline (`xcrun notarytool`)
- [ ] App icon design
- [ ] Onboarding flow (one window, 3 cards)
- [ ] Marketing site at `superaudio.app` (rework `index.html`)
- [ ] Paddle integration for license keys (Merchant of Record handles VAT)
- [ ] Privacy policy + ToS (template; we collect nothing)
- [ ] Crash log capture **strictly local** — no telemetry, no cloud upload

**Gate:** install a fresh download on a friend's Mac without showing them anything; they get the speakers working in under 5 minutes.

---

### M8 — Public beta, Mac app at $19 (the v1 ship) **← scope tightened 2026-05-30, expanded 2026-05-31**

**V1 scope as of 2026-05-31** (supersedes 2026-05-30 partial deferral):
- AirPlay 1 multi-sink sync (shipped, proven)
- AirPlay 2 sender via M12 (3-4 weeks)
- **Legacy Sonos sync via SonosNet group-piggyback** (M6.6a, ~1.5 weeks) — covers the ~70-85% of legacy-Sonos households that own at least one AP2-capable Sonos. Auto-grouping via Sonos Cloud Control API; SonosNet's own sample-accurate sync handles the legacy speaker.
- Claude Skill onboarding (M6.5)
- Device Profile substrate (M5.5)

**Still deferred to v1.1**: pure-legacy-Sonos sync (M6.7 closed-loop) for households with NO AP2-capable Sonos anywhere on the LAN. See DECISIONS.md 2026-05-30 + 2026-05-31.

**The launch headline is the Claude Skill** — that's the resequence outcome from 2026-05-15. The technical story (lossless AP1 renaissance + cross-protocol AP1+AP2 fan-out) is real but emotionally subtle. The Skill story is concrete and quotable: *"Your AirPort Express still works. Your $1500 B&W from 2013 still works. Use Claude Skill to onboard any speaker you own."*

**Modern Sonos works at launch via AP2** — Beam gen 1+, Arc, Era, One, Move, Roam all receive AP2 deterministically. **Legacy Sonos (Playbar gen 1, Play:1/3, Play:5 gen 1, Connect gen 1, etc.) works at launch via auto-grouping** — if the user has at least one AP2-capable Sonos on their network, SuperAudio automatically groups the legacy speaker with the modern one via Sonos Cloud Control API, and SonosNet handles the rest (sample-accurate sync, free, no calibration). **Pure-legacy-Sonos users** (zero AP2 hardware anywhere) get a clear "perfect sync coming in v1.1" message + the option to add any AP2-capable Sonos for immediate v1 support.

- [ ] Paddle checkout live
- [ ] License key delivery + validation
- [ ] Forum or Discord for users
- [ ] **Marketing hook**: Claude Skill onboarding is the headline of every surface — landing page, press kit, demo video. Lossless + AP1+AP2 fan-out are the supporting story.
- [ ] **Demo video showing the Skill**: walks an unfamiliar speaker through profile drafting and PR submission in real time. Under 90 seconds.
- [ ] **Press outreach (Skill-first framing)**: The Verge, Hacker News, Ars Technica, The Register. Pitch is "indie Mac app uses Claude Skills to onboard hardware" — a real HN front-page candidate.
- [ ] **AirPlay enthusiast community outreach** (Reddit r/audiophile, r/sonos, AVS Forum, /r/HomeTheater) — these are the audiences who care about the lossless + cross-protocol angle even if the Skill is the headline.
- [ ] **Honest scope language**: marketing and store copy say "perfect AP1 + AP2 sync" — not "every speaker syncs perfectly." Legacy Sonos limitation is mentioned in FAQs without being a launch-day caveat.
- [ ] Public profile repo on GitHub passes 50 stars (a tractable launch-week target via HN + community outreach).
- [ ] **Teaser v1.1 in marketing copy**: *"Coming in v1.1 — Perfect sync for users with only legacy Sonos hardware (no modern Sonos required). Closed-loop continuous tracking. The only product that does it."* M6.7 stays the v1.1 hero, but now it serves a narrower (and clearer) niche: users who genuinely have only pre-2018 Sonos. The mixed-Sonos majority is already covered by v1's auto-grouping feature.

This is the moment SuperAudio becomes a product. Everything after this is paid expansion.

**V1.1 (~3-6 weeks post-launch)** — M6.7 closed-loop continuous tracking for legacy Sonos. Hardware-validation gate already passed 2026-05-30. Implementation is real but no longer blocks v1.

---

### M9 — ~~Apple TV companion, $5 addon~~ **CANCELLED — not buildable on tvOS (2026-06-04)**

> **CANCELLED 2026-06-04 — built on a false premise.** The original idea was a tvOS app that fans audio out from an Apple TV "instead of a Mac," removing the "Mac must stay on" requirement. **tvOS cannot do this.** There is no tvOS system-audio / process-tap API, and the platform forbids capturing other apps' audio; DRM/FairPlay content (Netflix, Apple TV+, Disney+, etc.) is untouchable. A tvOS app could only fan out audio it plays *itself* (its own media player) — useless for the streaming services people actually watch. The original "Mac sends to Apple TV, Apple TV re-fans-out" plan below does *not* solve this either: receiving the Mac's audio over AP2 just relays the Mac's audio; it does nothing for content the Apple TV itself is playing (which is the whole point of a TV-anchored household). See DECISIONS.md 2026-06-04.
>
> **The TV → all-speakers use case is delivered by the hardware hub, not a tvOS app.** A hub on the TV's audio output (HDMI ARC = **M14 Hub Pro**; optical = **M15 Optical Hub**) captures the actual audio signal downstream of the sandbox + DRM, then fans out + syncs across protocols. That's the technically-sound path. For all-AirPlay-2 homes the Apple TV already fans its own audio to every AP2 speaker natively — no third party needed; SuperAudio's value is the heterogeneous / legacy case (AirPlay 1, legacy Sonos), which the hub serves and a tvOS app cannot.
>
> The "Mac must stay on" concern that motivated this SKU is instead answered by the **Hub Stick (M13)** for non-Mac sourcing and by the hubs for the living room. The cross-protocol acoustic sync engine (the novel IP) is unaffected — it's the shared brain reused by both the Mac app and the hubs.

*Original spec preserved below for the record (the approach does not work — see cancellation note above):*

- ~~tvOS target in SPM (`SuperAudioTV`)~~
- ~~Apple TV runs `AirPlay 2 receiver` natively → SuperAudio Mac sends to it via AP2 receive~~
- ~~tvOS app then runs the same RAOP + Sonos sender code we already wrote (sharing `SuperAudioAirPlay1` + `SuperAudioSonos`)~~
- ~~tvOS app published in tvOS App Store~~
- ~~Mac app gains "Use Apple TV as hub" toggle~~

---

### M10 — iOS companion, free with base (est. 2 weeks)

Remote control + the dedicated UI for Room Tuning.

- [ ] iOS app (`SuperAudioiOS`) — list groups, play/pause, per-speaker volume
- [ ] Bonjour-discovered control protocol (custom, JSON over TCP, LAN-only)
- [ ] Free with base app (license is per-household, not per-device)
- [ ] App Store distribution

**Gate:** phone controls a Mac-anchored or hub-anchored SuperAudio system from across the house.

---

### M11 — Room Tuning addon, $5 (est. 4 weeks, **Path A precursor ships in M6.3**) **← BIGGEST SOFTWARE MOAT**

Walk-around mic calibration that works **across protocols** — A5 + A7 + Sonos all tuned together. Nobody else does this.

**Path A (Mac-mic, single position)** ships in **M6.3** as auto-calibration — the calibration engine is built and proven on the Mac side; this milestone (M11 = Path B) extends it to the iOS companion for multi-position walk-around tuning.

- [x] **Algorithm prototype** — Accelerate FFT cross-correlation against `AudioBroadcaster` chunks. Done as part of M6.3 #98.
- [ ] iOS-side: capture mic audio at 48 kHz, time-aligned with chirp playback
- [ ] Each speaker plays a sequence of log-sweep chirps; we measure the impulse response from each location
- [ ] Per-speaker EQ generation (parametric, ~6 bands)
- [ ] Per-speaker delay estimate (cross-correlation, refined over multiple measurement positions — extends the single-position estimate from M6.3 Path A)
- [ ] EQ applied at the SuperAudio mixer (before fan-out, so it lands on every protocol)
- [ ] iOS UI: "walk to where you sit" → tap → "now walk to the kitchen" → tap → "done"

**Gate:** A/B test with the user. Same playlist, Tuning OFF vs Tuning ON. Subjective improvement audible.

**Why this matters:** Sonos has Trueplay, Bluesound has Dirac, Roon has REW filters. **All locked to their ecosystem.** We're the only cross-protocol calibration product if we ship this.

---

### M12 — Protocol addons, $5 each (staggered)

Order by demand. Each is a new SPM module per the Extensibility model in CLAUDE.md. **No edits to Core or existing modules** — that's the test.

- [ ] **AirPlay 2 sender — est. 3-4 weeks** (revised down 2026-05-29 from 4-6 weeks after GitHub scout). Biggest protocol gap. Reverse-engineered (per public refs). MFi licensing not required for sender-side per public posture.

  **Bootstrap stack identified 2026-05-29:**

  | Component | Path | Effort |
  |---|---|---|
  | SRP + Curve25519 + ChaCha20-Poly1305 pairing | Vendor [`ejurgensen/pair_ap`](https://github.com/ejurgensen/pair_ap) (**MIT**) as C library, thin Swift wrapper | ~3 days |
  | Opus codec encoding | [`alta/swift-opus`](https://github.com/alta/swift-opus) Swift Package, wraps libopus | ~3 days |
  | PTP timing monitor | Fresh Swift implementation, [`mikebrady/nqptp`](https://github.com/mikebrady/nqptp) (GPLv2) as protocol reference | ~1 week |
  | RTSP control plane | Fresh Swift, [`mikebrady/shairport-sync`](https://github.com/mikebrady/shairport-sync) (GPLv3) `rtsp.c` + [`lmcgartland/airplay2-rs`](https://github.com/lmcgartland/airplay2-rs) (GPL-2.0, sender, **read-only reference**) as references | ~1 week |
  | RTP audio plane + AP2 buffer processor | Fresh Swift, shairport-sync `rtp.c` + `ap2_*_processor.c` as references | ~1 week |
  | ~~`AudioSink` + `SinkDiscoverer` for `_airplay._tcp` mDNS~~ ✅ **discovery SHIPPED 2026-06-25** | Following existing module pattern | done |
  | Real-device testing | HomePod / Sonos Beam gen 2 / modern AVR | ~1 week |

  **✅ Sub-task 1 — module + discovery SHIPPED (2026-06-25, sprint day 1).** Created `SuperAudioAirPlay2` (new SPM module, deps Core + Discovery only — the extensibility-model test held: no edits to other protocol modules; Core only gained its pre-provisioned `Log.airplay2` line, mirroring the already-present `ProtocolKind.airplay2`/`Addon.airplay2`). `AirPlay2Discoverer` browses `_airplay._tcp`, parses the AP2 TXT (deviceid, model, `pk`, the 64-bit `features` bitfield incl. comma-split `lo,hi` encoding), self-filters the local Mac, and uses an `ap2:`-prefixed SinkID. Registered in `AppDelegate` gated by `LicenseManager.isEnabled(.airplay2)`. **Verified on real hardware:** found the Sonos One SL ("Spacelab Den", model "One SL", `needsPairing=yes`); correctly did NOT find the Playbar gen 1 (not AP2-capable) or the local Mac (filtered); Apple TV 4K was asleep (drops `_airplay._tcp` ad in deep sleep). Surfaced gotcha #25 (`NSBonjourServices` must declare each browsed type or `NWBrowser` fails `-65555 NoAuth`). **Next sub-task:** pairing — vendor `pair_ap` (MIT) + Swift wrapper, run pair-setup/pair-verify against the One SL / a woken Apple TV. **Known cosmetic follow-up:** an AP2-capable Sonos now appears as both a Sonos sink and an AP2 sink (its RAOP face is already deduped) — the dedup/preferred-path decision is deferred until the AP2 sink actually streams, since it depends on which path we prefer.

  **The single biggest win**: `pair_ap` is MIT-licensed and standalone — SRP+Curve25519+ChaCha20 pairing was projected at ~2 weeks of fresh Swift impl; vendoring drops it to ~3 days. **License hygiene preserved**: pair_ap is MIT, swift-opus is MIT, shairport-sync/nqptp are read-only protocol reference (no code lifted). The fresh-Swift discipline holds.

  **Strategic consequence (logged in DECISIONS.md 2026-05-29 evening):** with M12 AP2 dropping from 4-6 weeks to 3-4 weeks, the v1 "AirPlay 1 + AirPlay 2 + best-effort Sonos beta" launch story becomes more feasible. AP2 unlocks every HomePod, every modern Sonos (Beam gen 1+, Arc, Era, Roam, Move), Bluesound, modern Marantz/Denon/Yamaha network players — a much bigger AirPlay-capable universe than the legacy AP1-only path.

- [ ] **Chromecast** — Google Cast v2 protocol, used widely in OSS senders.
- [ ] **Bluetooth A2DP fan-out** — uses macOS Core Bluetooth + multi-device A2DP (intrinsic OS limit: typically 1 active sink, but `AVAudioSession.allowBluetoothA2DP` works around it for monitoring)
- [ ] **Multi-zone groups** — independent audio per zone (kitchen plays podcast, living room plays music). Pure UI/state layer atop the mixer.

---

### M13 — Hub Stick, $59 hardware (est. 3 months)

Pi Zero 2 W in a preconfigured case. Solves the "no Mac" households (and is the answer to the "Mac must stay on" concern that the cancelled tvOS companion was meant to address — see M9). **Full design vision + hardware-sizing analysis + manufacturing strategy in [`website/HUB_DESIGN.html`](../website/HUB_DESIGN.html).**

- [ ] Pi OS image build pipeline (Buildroot or Raspberry Pi OS Lite — decision deferred)
- [ ] Port `SuperAudioCore` + protocol modules to Linux (Swift on Linux is solid for our use case; Network.framework alternatives like SwiftNIO; audio capture via PipeWire or PulseAudio loopback instead of CoreAudio process tap)
- [ ] Receive audio from any LAN device that speaks AirPlay 2 or Cast (the Hub Stick is itself a receiver) — for AP2 receive, evaluate shipping `shairport-sync + nqptp` as a standalone bundled binary (GPLv3-compatible as long as we link separately, not statically)
- [ ] Fan out to all protocols downstream (reuses M5 `AudioBroadcaster` + per-chunk wall-time NTP)
- [ ] Headless config via iOS companion (Bonjour-discovered first-time setup, scan-QR onboarding)
- [ ] PCB + carrier board: Pi Zero 2 W + 16 GB eMMC + USB-C power + 1× USB-A + optional 3.5 mm analog out + LED status; BOM target $35–45
- [ ] Case: plain ABS injection-molded; tooling ~$5–15K one-time, amortized over thousands of units
- [ ] FCC / CE / IC certification — $8–14K one-time per market (radio chip is the Pi's; cert leverages chipset's existing certs)
- [ ] **Sizing-risk hedge: Hub Stick Plus ($99 retail) on Pi 5 (2 GB)** as planned post-M13 upsell SKU if stress-testing surfaces audio glitches at 4+ sinks per household. Decision deferred until benchmarking.
- [ ] **Tier-3 polish (post-launch): USB-A-from-TV power source** — eliminate wall wart if Pi Zero 2 W power draw fits TV USB-A's 500 mA budget. UX win worth real testing.

**Gate:** out-of-box experience: plug in Hub Stick, scan QR code with phone, all home speakers light up in iOS companion. 3-sink household plays in audible sync; 5-sink household plays without glitches over a 30-min soak.

---

### M14 — Hub Pro (HDMI ARC), $249 hardware (est. 6 months)

The headline product: **every TV → every speaker**. Sits on the HDMI ARC return path, captures all TV audio (Netflix, broadcast, every smart-TV app), fans out to wireless speakers in sync. **Press TV power, audio everywhere, two seconds, zero phone interaction.** Full UX vision + sizing analysis + design gaps in [`website/HUB_DESIGN.html`](../website/HUB_DESIGN.html). UX decisions captured in `DECISIONS.md` 2026-05-16 entries.

**Hardware:**
- [ ] **Pi Compute Module 4 (4 GB Lite)** as the SoC — picked over CM5 for $30–45 BOM savings (CM5's A76 cores aren't needed for our workload; revisit if M14 v2 Atmos passthrough surfaces CPU saturation). Adafruit's own boards (ESP32 Feather etc.) are wrong tier — microcontrollers, not Linux SBCs.
- [ ] HDMI 2.x eARC capture chipset: Realtek RTD2173 (or similar) — handles ARC + eARC + HDCP 2.3 transparently
- [ ] TOSLINK optical input: Cirrus Logic CS8416 + CS5341 ADC for older TVs without HDMI ARC
- [ ] 32 GB eMMC + M.2 NVMe slot (future audio buffering for replay features)
- [ ] Custom carrier board with: HDMI ARC in, TOSLINK in, 2× USB-A, USB-C power, Ethernet RJ45, 3.5 mm analog out, optical out, status LED
- [ ] Custom case — sits behind TV or in AV cabinet; ~120 × 80 × 25 mm
- [ ] FCC / CE / IC certification — shared chassis with Hub Stick where possible
- [ ] Manufacturing: Mexico assembly via cousin's network (Guadalajara or Monterrey), USMCA zero-tariff. ~$100–115 BOM at 1k units; $130–150 margin at $249 retail.

**Hub Pro killer UX (the magic moment):**
- [ ] **Dual auto-trigger** — HDMI-CEC `Set Stream Path` + ARC audio-activity detection. CEC for fast trigger + TV identification (auto-pick saved profile); ARC audio-activity as redundant backup if CEC misbehaves (Anynet+ / Bravia Sync / Simplink quirks).
- [ ] **CEC remote passthrough** — Hub Pro registers as TV's "Audio System." TV remote volume / mute / power buttons fan out to every active sink via libCEC. Multiplicative scaling preserves relative balance (each sink × 1.05 per volume-up click). **The differentiator vs. Sonos / WiiM / Apple TV — none does this for a heterogeneous mesh.**
- [ ] **Per-TV / per-HDMI-input profiles.** CEC EDID lookup auto-resolves TV make/model; first-connect picker as fallback. Profile = `{source: TV/AP2-receive/Cast-receive/Manual, speakers: [SinkID], volumes, offsets, EQ, surround mode}`. Same JSON-on-UserDefaults persistence as Mac app's `SpeakerGroups`.
- [ ] **Graceful teardown on TV power-off.** ARC silent >5 s → RTSP TEARDOWN + Sonos SOAP Stop. Reuses existing `applicationWillTerminate` path.
- [ ] **Boot-time optimization** — custom initramfs + direct-boot to our daemon. Target <5 s power-on to ready (vs. ~15 s default Pi CM4 boot).

**Decisions deferred for v1:**
- [ ] Surround audio handling — M14 v1 ships stereo downmix; M14 v2 ships per-sink Atmos passthrough (capable sinks get Atmos, non-capable sinks get downmix, all in sync).
- [ ] HDMI passthrough topology — M14 v1 is ARC-only (Hub Pro plugs into ARC port, doesn't touch video signal). Full passthrough is a future $349 "Hub Pro Plus" SKU if customers ask.
- [ ] Voice-assistant conflict resolution (Alexa said in the room → only Sonos hears it → mesh out of sync). Tier 2 polish, post-launch.

**Gate:** turn on TV, audio plays through every wireless speaker in the house, in sync, regardless of which app is producing it. Within 2 sec of TV power-on, no phone interaction required. TV remote volume / mute work across the mesh.

---

### M15 — Optical Hub, $79 hardware (est. 3 months) **— scope expanded 2026-05-16; possibly reorder before M14**

**Mass-market sweet-spot SKU** for the huge 2014–2018 TV cohort with optical out + no reliable HDMI ARC. Adds IR receiver hardware + remote-learning UX to give TV-remote integration without HDMI complexity. Same Sonos Beam optical-mode pattern.

**Hardware:**
- [ ] TOSLINK receiver chip (CS8416 + CS5341 ADC, or off-the-shelf S/PDIF input module)
- [ ] **IR receiver — 38 kHz IR demodulator chip** (~$0.50 BOM addition) + small IR window in the case
- [ ] Pi Zero 2 W SoC (same as Hub Stick — workload is light without HDMI processing)
- [ ] Adapt Hub Stick OS image to read S/PDIF instead of network audio
- [ ] Cert leverages Hub Stick chassis

**IR remote-learning UX (the killer feature of this SKU):**
- [ ] iOS companion setup flow: "Point your TV remote at the Optical Hub and press Volume Up." Hub learns the IR code.
- [ ] Repeat for Volume Down + Mute.
- [ ] Optional: learn Power codes for graceful teardown when TV powers off.
- [ ] After setup: TV remote becomes the universal volume control for the mesh, fan-out via the same multiplicative-scaling math as Hub Pro's CEC remote passthrough.

**Possibly reorder M14 ↔ M15 — decision deferred:**
Optical Hub is simpler hardware than Hub Pro (no HDMI receiver chipset, no eARC, no HDCP). It also addresses a bigger immediate audience (median US household has a pre-2018 TV). Shipping it first would:
- Validate the manufacturing chain at a lower-risk SKU
- Reach more households at $79 than Hub Pro reaches at $249
- Build the IR-learning hardware experience before tackling Hub Pro's HDMI complexity

Argument against reordering: Hub Pro is the headline / press / demo product. "Press TV power audio everywhere" wins the press cycle. Optical Hub's "IR remote learning" is incremental.

**Decision deferred** until M13 first-ship manufacturing experience + M8 press strategy clarify. See `docs/DECISIONS.md` 2026-05-16 (same night) "5-SKU lineup expansion" entry.

---

## Parallel tracks — non-engineering work that runs alongside the engineering milestones

Committed 2026-05-15 from strategy threads 2 and 3 in `docs/DECISIONS.md`. These tracks **don't block engineering** — they're outreach + community work that runs in parallel with the M5–M8 timeline.

### Partnership outreach (start during M7)

**Audience:** the second tier of audiophile brands that have abandoned customer install bases via the AirPlay 2 transition and have **no walled-garden conflict** with us (they don't sell software platforms, so a cross-protocol pitch doesn't contradict any business they're defending).

- [ ] **B&W (Bowers & Wilkins) — first contact.** Cleanest narrative — we already use their A5/A7 as primary test hardware. Pitch: "your AP1 customer base needs a lifeline; SuperAudio is it." Ask: profile validation, co-marketing, optionally a "B&W recommended" badge on the landing page.
- [ ] **Naim Audio — second contact.** Same pitch shape; Naim has a strong audiophile reputation and a similarly abandoned AP1 install base (Mu-so 1st gen).
- [ ] **KEF, Marantz, McIntosh, NAD — staggered.** Same template. Drop if first contact lands poorly; the strategy doesn't depend on partnerships succeeding.
- [ ] **Track outcomes**: which brands respond, which decline, which propose alternatives (e.g., affiliate revenue share). Capture in `docs/DECISIONS.md` so the next outreach round has institutional memory.

**Decision trigger to abandon track:** if the first three contacts produce no response within 4 weeks. Pivot to community-driven attribution ("Profile contributed by [brand fan community]") instead of formal brand partnerships.

### Anthropic Skills outreach (start when M6.5 ships)

**The play:** SuperAudio's Claude Skill is a real-world consumer-facing use of Skills doing hardware-adjacent work. Anthropic wants those case studies; we want the discovery surface.

- [ ] **DevRel outreach** — direct contact (LinkedIn / public channels) when the Skill alpha is testable. Offer to be a launch-partner case study for whatever Skills marketplace ships next.
- [ ] **Risk hedge**: ship the Skill as a bundled in-app feature first; marketplace distribution is bonus, not load-bearing. If Anthropic decides tcpdump-via-skill is too sensitive a surface, the in-app version still works (it asks the user to run `sudo tcpdump` themselves).
- [ ] **If marketplace launch happens**: be present on day one with at least 20 working profiles in the public repo. Without seed coverage, the Skill looks like a demo rather than a system.

**Decision trigger to abandon track:** if Anthropic does not respond within 6 weeks, OR if a Skills marketplace doesn't ship within 12 months of our M8 launch. The Skill still works without the marketplace — we just lose the discovery channel.

### Community + open-source repo (continuous, starts at M5.5)

- [ ] **Public repo go-live at M5.5** — `github.com/davidpuerto/superaudio-device-profiles` (final naming when shipped) with MIT license, JSON schema, four seed profiles, CI for PR validation, CODEOWNERS routing by protocol.
- [ ] **Contributor recognition**: each profile carries a `contributed_by` field; the app surfaces this in the device picker tooltip ("Profile contributed by @username"). Cheap, high-signal community engagement.
- [ ] **Profile attribution in About box**: in-app "About" lists all profile contributors by handle. Optional opt-out for contributors who prefer anonymity.
- [ ] **GitHub Discussions enabled for issue triage** — keep the main issue tracker for the app, route profile-specific issues to Discussions to avoid mixing.

---

## What the product looks like at M14

A household with:
- A Mac (or Hub Stick) for sourcing audio
- A TV (with Hub Pro on the HDMI ARC port — this, not a tvOS app, is what captures TV audio downstream of the sandbox + DRM and fans it out)
- Any mix of speakers: AP1, AP2, Sonos, Chromecast, Bluetooth
- An iPhone for control + Room Tuning

→ Press play on the TV (or phone, or Mac). Audio plays everywhere, in sync, tuned to each room. No walled garden, no subscription. One-time purchase: $19 base + $5 addons + $59/$249 hardware as needed. Total spend for a fully kitted household: **~$80–350**.

The Sonos / Bluesound / Apple equivalent: **$800–2,000+** in vendor-locked hardware before you can hear it.

---

## What we explicitly punt on (forever or for v1)

(See full list in [../CLAUDE.md](../CLAUDE.md) Non-goals)

- App Store distribution (Mac and Hub — sandbox incompatible; iOS companion uses App Store standardly). *tvOS app dropped entirely — see M9 cancellation (tvOS can't capture system/other-app/DRM audio).*
- DRM-protected content (Apple Music FairPlay output is silent through the tap — expected)
- Cross-platform Mac apps for Windows or Linux (Windows is the only one that'd move the needle; deferred to post-M14)
- A cloud service of any kind (LAN-only, no telemetry, no analytics — this is a competitive differentiator)
- Voice control / Siri shortcuts (Apple's APIs are limited and locked; not worth the integration cost)
- Sonos Voice or any in-house voice assistant
- Subscription pricing (one-time purchases only; addons are one-time; pricing is the moat)

---

## Patents / legal exposure

(See full analysis in [../website/COMPETITIVE_LANDSCAPE.html](../website/COMPETITIVE_LANDSCAPE.html))

Headline: **~$3–5K FTO patent search budget** required before M13 (first hardware ship). **No patent exposure for M1–M12** — all software, all using public protocols with 15+ year prior-art precedent. Sonos's multi-room patents are the highest-risk area; our defense is that we use each protocol's native sync mechanism rather than inventing our own.

---

## How to use this file

- **If you're new:** start here, then read `CLAUDE.md` for architecture.
- **Before starting a milestone:** read its sub-tasks, then read the relevant sections of `CLAUDE.md` (architecture, gotchas, tripwires).
- **When a milestone completes:** mark its checkboxes, update the "Progress snapshot" section at the top, and add a one-line entry to `DECISIONS.md` if any architectural choice was made along the way.
- **If a milestone reveals the plan is wrong:** stop and update this file (and CLAUDE.md / DECISIONS.md as needed) **before** writing more code.

---

*Last updated: 2026-06-03 — cross-protocol sync PROVEN on real hardware (B&W A5 + Sonos Playbar + Sonos One SL); new M6.8 `PassiveSyncMonitor` milestone (passive content-based continuous sync; GCC-PHAT = #1 next lever, chirp re-anchor interim, ultrasonic pilot endgame); rotary knob UI (#100) marked REMOVED/cancelled (AirPlay delay slider now 25 ms steps); current frontier = M12 AP2 sender (committed V1 hero, hardware on the LAN) + the passive-sync/GCC-PHAT thread. Earlier 2026-05-17 (Sunday) — M6 sync arc DONE (sender-side broadcaster delay, handshake barrier, Sonos start-align defer, supervisor retry cap, session-race nonce guard, volume debounce, TEARDOWN timeout, Mac-mute fix, audio-gap telemetry, Sonos Δ slider rip, idempotent Play All, Restart All); M3 signal-handler item marked done; new M6.3 Sync UX milestone added with 5 tasks (#98–#102) including Mac-mic auto-calibration as M11 Path A precursor; M11 reframed to acknowledge Path A ships in M6.3. Earlier 2026-05-16 (night, same-night expansion) — M5.5 schema gains dual roles (sink + control); M6.5 Claude Skill scope expanded to onboard soundbars + control-layer devices alongside speakers; M15 Optical Hub gains IR remote-learning hardware ($0.50 BOM addition); 5-SKU lineup; M14 ↔ M15 reorder under consideration. Earlier 2026-05-16 update: M13/M14 hardware sizing + LATAM mfg strategy. Earlier 2026-05-15 (night) — M5 done + M6 partial.*
