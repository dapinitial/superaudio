// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.
//
// Device profiles themselves (the JSON data in superaudio-device-profiles/)
// are MIT-licensed pure data — see that repo's LICENSE file. This Swift
// loader code is MIT under the SuperAudio license.

import Foundation

/// #112 / M5.5 — Device Profile substrate.
///
/// One profile = one device model's protocol/codec/quirk fingerprint, loaded
/// from JSON at runtime. The substrate for the M6.5 Claude Skill (which
/// drafts these and opens PRs to the public repo) and the structural
/// foundation for community-crowdsourced device support — the third
/// moat-grade capability alongside cross-protocol fan-out and cross-protocol
/// mic calibration.
///
/// **Two roles per profile** (introduced 2026-05-16 expansion):
/// - `sink`: how to send audio TO this device
/// - `control`: how to observe events FROM this device (for soundbars-as-
///   audio-brain paired with our Audio Bridge)
///
/// **No executable code in profiles.** The loader is a JSON parser, never
/// an interpreter. Hostile profile cannot pwn the user.
///
/// **Versioning**: `schemaVersion = 1`. Future versions will be non-breaking
/// additive — new optional fields only. Old loaders ignore fields they don't
/// understand. Major bumps (rare) would ship with a migration script.
///
/// See `superaudio-device-profiles/schema.json` at the repo root for the
/// full field reference + `superaudio-device-profiles/README.md` for the
/// contribution model.
public struct DeviceProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let manufacturer: String
    public let model: String
    public let firstRelease: Int?
    public let lastFirmware: String?
    public let match: MatchHints
    public let roles: Roles
    public let verifiedBy: [String]?
    public let verifiedDate: String?
    public let contributedDate: String?
    public let notes: String?

    public struct MatchHints: Codable, Equatable, Sendable {
        public let bonjourServiceType: String?
        public let modelHints: [String]?
        public let macOUI: [String]?
    }

    public struct Roles: Codable, Equatable, Sendable {
        public let sink: SinkRole?
        public let control: ControlRole?
    }

    public struct SinkRole: Codable, Equatable, Sendable {
        public let `protocol`: ProtocolKind
        public let codec: Codec
        public let encryption: Encryption?
        public let audioLatencyMs: Int?
        public let buffer: String?
        public let transport: Transport?
        public let quirks: [String]?
        public let volumeScale: VolumeScale?
        public let knownFirmware: [String]?

        public enum ProtocolKind: String, Codable, Sendable {
            case airplay1, airplay2, sonos, chromecast, bluetooth, snapcast, dlna
        }

        public struct Codec: Codable, Equatable, Sendable {
            public let format: Format
            public let sampleRate: Int
            public let bitDepth: Int?
            public let channels: Int
            public let compressed: Bool?
            public let container: String?

            public enum Format: String, Codable, Sendable {
                case alac
                case aacLC = "aac-lc"
                case aacELC = "aac-elc"
                case mp3, pcm, opus, flac
            }
        }

        public struct Encryption: Codable, Equatable, Sendable {
            public let et: Int?
            public let fallback: String?
        }

        public struct Transport: Codable, Equatable, Sendable {
            public let scheme: String?
            public let metadataRequired: Bool?
            public let metadataNote: String?
        }

        public struct VolumeScale: Codable, Equatable, Sendable {
            public let type: ScaleType
            public let min: Double
            public let max: Double
            public let muted: Double?

            public enum ScaleType: String, Codable, Sendable {
                case dB, percent, raw
            }
        }
    }

    public struct ControlRole: Codable, Equatable, Sendable {
        public let volumeEventSource: EventSource?
        public let subscriptionEndpoint: String?
        public let powerEventSource: EventSource?
        public let irCodesLearned: Bool?
        public let fallbackStrategy: String?

        public enum EventSource: String, Codable, Sendable {
            case upnpEventing = "upnp-eventing"
            case homekit
            case smartthings
            case cecHDMI = "cec-hdmi"
            case irLearned = "ir-learned"
            case polling
            case none
        }
    }
}
