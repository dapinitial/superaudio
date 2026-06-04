// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

public extension SinkDescriptor {
    /// Heuristic: is this device a dedicated audio receiver (vs. a general-purpose
    /// computer/phone/tablet that also happens to advertise RAOP)?
    ///
    /// Apple makes every Mac, iPhone, iPad, iPod, and Apple Watch advertise
    /// `_raop._tcp` so they can receive AirPlay from each other. They show up
    /// in our discovery but aren't what users mean by "speakers." This property
    /// lets the UI default to hiding them while keeping them available via a
    /// "Show all devices" toggle for diagnostics.
    ///
    /// Kept visible: dedicated speakers (B&W, Sonos, Bose, Naim, JBL, KEF, ...),
    /// Apple TVs, HomePods, AirPort Express, and anything with an unrecognized
    /// `am=` value (better to show an unknown than hide a real speaker).
    var isLikelySpeaker: Bool {
        // Sonos discoverer only emits Sonos speakers.
        if protocolKind == .sonos { return true }

        // AirPlay 1 RAOP devices: check the `am=` (Apple Model) field.
        guard let am = endpoint.metadata["am"]?.lowercased() else {
            return true   // Unknown model — default to showing.
        }

        let nonSpeakerPrefixes = [
            "mac",       // Mac15,*, Mac16,*, Macmini, MacBookPro, etc.
            "imac",
            "iphone",
            "ipad",
            "ipod",
            "watch",
        ]
        return !nonSpeakerPrefixes.contains { am.hasPrefix($0) }
    }
}
