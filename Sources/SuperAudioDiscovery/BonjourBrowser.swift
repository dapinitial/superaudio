// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore

/// Thin wrapper around `NWBrowser` for Bonjour service discovery, with
/// the same callback shape every protocol-module discoverer wants.
///
/// Phase 1 — Bonjour discovery of `_raop._tcp` (AirPlay 1) gets wired
/// through this. SSDP for Sonos goes in a sibling file in this module.
///
/// Stub for the scaffold commit; populated in Phase 1 sub-tasks.
public final class BonjourBrowser {
    public let serviceType: String
    public let domain: String

    public init(serviceType: String, domain: String = "local.") {
        self.serviceType = serviceType
        self.domain = domain
    }

    public func start() {
        Log.discovery.info("BonjourBrowser.start(\(self.serviceType, privacy: .public)) — stub, no discovery yet")
    }

    public func stop() {
        Log.discovery.info("BonjourBrowser.stop(\(self.serviceType, privacy: .public))")
    }
}
