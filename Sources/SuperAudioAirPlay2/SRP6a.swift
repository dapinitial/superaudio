// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CryptoKit
import BigInt

/// SRP-6a client (RFC 5054 / RFC 2945 conventions) — the password-authenticated
/// key agreement at the heart of AirPlay 2 `/pair-setup`. We are always the
/// **client** (the sender); the receiver is the SRP server.
///
/// Implemented fresh in Swift on CryptoKit (hashing) + BigInt (3072-bit modular
/// arithmetic, which neither Swift nor CryptoKit provide). shairport-sync's
/// `pair_ap/` and RFC 5054 read as reference; no code copied. The wire math is
/// a published standard, not copyrightable.
///
/// Parameterized over the group (N, g) and hash so the exact same code path is
/// verifiable against RFC 5054 Appendix B (1024-bit / SHA-1 published vectors)
/// and then instantiated for HomeKit (3072-bit / SHA-512). See `selfTestRFC5054()`.
public struct SRP6aClient {

    public struct Group {
        public let N: BigUInt
        public let g: BigUInt
        /// Byte length of N — the PAD() target width per RFC 5054 §2.6.
        public var width: Int { (N.bitWidth + 7) / 8 }

        public init(N: BigUInt, g: BigUInt) { self.N = N; self.g = g }

        /// RFC 5054 Appendix A 1024-bit group (g = 2). For test vectors only.
        public static let rfc5054_1024 = Group(
            N: BigUInt("""
            EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496\
            EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8E\
            F4AD69B15D4982559B297BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA\
            9AFD5138FE8376435B9FC61D2FC0EB06E3
            """.replacingOccurrences(of: "\n", with: ""), radix: 16)!,
            g: 2
        )

        /// RFC 5054 Appendix A 3072-bit group (g = 5) — the group HomeKit /
        /// AirPlay 2 pair-setup uses, paired with SHA-512.
        public static let rfc5054_3072 = Group(
            N: BigUInt("""
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B\
            139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485\
            B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1F\
            E649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23\
            DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32\
            905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF69558\
            17183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521\
            ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D7\
            1E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B1817\
            7B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82\
            D120A93AD2CAFFFFFFFFFFFFFFFF
            """.replacingOccurrences(of: "\n", with: ""), radix: 16)!,
            g: 5
        )
    }

    public enum HashAlg {
        case sha1, sha512
        func hash(_ data: Data) -> Data {
            switch self {
            case .sha1:   return Data(Insecure.SHA1.hash(data: data))
            case .sha512: return Data(SHA512.hash(data: data))
            }
        }
    }

    let group: Group
    let alg: HashAlg

    public init(group: Group, alg: HashAlg) {
        self.group = group
        self.alg = alg
    }

    // MARK: - Primitives

    /// Big-endian serialization of x, left-padded with zeros to `width` bytes
    /// (RFC 5054 PAD()). No mod-N reduction here: PAD is applied to N itself
    /// (in computing k) where reducing would wrongly yield zero. Callers pass
    /// values already ≤ N (g, A, B, S), so the serialized form never exceeds
    /// `width`.
    func pad(_ x: BigUInt) -> Data {
        let raw = x.serialize()                   // BigUInt.serialize is big-endian, minimal-length
        if raw.count >= group.width { return raw }
        return Data(repeating: 0, count: group.width - raw.count) + raw
    }

    func hashToInt(_ data: Data) -> BigUInt { BigUInt(alg.hash(data)) }

    /// k = H(N | PAD(g))
    var multiplierK: BigUInt { hashToInt(pad(group.N) + pad(group.g)) }

    /// x = H(s | H(I | ":" | P))
    func computeX(identity: String, password: String, salt: Data) -> BigUInt {
        let inner = alg.hash(Data("\(identity):\(password)".utf8))
        return hashToInt(salt + inner)
    }

    /// u = H(PAD(A) | PAD(B))
    func computeU(A: BigUInt, B: BigUInt) -> BigUInt {
        hashToInt(pad(A) + pad(B))
    }

    /// Client public ephemeral A = g^a mod N.
    public func publicA(privateA a: BigUInt) -> BigUInt {
        group.g.power(a, modulus: group.N)
    }

    /// Big-endian, PAD-to-width byte form of a public value (A, B, S) for the
    /// wire (TLV8 publicKey field is fixed at `width` bytes).
    public func padPublic(_ x: BigUInt) -> Data { pad(x) }

    /// Client premaster secret S = (B - k·g^x)^(a + u·x) mod N.
    /// Throws on the SRP safety check B mod N == 0 (a hostile/garbled server).
    public func premaster(identity: String,
                          password: String,
                          salt: Data,
                          privateA a: BigUInt,
                          serverB B: BigUInt) throws -> BigUInt {
        guard B % group.N != 0 else { throw SRPError.badServerPublicKey }
        let N = group.N
        let x = computeX(identity: identity, password: password, salt: salt)
        let u = computeU(A: publicA(privateA: a), B: B)
        let k = multiplierK
        // base = (B - k·g^x) mod N, kept non-negative.
        let gx = group.g.power(x, modulus: N)
        let kgx = (k * gx) % N
        var base = B % N
        if base >= kgx { base -= kgx } else { base = base + N - kgx }
        let exp = a + u * x
        return base.power(exp, modulus: N)
    }

    /// Session key K = H(S). (HomeKit derives further keys via HKDF over K /
    /// the shared secret in pair-verify; pair-setup proofs use K directly.)
    public func sessionKey(premaster S: BigUInt) -> Data {
        alg.hash(pad(S))
    }

    /// Client proof M1 = H( (H(N) XOR H(g)) | H(I) | s | PAD(A) | PAD(B) | K )
    /// — the Stanford SRP-6a / fast-srp-hap convention HomeKit interops with.
    ///
    /// Two subtleties, both load-bearing (verified live vs an Apple TV
    /// 2026-07-08):
    ///  - **A and B are PAD-to-width** here (matching the wire form), same as u.
    ///  - **g is hashed in MINIMAL form** (`serialize()` → a single 0x05 byte),
    ///    NOT PAD(g) — even though the multiplier k = H(N | PAD(g)) pads it.
    ///    Mixing those two g conventions is what made an otherwise-correct
    ///    handshake fail authentication at M4 with the right PIN.
    public func clientProof(identity: String, salt: Data, A: BigUInt, B: BigUInt, sessionKey K: Data) -> Data {
        let hN = alg.hash(pad(group.N))
        let hg = alg.hash(group.g.serialize())
        let hNxorG = Data(zip(hN, hg).map { $0 ^ $1 })
        let hI = alg.hash(Data(identity.utf8))
        return alg.hash(hNxorG + hI + salt + pad(A) + pad(B) + K)
    }

    /// Expected server proof M2 = H( PAD(A) | M1 | K ). The receiver returns
    /// this in pair-setup M4; we recompute and compare to confirm the receiver
    /// also derived the same key (mutual authentication).
    public func expectedServerProof(A: BigUInt, clientProof M1: Data, sessionKey K: Data) -> Data {
        alg.hash(pad(A) + M1 + K)
    }

    public enum SRPError: Error { case badServerPublicKey }
}
