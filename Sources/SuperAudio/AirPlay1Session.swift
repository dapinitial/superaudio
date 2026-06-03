// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import AVFoundation
import SuperAudioCore
import SuperAudioAirPlay1

/// One end-to-end AirPlay 1 session: RTSP handshake, then live audio from the
/// system tap, then clean teardown. M3a uses verbatim ALAC mode (lossless,
/// ~1.4 Mbps over WiFi); M3b will swap in Apple's open-source ALAC encoder.
///
/// Invoked from the menu bar click handler. For Phase 1 we run a fixed-length
/// (30 s) test session so the test loop stays tight. The Phase 1 demo gate
/// (30 min soak test) will reuse this code with a longer duration.
enum AirPlay1Session {

    /// Default duration used by the auto-click test driver. Menu-bar clicks
    /// pass `nil` to run until the user toggles off.
    static let autoClickDurationSeconds: UInt64 = 60

    /// M3a bisect — set to `false` to send et=0 (no SDP crypto, cleartext
    /// audio). Helps isolate whether the AES layer is responsible for silent
    /// playback. Flip back to `true` once the bug is identified and the
    /// encrypted path is verified working.
    ///
    /// 2026-05-14 status: pipeline now produces real compressed ALAC matching
    /// Music.app's 642-1117 byte signature. With et=1 the speaker's LED goes
    /// Default during M3 bisect was et=0 because RED decode errors looked
    /// encryption-related (turned out to be the ALAC verbatim/compressed
    /// mismatch — see CLAUDE.md gotcha #10). Now that et=0 is confirmed
    /// working on B&W A5/A7, this defaults to false but is OVERRIDABLE
    /// via the `useEncryptedAirPlay` UserDefault for verification on
    /// receivers that require et=1 (Apple AirPort Express, some older
    /// firmware revisions, some third-party receivers).
    ///
    /// **2026-05-18 — verification of et=1 with compressed ALAC is the
    /// M3 hardening (2/2) gate.** Toggle in Preferences and confirm
    /// audio still plays on B&W A5/A7.
    static var useEncryption: Bool {
        UserDefaults.standard.bool(forKey: "useEncryptedAirPlay")
    }

    /// - Parameter duration: if non-nil, run for that many seconds then
    ///   TEARDOWN. If nil, run until the surrounding Task is cancelled —
    ///   this is what menu-bar "toggle off" relies on.
    /// Tracks mid-session network health. Set by the periodic OPTIONS
    /// keepalive task; checked by the main wait loop. Wrapped in a class
    /// so a detached health-monitor `Task` can flip it from off the main
    /// run() call. `@unchecked Sendable` because Bool writes on Apple
    /// silicon are word-sized and atomic in practice, and we don't need
    /// strict happens-before — eventual visibility is sufficient.
    final class HealthFlag: @unchecked Sendable {
        var lost: Bool = false
    }

    /// Defer-window for the health monitor. When the broadcaster delay is
    /// bumped by a large amount via `setOffset`, the AP1 receiver goes
    /// silent for the duration of the bump (no audio to play → no timing
    /// packets emitted). The health monitor would interpret that as a
    /// dead receiver and tear down a perfectly-healthy session. Setting
    /// `snoozeUntilUnixTime` to a future time tells the monitor "skip
    /// staleness checks until then." `@unchecked Sendable` for the same
    /// reason as `HealthFlag` — word-sized atomic writes.
    final class HealthSnooze: @unchecked Sendable {
        var snoozeUntilUnixTime: Double = 0
    }

    /// Returns the reason this session ended. The supervisor uses it to
    /// decide retry strategy: `.networkLost` / `.failedAfterAudio` retry
    /// indefinitely; `.failedBeforeAudio` counts against the supervisor's
    /// "give up after N" cap; `.cleanExit` exits the loop.
    @discardableResult
    static func run(descriptor: SinkDescriptor, duration: TimeInterval? = nil) async -> SessionState.SessionExitReason {
        let label = descriptor.displayName

        // Mark the sink as currently-playing so the menu shows a checkmark
        // and the menu-bar icon pulses. Cleared on every exit path via
        // `defer` so the UI never gets stuck.
        let sinkID = descriptor.id
        // Capture our session nonce so the defer block can detect whether
        // a newer session has taken over the sink before we exited — in
        // which case we MUST NOT wipe state the new session has registered.
        // Without this guard, an old session's slow async teardown (e.g.,
        // 4 s "RTSP timed out" on sendTeardown) can clobber the freshly-
        // started replacement session's volume/offset setters and active
        // flag. Diagnosed 2026-05-16 from logs showing "A5 unchecked but
        // still playing" — old session's defer wiped new session's state.
        let sessionNonce = await MainActor.run {
            SessionState.shared.markActive(sinkID)
            return SessionState.shared.currentNonce(for: sinkID) ?? UUID()
        }
        // `reachedLiveStream` flips true once we've made it past the
        // handshake → broadcaster subscribe → RTPSender connect sequence
        // and are actively pumping audio. If the function exits before
        // that point, the defer block records a failure so the UI shows
        // a red ❌ in place of a silent uncheck.
        var reachedLiveStream = false
        defer {
            let succeeded = reachedLiveStream
            Task { @MainActor in
                SessionState.shared.endSessionIfStillCurrent(
                    sinkID: sinkID,
                    nonce: sessionNonce,
                    wasSuccess: succeeded
                )
            }
        }

        // Generate the per-session RTP starting values BEFORE the RECORD
        // request so the values we advertise in the RTP-Info header match
        // the values RTPSender will actually stamp into the first packet.
        let initialSeq = UInt16.random(in: 1_000...30_000)
        let initialTS  = UInt32.random(in: 1_000_000...3_000_000_000)

        // Handshake with retry. B&W AP1 receivers (and likely the wider
        // AirTunes/103.x family) sometimes drop the very first connection
        // attempt while waking from low-power state — the TCP/RTSP path
        // times out and a fresh attempt seconds later succeeds cleanly.
        // 2 attempts with a 200ms backoff covers the cold-start case
        // transparently. See `docs/DECISIONS.md` 2026-05-15 and
        // `memory/project_a7_rtsp_timeout.md` for the evidence trail.
        let handshakeResult = await Self.handshakeWithRetry(
            descriptor: descriptor,
            initialSeq: initialSeq,
            initialTS: initialTS,
            label: label
        )
        guard let (client, ports) = handshakeResult else {
            Log.app.error("✗ Handshake exhausted retries for \(label, privacy: .public) — giving up (red ❌ via defer)")
            // Drain the barrier entry even on failure — otherwise other
            // sinks in the batch stall until the 10 s fallback timeout.
            await MainActor.run { SessionState.shared.markHandshakeComplete(sinkID) }
            return .failedBeforeAudio
        }

        do {

            // Initial volume comes from SessionState — defaults to 15%
            // (quiet-by-default per defaultVolumePercent). Subsequent
            // slider changes hit the speaker live via the volumeSetter
            // closure registered below.
            //
            // **Done BEFORE the barrier mark** so SET_PARAMETER's
            // RTSP/TCP round-trip is part of each sink's "ready"
            // signal. Otherwise A7's slow SET_PARAMETER under TCP
            // contention (2.2 s observed in 2026-05-17 logs) would
            // delay its subscribe by 2.2 s after barrier release,
            // re-introducing exactly the skew the barrier exists to
            // prevent.
            let initialPct = await MainActor.run { SessionState.shared.volume(for: sinkID) }
            let initialDB = SessionState.airplay1Volume(fromPercent: initialPct)
            let volume = try await client.sendSetVolume(level: initialDB)
            if volume.isOK {
                Log.app.notice("✓ VOLUME   \(label, privacy: .public) → \(volume.statusLine, privacy: .public)  (\(initialPct)%, \(String(format: "%.1f", initialDB)) dB)")
            } else {
                Log.app.error("✗ VOLUME   \(label, privacy: .public) → \(volume.statusLine, privacy: .public)")
            }

            // Register a live-update closure so the menu slider drives
            // SET_PARAMETER volume on this RTSP session mid-stream. The
            // closure captures `client` weakly — when the session tears down
            // and `defer` unregisters us, any in-flight update becomes a
            // no-op rather than racing the TEARDOWN.
            let volumeSetter: @Sendable (Int) async -> Void = { [weak client] pct in
                guard let client else { return }
                let dB = SessionState.airplay1Volume(fromPercent: pct)
                _ = try? await client.sendSetVolume(level: dB)
                Log.airplay1.info("Volume → \(pct)% (\(String(format: "%.1f", dB)) dB) on \(label, privacy: .public)")
            }
            await MainActor.run { SessionState.shared.registerVolumeSetter(volumeSetter, for: sinkID) }

            // Resolve the receiver's numeric IP for the UDP audio socket.
            // descriptor.endpoint.host is empty (NWConnection.service resolves
            // lazily for TCP). We use the same Bonjour-name → IP helper the
            // RTSP layer uses.
            guard let host = RTSPClient.resolveServiceHost(for: descriptor) else {
                Log.app.error("Could not resolve receiver IP for \(label, privacy: .public) — abort audio path")
                _ = try? await client.sendTeardown()
                client.disconnect()
                // Drain barrier entry on failure
                await MainActor.run { SessionState.shared.markHandshakeComplete(sinkID) }
                return .failedBeforeAudio
            }
            Log.app.notice("Resolved \(label, privacy: .public) → \(host, privacy: .public):\(ports.audio)")

            // **NOW** mark this sink's full pre-audio setup as done and
            // wait for the rest of the batch. All RTSP-over-TCP work
            // (SET_PARAMETER, etc.) has completed by here — what's left
            // is broadcaster subscribe + UDP RTPSender connect, both
            // sub-millisecond. So when the barrier releases, every sink
            // subscribes simultaneously.
            await MainActor.run { SessionState.shared.markHandshakeComplete(sinkID) }
            Log.app.notice("Awaiting start barrier — \(label, privacy: .public)")
            await SessionState.shared.awaitStartBarrier()
            Log.app.notice("Start barrier released — proceeding for \(label, privacy: .public)")

            // Subscribe to the shared AudioBroadcaster. M5: every active
            // sink reads from one SystemAudioCapture instead of N — so the
            // `presentationHostTime` on each chunk is the same reference
            // frame across A5, A7, Sonos Den. Per-sink clock translation
            // anchors against a single canonical moment, which is what
            // makes sample-accurate sync achievable.
            //
            // 2026-05-16 night (take 2): `delaySeconds` shifts AP1's
            // chunk delivery to match Sonos's intrinsic buffer floor.
            // The broadcaster makes a defensive PCM copy and rewrites
            // `presentationHostTime` to keep sync-NTP math in the
            // present (vs take 1 which hit silence because chunks
            // arrived with timestamps from 2 sec ago, sending NTP
            // values in the past that receivers rejected).
            let initialDelaySeconds = await MainActor.run {
                Double(SessionState.shared.effectiveOffsetForAirPlay1(sinkID: sinkID, label: label)) / 1000.0
            }
            let chunkStream: AsyncStream<AudioChunk>
            do {
                chunkStream = try AudioBroadcaster.shared.subscribe(id: sinkID, delaySeconds: initialDelaySeconds)
            } catch {
                Log.app.error("AudioBroadcaster subscribe failed: \(String(describing: error), privacy: .public)")
                _ = try? await client.sendTeardown()
                client.disconnect()
                return .failedBeforeAudio
            }
            guard let captureFormat = AudioBroadcaster.shared.streamFormat else {
                Log.app.error("AudioBroadcaster has no streamFormat after subscribe")
                AudioBroadcaster.shared.unsubscribe(id: sinkID)
                _ = try? await client.sendTeardown()
                client.disconnect()
                return .failedBeforeAudio
            }

            // Spin up the RTP sender bound to the same session keys.
            // M5c: pass both the wall-clock and mach-time anchor parts from
            // `AudioBroadcaster.shared.anchor` so sync packets compute their
            // NTP value from the CURRENT chunk's wall time (not from a
            // fixed past anchor). Every active AP1 session computes the
            // same NTP for the same chunk → every receiver schedules audio
            // against the same wall time → sample-accurate cross-sink sync.
            // Always in the (near) future because the chunk's wall time is
            // approximately "now", so the past-anchor regression that
            // broke A7 in M5 second pass does not recur for late subscribers.
            let anchor = AudioBroadcaster.shared.anchor
            let sender: RTPSender
            do {
                sender = try RTPSender(
                    host: host,
                    audioPort: ports.audio,
                    controlPort: ports.control,
                    audioLatency: client.negotiatedAudioLatency,
                    aesKey: client.aesKey,
                    aesIV: client.aesIV,
                    useEncryption: useEncryption,
                    initialSequence: initialSeq,
                    initialRTPTimestamp: initialTS,
                    inputFormat: captureFormat,
                    playbackAnchorWallTime: anchor?.referenceWallTime,
                    playbackAnchorHostTime: anchor?.referenceHostTime,
                    // Source-port matters: route sync packets through
                    // RTSPClient's BSD socket bound to our advertised local
                    // control port. Confirmed via PortProbe on 2026-05-14:
                    // the receiver `connect()`s its control socket to that
                    // exact source port and ICMP-rejects everything else.
                    controlPacketSender: { [weak client] data in
                        client?.sendOnControlSocket(data, toHost: host, port: ports.control)
                    }
                )
                try await sender.connect()
                // RTPSender's `manualOffsetSeconds` is now 0 — the per-sink
                // offset is applied at the broadcaster (sender-side audio
                // delay), not via NTP scheduling. B&W A5/A7 receivers
                // clamp far-future NTP scheduling to their internal
                // buffer (~93 ms) and ignore the rest, so the M5d NTP
                // shift never actually delayed playback. Sender-side
                // delay sidesteps that entirely.
                //
                // Cross-AP1 sync is preserved because every AP1 session
                // subscribed with the same `delaySeconds` gets chunks
                // with the same rewritten `presentationHostTime` (every
                // delayed yield computes `original + delayHostUnits`,
                // which is deterministic per chunk regardless of which
                // Task wakes when).
                sender.manualOffsetSeconds = 0
                // Mid-stream offset slider changes call directly into
                // `AudioBroadcaster.setDelay`, which retimes every chunk
                // already in the per-subscriber queue (M6.3 #99 — real-
                // time slider drag). The user hears the drag IN REAL TIME:
                // - Slider UP: queued chunks shift forward, brief pause
                // - Slider DOWN: queued chunks shift back, brief fast-forward
                // Both effects are sub-perceptible at typical 5–10 ms
                // slider ticks.
                let captureSinkID = sinkID
                let offsetSetter: @Sendable (Int) -> Void = { ms in
                    AudioBroadcaster.shared.setDelay(Double(ms) / 1000.0, for: captureSinkID)
                    Log.airplay1.info("Offset → \(ms) ms (live) on \(label, privacy: .public)")
                }
                await MainActor.run { SessionState.shared.registerOffsetSetter(offsetSetter, for: sinkID) }
                // sendInitialSync is now fired from the pump task on the
                // FIRST chunk arrival (see pumpTask below), seeded with
                // that chunk's host time. Required for broadcaster-side
                // delay to work — calling it inline here would emit NTP
                // referencing "now + 0.2 s" but no audio would arrive
                // until `delaySeconds` later, wedging the receiver's
                // playback schedule.
            } catch {
                Log.app.error("RTPSender failed: \(String(describing: error), privacy: .public)")
                AudioBroadcaster.shared.unsubscribe(id: sinkID)
                _ = try? await client.sendTeardown()
                client.disconnect()
                return .failedBeforeAudio
            }

            if let duration {
                Log.app.notice("◆ Audio pipeline live for \(Int(duration))s. Press play in any app — \(label, privacy: .public) should produce sound.")
            } else {
                Log.app.notice("◆ Audio pipeline live until cancelled — \(label, privacy: .public) should produce sound.")
            }
            // From here on we are streaming. Exiting after this point counts
            // as a clean run, not a failure — clear the failure-defer flag.
            reachedLiveStream = true

            // Pump captured chunks into the sender. Runs on a background task
            // so the surrounding orchestration can await the timed teardown.
            // The chunkStream comes from AudioBroadcaster.shared — same
            // chunks (same presentationHostTime) reach every active sink.
            //
            // On the FIRST chunk we send the initial sync packets (with
            // NTP seeded from the chunk's host time, so the receiver's
            // playback schedule aligns with when audio actually starts
            // flowing — critical for broadcaster-side delay paths where
            // chunks may not arrive until N seconds after session start).
            let pumpTask = Task.detached {
                var firstChunkSeen = false
                for await chunk in chunkStream {
                    if !firstChunkSeen {
                        firstChunkSeen = true
                        sender.sendInitialSync(seedingFirstChunkHostTime: chunk.presentationHostTime)
                        Log.airplay1.info("Initial sync emitted on first chunk arrival for \(label, privacy: .public)")
                    }
                    do {
                        try sender.enqueue(chunk)
                    } catch {
                        Log.app.error("RTP enqueue failed: \(String(describing: error), privacy: .public)")
                    }
                }
                Log.app.info("RTP pump loop ended (broadcaster unsubscribed)")
            }

            // Mid-stream health monitor — UDP timing-packet presence.
            //
            // **Rewritten 2026-05-16 Saturday** after soak-test logs
            // showed false positives from the old OPTIONS-over-TCP
            // approach. The OPTIONS health check would time out during
            // active streaming because the RTSP TCP socket goes idle
            // (audio is over UDP) and either (a) the kernel/router
            // drops the connection silently or (b) B&W firmware doesn't
            // respond to OPTIONS reliably while in active RECORD state.
            //
            // The canonical "is the receiver still alive?" signal is
            // **whether the receiver is sending us timing requests**.
            // RAOP receivers transmit PT 0xD2 timing packets to our
            // timing port every ~1 sec while actively playing audio
            // we sent them. If they stop (because the connection died,
            // the speaker rebooted, or Wi-Fi dropped), the timestamp
            // recorded by `RTSPClient.lastTimingPacketUnixTime` stops
            // advancing. We watch that timestamp for staleness.
            //
            // Belt-and-braces: the M5 TCP-keepalive socket option also
            // detects connection death at the kernel layer (~60 s);
            // this check catches receiver-side failures faster (~15 s).
            //
            // Tuning:
            //   - 30 s startup grace — give the receiver time to begin
            //     its periodic timing transmissions after RECORD.
            //   - 5 s polling interval — check staleness every 5 s.
            //   - 15 s staleness threshold — if last timing packet is
            //     older than 15 s, flag network loss. Timing packets
            //     arrive at ~1 Hz under healthy conditions, so 15 s of
            //     absence is unambiguous.
            let healthFlag = HealthFlag()
            let healthSnooze = HealthSnooze()
            // Register the snooze handle so `SessionState.setOffset` can
            // temporarily pause health checks when a big delay bump is
            // applied (Auto-Align or large manual slider drag). Otherwise
            // the receiver going silent for ~3 sec during the bump trips
            // the timing-packet staleness check and tears down a healthy
            // session. Diagnosed 2026-05-18 from Auto-Align test logs.
            await MainActor.run {
                SessionState.shared.registerHealthSnoozer({ [weak healthSnooze] seconds in
                    healthSnooze?.snoozeUntilUnixTime = Date().timeIntervalSince1970 + seconds
                }, for: sinkID)
            }
            let healthMonitor = Task { [weak client, weak healthSnooze] in
                let startupGraceNs: UInt64 = 30_000_000_000  // 30 sec
                let pollIntervalNs: UInt64 = 5_000_000_000    // 5 sec
                let stalenessThreshold: Double = 15.0          // 15 sec
                try? await Task.sleep(nanoseconds: startupGraceNs)
                while !Task.isCancelled {
                    guard let c = client else { return }
                    let last = c.lastTimingPacketUnixTime
                    let now = Date().timeIntervalSince1970
                    // Snooze gate — skip the staleness check if we're
                    // inside a delay-bump window. Receivers legitimately
                    // stop emitting timing packets while they wait out
                    // future-scheduled audio.
                    if let snoozeUntil = healthSnooze?.snoozeUntilUnixTime, now < snoozeUntil {
                        try? await Task.sleep(nanoseconds: pollIntervalNs)
                        continue
                    }
                    if last == 0 {
                        // Still haven't received any timing packet 30 s
                        // post-RECORD. Unusual — receiver may not be
                        // emitting them. Log + keep watching.
                        Log.app.notice("Health: no timing packets yet on \(label, privacy: .public) — receiver hasn't started transmitting")
                    } else {
                        let staleness = now - last
                        if staleness > stalenessThreshold {
                            Log.app.error("Health: timing packets stale by \(String(format: "%.1f", staleness))s on \(label, privacy: .public) — flagging network loss")
                            healthFlag.lost = true
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: pollIntervalNs)
                }
            }

            if let duration {
                // Fixed duration (auto-click test mode).
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            } else {
                // Run until the wrapping Task is cancelled OR the health
                // monitor flags a network loss. Poll every second so we
                // react promptly without burning CPU.
                while !Task.isCancelled && !healthFlag.lost {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        break // Cancellation throws — drop out and tear down.
                    }
                }
            }

            if healthFlag.lost {
                Log.app.notice("◆ Network loss detected on \(label, privacy: .public) — exiting session for auto-reconnect")
            }

            healthMonitor.cancel()
            pumpTask.cancel()
            AudioBroadcaster.shared.unsubscribe(id: sinkID)
            sender.disconnect()

            // Tight TEARDOWN timeout (1.5 s). When a session is being
            // cancelled because the user toggled it off — or because a
            // newer session is replacing it — we don't want to block the
            // next start for the default 5 s. If the receiver doesn't
            // ACK the TEARDOWN in 1.5 s, we proceed to disconnect anyway;
            // the TCP socket close will free the receiver's session
            // state within its own session timeout (~30 s). Tuned
            // 2026-05-16 alongside Play All idempotency + generation
            // guard fix.
            do {
                let teardown = try await client.sendTeardown(timeout: 1.5)
                Log.app.notice("✓ TEARDOWN \(label, privacy: .public) → \(teardown.statusLine, privacy: .public)")
            } catch {
                Log.app.notice("TEARDOWN timed out / failed on \(label, privacy: .public) — proceeding to disconnect (\(String(describing: error), privacy: .public))")
            }
            client.disconnect()

            // Map exit cause to supervisor enum: lost-mid-stream signals
            // the supervisor to retry; clean exit (Task cancelled or
            // duration expired) tells it to stop the loop.
            return healthFlag.lost ? .networkLost : .cleanExit

        } catch {
            Log.app.error("AirPlay 1 session failed: \(label, privacy: .public) → \(String(describing: error), privacy: .public)")
            client.disconnect()
            // If we'd already started streaming audio, this is a mid-
            // stream failure (worth retrying). Otherwise it's a pre-
            // audio setup failure (counts against retry cap).
            return reachedLiveStream ? .failedAfterAudio : .failedBeforeAudio
        }
    }

    /// Attempts the RTSP handshake (connect → OPTIONS → ANNOUNCE → SETUP →
    /// RECORD) up to 2 times with a 200 ms backoff between attempts.
    /// Returns the connected `RTSPClient` + negotiated `ServerPorts` on
    /// success, or `nil` if both attempts fail.
    ///
    /// Retry mitigates AP1 receivers (B&W A5/A7 confirmed, likely wider
    /// AirTunes/103.x family) silently dropping the cold first attempt
    /// while waking from low-power mode. Cold-start failures are
    /// reproducible 5+ hours after a successful test against the same
    /// hardware; retry resolves them transparently. See
    /// `memory/project_a7_rtsp_timeout.md` for the evidence trail.
    private static func handshakeWithRetry(
        descriptor: SinkDescriptor,
        initialSeq: UInt16,
        initialTS: UInt32,
        label: String,
        maxAttempts: Int = 2,
        backoffNanos: UInt64 = 200_000_000
    ) async -> (RTSPClient, RTSPClient.ServerPorts)? {
        for attempt in 1...maxAttempts {
            let c = RTSPClient(descriptor: descriptor, useEncryption: useEncryption)
            do {
                try await c.connect()

                let options = try await c.sendOptions()
                guard options.isOK else {
                    Log.app.error("✗ OPTIONS  \(label, privacy: .public) (\(attempt)/\(maxAttempts)) → \(options.statusLine, privacy: .public)")
                    c.disconnect()
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: backoffNanos)
                    }
                    continue
                }
                Log.app.notice("✓ OPTIONS  \(label, privacy: .public) → \(options.statusLine, privacy: .public)")

                let announce = try await c.sendAnnounce()
                guard announce.isOK else {
                    Log.app.error("✗ ANNOUNCE \(label, privacy: .public) (\(attempt)/\(maxAttempts)) → \(announce.statusLine, privacy: .public)")
                    c.disconnect()
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: backoffNanos)
                    }
                    continue
                }
                Log.app.notice("✓ ANNOUNCE \(label, privacy: .public) → \(announce.statusLine, privacy: .public)")

                let setup = try await c.sendSetup()
                guard setup.isOK, let ports = c.serverPorts else {
                    Log.app.error("✗ SETUP    \(label, privacy: .public) (\(attempt)/\(maxAttempts)) → \(setup.statusLine, privacy: .public)")
                    c.disconnect()
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: backoffNanos)
                    }
                    continue
                }
                Log.app.notice("✓ SETUP    \(label, privacy: .public) → audio=\(ports.audio) control=\(ports.control) timing=\(ports.timing)")

                let record = try await c.sendRecord(
                    initialSequence: initialSeq,
                    initialRTPTimestamp: initialTS
                )
                guard record.isOK else {
                    Log.app.error("✗ RECORD   \(label, privacy: .public) (\(attempt)/\(maxAttempts)) → \(record.statusLine, privacy: .public)")
                    c.disconnect()
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: backoffNanos)
                    }
                    continue
                }
                Log.app.notice("✓ RECORD   \(label, privacy: .public) → \(record.statusLine, privacy: .public)")

                if attempt > 1 {
                    Log.app.notice("✓ Handshake recovered on retry \(attempt)/\(maxAttempts) for \(label, privacy: .public)")
                }
                return (c, ports)
            } catch {
                Log.app.error("✗ Handshake threw on attempt \(attempt)/\(maxAttempts) for \(label, privacy: .public) — \(String(describing: error), privacy: .public)")
                c.disconnect()
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: backoffNanos)
                }
            }
        }
        return nil
    }
}
