// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore
import SuperAudioDiscovery

/// Discoverer for Sonos devices.
///
/// Sonos publishes a Bonjour service of type `_sonos._tcp` alongside its
/// UPnP/SSDP advertisement. The Bonjour record is sufficient for our v1:
/// the service instance name has the format `RINCON_<UDN>@<RoomName>`
/// (giving us both unique ID and user-visible label without an XML fetch),
/// and the TXT record carries `location=<descriptor URL>` for when we
/// need to issue SOAP control commands in Phase 3.
///
/// Using Bonjour for Sonos lets us reuse the same `NWBrowser` pattern as
/// `AirPlay1Discoverer` and avoids the macOS multicast entitlement that
/// raw SSDP would require.
///
/// The actual control surface (UPnP/SOAP envelopes for `SetAVTransportURI`,
/// `Play`, etc.) and the local HTTP audio server live in Phase 3 sub-tasks.
public final class SonosDiscoverer: SinkDiscoverer, @unchecked Sendable {
    public let protocolKind: ProtocolKind = .sonos

    public let sinks: AsyncStream<SinkChange>

    private let continuation: AsyncStream<SinkChange>.Continuation
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.sonos.discovery")
    private var browser: NWBrowser?
    private var knownByEndpoint: [NWEndpoint: SinkID] = [:]

    public init() {
        var continuation: AsyncStream<SinkChange>.Continuation!
        self.sinks = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard browser == nil else { return }
        Log.sonos.info("SonosDiscoverer.start — NWBrowser for _sonos._tcp")

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_sonos._tcp",
            domain: "local."
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { state in
            Log.sonos.info("NWBrowser state: \(String(describing: state), privacy: .public)")
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handle(results: results, changes: changes)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        Log.sonos.info("SonosDiscoverer.stop")
        browser?.cancel()
        browser = nil
        knownByEndpoint.removeAll()
        continuation.finish()
    }

    public func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink {
        Log.sonos.error("SonosDiscoverer.createSink not implemented yet — Phase 3 (SOAP control + HTTP audio server)")
        throw SonosError.notImplemented
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
        Log.sonos.info("Sonos added: \(descriptor.displayName, privacy: .public) UDN=\(descriptor.endpoint.metadata["udn"] ?? "?", privacy: .public)")
        continuation.yield(.added(descriptor))
    }

    private func handleRemoved(_ result: NWBrowser.Result) {
        guard let id = knownByEndpoint.removeValue(forKey: result.endpoint) else { return }
        Log.sonos.info("Sonos removed: \(id, privacy: .public)")
        continuation.yield(.removed(id))
    }

    private func handleChanged(old: NWBrowser.Result, new: NWBrowser.Result) {
        guard let descriptor = makeDescriptor(for: new) else {
            handleRemoved(old)
            return
        }
        knownByEndpoint[old.endpoint] = nil
        knownByEndpoint[new.endpoint] = descriptor.id
        Log.sonos.info("Sonos updated: \(descriptor.displayName, privacy: .public)")
        continuation.yield(.updated(descriptor))
    }

    private func makeDescriptor(for result: NWBrowser.Result) -> SinkDescriptor? {
        guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint else {
            return nil
        }

        // Sonos service names are `RINCON_<UDN>@<RoomName>`. Parse both out.
        let (udn, roomName): (String, String) = {
            if let atIndex = serviceName.firstIndex(of: "@") {
                let prefix = String(serviceName[..<atIndex])
                let suffix = String(serviceName[serviceName.index(after: atIndex)...])
                return (prefix, suffix)
            }
            return (serviceName, serviceName)
        }()

        var txt = parseTXT(from: result.metadata)
        txt["udn"] = udn
        txt["roomName"] = roomName

        let descriptorURL = txt["location"]
        let port = URL(string: descriptorURL ?? "")?.port ?? 1400
        let host = URL(string: descriptorURL ?? "")?.host ?? ""

        return SinkDescriptor(
            id: udn,
            displayName: roomName,
            protocolKind: .sonos,
            endpoint: SinkEndpoint(
                host: host,
                port: port,
                metadata: txt
            )
        )
    }

    private func parseTXT(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        return Dictionary(uniqueKeysWithValues: record.dictionary.map { ($0.key, $0.value) })
    }
}

public enum SonosError: Error, CustomStringConvertible {
    case notImplemented
    case soapError(String)
    case httpServerError(String)

    public var description: String {
        switch self {
        case .notImplemented:
            return "Sonos sender not implemented in this scaffold"
        case .soapError(let msg):
            return "Sonos SOAP error: \(msg)"
        case .httpServerError(let msg):
            return "Sonos local HTTP server error: \(msg)"
        }
    }
}
