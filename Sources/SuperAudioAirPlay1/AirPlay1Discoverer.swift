// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore
import SuperAudioDiscovery

/// Discoverer for AirPlay 1 (RAOP) devices on the local network.
///
/// Uses `NWBrowser` for `_raop._tcp` Bonjour discovery. Emits `SinkChange`
/// events as devices appear, update their TXT records, or leave the LAN.
/// The actual `AudioSink` implementation (RTSP state machine, ALAC, RTP,
/// AES) is a separate Phase 1 sub-task that follows discovery.
///
/// **Self-filter:** macOS advertises its own RAOP service. We skip any
/// service whose display name matches the current host's localized name
/// so the local Mac doesn't appear as a target speaker.
public final class AirPlay1Discoverer: SinkDiscoverer, @unchecked Sendable {
    public let protocolKind: ProtocolKind = .airplay1

    public let sinks: AsyncStream<SinkChange>

    private let continuation: AsyncStream<SinkChange>.Continuation
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay1.discovery")
    private var browser: NWBrowser?
    private var knownByEndpoint: [NWEndpoint: SinkID] = [:]

    public init() {
        var continuation: AsyncStream<SinkChange>.Continuation!
        self.sinks = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard browser == nil else { return }
        Log.airplay1.info("AirPlay1Discoverer.start — NWBrowser for _raop._tcp")

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_raop._tcp",
            domain: "local."
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = false   // LAN only

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { state in
            Log.airplay1.info("NWBrowser state: \(String(describing: state), privacy: .public)")
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handle(results: results, changes: changes)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        Log.airplay1.info("AirPlay1Discoverer.stop")
        browser?.cancel()
        browser = nil
        knownByEndpoint.removeAll()
        continuation.finish()
    }

    public func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink {
        Log.airplay1.error("AirPlay1Discoverer.createSink not implemented yet — Phase 1 sub-task (RTSP + ALAC + RTP)")
        throw AirPlay1Error.notImplemented
    }

    // MARK: - Discovery handling

    private func handle(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleAdded(result)
            case .removed(let result):
                handleRemoved(result)
            case .changed(let old, let new, _):
                handleChanged(old: old, new: new)
            case .identical:
                continue
            @unknown default:
                continue
            }
        }
    }

    private func handleAdded(_ result: NWBrowser.Result) {
        guard let descriptor = makeDescriptor(for: result) else { return }
        knownByEndpoint[result.endpoint] = descriptor.id
        Log.airplay1.info("RAOP added: \(descriptor.displayName, privacy: .public) — am=\(descriptor.endpoint.metadata["am"] ?? "?", privacy: .public)")
        continuation.yield(.added(descriptor))
    }

    private func handleRemoved(_ result: NWBrowser.Result) {
        guard let id = knownByEndpoint.removeValue(forKey: result.endpoint) else { return }
        Log.airplay1.info("RAOP removed: \(id, privacy: .public)")
        continuation.yield(.removed(id))
    }

    private func handleChanged(old: NWBrowser.Result, new: NWBrowser.Result) {
        guard let descriptor = makeDescriptor(for: new) else {
            handleRemoved(old)
            return
        }
        knownByEndpoint[old.endpoint] = nil
        knownByEndpoint[new.endpoint] = descriptor.id
        Log.airplay1.info("RAOP updated: \(descriptor.displayName, privacy: .public)")
        continuation.yield(.updated(descriptor))
    }

    private func makeDescriptor(for result: NWBrowser.Result) -> SinkDescriptor? {
        guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint else {
            return nil
        }

        // RAOP service names are formatted "{MAC}@{DisplayName}".
        // Display name is the user-visible part.
        let displayName: String
        if let atIndex = serviceName.firstIndex(of: "@") {
            displayName = String(serviceName[serviceName.index(after: atIndex)...])
        } else {
            displayName = serviceName
        }

        // Skip the local Mac's self-advertised RAOP service.
        if isLocalService(displayName: displayName) {
            Log.airplay1.debug("Skipping local RAOP service: \(serviceName, privacy: .public)")
            return nil
        }

        let txt = parseTXT(from: result.metadata)

        return SinkDescriptor(
            id: serviceName,            // Full service name is the unique LAN identifier
            displayName: displayName,
            protocolKind: .airplay1,
            endpoint: SinkEndpoint(
                host: "",               // Resolved lazily by NWConnection at connect time
                port: Int(txt["port"] ?? "5000") ?? 5000,
                metadata: txt
            )
        )
    }

    private func parseTXT(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        return Dictionary(uniqueKeysWithValues: record.dictionary.map { ($0.key, $0.value) })
    }

    private func isLocalService(displayName: String) -> Bool {
        guard let localName = Host.current().localizedName else { return false }
        return displayName.caseInsensitiveCompare(localName) == .orderedSame
    }
}

public enum AirPlay1Error: Error, CustomStringConvertible {
    case notImplemented
    case handshakeFailed(String)
    case rtspError(Int32)

    public var description: String {
        switch self {
        case .notImplemented:
            return "AirPlay 1 sender not implemented in this scaffold"
        case .handshakeFailed(let msg):
            return "AirPlay 1 handshake failed: \(msg)"
        case .rtspError(let code):
            return "AirPlay 1 RTSP error: \(code)"
        }
    }
}
