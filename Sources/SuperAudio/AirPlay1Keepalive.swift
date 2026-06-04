// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore
import SuperAudioAirPlay1

/// Periodic OPTIONS pings to every discovered AirPlay 1 sink, intended
/// to keep receivers awake so the first user-driven session doesn't hit
/// the cold-start RTSP-timeout failure mode documented in
/// `memory/project_a7_rtsp_timeout.md`.
///
/// Cycle: every `interval` seconds (default 240 s = 4 min, well under
/// the typical AP1 receiver idle-to-sleep timeout of ~5 min), iterate
/// every AP1 sink in `DiscoveredSinks.shared.sinks`, skip any sink
/// already in an active session (those are streaming audio constantly
/// and don't need our help), and send `connect → OPTIONS → disconnect`
/// for the rest. Each ping is a single TCP round-trip — trivial network
/// load (3 sinks × every 4 min = ~0.05 KB/s steady state).
///
/// Layered alongside the 2-attempt RTSP retry in `AirPlay1Session.run`:
/// retry is the safety net for when speakers go cold despite this; the
/// keepalive is the prevention. Together they make Play All "just work"
/// in the median case.
@MainActor
final class AirPlay1Keepalive {

    static let shared = AirPlay1Keepalive()

    /// Slightly under the typical AP1 receiver idle-to-sleep timeout
    /// (~5 min). 4 min keeps comfortable headroom.
    private static let interval: TimeInterval = 240

    /// Grace period at app launch — wait this long after start before
    /// the first ping cycle so discovery has time to populate
    /// `DiscoveredSinks.shared.sinks`.
    private static let startupGrace: TimeInterval = 5

    private var task: Task<Void, Never>?

    private init() {}

    /// Start the keepalive loop. Idempotent — calling again while
    /// already running is a no-op.
    func start() {
        guard task == nil else { return }
        Log.airplay1.notice("AirPlay1Keepalive: starting (interval=\(Int(Self.interval))s, grace=\(Int(Self.startupGrace))s)")
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startupGrace * 1_000_000_000))
            while !Task.isCancelled {
                await self?.pingAllAP1Sinks()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    /// Stop the keepalive loop. Called on app teardown via `AppDelegate`.
    func stop() {
        task?.cancel()
        task = nil
        Log.airplay1.notice("AirPlay1Keepalive: stopped")
    }

    /// Single ping cycle. Skips sinks currently in an active session
    /// (they don't need warming up — audio is already flowing).
    private func pingAllAP1Sinks() async {
        let candidates = DiscoveredSinks.shared.sinks.filter { $0.protocolKind == .airplay1 }
        let active = SessionState.shared.activeSinks

        let toPing = candidates.filter { !active.contains($0.id) }
        guard !toPing.isEmpty else {
            Log.airplay1.info("AirPlay1Keepalive: skipping cycle — \(candidates.count) AP1 sink(s) all in active sessions or no AP1 sinks discovered")
            return
        }
        Log.airplay1.notice("AirPlay1Keepalive: pinging \(toPing.count) idle AP1 sink(s)")

        // Pings run in parallel — each is ~50–200 ms; doing them
        // sequentially would block the loop for multiple seconds when
        // the household has several AP1 speakers.
        await withTaskGroup(of: Void.self) { group in
            for descriptor in toPing {
                group.addTask {
                    await Self.pingOne(descriptor: descriptor)
                }
            }
        }
    }

    /// Connect → OPTIONS → disconnect. Errors are logged but never
    /// propagate — a failed keepalive ping is information, not a problem
    /// (the speaker may be powered off; user click will surface that via
    /// the retry + failure UI).
    private static func pingOne(descriptor: SinkDescriptor) async {
        let label = descriptor.displayName
        let client = RTSPClient(descriptor: descriptor, useEncryption: false)
        do {
            try await client.connect()
            let response = try await client.sendOptions()
            if response.isOK {
                Log.airplay1.info("AirPlay1Keepalive ✓ \(label, privacy: .public) → \(response.statusLine, privacy: .public)")
            } else {
                Log.airplay1.info("AirPlay1Keepalive ✗ \(label, privacy: .public) → \(response.statusLine, privacy: .public)")
            }
        } catch {
            Log.airplay1.info("AirPlay1Keepalive ✗ \(label, privacy: .public) → \(String(describing: error), privacy: .public)")
        }
        client.disconnect()
    }
}
