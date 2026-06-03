// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

/// Identifies the wire protocol a sink speaks. New protocols added to this enum
/// also need a corresponding SPM module and `SinkDiscoverer` implementation.
public enum ProtocolKind: String, Sendable, CaseIterable, Hashable {
    case airplay1
    case sonos
    case airplay2
    case chromecast
    case bluetooth

    public var displayName: String {
        switch self {
        case .airplay1:   "AirPlay 1"
        case .sonos:      "Sonos"
        case .airplay2:   "AirPlay 2"
        case .chromecast: "Chromecast"
        case .bluetooth:  "Bluetooth"
        }
    }
}
