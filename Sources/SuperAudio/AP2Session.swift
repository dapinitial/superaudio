// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore
import SuperAudioAirPlay2

/// Adapts `AP2AudioSession` (the full AirPlay 2 realtime path: pair-verify →
/// encrypted channel → SETUP → PTP → stream) to the supervisor's
/// `run() -> SessionExitReason` contract, so AirPlay 2 sinks work from the menu
/// exactly like AirPlay 1 and Sonos. Requires a stored pairing for the sink
/// (do the one-time `--ap2-pair` PIN pairing first); an unpaired device returns
/// `.failedBeforeAudio`.
enum AP2Session {
    static func run(descriptor: SinkDescriptor, duration: TimeInterval?) async -> SessionState.SessionExitReason {
        let session = AP2AudioSession(descriptor: descriptor)
        do {
            try await session.start()
        } catch {
            Log.app.error("AP2Session[\(descriptor.displayName, privacy: .public)] start failed: \(String(describing: error), privacy: .public)")
            session.stop()
            return .failedBeforeAudio
        }
        Log.app.notice("AP2Session[\(descriptor.displayName, privacy: .public)] streaming — awaiting cancel")

        // start() reached the streaming stage; hold until the supervisor
        // cancels this task (user toggles off / stopAll), then tear down.
        do {
            if let duration {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            } else {
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 500_000_000) }
            }
        } catch {
            // cancelled — fall through to teardown
        }
        session.stop()
        return .cleanExit
    }
}
