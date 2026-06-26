// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore
import SuperAudioSonos

/// M6.6 full — programmatic Sonos grouping from inside SuperAudio.
///
/// Builds on the M6.6a precursor: today the app *reads* zone-group topology
/// and feeds only the coordinator. This adds the *write* side — group every
/// discovered Sonos under one coordinator (or dissolve the group) with a single
/// action — so a user who hasn't grouped in the Sonos app gets sample-locked,
/// coordinator-only playback without leaving SuperAudio. Local SOAP only
/// (`x-rincon:` / `BecomeCoordinatorOfStandaloneGroup`), no Sonos cloud account
/// (the roadmap's Cloud-Control-API framing isn't needed for grouping).
///
/// After a group/ungroup, `SonosTopology`'s poll picks up the new layout within
/// ~10 s and the menu collapses/expands accordingly; we also kick an immediate
/// refresh so the UI reacts right away.
@MainActor
enum SonosGrouping {

    /// All discovered Sonos sinks (the raw renderers, pre-group-filtering).
    static func discoveredSonos() -> [SinkDescriptor] {
        DiscoveredSinks.shared.sinks.filter { $0.protocolKind == .sonos && !$0.endpoint.host.isEmpty }
    }

    /// Group every discovered Sonos under a single coordinator. Prefers an
    /// already-active coordinator if one exists in the current topology (so we
    /// don't needlessly re-home a playing group); otherwise the first Sonos.
    /// No-op with fewer than two Sonos.
    static func groupAll() async {
        let sonos = discoveredSonos()
        guard sonos.count >= 2 else {
            Log.app.info("SonosGrouping.groupAll: <2 Sonos discovered — nothing to group")
            return
        }
        let coordinator = preferredCoordinator(among: sonos)
        let followers = sonos.filter { $0.id != coordinator.id }
        Log.app.notice("SonosGrouping: grouping \(followers.count) follower(s) under coordinator '\(coordinator.displayName, privacy: .public)'")

        for follower in followers {
            do {
                _ = try await SonosClient(descriptor: follower).joinGroup(coordinatorUUID: coordinator.id)
                Log.app.notice("SonosGrouping: '\(follower.displayName, privacy: .public)' → joined '\(coordinator.displayName, privacy: .public)'")
            } catch {
                Log.app.error("SonosGrouping: '\(follower.displayName, privacy: .public)' join failed — \(String(describing: error), privacy: .public)")
            }
        }
        await SonosTopology.shared.refreshNow()
    }

    /// Dissolve any Sonos grouping — make every discovered Sonos a standalone
    /// coordinator again.
    static func ungroupAll() async {
        let sonos = discoveredSonos()
        guard !sonos.isEmpty else { return }
        Log.app.notice("SonosGrouping: ungrouping \(sonos.count) Sonos")
        for s in sonos {
            do {
                _ = try await SonosClient(descriptor: s).becomeStandalone()
                Log.app.notice("SonosGrouping: '\(s.displayName, privacy: .public)' → standalone")
            } catch {
                Log.app.error("SonosGrouping: '\(s.displayName, privacy: .public)' ungroup failed — \(String(describing: error), privacy: .public)")
            }
        }
        await SonosTopology.shared.refreshNow()
    }

    /// Pick the coordinator to group under: reuse the coordinator of the
    /// largest existing multi-member group if there is one (avoids re-homing a
    /// group that's already partly formed), else the first discovered Sonos.
    private static func preferredCoordinator(among sonos: [SinkDescriptor]) -> SinkDescriptor {
        let groups = SonosTopology.shared.groups
        if let biggest = groups.filter(\.isMultiMember).max(by: { $0.members.count < $1.members.count }),
           let match = sonos.first(where: { $0.id == biggest.coordinatorUUID }) {
            return match
        }
        return sonos[0]
    }
}
