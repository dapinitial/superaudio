// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Security
import SuperAudioCore

/// Helper for the legacy RAOP (AirPort Express era) RSA key wrapping.
///
/// AirPlay 1 / RAOP receivers that speak `et=1` expect the sender to:
///   1. Generate a random 16-byte AES-128 session key and 16-byte IV.
///   2. RSA-OAEP-SHA1 encrypt the AES key with Apple's AirPort Express
///      public key (a 2048-bit RSA key published in AirPort Express
///      firmware since 2008; **not a secret** — embedded verbatim in
///      shairport-sync, libraop, OwnTone, node-airtunes, AirConnect,
///      and every other open-source RAOP sender).
///   3. Send the ciphertext (base64-encoded, trailing `=` stripped) in
///      the ANNOUNCE SDP body as `a=rsaaeskey:<base64>`, with the IV
///      in `a=aesiv:<base64>`.
///
/// **Why we keep this code even though our target hardware accepts `et=0`.**
/// Confirmed against B&W A5/A7 (2026-05-13): with the NTP timing-channel
/// reply implemented, both `et=0` and `et=1` ANNOUNCE bodies result in
/// RECORD returning `200 OK`. We default to `et=1` for broader receiver
/// compatibility — some older AirPort Express models and licensed
/// third-party AP1 hardware are documented as requiring it. Cheap
/// insurance, ~150 lines.
///
/// **License note:** the key value below is a verbatim public number used
/// for interoperability with Apple's published AirTunes wire format.
/// Numbers (including cryptographic public keys) are facts, not
/// copyrightable. We are not copying code from any source — only reading
/// the key as a published fact. See `THIRD_PARTY_NOTICES.md`.
public enum AppleAirPortRSA {

    /// Apple AirPort Express RSA-2048 public key modulus, base64-encoded
    /// (256 bytes when decoded). Verbatim from owntone-server, libraop,
    /// and node-airtunes — all three agree byte-for-byte.
    private static let modulusBase64 = """
    59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC5v\
    OYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv\
    6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/\
    bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV\
    3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnhimNVvYFZeC\
    Xg/IdTQ+x4IRdiXNv5hEew==
    """

    public enum CryptoError: Error, CustomStringConvertible {
        case invalidKeyData
        case secKeyCreateFailed(String)
        case encryptFailed(String)

        public var description: String {
            switch self {
            case .invalidKeyData:           return "Apple AirPort RSA modulus is malformed (this is a bug)"
            case .secKeyCreateFailed(let m): return "SecKeyCreateWithData failed: \(m)"
            case .encryptFailed(let m):     return "SecKeyCreateEncryptedData failed: \(m)"
            }
        }
    }

    /// Lazy-built `SecKey` cached for reuse. Constructed by wrapping the
    /// bare 256-byte modulus and a fixed public exponent (65537) into
    /// PKCS#1 RSAPublicKey DER framing.
    private static let publicKey: Result<SecKey, CryptoError> = {
        let cleanBase64 = modulusBase64.replacingOccurrences(of: "\n", with: "")
        guard let modulus = Data(base64Encoded: cleanBase64), modulus.count == 256 else {
            return .failure(.invalidKeyData)
        }

        // PKCS#1 RSAPublicKey DER for 2048-bit key:
        //   SEQUENCE (266 bytes) { INTEGER modulus (257), INTEGER 65537 (3) }
        var der = Data()
        der.append(contentsOf: [0x30, 0x82, 0x01, 0x0a])              // SEQUENCE, len 266
        der.append(contentsOf: [0x02, 0x82, 0x01, 0x01, 0x00])        // INTEGER, len 257, sign byte
        der.append(modulus)                                            // 256 bytes
        der.append(contentsOf: [0x02, 0x03, 0x01, 0x00, 0x01])         // INTEGER 65537

        let attributes: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:      kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var cferr: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &cferr) else {
            let msg = (cferr?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String? ?? "unknown" } ?? "unknown"
            Log.airplay1.error("AppleAirPortRSA: SecKeyCreateWithData failed: \(msg, privacy: .public)")
            return .failure(.secKeyCreateFailed(msg))
        }
        Log.airplay1.info("AppleAirPortRSA: 2048-bit public key loaded successfully")
        return .success(key)
    }()

    /// Encrypts a 16-byte AES-128 session key under the Apple AirPort
    /// public key using RSA-OAEP-SHA1 padding. Returns 256-byte ciphertext.
    public static func encryptSessionKey(_ aesKey: Data) throws -> Data {
        let key: SecKey
        switch publicKey {
        case .success(let k): key = k
        case .failure(let e): throw e
        }
        var cferr: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionOAEPSHA1,
            aesKey as CFData,
            &cferr
        ) else {
            let msg = (cferr?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String? ?? "unknown" } ?? "unknown"
            throw CryptoError.encryptFailed(msg)
        }
        return encrypted as Data
    }
}
