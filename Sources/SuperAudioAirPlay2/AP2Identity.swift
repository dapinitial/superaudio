// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CryptoKit
import SuperAudioCore

/// HAP-flavored crypto helpers shared by pair-setup M5/M6 and pair-verify:
/// HKDF-SHA512 with HomeKit's string salts/infos, and ChaCha20-Poly1305 with
/// HomeKit's 8-char ASCII nonce labels (zero-padded to the 12-byte wire nonce).
/// Constants verified against HAP spec §5.6–5.7 conventions (openairplay
/// airplay2-receiver read as reference; fresh Swift on CryptoKit).
enum HAPCrypto {

    /// HKDF-SHA512(ikm, salt, info) → `count` bytes (extract+expand, RFC 5869).
    static func hkdf(_ ikm: Data, salt: String, info: String, count: Int = 32) -> Data {
        let key = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// HomeKit nonce: 4 zero bytes + the 8-byte ASCII label ("PS-Msg05" …).
    static func nonce(_ label: String) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data(label.utf8))
    }

    /// ChaCha20-Poly1305 seal, HAP wire form: ciphertext || 16-byte authTag.
    static func seal(_ plaintext: Data, key: Data, nonceLabel: String) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce(nonceLabel))
        return box.ciphertext + box.tag
    }

    /// Inverse of `seal` — input is ciphertext || authTag.
    static func open(_ data: Data, key: Data, nonceLabel: String) throws -> Data {
        guard data.count > 16 else { throw HAPCryptoError.tooShort }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce(nonceLabel),
            ciphertext: data.prefix(data.count - 16),
            tag: data.suffix(16)
        )
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }

    enum HAPCryptoError: Error { case tooShort }
}

/// A completed long-term pairing with one AP2 receiver — what pair-setup
/// M5/M6 produces once, and what pair-verify consumes on every session.
public struct AP2Pairing: Codable {
    public let deviceID: String            // receiver's stable ID (from /info)
    public let accessoryPairingID: String  // receiver's HAP pairing identifier
    public let accessoryLTPK: Data         // receiver's Ed25519 long-term public key (32B)
}

/// Our persistent controller identity: a pairing ID (UUID string) and an
/// Ed25519 long-term signing key. Created once, reused for every pairing —
/// receivers remember us by these.
///
/// Persisted in UserDefaults per the POC norm. TODO(M7): move the private key
/// to the Keychain before any public build.
public struct AP2ControllerIdentity {
    public let pairingID: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public var ltpk: Data { signingKey.publicKey.rawRepresentation }

    static let idKey = "ap2.identity.pairingID"
    static let keyKey = "ap2.identity.ltsk"

    public static func loadOrCreate() -> AP2ControllerIdentity {
        let d = UserDefaults.standard
        if let id = d.string(forKey: idKey),
           let b64 = d.string(forKey: keyKey),
           let raw = Data(base64Encoded: b64),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return AP2ControllerIdentity(pairingID: id, signingKey: key)
        }
        let fresh = AP2ControllerIdentity(
            pairingID: UUID().uuidString,
            signingKey: Curve25519.Signing.PrivateKey()
        )
        d.set(fresh.pairingID, forKey: idKey)
        d.set(fresh.signingKey.rawRepresentation.base64EncodedString(), forKey: keyKey)
        Log.airplay2.notice("AP2 identity created: \(fresh.pairingID, privacy: .public)")
        return fresh
    }
}

/// UserDefaults-backed store of long-term pairings, keyed by receiver deviceID.
public enum AP2PairingStore {
    static func key(_ deviceID: String) -> String { "ap2.pairing.\(deviceID)" }

    public static func save(_ pairing: AP2Pairing) {
        if let data = try? JSONEncoder().encode(pairing) {
            UserDefaults.standard.set(data, forKey: key(pairing.deviceID))
            Log.airplay2.notice("AP2 pairing stored for \(pairing.deviceID, privacy: .public) (accessory \(pairing.accessoryPairingID, privacy: .public))")
        }
    }

    public static func load(deviceID: String) -> AP2Pairing? {
        guard let data = UserDefaults.standard.data(forKey: key(deviceID)) else { return nil }
        return try? JSONDecoder().decode(AP2Pairing.self, from: data)
    }
}
