// swift-tools-version: 5.10
// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import PackageDescription

let package = Package(
    name: "SuperAudio",
    defaultLocalization: "en",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "SuperAudio", targets: ["SuperAudio"]),
        .library(name: "SuperAudioCore", targets: ["SuperAudioCore"]),
        .library(name: "SuperAudioDiscovery", targets: ["SuperAudioDiscovery"]),
        .library(name: "SuperAudioAirPlay1", targets: ["SuperAudioAirPlay1"]),
        .library(name: "SuperAudioSonos", targets: ["SuperAudioSonos"]),
    ],
    targets: [
        // Core contracts — depends on nothing project-internal. Pure Swift + Apple frameworks.
        // Bundles the device profile JSON resources for the M5.5 substrate.
        // Canonical source for the profile files is `superaudio-device-profiles/`
        // at the repo root (the eventual public-MIT split-out repo); the
        // `Sources/SuperAudioCore/Resources/DeviceProfiles/` directory is
        // kept in sync via `Scripts/sync_device_profiles.sh` so SPM can
        // bundle them as resources at the path it expects.
        .target(
            name: "SuperAudioCore",
            resources: [.copy("Resources/DeviceProfiles")]
        ),

        // Shared discovery primitives (Bonjour, SSDP). Depends on Core only.
        .target(
            name: "SuperAudioDiscovery",
            dependencies: ["SuperAudioCore"]
        ),

        // AirPlay 1 protocol module. Depends on Core + Discovery only.
        // Future siblings (SuperAudioAirPlay2, SuperAudioChromecast, etc.) follow the same shape.
        .target(
            name: "SuperAudioAirPlay1",
            dependencies: ["SuperAudioCore", "SuperAudioDiscovery"]
        ),

        // Sonos protocol module. Depends on Core + Discovery only.
        .target(
            name: "SuperAudioSonos",
            dependencies: ["SuperAudioCore", "SuperAudioDiscovery"]
        ),

        // Menu bar app. Wires everything together at startup. Only target that
        // depends on per-protocol modules.
        .executableTarget(
            name: "SuperAudio",
            dependencies: [
                "SuperAudioCore",
                "SuperAudioDiscovery",
                "SuperAudioAirPlay1",
                "SuperAudioSonos",
            ]
        ),

    ]
)
