// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import SuperAudioCore

/// Reduces the stream of `SinkChange` events from every registered discoverer
/// into a single observable list of currently-known sinks. Owned by
/// `AppDelegate`, consumed by `MenuBarView`.
///
/// Kept small on purpose: it doesn't hold connections or audio state, just the
/// list. The actual connect-to-sink work happens elsewhere when the user picks
/// a device from the menu.
@MainActor
@Observable
final class DiscoveredSinks {
    static let shared = DiscoveredSinks()

    private(set) var sinks: [SinkDescriptor] = []

    /// Sinks with cross-protocol duplicates removed. A Sonos speaker with
    /// AirPlay enabled (e.g. a Sonos One SL) advertises BOTH `_sonos` and
    /// `_raop`, so it shows up twice — once as Sonos, once as AirPlay. The
    /// AirPlay face is an AirPlay-2-only receiver our AirPlay-1 client can't
    /// drive (it times out), and we'd rather drive it via the Sonos path
    /// anyway. So drop any AirPlay sink whose name matches a Sonos sink.
    var deduplicated: [SinkDescriptor] { Self.deduplicate(sinks) }

    static func deduplicate(_ all: [SinkDescriptor]) -> [SinkDescriptor] {
        let sonosNames = Set(all.filter { $0.protocolKind == .sonos }
                                .map { $0.displayName.lowercased() })
        return all.filter { sink in
            !(sink.protocolKind == .airplay1 && sonosNames.contains(sink.displayName.lowercased()))
        }
    }

    private var observerTasks: [Task<Void, Never>] = []

    private init() {}

    /// Starts a task per registered discoverer. Called once from
    /// `AppDelegate.applicationDidFinishLaunching` after discoverers register.
    func startObserving() {
        guard observerTasks.isEmpty else { return }

        for discoverer in SinkRegistry.shared.allDiscoverers() {
            let task = Task { @MainActor [weak self] in
                for await change in discoverer.sinks {
                    self?.apply(change)
                }
            }
            observerTasks.append(task)
        }
    }

    func stopObserving() {
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
    }

    private func apply(_ change: SinkChange) {
        switch change {
        case .added(let descriptor):
            if !sinks.contains(where: { $0.id == descriptor.id }) {
                sinks.append(descriptor)
                Log.app.info("Sink added to UI list: \(descriptor.displayName, privacy: .public) (\(descriptor.protocolKind.rawValue, privacy: .public))")
            }
        case .updated(let descriptor):
            if let idx = sinks.firstIndex(where: { $0.id == descriptor.id }) {
                sinks[idx] = descriptor
            } else {
                sinks.append(descriptor)
            }
        case .removed(let id):
            if let idx = sinks.firstIndex(where: { $0.id == id }) {
                let removed = sinks.remove(at: idx)
                Log.app.info("Sink removed from UI list: \(removed.displayName, privacy: .public)")
            }
        }
    }
}
