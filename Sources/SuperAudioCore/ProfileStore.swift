// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CoreServices

/// M5.5 — runtime resolution layer over `DeviceProfileLoader`.
///
/// `DeviceProfileLoader` knows how to *load* and *match* profiles; `ProfileStore`
/// is the app-wide singleton that loads them and answers the question the
/// protocol modules actually ask: "given this discovered sink, what's its
/// device profile (if any)?" Results are memoized per `SinkID`.
///
/// This is the seam that lets protocol modules read device specifics (volume
/// scale, codec params, latency, quirks) from JSON instead of compile-time
/// constants. When no profile matches, callers fall back to their built-in
/// defaults — so an unknown speaker still works, it just doesn't get
/// profile-tuned behavior.
///
/// **Live reload (M6.5).** The store watches the user-overlay directory with
/// FSEvents. When a profile is added/edited/removed there — e.g. the
/// `onboard-audio-device` Skill installs a freshly drafted profile — the store
/// reloads and drops its per-SinkID cache, so the next match sees the new
/// profile *without an app restart*. Sinks already connected keep the behavior
/// they read at connect time; the new profile takes effect on the next lookup.
public final class ProfileStore: @unchecked Sendable {
    public static let shared = ProfileStore()

    private var _profiles: [DeviceProfile]
    private var _loadErrors: [(path: String, error: Error)]
    private var cache: [SinkID: DeviceProfile?] = [:]
    private let lock = NSLock()

    private var watcher: FSEventStreamRef?
    private let watchQueue = DispatchQueue(label: "com.davidpuerto.SuperAudio.profileWatch")

    /// Currently loaded profiles (bundle + user overlay, overlay winning).
    /// Snapshot under the lock — the set can change on overlay edits.
    public var profiles: [DeviceProfile] {
        lock.lock(); defer { lock.unlock() }
        return _profiles
    }

    /// Per-file load errors from the most recent (re)load.
    public var loadErrors: [(path: String, error: Error)] {
        lock.lock(); defer { lock.unlock() }
        return _loadErrors
    }

    private init() {
        let (profiles, errors) = DeviceProfileLoader.loadAll()
        self._profiles = profiles
        self._loadErrors = errors
        startWatchingOverlay()
    }

    /// The device profile for a discovered sink, or nil to use built-in
    /// defaults. Memoized per SinkID (matching is pure given the inputs);
    /// the memo is cleared whenever the overlay reloads.
    public func profile(for descriptor: SinkDescriptor) -> DeviceProfile? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[descriptor.id] { return cached }
        let match = DeviceProfileLoader.matchProfile(
            bonjourServiceType: Self.bonjourServiceType(for: descriptor.protocolKind),
            modelHintText: Self.modelHintText(for: descriptor),
            macOUI: nil,                       // RAOP names carry a MAC but not as a clean OUI; our profiles don't gate on it
            among: _profiles
        )
        cache[descriptor.id] = match
        if let match {
            Log.core.info("ProfileStore: matched '\(match.id, privacy: .public)' for sink '\(descriptor.displayName, privacy: .public)'")
        } else {
            Log.core.info("ProfileStore: no profile for sink '\(descriptor.displayName, privacy: .public)' — built-in defaults")
        }
        return match
    }

    // MARK: - Live reload

    /// Re-scan bundle + overlay and drop the match cache. File I/O happens
    /// outside the lock; only the swap + cache-clear is guarded.
    private func reload() {
        let (profiles, errors) = DeviceProfileLoader.loadAll()
        lock.lock()
        _profiles = profiles
        _loadErrors = errors
        cache.removeAll()                      // force every sink to re-match against the new set
        lock.unlock()
        Log.core.notice("ProfileStore: reloaded \(profiles.count, privacy: .public) profile(s) after overlay change — match cache cleared")
    }

    /// Watch the user-overlay directory for profile file changes and reload.
    /// `kFSEventStreamCreateFlagFileEvents` reports both directory-entry changes
    /// (a new profile copied in) and in-place content edits (re-installing the
    /// same id), so both the Skill's fresh-install and hand-edit flows fire.
    private func startWatchingOverlay() {
        let dir = DeviceProfileLoader.userProfileDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),   // singleton — lives forever, unretained is safe
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ProfileStore>.fromOpaque(info).takeUnretainedValue().reload()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [dir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,                                // coalesce the burst of events a single `cp` produces
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            Log.core.error("ProfileStore: could not create FSEventStream — overlay live-reload disabled")
            return
        }
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
        self.watcher = stream
        Log.core.info("ProfileStore: watching overlay for live profile reload: \(dir.path, privacy: .public)")
    }

    /// The sink-role of the matched profile (nil if no match or no sink role).
    public func sinkRole(for descriptor: SinkDescriptor) -> DeviceProfile.SinkRole? {
        profile(for: descriptor)?.roles.sink
    }

    /// The text `match.modelHints` substring-matches against. The schema
    /// documents hints as matching "the device's mDNS TXT record or HTTP
    /// description" — but the user-visible `displayName` (for RAOP, the part
    /// after the `@` in `{MAC}@{Name}`) is whatever the *owner* named the
    /// speaker, not the model. Matching on that alone makes community profiles
    /// non-portable: a "B&W A5" profile would only resolve on a downstream user
    /// who happened to name their speaker "B&W…". So we also fold in the
    /// model-bearing TXT keys — chiefly `am` (the AirPlay model identifier),
    /// which is stable across owners — letting profiles key on the model.
    ///
    /// Only an allowlist of model-bearing keys is included; dumping the whole
    /// TXT record would invite spurious substring hits on flag fields
    /// (`et`, `cn`, `sf`, …). Cross-protocol bleed is already prevented upstream
    /// by the `bonjourServiceType` filter in `matchProfile`.
    private static let modelHintTXTKeys = ["am", "model"]

    static func modelHintText(for descriptor: SinkDescriptor) -> String {
        var parts = [descriptor.displayName]
        for key in modelHintTXTKeys {
            if let value = descriptor.endpoint.metadata[key], !value.isEmpty {
                parts.append(value)
            }
        }
        return parts.joined(separator: " ")
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
