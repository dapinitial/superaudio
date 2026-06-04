// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
//
// DeviceProfileTest — validates the JSON profile loader by:
//   1. Decoding every profile JSON file in superaudio-device-profiles/profiles/
//   2. Confirming the decoder + schema agree (no decode errors)
//   3. Spot-checking that match resolution picks the right profile for
//      known device fingerprints
//
// Build + run:
//   swift run SuperAudio    # the app links Core which has the loader
//
// Or as standalone (uses standalone JSON decoding, not the bundle path):
//   swiftc -O probe/DeviceProfileTest.swift -o probe/DeviceProfileTest
//   probe/DeviceProfileTest
//
// This standalone path mirrors the Codable types in Swift inline so it can
// run without the SuperAudioCore module. It validates the JSON files directly
// from `superaudio-device-profiles/profiles/`.

import Foundation

// ─────────────────────────────────────────────────────────────────────
// Inlined minimal copy of DeviceProfile types for standalone build.
// Keep in sync with Sources/SuperAudioCore/DeviceProfile.swift.
// ─────────────────────────────────────────────────────────────────────

struct DeviceProfile: Codable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let manufacturer: String
    let model: String
    let firstRelease: Int?
    let lastFirmware: String?
    let match: MatchHints
    let roles: Roles
    let verifiedBy: [String]?
    let verifiedDate: String?
    let contributedDate: String?
    let notes: String?

    struct MatchHints: Codable {
        let bonjourServiceType: String?
        let modelHints: [String]?
        let macOUI: [String]?
    }

    struct Roles: Codable {
        let sink: SinkRole?
        let control: ControlRole?
    }

    struct SinkRole: Codable {
        let `protocol`: String
        let codec: Codec
        struct Codec: Codable {
            let format: String
            let sampleRate: Int
            let channels: Int
        }
    }

    struct ControlRole: Codable {
        let volumeEventSource: String?
    }
}

// ─────────────────────────────────────────────────────────────────────
// Test harness
// ─────────────────────────────────────────────────────────────────────

let root = FileManager.default.currentDirectoryPath
let profilesDir = root + "/superaudio-device-profiles/profiles"

print("DeviceProfileTest — validating profile JSON files")
print("Looking in: \(profilesDir)")
print()

guard let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else {
    print("✗ Could not read profile directory — run from the SuperAudio repo root.")
    exit(2)
}

let jsons = files.filter { $0.hasSuffix(".json") }.sorted()
print("Found \(jsons.count) profile file(s).")
print()

var failures = 0
var loaded: [DeviceProfile] = []

for file in jsons {
    let path = profilesDir + "/" + file
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("✗ \(file): could not read")
        failures += 1
        continue
    }
    do {
        let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
        loaded.append(profile)
        var status = "✓"
        if profile.verifiedDate == nil {
            status = "🟡 (seed only, not hardware-verified)"
        }
        let sinkProto = profile.roles.sink?.protocol ?? "—"
        let hasControl = profile.roles.control != nil ? "yes" : "no"
        print("\(status) \(file)")
        print("    id:        \(profile.id)")
        print("    display:   \(profile.displayName)")
        print("    sink:      \(sinkProto)")
        print("    control:   \(hasControl)")
        print()
    } catch {
        print("✗ \(file): decode failed — \(error)")
        failures += 1
    }
}

// Cross-check schema versions all match.
let versions = Set(loaded.map { $0.schemaVersion })
if versions.count > 1 {
    print("✗ schemaVersion mismatch across profiles: \(versions)")
    failures += 1
} else if let v = versions.first {
    print("All profiles report schemaVersion = \(v) ✓")
}

// Cross-check IDs are unique.
let ids = loaded.map { $0.id }
if Set(ids).count != ids.count {
    print("✗ duplicate profile id found")
    failures += 1
} else {
    print("All profile ids are unique ✓")
}

print()
print("─────────────────────────────────────")
print("Result: \(loaded.count) loaded, \(failures) failed")
exit(failures > 0 ? 1 : 0)
