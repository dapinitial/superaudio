// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore
import SuperAudioSonos

/// M6.6a — Sonos zone-group awareness.
///
/// Sonos speakers grouped in the Sonos app are sample-locked over SonosNet by
/// a single **coordinator**; the other members render the coordinator's relay,
/// not an external stream. SuperAudio used to see two `_sonos._tcp` renderers
/// and stream to BOTH independently, pushing a second competing stream into a
/// group that's already internally synced → the two fight and drift. (Root
/// cause confirmed 2026-06-16 from a live soak: "even the grouped Sonos went
/// out of sync." See gotcha #24.)
///
/// This poller queries `ZoneGroupTopology` (household-global — any one online
/// Sonos returns the whole layout) and exposes which discovered Sonos sinks
/// are non-coordinator members of a multi-speaker group. The menu hides those
/// and feeds only the coordinator; SonosNet relays to the rest. The result:
/// a grouped pair shows as a single device and stays in sync, with no manual
/// "deselect the duplicate" step.
///
/// **Fail-open contract:** when topology is unknown (no Sonos discovered yet,
/// or every poll failed), `groups` is empty and the query helpers hide
/// nothing — the app falls back to its prior show-everything behaviour rather
/// than risk hiding a speaker the user wants.
@MainActor
@Observable
final class SonosTopology {
    static let shared = SonosTopology()

    /// Latest known groups. Empty means "topology unknown" — NOT "no groups".
    private(set) var groups: [SonosClient.ZoneGroup] = []
    private(set) var lastUpdated: Date?

    /// Poll cadence. Group membership changes rarely (user regroups in the
    /// Sonos app), so a slow poll is plenty; it also refreshes on demand when
    /// the discovered-sink set changes.
    private let pollIntervalSeconds: UInt64 = 10

    private var pollTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        Log.app.info("SonosTopology: starting ZoneGroupTopology poller (\(self.pollIntervalSeconds)s)")
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(nanoseconds: (self?.pollIntervalSeconds ?? 10) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Poll any one online Sonos for the household topology. Picks the first
    /// discovered Sonos with a non-empty host; on success replaces `groups`.
    /// On failure leaves the prior snapshot intact (a transient SOAP timeout
    /// shouldn't briefly un-hide a member and flicker the menu).
    func refreshNow() async {
        let sonos = DiscoveredSinks.shared.sinks.first {
            $0.protocolKind == .sonos && !$0.endpoint.host.isEmpty
        }
        guard let sonos else { return }

        do {
            let fresh = try await SonosClient(descriptor: sonos).getZoneGroupState()
            let changed = fresh != groups
            groups = fresh
            lastUpdated = Date()
            if changed {
                let summary = fresh
                    .filter(\.isMultiMember)
                    .map { "\($0.members.count)×[\($0.members.map(\.zoneName).joined(separator: "+"))]" }
                    .joined(separator: " ")
                Log.app.notice("SonosTopology updated: \(fresh.count) group(s)\(summary.isEmpty ? "" : " — grouped: \(summary)", privacy: .public)")
            }
        } catch {
            Log.app.info("SonosTopology poll failed (keeping prior \(self.groups.count)-group snapshot): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Query helpers (fail-open: empty topology hides nothing)

    /// SinkIDs of the Sonos sinks that are non-coordinator members of a
    /// multi-speaker group, among the given discovered Sonos sinks. These are
    /// the rows to hide and exclude from Play All — we feed only the
    /// coordinator.
    func hiddenMemberIDs(among sonos: [SinkDescriptor]) -> Set<SinkID> {
        guard !groups.isEmpty else { return [] }
        var hidden: Set<SinkID> = []
        for group in groups where group.isMultiMember {
            for member in group.members where member.uuid != group.coordinatorUUID {
                if let sink = match(member, in: sonos) {
                    hidden.insert(sink.id)
                }
            }
        }
        return hidden
    }

    /// The room names of the OTHER members grouped with this sink's group,
    /// when this sink is the coordinator of a multi-speaker group. Used to
    /// annotate the coordinator's menu row ("+ Den 2"). Empty otherwise.
    func groupedMemberNames(forCoordinator descriptor: SinkDescriptor) -> [String] {
        guard let group = groups.first(where: { isCoordinator(descriptor, of: $0) }),
              group.isMultiMember else { return [] }
        return group.members
            .filter { $0.uuid != group.coordinatorUUID }
            .map(\.zoneName)
    }

    // MARK: - Matching

    /// Match a topology member to a discovered sink. Primary key is the
    /// RINCON UUID (== our Sonos SinkID in the common case); the room-name
    /// fallback covers any Bonjour-vs-topology UUID-format drift, since room
    /// names are unique per Sonos household.
    private func match(_ member: SonosClient.ZoneGroup.Member, in sonos: [SinkDescriptor]) -> SinkDescriptor? {
        if let byUUID = sonos.first(where: { $0.id == member.uuid }) { return byUUID }
        return sonos.first { $0.displayName.caseInsensitiveCompare(member.zoneName) == .orderedSame }
    }

    /// Whether `descriptor` is the coordinator of `group` (UUID first, then
    /// room-name fallback against the coordinator's member entry).
    private func isCoordinator(_ descriptor: SinkDescriptor, of group: SonosClient.ZoneGroup) -> Bool {
        if descriptor.id == group.coordinatorUUID { return true }
        guard let coordMember = group.members.first(where: { $0.uuid == group.coordinatorUUID }) else { return false }
        return descriptor.displayName.caseInsensitiveCompare(coordMember.zoneName) == .orderedSame
    }
}
