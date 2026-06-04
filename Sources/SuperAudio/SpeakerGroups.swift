// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore

/// Saved named sets of sinks the user activates with one click. Solves
/// the daily-use friction of dragging multiple toggles every night —
/// instead, save "Whole house" (A5 + A7 + Den), "Living room" (A7),
/// "Bedroom" (A7 only), and re-activate from the menu with a single tap.
///
/// Persisted as a JSON-encoded `[Group]` in `UserDefaults` under
/// `speakerGroups.v1`. The `.v1` suffix is forward-compatible — when the
/// schema changes (e.g., adding stored per-sink volume per group), bump
/// to `.v2` with a migration path.
@MainActor
@Observable
final class SpeakerGroups {

    static let shared = SpeakerGroups()

    /// A saved speaker group. `sinkIDs` is ordered for predictable
    /// startup — AirPlay 1 sinks usually want to start before Sonos to
    /// reach RTSP RECORD before Sonos's HTTP pull kicks in.
    struct Group: Identifiable, Codable, Hashable {
        let id: UUID
        var name: String
        var sinkIDs: [SinkID]
        var createdAt: Date

        init(id: UUID = UUID(), name: String, sinkIDs: [SinkID], createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.sinkIDs = sinkIDs
            self.createdAt = createdAt
        }
    }

    private(set) var groups: [Group] = []

    private let userDefaultsKey = "speakerGroups.v1"

    private init() {
        load()
    }

    /// Save a new group from the currently-listed sink IDs. Auto-trims
    /// the name; ignores empty names.
    func save(name: String, sinkIDs: [SinkID]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sinkIDs.isEmpty else { return }
        let group = Group(name: trimmed, sinkIDs: sinkIDs)
        groups.append(group)
        groups.sort(by: { $0.createdAt < $1.createdAt })
        persist()
        Log.app.notice("SpeakerGroups: saved '\(trimmed, privacy: .public)' with \(sinkIDs.count) sink(s)")
    }

    /// Delete by ID.
    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
        Log.app.notice("SpeakerGroups: deleted \(id)")
    }

    /// Resolve a group's stored sink IDs against the currently-discovered
    /// sinks and start every sink that's currently online. Sinks in the
    /// group but not currently discovered (e.g., a speaker that's powered
    /// off) are silently skipped — the user gets the partial group rather
    /// than no group at all.
    func play(_ group: Group, discoveredSinks: [SinkDescriptor]) {
        let descriptorsByID = Dictionary(uniqueKeysWithValues: discoveredSinks.map { ($0.id, $0) })
        let resolved = group.sinkIDs.compactMap { descriptorsByID[$0] }
        let missing = group.sinkIDs.count - resolved.count
        if missing > 0 {
            Log.app.notice("SpeakerGroups: playing '\(group.name, privacy: .public)' — \(resolved.count) of \(group.sinkIDs.count) sink(s) online, \(missing) offline / not discovered")
        } else {
            Log.app.notice("SpeakerGroups: playing '\(group.name, privacy: .public)' — \(resolved.count) sink(s)")
        }
        SessionState.shared.startAll(resolved)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([Group].self, from: data)
            self.groups = decoded
            Log.app.info("SpeakerGroups: loaded \(decoded.count) group(s) from UserDefaults")
        } catch {
            Log.app.error("SpeakerGroups: failed to decode (\(String(describing: error), privacy: .public)) — starting fresh")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(groups)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            Log.app.error("SpeakerGroups: persist failed — \(String(describing: error), privacy: .public)")
        }
    }
}
