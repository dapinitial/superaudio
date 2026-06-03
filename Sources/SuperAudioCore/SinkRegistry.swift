// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation

/// Central, app-wide registry of protocol discoverers. The menu bar app
/// asks the registry for all known discoverers when building its device list,
/// and routes `createSink(for:)` to the right one based on `ProtocolKind`.
///
/// The registry is intentionally minimal — it owns no audio state, just the
/// mapping from `ProtocolKind` to the discoverer that handles it.
public final class SinkRegistry: @unchecked Sendable {
    public static let shared = SinkRegistry()

    private let lock = NSLock()
    private var byProtocol: [ProtocolKind: SinkDiscoverer] = [:]

    private init() {}

    public func register(_ discoverer: SinkDiscoverer) {
        lock.lock()
        defer { lock.unlock() }
        byProtocol[discoverer.protocolKind] = discoverer
        Log.core.info("Registered \(discoverer.protocolKind.rawValue, privacy: .public) discoverer")
    }

    public func allDiscoverers() -> [SinkDiscoverer] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byProtocol.values)
    }

    public func discoverer(for protocolKind: ProtocolKind) -> SinkDiscoverer? {
        lock.lock()
        defer { lock.unlock() }
        return byProtocol[protocolKind]
    }

    public func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink {
        guard let discoverer = discoverer(for: descriptor.protocolKind) else {
            throw SinkRegistryError.noDiscovererRegistered(descriptor.protocolKind)
        }
        return try await discoverer.createSink(for: descriptor)
    }
}

public enum SinkRegistryError: Error, CustomStringConvertible {
    case noDiscovererRegistered(ProtocolKind)

    public var description: String {
        switch self {
        case .noDiscovererRegistered(let kind):
            return "No discoverer registered for protocol \(kind.rawValue) — addon not licensed or module not linked"
        }
    }
}
