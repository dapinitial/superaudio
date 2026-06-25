// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore
import SuperAudioDiscovery

/// Discoverer for AirPlay 2 receivers on the local network (M12).
///
/// AirPlay 2 devices advertise `_airplay._tcp` (the control/RTSP plane) in
/// addition to `_raop._tcp` (the legacy audio sub-service that `AirPlay1Discoverer`
/// finds). We browse `_airplay._tcp` because its TXT record carries everything
/// the AP2 pairing + connection handshake needs — most importantly the device's
/// Ed25519 public key (`pk`) for pair-verify and the `features` bitfield that
/// says whether pairing/encryption is required.
///
/// **Same module shape as `AirPlay1Discoverer`** — pure Swift + `NWBrowser`,
/// depends only on Core + Discovery, no edits to Core or other protocol modules
/// (the extensibility-model test from CLAUDE.md). The `AudioSink` implementation
/// (pairing via vendored `pair_ap`, PTP/RTSP/RTP, Opus) lands in later M12
/// sub-tasks; this is the discovery scaffold that unblocks them.
///
/// **Self-filter:** the local Mac advertises `_airplay._tcp` too; we skip any
/// service whose name matches the host's localized name.
public final class AirPlay2Discoverer: SinkDiscoverer, @unchecked Sendable {
    public let protocolKind: ProtocolKind = .airplay2

    public let sinks: AsyncStream<SinkChange>

    private let continuation: AsyncStream<SinkChange>.Continuation
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.discovery")
    private var browser: NWBrowser?
    private var knownByEndpoint: [NWEndpoint: SinkID] = [:]

    public init() {
        var continuation: AsyncStream<SinkChange>.Continuation!
        self.sinks = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard browser == nil else { return }
        Log.airplay2.info("AirPlay2Discoverer.start — NWBrowser for _airplay._tcp")

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_airplay._tcp",
            domain: "local."
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = false   // LAN only

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { state in
            Log.airplay2.info("NWBrowser state: \(String(describing: state), privacy: .public)")
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handle(results: results, changes: changes)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        Log.airplay2.info("AirPlay2Discoverer.stop")
        browser?.cancel()
        browser = nil
        knownByEndpoint.removeAll()
        continuation.finish()
    }

    public func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink {
        Log.airplay2.error("AirPlay2Discoverer.createSink not implemented yet — M12 sub-task (pair-setup/verify + RTSP + PTP + RTP/Opus)")
        throw AirPlay2Error.notImplemented
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
        let m = descriptor.endpoint.metadata
        Log.airplay2.info("AP2 added: \(descriptor.displayName, privacy: .public) — model=\(m["model"] ?? "?", privacy: .public) features=\(m["features"] ?? m["ft"] ?? "?", privacy: .public) needsPairing=\(AirPlay2Features.requiresPairing(m) ? "yes" : "no", privacy: .public)")
        continuation.yield(.added(descriptor))
    }

    private func handleRemoved(_ result: NWBrowser.Result) {
        guard let id = knownByEndpoint.removeValue(forKey: result.endpoint) else { return }
        Log.airplay2.info("AP2 removed: \(id, privacy: .public)")
        continuation.yield(.removed(id))
    }

    private func handleChanged(old: NWBrowser.Result, new: NWBrowser.Result) {
        guard let descriptor = makeDescriptor(for: new) else {
            handleRemoved(old)
            return
        }
        knownByEndpoint[old.endpoint] = nil
        knownByEndpoint[new.endpoint] = descriptor.id
        Log.airplay2.info("AP2 updated: \(descriptor.displayName, privacy: .public)")
        continuation.yield(.updated(descriptor))
    }

    private func makeDescriptor(for result: NWBrowser.Result) -> SinkDescriptor? {
        guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint else {
            return nil
        }

        // `_airplay._tcp` instance names are the friendly device name directly
        // (e.g. "Living Room", "Apple TV") — no `MAC@` prefix like RAOP.
        let displayName = serviceName

        // Skip the local Mac's self-advertised AirPlay service.
        if isLocalService(displayName: displayName) {
            Log.airplay2.debug("Skipping local AirPlay service: \(serviceName, privacy: .public)")
            return nil
        }

        let txt = parseTXT(from: result.metadata)

        // Stable identity: prefer `deviceid` (the receiver's MAC, constant
        // across renames and reboots). Fall back to `pi` (public instance id),
        // then the service name. Prefix so it can't ever collide with an AP1
        // SinkID (those are the raw RAOP `{MAC}@{Name}` service string).
        let stableID = txt["deviceid"] ?? txt["pi"] ?? serviceName
        let id = "ap2:\(stableID)"

        return SinkDescriptor(
            id: id,
            displayName: displayName,
            protocolKind: .airplay2,
            endpoint: SinkEndpoint(
                host: "",                                       // resolved at connect time
                port: Int(txt["port"] ?? "7000") ?? 7000,       // AP2 control port (RTSP)
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

/// Helpers for reading the AirPlay 2 `features` bitfield out of a discovered
/// device's TXT record. The field is a 64-bit flag set, published either as a
/// single hex string (`features=0x...`) or, on some firmware, split into two
/// 32-bit halves (`features=0x<lo>,0x<hi>`). We only need a couple of bits at
/// the discovery stage; the full map gets exercised during the M12 handshake.
public enum AirPlay2Features {
    /// Parse the combined 64-bit features value, tolerating the single-value
    /// and comma-split (`lo,hi`) encodings. Returns nil if absent/unparseable.
    public static func value(_ txt: [String: String]) -> UInt64? {
        guard let raw = txt["features"] ?? txt["ft"] else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func hex(_ s: String) -> UInt64? {
            let clean = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
            return UInt64(clean, radix: 16)
        }
        switch parts.count {
        case 1: return hex(parts[0])
        case 2:
            guard let lo = hex(parts[0]), let hi = hex(parts[1]) else { return nil }
            return (hi << 32) | lo
        default: return nil
        }
    }

    /// Bit 27 (`SupportsUnifiedPairSetupAndMFi`) / bit 9 (`SupportsAirPlayAuthentication`)
    /// indicate the device wants the AP2 pairing dance before it will accept a
    /// stream. HomePods and modern Sonos require it; some AVRs accept transient
    /// pairing only. Heuristic for discovery-time labelling — the handshake is
    /// authoritative. If the bitfield is missing we assume pairing IS needed
    /// (the safe default for modern AP2 receivers).
    public static func requiresPairing(_ txt: [String: String]) -> Bool {
        guard let v = value(txt) else { return true }
        let supportsAuth        = (v & (1 << 9))  != 0
        let unifiedPairSetupMFi = (v & (1 << 27)) != 0
        return supportsAuth || unifiedPairSetupMFi
    }
}

public enum AirPlay2Error: Error, CustomStringConvertible {
    case notImplemented
    case pairingFailed(String)
    case rtspError(Int)

    public var description: String {
        switch self {
        case .notImplemented:
            return "AirPlay 2 sender not implemented in this scaffold"
        case .pairingFailed(let msg):
            return "AirPlay 2 pairing failed: \(msg)"
        case .rtspError(let code):
            return "AirPlay 2 RTSP error: \(code)"
        }
    }
}
