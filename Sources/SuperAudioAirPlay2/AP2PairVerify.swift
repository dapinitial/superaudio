// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CryptoKit
import SuperAudioCore

/// AirPlay 2 **pair-verify** — the silent per-session handshake that replaces
/// the PIN once pair-setup M5/M6 has stored a long-term pairing. Every
/// streaming session begins here; the X25519 shared secret it produces is
/// what the encrypted control channel and stream keys derive from.
///
///   M1 → POST /pair-verify { state=1, publicKey: our ephemeral X25519 }
///   M2 ← { state=2, publicKey: accessory ephemeral, encryptedData }
///        → ECDH shared secret; decrypt (PV-Msg02); Ed25519-verify the
///          accessory's signature against its STORED long-term public key
///   M3 → { state=3, encryptedData (PV-Msg03): our id + our signature }
///   M4 ← { state=4 }                                        (or { error })
///
/// HAP §5.7 flow, fresh Swift on CryptoKit (openairplay airplay2-receiver
/// read as reference only).
public enum AP2PairVerify {

    /// A verified session: the ECDH shared secret plus the control-channel
    /// keys derived from it (from OUR perspective: write = what we encrypt).
    public struct Session {
        public let sharedSecret: Data      // X25519, 32B
        public let controlWriteKey: Data   // "Control-Write-Encryption-Key"
        public let controlReadKey: Data    // "Control-Read-Encryption-Key"
    }

    public enum PairVerifyError: Error, CustomStringConvertible {
        case noStoredPairing(String)
        case deviceError(UInt8, stateLabel: String)
        case missingField(String)
        case accessoryMismatch(expected: String, got: String)
        case accessorySignature
        case cryptoFailed(String)
        case transport(Error)

        public var description: String {
            switch self {
            case .noStoredPairing(let d):  return "no stored pairing for \(d) — run pair-setup (PIN) first"
            case .deviceError(let c, let s):
                let name = TLV8.PairingError(rawValue: c).map { "\($0)" } ?? "code \(c)"
                return "receiver returned error \(name) at \(s)"
            case .missingField(let f):     return "missing \(f) in response"
            case .accessoryMismatch(let e, let g): return "accessory identity changed (stored \(e), got \(g))"
            case .accessorySignature:      return "accessory signature did not verify against stored LTPK"
            case .cryptoFailed(let m):     return "crypto: \(m)"
            case .transport(let e):        return "transport: \(e)"
            }
        }
    }

    /// A verified, still-open connection with channel encryption already
    /// enabled — ready for SETUP and the rest of the RTSP plane. The caller
    /// owns `client` and must `disconnect()` it when the stream ends.
    public struct LiveSession {
        public let client: AP2RTSPClient
        public let session: Session
    }

    /// Convenience: open a fresh connection, resolve the receiver's deviceID
    /// via /info (the pairing-store key), and run pair-verify on it. The
    /// connection is closed before returning (handshake-only check).
    public static func run(descriptor: SinkDescriptor) async throws -> Session {
        let client = AP2RTSPClient(descriptor: descriptor)
        do {
            try await client.connect()
        } catch {
            throw PairVerifyError.transport(error)
        }
        defer { client.disconnect() }
        return try await run(client: client, deviceID: resolveDeviceID(client, descriptor))
    }

    /// Connect, pair-verify, and switch the channel to encryption — returning
    /// the live client so the caller can proceed straight to SETUP. On any
    /// failure the connection is closed before throwing.
    public static func establish(descriptor: SinkDescriptor) async throws -> LiveSession {
        let client = AP2RTSPClient(descriptor: descriptor)
        do {
            try await client.connect()
        } catch {
            throw PairVerifyError.transport(error)
        }
        do {
            let session = try await run(client: client, deviceID: resolveDeviceID(client, descriptor))
            client.enableEncryption(writeKey: session.controlWriteKey, readKey: session.controlReadKey)
            return LiveSession(client: client, session: session)
        } catch {
            client.disconnect()
            throw error
        }
    }

    /// The receiver's stable deviceID (pairing-store key), read from /info;
    /// falls back to the display name to match pair-setup's keying.
    private static func resolveDeviceID(_ client: AP2RTSPClient, _ descriptor: SinkDescriptor) async -> String {
        if let info = try? await client.get(path: "/info"),
           let plist = try? PropertyListSerialization.propertyList(from: info.body, options: [], format: nil) as? [String: Any],
           let id = plist["deviceID"] as? String {
            return id
        }
        return descriptor.displayName
    }

    /// Runs pair-verify on an already-connected client. `deviceID` selects the
    /// stored pairing (falls back to display name, matching pair-setup's key).
    public static func run(client: AP2RTSPClient, deviceID: String) async throws -> Session {
        let label = client.descriptor.displayName
        guard let pairing = AP2PairingStore.load(deviceID: deviceID) else {
            throw PairVerifyError.noStoredPairing(deviceID)
        }
        let identity = AP2ControllerIdentity.loadOrCreate()
        let headers = AP2PairSetup.pairingHeaders(transient: true)

        // ---- M1 → M2 ----------------------------------------------------
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        let m1 = TLV8.encode([
            TLV8.Item(.state, byte: 0x01),
            TLV8.Item(.publicKey, ephPub),
        ])
        Log.airplay2.notice("pair-verify[\(label, privacy: .public)] → M1 (ephemeral pk 32B)")
        let m2resp: AP2RTSPClient.Response
        do {
            m2resp = try await client.post(path: "/pair-verify", body: m1, extraHeaders: headers)
        } catch {
            throw PairVerifyError.transport(error)
        }
        let m2 = TLV8.decode(m2resp.body)
        if let code = TLV8.byte(.error, in: m2) {
            Log.airplay2.error("pair-verify[\(label, privacy: .public)] M2 error code=\(code) (\(m2resp.statusLine, privacy: .public))")
            throw PairVerifyError.deviceError(code, stateLabel: "M2")
        }
        guard let accEphPub = TLV8.value(.publicKey, in: m2) else {
            Log.airplay2.error("pair-verify[\(label, privacy: .public)] M2 raw: \(m2resp.statusLine, privacy: .public) body=\(m2resp.body.count)B")
            throw PairVerifyError.missingField("M2 publicKey")
        }
        guard let m2enc = TLV8.value(.encryptedData, in: m2) else {
            throw PairVerifyError.missingField("M2 encryptedData")
        }

        // ---- ECDH + verify the accessory --------------------------------
        let shared: Data
        do {
            let accKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: accEphPub)
            let secret = try eph.sharedSecretFromKeyAgreement(with: accKey)
            shared = secret.withUnsafeBytes { Data($0) }
        } catch {
            throw PairVerifyError.cryptoFailed("X25519: \(error)")
        }
        let vKey = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let m2sub: [TLV8.Item]
        do {
            m2sub = TLV8.decode(try HAPCrypto.open(m2enc, key: vKey, nonceLabel: "PV-Msg02"))
        } catch {
            throw PairVerifyError.cryptoFailed("M2 open: \(error)")
        }
        guard let accIDData = TLV8.value(.identifier, in: m2sub),
              let accSig = TLV8.value(.signature, in: m2sub),
              let accID = String(data: accIDData, encoding: .utf8) else {
            throw PairVerifyError.missingField("M2 sub-TLV (identifier/signature)")
        }
        guard accID == pairing.accessoryPairingID else {
            throw PairVerifyError.accessoryMismatch(expected: pairing.accessoryPairingID, got: accID)
        }
        let accInfo = accEphPub + accIDData + ephPub
        guard let ltpk = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.accessoryLTPK),
              ltpk.isValidSignature(accSig, for: accInfo) else {
            throw PairVerifyError.accessorySignature
        }
        Log.airplay2.notice("pair-verify[\(label, privacy: .public)] ← M2 ✓ — accessory \(accID, privacy: .public) verified against stored LTPK")

        // ---- M3 → M4 ----------------------------------------------------
        let ourInfo = ephPub + Data(identity.pairingID.utf8) + accEphPub
        let ourSig: Data
        do {
            ourSig = try identity.signingKey.signature(for: ourInfo)
        } catch {
            throw PairVerifyError.cryptoFailed("Ed25519 sign: \(error)")
        }
        let m3sub = TLV8.encode([
            TLV8.Item(.identifier, Data(identity.pairingID.utf8)),
            TLV8.Item(.signature, ourSig),
        ])
        let m3enc: Data
        do {
            m3enc = try HAPCrypto.seal(m3sub, key: vKey, nonceLabel: "PV-Msg03")
        } catch {
            throw PairVerifyError.cryptoFailed("M3 seal: \(error)")
        }
        let m3 = TLV8.encode([
            TLV8.Item(.state, byte: 0x03),
            TLV8.Item(.encryptedData, m3enc),
        ])
        Log.airplay2.notice("pair-verify[\(label, privacy: .public)] → M3 (encryptedData \(m3enc.count)B)")
        let m4resp: AP2RTSPClient.Response
        do {
            m4resp = try await client.post(path: "/pair-verify", body: m3, extraHeaders: headers)
        } catch {
            throw PairVerifyError.transport(error)
        }
        let m4 = TLV8.decode(m4resp.body)
        if let code = TLV8.byte(.error, in: m4) {
            throw PairVerifyError.deviceError(code, stateLabel: "M4")
        }

        Log.airplay2.notice("pair-verify[\(label, privacy: .public)] ← M4 ✓ — SESSION VERIFIED, control keys derived")
        return Session(
            sharedSecret: shared,
            controlWriteKey: HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
            controlReadKey: HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        )
    }
}
