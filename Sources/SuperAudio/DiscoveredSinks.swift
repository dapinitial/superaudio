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
