// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import AppKit
import SuperAudioCore
import SuperAudioAirPlay1
import SuperAudioAirPlay2
import SuperAudioSonos

/// SwiftUI's `@main App` handles UI lifecycle, but we still need an
/// `NSApplicationDelegate` for non-UI startup work (registering sink
/// discoverers, cleanup on terminate). Wired via `@NSApplicationDelegateAdaptor`
/// in `main.swift`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held to keep `DispatchSourceSignal` instances alive — GDC ARCs them
    /// the moment they go out of scope, which kills the handler.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("SuperAudio launching")
        registerUserDefaultsDefaults()
        installSignalHandlers()
        registerSinkDiscoverers()
        DiscoveredSinks.shared.startObserving()
        Task { @MainActor in AirPlay1Keepalive.shared.start() }
        // M6.6a — poll Sonos zone-group topology so the menu can hide
        // non-coordinator grouped members and feed only the coordinator.
        Task { @MainActor in SonosTopology.shared.start() }
        Log.app.info("SuperAudio ready")

        // `--auto-click=<displayName>` — launched with this arg, the app
        // waits up to 10s for a sink with that exact display name to
        // appear via discovery, then triggers `AirPlay1Session.run`
        // automatically. Lets external tooling (test scripts, CI, the
        // M3 debug loop) drive a full session without GUI interaction.
        if let target = Self.autoClickTarget() {
            Log.app.info("Auto-click target: '\(target, privacy: .public)' — waiting for discovery…")
            Task { @MainActor in
                let descriptor = await Self.awaitSink(named: target, timeout: 10)
                guard let descriptor else {
                    Log.app.error("Auto-click target '\(target, privacy: .public)' never appeared — giving up")
                    return
                }
                Log.app.info("Auto-click firing AirPlay1Session for \(descriptor.displayName, privacy: .public)")
                await AirPlay1Session.run(
                    descriptor: descriptor,
                    duration: TimeInterval(AirPlay1Session.autoClickDurationSeconds)
                )
                Log.app.info("Auto-click session complete — terminating")
                NSApp.terminate(nil)
            }
        }
    }

    private static func autoClickTarget() -> String? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--auto-click=") {
                return String(arg.dropFirst("--auto-click=".count))
            }
        }
        return nil
    }

    /// Polls `DiscoveredSinks.shared.sinks` once per 250 ms for up to
    /// `timeout` seconds. Returns the matching descriptor or `nil`.
    @MainActor
    private static func awaitSink(named name: String, timeout: TimeInterval) async -> SinkDescriptor? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = DiscoveredSinks.shared.sinks.first(where: { $0.displayName == name }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("SuperAudio terminating — graceful shutdown")

        // Stop the keepalive ping loop before tearing down sessions —
        // otherwise it might fire one more cycle as discoverers are
        // shutting down and produce noisy "speaker unreachable" errors.
        AirPlay1Keepalive.shared.stop()

        // Cancel all AP1 sessions (TEARDOWN fires async inside each
        // session's `defer`). Send Sonos `Stop` to every active sink.
        // Wait up to 2 seconds for these to land before we exit.
        SessionState.shared.stopAll()
        let group = DispatchGroup()
        group.enter()
        Task {
            await SessionState.shared.stopAllSonos()
            // Give AP1 TEARDOWN packets time to reach the speakers.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.5)

        SonosTopology.shared.stop()
        DiscoveredSinks.shared.stopObserving()
        for discoverer in SinkRegistry.shared.allDiscoverers() {
            discoverer.stop()
        }
        Log.app.info("SuperAudio terminated")
    }

    /// Installs `SIGTERM` and `SIGINT` handlers via `DispatchSourceSignal`.
    /// When fired, they call `NSApp.terminate(nil)` which routes through
    /// `applicationWillTerminate(_:)` and the graceful-shutdown path above.
    /// Without this, `killall SuperAudio` skips cleanup and leaves AirPlay
    /// 1 receivers holding their RTSP TCP port closed for 1–5 minutes.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            // Disable the default disposition so DispatchSource gets it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.app.info("Received signal \(sig) — initiating graceful terminate")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
        Log.app.info("Signal handlers installed (SIGTERM, SIGINT)")
    }

    /// Single point of truth for which protocols this build supports.
    /// Each protocol is its own SPM module and is gated by LicenseManager so
    /// the commercial track can sell them as $5 addons without code edits.
    /// Default values for first-launch UserDefaults keys. Registered before
    /// `SessionState.shared` is first accessed so its `var = bool(forKey:)`
    /// initializers see these as the baseline.
    ///
    /// **`muteMacWhilePlaying` defaults to TRUE** as of 2026-05-15 because
    /// the playing-on-Mac-and-also-on-AP1 path produces an audible ~93 ms
    /// echo between the local DAC and the AirPlay-buffered remote DAC. The
    /// toggle stays in the menu — users who *want* the Mac speaker as a
    /// fourth zone can flip it off.
    private func registerUserDefaultsDefaults() {
        UserDefaults.standard.register(defaults: [
            "muteMacWhilePlaying": true
        ])
    }

    private func registerSinkDiscoverers() {
        // Base app — always included.
        SinkRegistry.shared.register(AirPlay1Discoverer())
        SinkRegistry.shared.register(SonosDiscoverer())

        // M12 — AirPlay 2. Discovery scaffold is live; the sink (pairing +
        // PTP/RTSP/RTP/Opus) is still landing, so createSink throws for now.
        // Gated by LicenseManager exactly as the $5-addon model intends.
        if LicenseManager.isEnabled(.airplay2) {
            SinkRegistry.shared.register(AirPlay2Discoverer())
        }

        // Future addons — drop the modules in, uncomment, ship.
        // if LicenseManager.isEnabled(.chromecast) {
        //     SinkRegistry.shared.register(ChromecastDiscoverer())
        // }
        // if LicenseManager.isEnabled(.bluetooth) {
        //     SinkRegistry.shared.register(BluetoothDiscoverer())
        // }

        for discoverer in SinkRegistry.shared.allDiscoverers() {
            discoverer.start()
        }
    }
}
