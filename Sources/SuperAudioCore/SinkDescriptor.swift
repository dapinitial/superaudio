// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation

/// Stable identifier for a discovered sink. Format is implementation-defined
/// per protocol (e.g., RAOP service name + MAC, Sonos household + room UUID).
public typealias SinkID = String

/// Lightweight description of a sink the user can choose to connect to.
/// Discovery emits these as devices appear / change; the app uses them to
/// build the menu bar device list.
public struct SinkDescriptor: Identifiable, Hashable, Sendable {
    public let id: SinkID
    public let displayName: String
    public let protocolKind: ProtocolKind
    public let endpoint: SinkEndpoint

    public init(
        id: SinkID,
        displayName: String,
        protocolKind: ProtocolKind,
        endpoint: SinkEndpoint
    ) {
        self.id = id
        self.displayName = displayName
        self.protocolKind = protocolKind
        self.endpoint = endpoint
    }
}

/// Network-level reach info plus a per-protocol opaque metadata bag.
/// Avoids leaking protocol details into Core.
public struct SinkEndpoint: Hashable, Sendable {
    public let host: String
    public let port: Int
    public let metadata: [String: String]

    public init(host: String, port: Int, metadata: [String: String] = [:]) {
        self.host = host
        self.port = port
        self.metadata = metadata
    }
}
