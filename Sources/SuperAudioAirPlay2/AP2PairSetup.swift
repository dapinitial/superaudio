// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Security
import CryptoKit
import BigInt
import SuperAudioCore

/// AirPlay 2 **pair-setup** (SRP) over the control channel — two modes:
///
/// **Transient** (default) is the path AirPlay-2 audio senders use against
/// HomePods and modern Sonos: SRP-6a (3072-bit / SHA-512) establishes a shared
/// secret without persisting a long-term key pair, so there's no PIN to type
/// and no stored pairing — each streaming session re-derives the channel key.
/// Apple TVs also accept it when AirPlay access is "Everyone" / "Anyone on the
/// Same Network" with no password.
///
/// **PIN** (pass a `pinProvider`) is the non-transient HomeKit path for
/// receivers that require device verification: `POST /pair-pin-start` makes an
/// Apple TV display a 4-digit PIN on screen, and that PIN becomes the SRP
/// password. (A fixed AirPlay password set by the user works the same way,
/// minus the on-screen display.)
///
///   [PIN mode] → POST /pair-pin-start                     (PIN appears on TV)
///   M1 → POST /pair-setup  { state=1, method[, flags=transient] }
///   M2 ← { state=2, salt, serverPublicKey B }            (or { error })
///   M3 → POST /pair-setup  { state=3, clientPublicKey A, proof M1 }
///   M4 ← { state=4, proof M2 }                           (or { error })
///
/// then both sides hold the SRP session key K. M5/M6 — the long-term key
/// exchange — are skipped in transient mode and NOT YET IMPLEMENTED for PIN
/// mode (M4 still fully verifies the SRP handshake against real hardware).
///
/// **Reverse-engineered constants** (flags, the transient setup code) are
/// marked below and logged verbatim so they can be tuned against a live
/// receiver. The transport, TLV8, and SRP math are firm; the pairing-mode
/// constants are the iterate-against-hardware part.
public enum AP2PairSetup {

    /// What a successful pair-setup yields: the SRP session key, and — when the
    /// PIN (M5/M6) path ran — the long-term pairing to persist for pair-verify.
    public struct Result {
        public let sessionKey: Data          // K = H(S)
        public let sharedSecret: Data        // PAD(S)
        public let pairing: AP2Pairing?      // non-nil after a completed M5/M6
    }

    public enum PairSetupError: Error, CustomStringConvertible {
        case deviceError(UInt8, stateLabel: String)
        case unexpectedState(UInt8)
        case missingField(String)
        case proofMismatch
        case accessorySignature
        case cryptoFailed(String)
        case transport(Error)

        public var description: String {
            switch self {
            case .deviceError(let c, let s):
                let name = TLV8.PairingError(rawValue: c).map { "\($0)" } ?? "code \(c)"
                return "receiver returned error \(name) at \(s)"
            case .unexpectedState(let s): return "unexpected pairing state \(s)"
            case .missingField(let f):    return "missing \(f) in response"
            case .proofMismatch:          return "server proof did not verify (wrong setup code?)"
            case .accessorySignature:     return "accessory M6 signature did not verify"
            case .cryptoFailed(let m):    return "crypto: \(m)"
            case .transport(let e):       return "transport: \(e)"
            }
        }
    }

    // MARK: - Reverse-engineered constants (tune against hardware)

    /// SRP identity for HomeKit pair-setup.
    static let identity = "Pair-Setup"

    /// Transient streaming setup code. HomePods / modern Sonos don't display a
    /// PIN for transient AirPlay audio; senders use a fixed code. Best-guess
    /// default — only consulted at M3 (the proof), so M1→M2 succeeds regardless
    /// and we tune this from the M4 result.
    static let transientSetupCode = "3939"

    /// kTLVType_Flags value for transient pairing (HAP `kPairingFlag_Transient`
    /// = 0x10). Sent as a minimal little-endian integer.
    static let transientFlag: [UInt8] = [0x10]

    /// kTLVType_Method for pair-setup. Logged + easy to flip if a receiver
    /// wants a different value.
    static let methodPairSetup: UInt8 = 0x00

    /// `X-Apple-HKP` — the HomeKit-pairing flavor header AP2 receivers use to
    /// route /pair-setup. tvOS returns 470 Connection Authorization Required
    /// to a pair-setup that omits it (observed live vs AppleTV11,1 on
    /// 2026-07-08). HKP=3 is what authorized the connection through to M2 on
    /// real hardware — for BOTH modes. (HKP=4 authorized /pair-pin-start but
    /// then 470'd the pair-setup M1, so the value is a per-connection auth
    /// gate, not a mode selector; the PIN vs transient distinction is carried
    /// by /pair-pin-start + the transient flag, not this header.) `X-Apple-PD:
    /// 1` rides along.
    static func pairingHeaders(transient: Bool) -> [String: String] {
        ["X-Apple-HKP": "3", "X-Apple-PD": "1"]
    }

    // MARK: - Run

    /// - Parameter pinProvider: nil → transient pairing (fixed code). Non-nil →
    ///   PIN (HomeKit) pairing: `/pair-pin-start` fires first, then the provider
    ///   is awaited after M2 to collect the PIN the receiver is displaying.
    public static func run(descriptor: SinkDescriptor,
                           pinProvider: (@Sendable () async -> String?)? = nil) async throws -> Result {
        let label = descriptor.displayName
        let client = AP2RTSPClient(descriptor: descriptor)
        do {
            try await client.connect()
        } catch {
            throw PairSetupError.transport(error)
        }
        defer { client.disconnect() }

        let srp = SRP6aClient(group: .rfc5054_3072, alg: .sha512)

        // ---- GET /info (capability negotiation) ------------------------
        // Most AP2 receivers require this on the connection before they will
        // honor /pair-setup (a bare pair-setup gets 403 Forbidden). The body
        // is a binary plist; log the top-level keys so we can see the device's
        // declared features / supported pairing.
        var deviceID: String? = nil
        do {
            let info = try await client.get(path: "/info")
            Log.airplay2.notice("pair-setup[\(label, privacy: .public)] ← GET /info \(info.statusLine, privacy: .public) (\(info.body.count)B)")
            if !info.body.isEmpty,
               let plist = try? PropertyListSerialization.propertyList(from: info.body, options: [], format: nil) as? [String: Any] {
                let keys = plist.keys.sorted().joined(separator: ", ")
                Log.airplay2.notice("pair-setup[\(label, privacy: .public)] /info keys: \(keys, privacy: .public)")
                for k in ["features", "statusFlags", "flags", "model", "deviceID", "pi", "protocolVersion", "sourceVersion", "keepAliveLowPower", "pw"] {
                    if let v = plist[k] { Log.airplay2.notice("pair-setup[\(label, privacy: .public)] /info \(k, privacy: .public)=\(String(describing: v), privacy: .public)") }
                }
                deviceID = plist["deviceID"] as? String
            }
        } catch {
            Log.airplay2.error("pair-setup[\(label, privacy: .public)] GET /info failed: \(String(describing: error), privacy: .public)")
        }

        // ---- /pair-pin-start (PIN mode only) ---------------------------
        // Makes an Apple TV put the 4-digit PIN on screen. Must precede M1;
        // the PIN itself isn't needed until the M3 proof.
        let hkpHeaders = pairingHeaders(transient: pinProvider == nil)
        if pinProvider != nil {
            do {
                let r = try await client.post(path: "/pair-pin-start", body: Data(), extraHeaders: hkpHeaders)
                Log.airplay2.notice("pair-setup[\(label, privacy: .public)] ← POST /pair-pin-start \(r.statusLine, privacy: .public) — PIN should now be on the receiver's screen")
            } catch {
                throw PairSetupError.transport(error)
            }
        }

        // ---- M1 → M2 ---------------------------------------------------
        // The transient flag is what makes it transient; PIN mode omits it.
        var m1Items: [TLV8.Item] = [
            TLV8.Item(.state, byte: 0x01),
            TLV8.Item(.method, byte: methodPairSetup),
        ]
        if pinProvider == nil {
            m1Items.append(TLV8.Item(.flags, Data(transientFlag)))
        }
        let m1 = TLV8.encode(m1Items)
        let flagsDesc = pinProvider == nil ? "flags=" + transientFlag.map { String(format: "%02x", $0) }.joined() : "PIN mode, no flags"
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] → M1 (state=1 method=\(methodPairSetup) \(flagsDesc, privacy: .public))")

        let m2resp: AP2RTSPClient.Response
        do {
            m2resp = try await client.post(path: "/pair-setup", body: m1, extraHeaders: hkpHeaders)
        } catch {
            throw PairSetupError.transport(error)
        }
        let m2 = TLV8.decode(m2resp.body)
        // Full diagnostic dump — when a receiver refuses or reshapes M2, the
        // status line + TLV types + raw bytes are the only clue what it wants.
        let m2tlv = m2.map { "t\($0.type)(\($0.value.count)B)" }.joined(separator: " ")
        let m2hex = m2resp.body.prefix(96).map { String(format: "%02x", $0) }.joined()
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] M2 raw: \(m2resp.statusLine, privacy: .public) body=\(m2resp.body.count)B tlv=[\(m2tlv, privacy: .public)] hex=\(m2hex, privacy: .public)")
        try throwIfDeviceError(m2, state: "M2")
        if let st = TLV8.byte(.state, in: m2), st != 0x02 {
            Log.airplay2.error("pair-setup[\(label, privacy: .public)] M2 unexpected state=\(st)")
            throw PairSetupError.unexpectedState(st)
        }
        guard let salt = TLV8.value(.salt, in: m2) else { throw PairSetupError.missingField("salt") }
        guard let bData = TLV8.value(.publicKey, in: m2) else { throw PairSetupError.missingField("serverPublicKey") }
        let B = BigUInt(bData)
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] ← M2 ✓ salt=\(salt.count)B serverB=\(bData.count)B")

        // ---- compute SRP client side ----------------------------------
        // PIN mode collects the password here — after M2, once the receiver
        // is already displaying it.
        let password: String
        if let pinProvider {
            guard let pin = await pinProvider(), !pin.isEmpty else {
                throw PairSetupError.missingField("PIN (provider returned none)")
            }
            password = pin
        } else {
            password = transientSetupCode
        }

        let a = randomScalar(byteCount: 32)
        let A = srp.publicA(privateA: a)
        let S: BigUInt
        do {
            S = try srp.premaster(identity: identity, password: password, salt: salt, privateA: a, serverB: B)
        } catch {
            throw PairSetupError.transport(error)
        }
        let K = srp.sessionKey(premaster: S)
        let proof = srp.clientProof(identity: identity, salt: salt, A: A, B: B, sessionKey: K)

        // ---- M3 → M4 ---------------------------------------------------
        let m3 = TLV8.encode([
            TLV8.Item(.state, byte: 0x03),
            TLV8.Item(.publicKey, srp.padPublic(A)),
            TLV8.Item(.proof, proof),
        ])
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] → M3 (A=\(srp.padPublic(A).count)B proof=\(proof.count)B)")

        let m4resp: AP2RTSPClient.Response
        do {
            m4resp = try await client.post(path: "/pair-setup", body: m3, extraHeaders: hkpHeaders)
        } catch {
            throw PairSetupError.transport(error)
        }
        let m4 = TLV8.decode(m4resp.body)
        try throwIfDeviceError(m4, state: "M4")
        guard let serverProof = TLV8.value(.proof, in: m4) else { throw PairSetupError.missingField("serverProof") }

        let expected = srp.expectedServerProof(A: A, clientProof: proof, sessionKey: K)
        guard serverProof == expected else {
            Log.airplay2.error("pair-setup[\(label, privacy: .public)] M4 proof mismatch — likely wrong transient setup code")
            throw PairSetupError.proofMismatch
        }
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] ← M4 ✓ — SRP session key established")

        // Transient mode: pair-setup IS the session; no long-term keys exist.
        guard pinProvider != nil else {
            return Result(sessionKey: K, sharedSecret: srp.padPublic(S), pairing: nil)
        }

        // ---- M5 → M6: long-term key exchange (PIN mode only) ------------
        // Both sides sign (HKDF-derived X || pairingID || LTPK) with their
        // Ed25519 long-term key, encrypted under the SRP session key. This is
        // the part that makes the pairing PERSISTENT: after M6 verifies, the
        // receiver remembers our LTPK and pair-verify replaces the PIN forever.
        let identity2 = AP2ControllerIdentity.loadOrCreate()
        let encKey = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let deviceX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let deviceInfo = deviceX + Data(identity2.pairingID.utf8) + identity2.ltpk
        let deviceSig: Data
        do {
            deviceSig = try identity2.signingKey.signature(for: deviceInfo)
        } catch {
            throw PairSetupError.cryptoFailed("Ed25519 sign: \(error)")
        }
        let m5sub = TLV8.encode([
            TLV8.Item(.identifier, Data(identity2.pairingID.utf8)),
            TLV8.Item(.publicKey, identity2.ltpk),
            TLV8.Item(.signature, deviceSig),
        ])
        let m5enc: Data
        do {
            m5enc = try HAPCrypto.seal(m5sub, key: encKey, nonceLabel: "PS-Msg05")
        } catch {
            throw PairSetupError.cryptoFailed("M5 seal: \(error)")
        }
        let m5 = TLV8.encode([
            TLV8.Item(.state, byte: 0x05),
            TLV8.Item(.encryptedData, m5enc),
        ])
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] → M5 (encryptedData \(m5enc.count)B)")

        let m6resp: AP2RTSPClient.Response
        do {
            m6resp = try await client.post(path: "/pair-setup", body: m5, extraHeaders: hkpHeaders)
        } catch {
            throw PairSetupError.transport(error)
        }
        let m6 = TLV8.decode(m6resp.body)
        try throwIfDeviceError(m6, state: "M6")
        guard let m6enc = TLV8.value(.encryptedData, in: m6) else {
            Log.airplay2.error("pair-setup[\(label, privacy: .public)] M6 raw: \(m6resp.statusLine, privacy: .public) body=\(m6resp.body.count)B")
            throw PairSetupError.missingField("M6 encryptedData")
        }
        let m6sub: [TLV8.Item]
        do {
            m6sub = TLV8.decode(try HAPCrypto.open(m6enc, key: encKey, nonceLabel: "PS-Msg06"))
        } catch {
            throw PairSetupError.cryptoFailed("M6 open: \(error)")
        }
        guard let accIDData = TLV8.value(.identifier, in: m6sub),
              let accLTPK = TLV8.value(.publicKey, in: m6sub),
              let accSig = TLV8.value(.signature, in: m6sub),
              let accID = String(data: accIDData, encoding: .utf8) else {
            throw PairSetupError.missingField("M6 sub-TLV (identifier/publicKey/signature)")
        }

        // Verify AccessoryInfo signature with the accessory's own LTPK.
        let accessoryX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let accessoryInfo = accessoryX + accIDData + accLTPK
        guard let accKey = try? Curve25519.Signing.PublicKey(rawRepresentation: accLTPK),
              accKey.isValidSignature(accSig, for: accessoryInfo) else {
            throw PairSetupError.accessorySignature
        }

        let pairing = AP2Pairing(
            deviceID: deviceID ?? descriptor.displayName,
            accessoryPairingID: accID,
            accessoryLTPK: accLTPK
        )
        Log.airplay2.notice("pair-setup[\(label, privacy: .public)] ← M6 ✓ — LONG-TERM PAIRING ESTABLISHED (accessory \(accID, privacy: .public), LTPK \(accLTPK.count)B)")
        return Result(sessionKey: K, sharedSecret: srp.padPublic(S), pairing: pairing)
    }

    // MARK: - Helpers

    private static func throwIfDeviceError(_ items: [TLV8.Item], state: String) throws {
        if let code = TLV8.byte(.error, in: items) {
            Log.airplay2.error("pair-setup \(state, privacy: .public): receiver error code=\(code)")
            throw PairSetupError.deviceError(code, stateLabel: state)
        }
    }

    /// Cryptographically random scalar in [0, 2^(8·byteCount)).
    static func randomScalar(byteCount: Int) -> BigUInt {
        var bytes = Data(count: byteCount)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        return BigUInt(bytes)
    }
}
