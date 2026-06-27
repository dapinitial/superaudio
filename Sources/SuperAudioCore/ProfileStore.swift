// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation

/// M5.5 — runtime resolution layer over `DeviceProfileLoader`.
///
/// `DeviceProfileLoader` knows how to *load* and *match* profiles; `ProfileStore`
/// is the app-wide singleton that loads them once and answers the question the
/// protocol modules actually ask: "given this discovered sink, what's its
/// device profile (if any)?" Results are memoized per `SinkID`.
///
/// This is the seam that lets protocol modules read device specifics (volume
/// scale, codec params, latency, quirks) from JSON instead of compile-time
/// constants. When no profile matches, callers fall back to their built-in
/// defaults — so an unknown speaker still works, it just doesn't get
/// profile-tuned behavior.
public final class ProfileStore: @unchecked Sendable {
    public static let shared = ProfileStore()

    public let profiles: [DeviceProfile]
    public let loadErrors: [(path: String, error: Error)]

    private var cache: [SinkID: DeviceProfile?] = [:]
    private let lock = NSLock()

    private init() {
        let (profiles, errors) = DeviceProfileLoader.loadAll()
        self.profiles = profiles
        self.loadErrors = errors
    }

    /// The device profile for a discovered sink, or nil to use built-in
    /// defaults. Memoized per SinkID (matching is pure given the inputs).
    public func profile(for descriptor: SinkDescriptor) -> DeviceProfile? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[descriptor.id] { return cached }
        let match = DeviceProfileLoader.matchProfile(
            bonjourServiceType: Self.bonjourServiceType(for: descriptor.protocolKind),
            modelHintText: descriptor.displayName,
            macOUI: nil,                       // RAOP names carry a MAC but not as a clean OUI; our profiles don't gate on it
            among: profiles
        )
        cache[descriptor.id] = match
        if let match {
            Log.core.info("ProfileStore: matched '\(match.id, privacy: .public)' for sink '\(descriptor.displayName, privacy: .public)'")
        } else {
            Log.core.info("ProfileStore: no profile for sink '\(descriptor.displayName, privacy: .public)' — built-in defaults")
        }
        return match
    }

    /// The sink-role of the matched profile (nil if no match or no sink role).
    public func sinkRole(for descriptor: SinkDescriptor) -> DeviceProfile.SinkRole? {
        profile(for: descriptor)?.roles.sink
    }

    /// Bonjour service type for a protocol kind — the `match.bonjourServiceType`
    /// key profiles are filtered on.
    public static func bonjourServiceType(for kind: ProtocolKind) -> String? {
        switch kind {
        case .airplay1: return "_raop._tcp"
        case .airplay2: return "_airplay._tcp"
        case .sonos:    return "_sonos._tcp"
        case .chromecast: return "_googlecast._tcp"
        case .bluetooth:  return nil
        }
    }
}
