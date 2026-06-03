// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

/// Per-protocol / per-feature addons. Anticipates the commercial track's
/// pricing model: base app ships AirPlay 1 + Sonos; everything else is a
/// $5 addon purchased via direct-sale website + license key.
public enum Addon: String, Sendable, CaseIterable {
    case airplay2
    case chromecast
    case bluetooth
    case eq
    case multizone
}

/// **V1 stub** — returns `true` for every addon so the POC ships everything.
///
/// When the commercial track is greenlit, this enum is replaced with a real
/// implementation that validates a license key (locally, no phoning home)
/// against a list of enabled addons. The call sites in `AppDelegate.swift`
/// stay identical, so adopting real licensing is a one-file change rather
/// than an architectural refactor.
public enum LicenseManager {
    public static func isEnabled(_ addon: Addon) -> Bool {
        true
    }
}
