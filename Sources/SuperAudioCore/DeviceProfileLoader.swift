// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation

/// #112 / M5.5 — Device Profile loader.
///
/// Loads `DeviceProfile` instances from two sources, in priority order:
///   1. **User overlay**: `~/Library/Application Support/SuperAudio/Profiles/`
///      — user-authored or community-pulled profiles take precedence
///   2. **App bundle**: profiles shipped with the SuperAudio binary
///      (copied from `superaudio-device-profiles/profiles/` at build time)
///
/// The user-overlay path lets contributors test community profiles before
/// they ship to the public repo, and lets advanced users override quirks
/// for forks of devices we don't yet support.
///
/// **Match resolution** (used by sink discovery to pick a profile for a
/// just-discovered device): walk loaded profiles in deterministic order,
/// return the first whose `match` hints fit the device's bonjour service
/// + model hints + MAC OUI. If no match, returns nil — the protocol
/// module falls back to its built-in defaults.
///
/// **No code execution.** This is strictly `JSONDecoder` plus a filesystem
/// scan. Hostile profile cannot do more than fail to decode.
public enum DeviceProfileLoader {

    /// Errors that surface to the caller. Anything else (one bad profile
    /// in a directory of good ones) is logged but doesn't fail the whole load.
    public enum LoadError: Error, CustomStringConvertible {
        case bundleResourceMissing
        case userDirNotCreatable(String)

        public var description: String {
            switch self {
            case .bundleResourceMissing:
                return "App bundle has no embedded device profiles — superaudio-device-profiles/profiles/ wasn't copied at build time"
            case .userDirNotCreatable(let path):
                return "Could not create user profile directory at \(path)"
            }
        }
    }

    /// Default location for user-authored / community-pulled profiles.
    public static var userProfileDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SuperAudio/Profiles", isDirectory: true)
    }

    /// Load every available profile (bundle + user overlay), de-duplicated by
    /// `id` with the user overlay winning. Returns the loaded profiles plus
    /// per-file errors for caller to log/surface in diagnostics UI.
    ///
    /// Never throws — a load with zero profiles is a valid (if degraded) state.
    public static func loadAll() -> (profiles: [DeviceProfile], errors: [(path: String, error: Error)]) {
        var errors: [(path: String, error: Error)] = []
        var byID: [String: DeviceProfile] = [:]

        // Bundle: prefer the resource bundle's "DeviceProfiles" subdirectory if
        // present, else accept any *.json in the bundle root that looks like a
        // profile. SPM resource handling differs across configurations; tolerate.
        for url in bundleProfileURLs() {
            do {
                let data = try Data(contentsOf: url)
                let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
                byID[profile.id] = profile
                Log.core.info("DeviceProfile loaded from bundle: \(profile.id, privacy: .public)")
            } catch {
                errors.append((path: url.lastPathComponent, error: error))
                Log.core.error("DeviceProfile bundle load failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // User overlay: overwrites bundle entries with the same id.
        for url in userProfileURLs() {
            do {
                let data = try Data(contentsOf: url)
                let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
                byID[profile.id] = profile
                Log.core.info("DeviceProfile loaded from user overlay: \(profile.id, privacy: .public) (overrides bundle if same id)")
            } catch {
                errors.append((path: url.path, error: error))
                Log.core.error("DeviceProfile user-overlay load failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        let profiles = byID.values.sorted(by: { $0.id < $1.id })
        Log.core.notice("DeviceProfileLoader: loaded \(profiles.count) profile(s) (\(errors.count) error(s))")
        return (profiles, errors)
    }

    /// Pick a profile for a discovered device by matching against its
    /// bonjour service type + model hint text + MAC OUI.
    ///
    /// `modelHintText`: any free-form text from the discovery layer (TXT
    /// records, HTTP description). Case-insensitive substring match against
    /// each profile's `match.modelHints`.
    ///
    /// `macOUI`: first 3 octets of the device's MAC, formatted `"XX:XX:XX"`.
    /// Tiebreaker only — never the primary key because OUIs are shared
    /// across product lines.
    ///
    /// Returns the first profile whose hints fit, or nil for "use protocol
    /// module defaults."
    public static func matchProfile(
        bonjourServiceType: String?,
        modelHintText: String?,
        macOUI: String?,
        among profiles: [DeviceProfile]
    ) -> DeviceProfile? {
        for profile in profiles {
            let match = profile.match
            // Service-type filter: if profile specifies one and it doesn't
            // match the discovered service, skip.
            if let want = match.bonjourServiceType, let got = bonjourServiceType, want != got {
                continue
            }
            // Model-hint filter: if profile specifies hints, at least one
            // must substring-match the device's hint text.
            if let hints = match.modelHints, !hints.isEmpty {
                guard let txt = modelHintText?.lowercased() else { continue }
                let anyHit = hints.contains { txt.contains($0.lowercased()) }
                if !anyHit { continue }
            }
            // MAC OUI filter (tiebreaker): if profile specifies OUIs, the
            // device's OUI (if known) must be in the list.
            if let ouis = match.macOUI, !ouis.isEmpty, let dev = macOUI {
                if !ouis.contains(dev.uppercased()) { continue }
            }
            return profile
        }
        return nil
    }

    // MARK: - Internals

    /// Find all *.json profile candidates in the SuperAudioCore module bundle.
    /// SPM puts package resources under `Bundle.module`; the Xcode build path
    /// may differ slightly across configurations, so tolerate both.
    private static func bundleProfileURLs() -> [URL] {
        // The bundle copies `superaudio-device-profiles/profiles/` as a
        // resource directory named "DeviceProfiles" (configured in Package.swift).
        // If that's missing, fall back to scanning the bundle root for *.json
        // files that decode as a DeviceProfile.
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "DeviceProfiles", withExtension: nil) {
            return jsonFiles(in: url)
        }
        if let url = bundle.resourceURL {
            return jsonFiles(in: url).filter { url in
                // Only accept files that LOOK like profiles to avoid grabbing
                // unrelated JSON. Cheap pre-filter: must contain "schemaVersion".
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { return false }
                return text.contains("\"schemaVersion\"")
            }
        }
        return []
    }

    private static func userProfileURLs() -> [URL] {
        let dir = userProfileDirectory
        // Auto-create on first call so a fresh user can drop a file in.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return jsonFiles(in: dir)
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }
}
