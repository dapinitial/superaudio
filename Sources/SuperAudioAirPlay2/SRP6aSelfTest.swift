// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import BigInt

/// Offline correctness check for `SRP6aClient` against the **RFC 5054
/// Appendix B** published test vectors (1024-bit group, SHA-1). The project
/// has no XCTest harness (POC norm — "audio out the speaker is the test"), so
/// this in-code self-test is the regression guard for the pairing crypto.
///
/// What it proves, with the *same code path* HomeKit pair-setup uses (only the
/// group + hash differ):
///  - `x = H(s | H(I:P))` matches the RFC's published `x` → hashing/encoding
///    conventions are byte-correct.
///  - `u = H(PAD(A) | PAD(B))` matches the RFC's published `u` → the PAD()
///    width logic is correct.
///  - the client premaster `S` equals the independently-computed server
///    premaster `S = (A·v^u)^b mod N` → the full modular arithmetic agrees
///    end-to-end (the property the whole protocol rests on).
public enum SRP6aSelfTest {

    public static func runRFC5054() -> (ok: Bool, detail: String) {
        let c = SRP6aClient(group: .rfc5054_1024, alg: .sha1)
        let N = SRP6aClient.Group.rfc5054_1024.N
        let g = SRP6aClient.Group.rfc5054_1024.g

        let I = "alice", P = "password123"
        let s = hex("BEB25379D1A8581EB5A727673A2441EE")
        let a = BigUInt("60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393", radix: 16)!
        let b = BigUInt("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20", radix: 16)!
        let expectedX = BigUInt("94B7555AABE9127CC58CCF4993DB6CF84D16C124", radix: 16)!
        let expectedU = BigUInt("CE38B9593487DA98554ED47D70A7AE5F462EF019", radix: 16)!

        // 1. x convention
        let x = c.computeX(identity: I, password: P, salt: s)
        guard x == expectedX else {
            return (false, "x mismatch: got \(String(x, radix: 16))")
        }

        // 2. server-side verifier + public B (mirrors RFC roles)
        let v = g.power(x, modulus: N)
        let A = c.publicA(privateA: a)
        let k = c.multiplierK
        let B = (k * v + g.power(b, modulus: N)) % N

        // 3. u convention (depends on PAD of A and B)
        let u = c.computeU(A: A, B: B)
        guard u == expectedU else {
            return (false, "u mismatch: got \(String(u, radix: 16))")
        }

        // 4. premaster agreement (the cryptographic property)
        guard let clientS = try? c.premaster(identity: I, password: P, salt: s, privateA: a, serverB: B) else {
            return (false, "client premaster threw")
        }
        let serverS = ((A * v.power(u, modulus: N)) % N).power(b, modulus: N)
        guard clientS == serverS else {
            return (false, "premaster mismatch:\n  client \(String(clientS, radix: 16))\n  server \(String(serverS, radix: 16))")
        }

        return (true, "x✓ u✓ premaster✓ (client==server, \(c.pad(clientS).count)-byte S)")
    }

    private static func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
}
