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
        // M6.6 dev loop — headless Sonos group/ungroup triggers. Wait for
        // discovery + first topology poll, then act and log.
        if CommandLine.arguments.contains("--sonos-ungroup") || CommandLine.arguments.contains("--sonos-group") {
            let doGroup = CommandLine.arguments.contains("--sonos-group")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                await SonosTopology.shared.refreshNow()
                if doGroup { await SonosGrouping.groupAll() } else { await SonosGrouping.ungroupAll() }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await SonosTopology.shared.refreshNow()
            }
        }

        // M12 dev loop — headless AP2 pair-setup trigger.
        if let ap2Target = Self.ap2PairTarget() {
            Log.app.notice("AP2 pair target: '\(ap2Target, privacy: .public)' — waiting for discovery…")
            Task { @MainActor in
                guard let descriptor = await Self.awaitAP2Sink(named: ap2Target, timeout: 15) else {
                    Log.app.error("AP2 pair target '\(ap2Target, privacy: .public)' never appeared")
                    return
                }
                let pinProvider = Self.ap2PinProvider()
                Log.app.notice("AP2 pairing mode: \(pinProvider == nil ? "transient" : "PIN (HomeKit)", privacy: .public)")
                do {
                    let result = try await AP2PairSetup.run(descriptor: descriptor, pinProvider: pinProvider)
                    Log.app.notice("AP2 pair-setup ✓ \(descriptor.displayName, privacy: .public) — session key \(result.sessionKey.count)B")
                    if let pairing = result.pairing {
                        AP2PairingStore.save(pairing)
                        Log.app.notice("AP2 pairing persisted — running pair-verify to confirm PIN-free reconnect…")
                        let session = try await AP2PairVerify.run(descriptor: descriptor)
                        Log.app.notice("AP2 pair-verify ✓ \(descriptor.displayName, privacy: .public) — PIN-free session established (secret \(session.sharedSecret.count)B, control keys derived). Pairing layer COMPLETE.")
                    }
                } catch {
                    Log.app.error("AP2 pairing ✗ \(descriptor.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // M12 dev loop — pair-verify alone, against a previously stored pairing.
        if let verifyTarget = Self.ap2VerifyTarget() {
            Log.app.notice("AP2 verify target: '\(verifyTarget, privacy: .public)' — waiting for discovery…")
            Task { @MainActor in
                guard let descriptor = await Self.awaitAP2Sink(named: verifyTarget, timeout: 15) else {
                    Log.app.error("AP2 verify target '\(verifyTarget, privacy: .public)' never appeared")
                    return
                }
                do {
                    let session = try await AP2PairVerify.run(descriptor: descriptor)
                    Log.app.notice("AP2 pair-verify ✓ \(descriptor.displayName, privacy: .public) — secret \(session.sharedSecret.count)B, control keys derived")
                } catch {
                    Log.app.error("AP2 pair-verify ✗ \(descriptor.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

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

    /// `--ap2-pair=<displayName>` — M12 dev loop. Waits for an AirPlay 2 sink
    /// with that name, runs pair-setup, logs the result, and stays running.
    /// Lets the pairing handshake be driven headlessly (no menu click).
    private static func ap2PairTarget() -> String? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--ap2-pair=") {
                return String(arg.dropFirst("--ap2-pair=".count))
            }
        }
        return nil
    }

    /// `--ap2-verify=<displayName>` — pair-verify only, using the pairing
    /// stored by a previous PIN pair-setup. The PIN-free reconnect path.
    private static func ap2VerifyTarget() -> String? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--ap2-verify=") {
                return String(arg.dropFirst("--ap2-verify=".count))
            }
        }
        return nil
    }

    /// `--ap2-pin[=XXXX]` — companion to `--ap2-pair`. Switches pair-setup from
    /// transient to PIN (HomeKit) mode: `/pair-pin-start` puts a PIN on the
    /// receiver's screen. Bare `--ap2-pin` (or `=ask`) reads the PIN from the
    /// terminal — launch the binary directly, not via `open`, so stdin is a
    /// tty. `--ap2-pin=1234` supplies a fixed AirPlay password.
    private static func ap2PinProvider() -> (@Sendable () async -> String?)? {
        for arg in CommandLine.arguments {
            // `--ap2-pin-file=<path>`: poll a file for the PIN (up to 2 min).
            // Lets an orchestrator relay the on-screen PIN without a tty.
            if arg.hasPrefix("--ap2-pin-file=") {
                let path = String(arg.dropFirst("--ap2-pin-file=".count))
                return {
                    for _ in 0..<120 {
                        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                            let pin = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !pin.isEmpty { return pin }
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    return nil
                }
            }
            if arg == "--ap2-pin" || arg == "--ap2-pin=ask" {
                return {
                    print("Enter the PIN shown on the receiver's screen: ", terminator: "")
                    // readLine blocks — keep it off the main actor.
                    return await Task.detached {
                        readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.value
                }
            }
            if arg.hasPrefix("--ap2-pin=") {
                let pin = String(arg.dropFirst("--ap2-pin=".count))
                return { pin }
            }
        }
        return nil
    }

    @MainActor
    private static func awaitAP2Sink(named name: String, timeout: TimeInterval) async -> SinkDescriptor? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = DiscoveredSinks.shared.sinks.first(where: {
                $0.displayName == name && $0.protocolKind == .airplay2
            }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
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
