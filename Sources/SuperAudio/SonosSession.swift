// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import AVFoundation
import SuperAudioCore
import SuperAudioSonos

/// One end-to-end Sonos session: starts a local HTTP server, streams
/// AAC-LC of Mac audio into it, and tells the Sonos to play that URL.
///
/// Parallel to `AirPlay1Session`. The difference is that **Sonos doesn't
/// open a UDP audio channel** — it just pulls audio from an HTTP URL. So
/// the session lifecycle is:
///
///   1. Start `SystemAudioCapture` (shared format: 48 kHz f32 stereo)
///   2. Start `AACEncoder` (PCM → AAC-LC + ADTS)
///   3. Start `SonosStreamServer` (HTTP listener on `<mac-ip>:7331`)
///   4. Send Sonos `SetAVTransportURI(http://<mac-ip>:7331/stream.aac)`
///   5. Send Sonos `Play`
///   6. Pump capture chunks → encoder → server until cancelled
///   7. On cancel: send Sonos `Stop`, tear down server + capture
///
/// **Sonos floor (~200–500 ms):** Sonos buffers HTTP audio internally
/// and lag-syncs against its own clock. There's no per-packet timing
/// channel like AirPlay 1's NTP. Audio plays in the Sonos's own
/// scheduling, ~200–500 ms behind a Mac-direct or AirPlay 1 reference.
/// This is the documented "Sonos floor" from CLAUDE.md gotchas, exposed
/// to the user as a default offset slider in M5.
enum SonosSession {

    /// Default duration used when auto-click drives a fixed session. Menu
    /// toggle passes `nil` to run until cancelled.
    static let autoClickDurationSeconds: UInt64 = 60

    @discardableResult
    static func run(descriptor: SinkDescriptor, duration: TimeInterval? = nil) async -> SessionState.SessionExitReason {
        let label = descriptor.displayName
        let sinkID = descriptor.id
        let client = SonosClient(descriptor: descriptor)

        await MainActor.run { SessionState.shared.markSonosActive(descriptor) }
        // Flips true once SOAP Play has succeeded and audio is streaming.
        // If the function exits before then, defer records a failure so the
        // UI shows a red ❌ instead of silently unchecking the box.
        var reachedLiveStream = false
        defer {
            let succeeded = reachedLiveStream
            Task { @MainActor in
                SessionState.shared.unregisterVolumeSetter(for: sinkID)
                if !succeeded {
                    SessionState.shared.recordFailure(sinkID)
                }
                SessionState.shared.markSonosInactive(sinkID)
            }
        }

        // Live volume setter — the menu slider calls this every time the
        // user adjusts it for this sink. Sonos accepts SetVolume mid-stream
        // without interrupting playback (RenderingControl service runs
        // independently of AVTransport).
        let volumeSetter: @Sendable (Int) async -> Void = { [client] pct in
            _ = try? await client.setVolume(pct)
            Log.sonos.info("Volume → \(pct)% on \(label, privacy: .public)")
        }
        await MainActor.run { SessionState.shared.registerVolumeSetter(volumeSetter, for: sinkID) }

        // 1. Subscribe to AudioBroadcaster (M5 shared capture). Sonos reads
        // from the same fan-out stream as AirPlay 1, so all three speakers
        // see chunks with the same `presentationHostTime` reference frame.
        let chunkStream: AsyncStream<AudioChunk>
        do {
            chunkStream = try AudioBroadcaster.shared.subscribe(id: sinkID)
        } catch {
            Log.app.error("Sonos session broadcaster subscribe failed: \(label, privacy: .public) → \(String(describing: error), privacy: .public)")
            return .failedBeforeAudio
        }
        guard let captureFormat = AudioBroadcaster.shared.streamFormat else {
            Log.app.error("Sonos session: AudioBroadcaster has no streamFormat after subscribe")
            AudioBroadcaster.shared.unsubscribe(id: sinkID)
            return .failedBeforeAudio
        }

        // 2. AAC encoder
        let encoder: AACEncoder
        do {
            encoder = try AACEncoder(inputFormat: captureFormat)
        } catch {
            Log.app.error("Sonos session encoder failed: \(String(describing: error), privacy: .public)")
            AudioBroadcaster.shared.unsubscribe(id: sinkID)
            return .failedBeforeAudio
        }

        // 3. HTTP stream server
        let server = SonosStreamServer()
        do {
            try server.start()
        } catch {
            Log.app.error("Sonos session server failed: \(String(describing: error), privacy: .public)")
            AudioBroadcaster.shared.unsubscribe(id: sinkID)
            return .failedBeforeAudio
        }
        let httpURL = server.streamURL()
        let sonosURL = server.sonosStreamURL()
        Log.app.info("Sonos session: HTTP serving \(httpURL, privacy: .public); telling Sonos \(sonosURL, privacy: .public)")

        // 4. Start the audio pump BEFORE the SOAP call.
        //
        // Critical ordering: Sonos's `SetAVTransportURI` handler does a
        // live stream validation — it opens the HTTP URL, expects to see
        // real audio bytes within ~5 s, and times out the SOAP call if
        // nothing flows. If we start the pump only AFTER SOAP succeeds,
        // we get chicken-and-egg: Sonos waits for bytes, we wait for
        // SOAP, both time out.
        //
        // By starting the pump first, encoded AAC bytes are queued in
        // the server immediately. When Sonos connects (mid-SOAP) and
        // gets registered, the next `append()` pushes audio to it
        // within ~21 ms (the AAC frame cadence). Sonos sees real data,
        // validation succeeds, SOAP returns.
        let pumpTask = Task.detached {
            var chunkCount: UInt32 = 0
            for await chunk in chunkStream {
                do {
                    let aac = try encoder.encode(chunk.pcm)
                    server.append(aac)
                    chunkCount &+= 1
                    if chunkCount % 250 == 0 {
                        Log.sonos.info("Sonos pump: \(chunkCount) chunks encoded → \(server.connectionCount) listener(s)")
                    }
                } catch {
                    Log.sonos.error("Sonos pump encode error: \(String(describing: error), privacy: .public)")
                }
            }
            Log.app.info("Sonos pump loop ended (broadcaster unsubscribed)")
        }

        // 4.5. Start-time alignment.
        //
        // Wait for the AP1 handshake barrier (if any AP1 sinks are in the
        // same Play All batch) so all sessions cross this line together,
        // then apply the Sonos-specific defer. Net effect: Sonos's first
        // audio lands at approximately the same wall moment as AP1's,
        // regardless of how long the AP1 handshakes took. The pump
        // continues running during both the barrier wait and the defer,
        // queueing AAC bytes in the HTTP server for when Sonos connects.
        Log.app.notice("Sonos awaiting start barrier — \(label, privacy: .public)")
        await SessionState.shared.awaitStartBarrier()
        Log.app.notice("Start barrier released — Sonos applying defer for \(label, privacy: .public)")

        let deferSec = await MainActor.run { SessionState.shared.currentSonosStartDeferSec }
        if deferSec > 0 {
            Log.app.notice("Sonos start-align: deferring Play by \(String(format: "%.2f", deferSec))s for \(label, privacy: .public)")
            try? await Task.sleep(nanoseconds: UInt64(deferSec * 1_000_000_000))
            if Task.isCancelled {
                pumpTask.cancel()
                server.stop()
                AudioBroadcaster.shared.unsubscribe(id: sinkID)
                return .cleanExit
            }
        }

        // 5 + 6. Tell the Sonos to play our URL.
        //
        // Mimic the SomaFM SOAP call that worked: `x-rincon-mp3radio://`
        // URL scheme + EMPTY metadata. The `x-rincon-mp3radio:` prefix
        // is Sonos's "treat as continuous internet radio stream" hint.
        // DIDL-Lite metadata caused UPnP error 714.
        do {
            _ = try await client.setAVTransportURI(sonosURL, metadata: "")
            _ = try await client.play()
            // Snapshot the wall time at the moment Play succeeded —
            // this is the t=0 reference for Sonos-position auto-align
            // (#104). `GetPositionInfo.RelTime` ticks up from 0 from
            // here, so `sonos_lag = (now - playStart) - relTime`.
            let playStartedAt = Date()
            await MainActor.run { SessionState.shared.markSonosPlayStarted(sinkID, at: playStartedAt) }
            // Apply the saved per-sink volume immediately. Sonos's default
            // master volume is whatever the user last set via the Sonos app
            // — fine, but unrelated to *our* per-sink slider. Pushing our
            // saved value here keeps the two in sync the moment audio starts.
            let initialPct = await MainActor.run { SessionState.shared.volume(for: sinkID) }
            _ = try? await client.setVolume(initialPct)
            Log.app.notice("✓ Sonos PLAY \(label, privacy: .public) → \(sonosURL, privacy: .public)  (volume \(initialPct)%)")

            // #110 (M6.4) — auto-trigger Mic Calibrate (chirp) ~5 sec
            // after Sonos Play succeeds, when AP1 sinks are in the mix.
            // Calibration runs during Sonos's intrinsic ~30-sec settling
            // ramp (when AP1↔Sonos sync is bad anyway). By the time
            // Sonos hits steady-state, AP1 is already re-tuned to match.
            // User clicks Play All → music plays → sync locks in within
            // ~15 sec, no further user input.
            //
            // Gated on `autoCalibrateOnPlayAll` pref (default true) and
            // mic permission. Skipped on pure-Sonos sessions (no AP1 to
            // adjust) and recent-calibration sessions (avoid loops).
            // Detached so SOAP failures here don't cascade.
            let sonosSinkIDForCalibration = sinkID
            Task { @MainActor in
                guard SessionState.shared.autoCalibrateOnPlayAll else {
                    Log.app.info("Auto-calibrate (M6.4): disabled by pref — skipping")
                    return
                }
                // Wait 5 sec — let Sonos become audible + the broadcaster
                // reference tap accumulate enough samples. Per-sink
                // measurements need 7.5s mic + lookahead, so we need
                // the broadcaster running first.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // Recheck preconditions — user may have stopped, restarted,
                // or this Sonos may no longer be active.
                guard SessionState.shared.sonosPlayStartedAt[sonosSinkIDForCalibration] != nil else {
                    Log.app.info("Auto-calibrate (M6.4): Sonos no longer active — skipping")
                    return
                }
                let hasActiveAP1 = SessionState.shared.activeSinks.contains { id in
                    DiscoveredSinks.shared.sinks.first(where: { $0.id == id })?.protocolKind == .airplay1
                }
                guard hasActiveAP1 else {
                    Log.app.info("Auto-calibrate (M6.4): no AP1 sinks active — skipping (pure-Sonos session)")
                    return
                }
                guard !SessionState.shared.didRecentlyCalibrate else {
                    Log.app.info("Auto-calibrate (M6.4): recent calibration <2 min ago — skipping")
                    return
                }
                do {
                    Log.app.notice("Auto-calibrate (M6.4): running per-speaker chirp calibration silently…")
                    let result = try await MicCalibrator.runFullCalibration()
                    SessionState.shared.markCalibratedNow()
                    Log.app.notice("Auto-calibrate (M6.4) ✓ Sonos lag=\(String(format: "%.3f", result.sonosMeasurement.lagSec), privacy: .public)s; AP1 adjustments applied to \(result.ap1AdjustmentsMs.count) sink(s)")
                } catch {
                    Log.app.error("Auto-calibrate (M6.4) failed: \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            Log.app.error("Sonos SOAP failed: \(String(describing: error), privacy: .public)")
            pumpTask.cancel()
            server.stop()
            AudioBroadcaster.shared.unsubscribe(id: sinkID)
            return .failedBeforeAudio
        }

        if let duration {
            Log.app.notice("◆ Sonos pipeline live for \(Int(duration))s — \(label, privacy: .public)")
        } else {
            Log.app.notice("◆ Sonos pipeline live until cancelled — \(label, privacy: .public)")
        }
        // SOAP Play succeeded and pump task is running — clean run.
        reachedLiveStream = true

        if let duration {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
            }
        }

        // 7. Cleanup. Stop SOAP first so the Sonos releases its
        // HTTP-fetch socket cleanly; then tear down our side. Unsubscribe
        // from AudioBroadcaster — when this is the last subscriber, the
        // broadcaster will stop the shared SystemAudioCapture.
        pumpTask.cancel()
        AudioBroadcaster.shared.unsubscribe(id: sinkID)
        do {
            _ = try await client.stop()
            Log.app.notice("✓ Sonos STOP \(label, privacy: .public)")
        } catch {
            Log.app.error("Sonos STOP failed: \(String(describing: error), privacy: .public)")
        }
        server.stop()
        // Reached audio AND exited cleanly — user-cancelled or duration
        // expired. The supervisor uses this to stop retrying.
        return .cleanExit
    }

    /// Build a Sonos-compatible DIDL-Lite XML blob describing a live
    /// HTTP audio stream. Passed as the `CurrentURIMetaData` parameter
    /// of `SetAVTransportURI`. Without this, Sonos rejects the URI with
    /// UPnP error 714 ("Illegal MIME type").
    ///
    /// The returned string is **XML-escaped** so it can be embedded
    /// inline inside the SOAP envelope (SoCo and similar reference
    /// implementations do the same — `&lt;`, `&gt;`, `&quot;`, `&amp;`
    /// for the angle brackets, quotes, and ampersands inside DIDL-Lite).
    private static func buildDIDLLite(streamURL: String, mime: String) -> String {
        // Inner DIDL-Lite XML. `protocolInfo` is the load-bearing field:
        // names the transport (http-get) and the MIME type so Sonos
        // dispatches the right decoder. `audioBroadcast` upnp:class tells
        // Sonos it's a continuous stream, not a finite track.
        let inner = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="superaudio-live" parentID="-1" restricted="1">\
        <dc:title>SuperAudio</dc:title>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        <res protocolInfo="http-get:*:\(mime):*">\(streamURL)</res>\
        </item>\
        </DIDL-Lite>
        """
        // XML-escape so the SOAP envelope stays valid when this is
        // inlined inside <CurrentURIMetaData>.
        return inner
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
