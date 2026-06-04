// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore
import SuperAudioSonos

/// One-click auto-alignment using Sonos's UPnP playback telemetry.
///
/// **The trick (#104)**: Sonos exposes `AVTransport::GetPositionInfo`
/// which returns the playback position within the current stream.
/// For our `x-rincon-mp3radio://` URIs, that's the number of seconds
/// the Sonos has been actively playing audio (ticks up from 0 after
/// `Play`). Combined with the wall time we recorded when SOAP `Play`
/// was issued (`SessionState.sonosPlayStartedAt`), we can compute
/// Sonos's actual playback lag:
///
///     sonos_lag = (now - play_wall_time) - relTime_seconds
///
/// That's the slowest-sink lag in the wanted set. AP1 receivers have a
/// near-instant buffer (negotiated `Audio-Latency: 4096` ≈ 93 ms).
/// To align AP1 with Sonos, set each AP1 sink's broadcaster delay to
/// `sonos_lag - 93 ms`. The broadcaster's queue retiming (#99) carries
/// it the rest of the way.
///
/// No microphone, no permission flow, no test tone. The data we need is
/// already exchanged with Sonos as part of normal UPnP control.
///
/// Limitations:
/// - Only works when a Sonos sink is in the wanted set. Pure-AP1
///   sessions don't have a slow-sink reference.
/// - Assumes AP1 receiver lag = `audioLatencyDefaultMs`. Real AP1
///   receivers vary slightly (B&W A5/A7 confirmed 93 ms via negotiated
///   `Audio-Latency`); the mic-based Path A (#98) is the eventual
///   refinement.
/// - The 200 ms baseline pre-roll that RTPSender adds to sync NTP is
///   already accounted for in measured playback timing.
@MainActor
enum CalibrationCoordinator {

    /// AP1 receiver buffer in milliseconds. Matches the `Audio-Latency: 4096`
    /// value negotiated in RECORD response (4096 samples / 44100 Hz ≈ 93 ms).
    /// Used as the assumed offset of AP1 playback from RTP packet arrival.
    private static let audioLatencyDefaultMs: Double = 93

    /// Empirical correction for Sonos's reported `RelTime` vs actual audible
    /// playback. Reads from `SessionState.personalSonosHeadroomMs` (default
    /// 500ms, persisted per-install via UserDefaults). #105 Calibrate Sync
    /// verification step nudges this up/down based on user feedback so each
    /// environment self-tunes over time.
    private static var sonosRenderingHeadroomMs: Double {
        Double(SessionState.shared.personalSonosHeadroomMs)
    }

    /// Result of one calibration pass.
    struct Result {
        let sonosSinkID: SinkID
        let sonosSinkLabel: String
        /// Measured: wall-clock time between SOAP Play and "now."
        let elapsedSincePlaySec: Double
        /// Reported by `GetPositionInfo.RelTime` — Sonos's playback position.
        let sonosReportedPositionSec: Double
        /// Computed: `elapsedSincePlay - reportedPosition`. The true Sonos lag.
        let sonosLagSec: Double
        /// Applied per AP1 sink — `(sonosLagSec - 93ms)` clamped to slider range.
        let appliedAP1OffsetMs: Int
        /// Number of AP1 sinks that received the new offset.
        let ap1SinksUpdated: Int
    }

    /// Read Sonos's current playback position via UPnP, compute its lag,
    /// and apply matching offsets to every active AP1 sink.
    ///
    /// Returns the result for logging / UI display. Throws if no Sonos
    /// sink is active, the SOAP query fails, or the play-start snapshot
    /// is missing (race with a just-started session).
    static func runSonosPositionAutoAlign() async throws -> Result {
        let snapshot = currentSonosSnapshot()
        guard let (sinkID, descriptor, playStartedAt) = snapshot else {
            throw CalibrationError.noSonosActive
        }

        Log.app.notice("Auto-align: querying Sonos position for \(descriptor.displayName, privacy: .public)…")
        let client = SonosClient(descriptor: descriptor)
        let positionInfo: SonosClient.PositionInfo
        do {
            positionInfo = try await client.getPositionInfo()
        } catch {
            throw CalibrationError.sonosQueryFailed(String(describing: error))
        }

        let now = Date()
        let elapsedSincePlay = now.timeIntervalSince(playStartedAt)
        let sonosLag = elapsedSincePlay - positionInfo.relTimeSeconds

        guard sonosLag > 0 else {
            // Defensive — Sonos position can't be ahead of wall elapsed.
            // If we see this, the playStart snapshot is broken or the
            // SOAP response is mangled. Don't apply garbage offsets.
            throw CalibrationError.implausibleLag(sonosLag)
        }

        // Compute AP1 target offset. We want AP1 playback to land at the
        // same wall moment as Sonos. AP1 plays at `now + audioLatency` after
        // RTP packet arrival; with sender-side broadcaster delay, total AP1
        // playback lag from capture = broadcaster_delay + audioLatency.
        // Set broadcaster_delay = sonos_lag - audioLatency to converge.
        let targetOffsetMs = max(0, Int(((sonosLag * 1000) - Self.audioLatencyDefaultMs - Self.sonosRenderingHeadroomMs).rounded()))

        // Snapshot active AP1 descriptors (need full descriptors to
        // restart sessions, not just IDs).
        let ap1Descriptors = DiscoveredSinks.shared.sinks.filter { desc in
            desc.protocolKind == .airplay1 && SessionState.shared.activeSinks.contains(desc.id)
        }

        // Persist the new offset to UserDefaults before restart so the
        // fresh AP1 sessions pick it up on subscribe.
        for desc in ap1Descriptors {
            SessionState.shared.setOffset(targetOffsetMs, for: desc.id)
        }

        // **Critical**: don't try to apply the new delay mid-stream. AP1
        // receivers interpret the resulting RTP-timestamp jump as a
        // sequence gap and flood us with PT 0xD5 retransmit requests
        // (gotcha #5 — we don't implement retransmission, so they stay
        // stuck demanding the "missing" 189k samples forever). Diagnosed
        // 2026-05-18 from logs showing audio dead for minutes despite
        // healthy session + flowing RTP packets.
        //
        // Instead: stop each AP1 session, brief wait, restart. New RTSP
        // RECORD = clean RTP timeline at the receiver. Sonos is left
        // alone — it's already playing in steady state, no reason to
        // disturb it.
        if !ap1Descriptors.isEmpty {
            Log.app.notice("Auto-align: restarting \(ap1Descriptors.count) AP1 sink(s) to apply offset cleanly")
            for desc in ap1Descriptors {
                SessionState.shared.toggle(desc)  // OFF
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for desc in ap1Descriptors {
                SessionState.shared.toggle(desc)  // ON
            }
        }

        let result = Result(
            sonosSinkID: sinkID,
            sonosSinkLabel: descriptor.displayName,
            elapsedSincePlaySec: elapsedSincePlay,
            sonosReportedPositionSec: positionInfo.relTimeSeconds,
            sonosLagSec: sonosLag,
            appliedAP1OffsetMs: targetOffsetMs,
            ap1SinksUpdated: ap1Descriptors.count
        )

        Log.app.notice("Auto-align ✓ Sonos lag = \(String(format: "%.3f", sonosLag), privacy: .public)s → AP1 offset \(targetOffsetMs)ms applied to \(ap1Descriptors.count) sink(s) (elapsed \(String(format: "%.3f", elapsedSincePlay), privacy: .public)s − relTime \(String(format: "%.3f", positionInfo.relTimeSeconds), privacy: .public)s − \(Int(Self.audioLatencyDefaultMs))ms AP1 buffer − \(Int(Self.sonosRenderingHeadroomMs))ms Sonos headroom)")
        return result
    }

    // MARK: - Helpers

    private static func currentSonosSnapshot() -> (SinkID, SinkDescriptor, Date)? {
        for (id, desc) in SessionState.shared.activeSonosDescriptors {
            if let started = SessionState.shared.sonosPlayStartedAt[id] {
                return (id, desc, started)
            }
        }
        return nil
    }

    enum CalibrationError: Error, CustomStringConvertible {
        case noSonosActive
        case sonosQueryFailed(String)
        case implausibleLag(Double)

        var description: String {
            switch self {
            case .noSonosActive:           return "No Sonos sink active — auto-align requires a Sonos in the wanted set"
            case .sonosQueryFailed(let m): return "Sonos GetPositionInfo failed: \(m)"
            case .implausibleLag(let v):   return "Implausible Sonos lag: \(v) sec (must be > 0)"
            }
        }
    }
}
