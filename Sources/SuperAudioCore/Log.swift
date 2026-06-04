// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import os

/// Centralized OSLog subsystems. Every module gets its own category so
/// `log stream --predicate 'subsystem == "com.davidpuerto.SuperAudio"'`
/// can filter cleanly.
public enum Log {
    public static let subsystem = "com.davidpuerto.SuperAudio"

    public static let app       = Logger(subsystem: subsystem, category: "app")
    public static let core      = Logger(subsystem: subsystem, category: "core")
    public static let capture   = Logger(subsystem: subsystem, category: "capture")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let airplay1  = Logger(subsystem: subsystem, category: "airplay1")
    public static let sonos     = Logger(subsystem: subsystem, category: "sonos")
    public static let license   = Logger(subsystem: subsystem, category: "license")
}
