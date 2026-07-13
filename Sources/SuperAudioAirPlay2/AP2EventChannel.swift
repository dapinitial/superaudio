// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Network
import CryptoKit
import SuperAudioCore

/// AirPlay 2 **event channel** — a persistent TCP connection the sender opens
/// to the receiver's `eventPort` (returned by SETUP phase 1) right after SETUP.
/// Real senders (pyatv) always connect it; the Apple TV appears to require it
/// to actually enter "now playing" / start audio playback — without it the
/// receiver accepts the audio stream but never plays it.
///
/// Encrypted with the pair-verify shared secret via HKDF-SHA512 (constants from
/// pyatv `airplayv2.py`): `Events-Salt` + `Events-Read/Write-Encryption-Key`.
/// Same ChaCha20-Poly1305 length-prefixed framing as the control channel. The
/// receiver drives it (pushes events); we mostly just need it open + draining.
public final class AP2EventChannel: @unchecked Sendable {

    private let host: String
    private let port: UInt16
    private let outKey: SymmetricKey     // we encrypt outgoing with this
    private let inKey: SymmetricKey      // we decrypt incoming with this
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.event")
    private var connection: NWConnection?
    private var inCount: UInt64 = 0
    private var outCount: UInt64 = 0
    private var inBuffer = Data()

    /// Derive the event-channel keys from the pair-verify X25519 shared secret.
    /// Note the swap vs the control channel: the sender's OUTPUT uses the
    /// "Read" info and INPUT uses "Write" (the receiver is the event writer).
    public init(host: String, port: Int, sharedSecret: Data) {
        self.host = host
        self.port = UInt16(port)
        self.outKey = SymmetricKey(data: HAPCrypto.hkdf(sharedSecret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"))
        self.inKey = SymmetricKey(data: HAPCrypto.hkdf(sharedSecret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
    }

    public func connect() async throws {
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: ep, using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { st in
                guard !resumed else { return }
                switch st {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                case .cancelled: resumed = true; cont.resume(throwing: NWError.posix(.ECONNABORTED))
                default: break
                }
            }
            conn.start(queue: queue)
        }
        self.connection = conn
        Log.airplay2.notice("AP2 event channel connected → \(self.host, privacy: .public):\(self.port)")
        startDraining()
    }

    /// Read + decrypt incoming event frames and discard them. Keeping the
    /// socket drained (and the connection open) is what the receiver needs.
    private func startDraining() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inBuffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                Log.airplay2.info("AP2 event channel closed (\(error.map { "\($0)" } ?? "EOF", privacy: .public))")
                return
            }
            self.startDraining()
        }
    }

    private func drainFrames() {
        var bytes = [UInt8](inBuffer)
        var consumed = 0
        while bytes.count - consumed >= 2 {
            let len = Int(UInt16(bytes[consumed]) | (UInt16(bytes[consumed + 1]) << 8))
            let total = 2 + len + 16
            guard bytes.count - consumed >= total else { break }
            let lenData = Data(bytes[consumed..<consumed + 2])
            let ct = Data(bytes[(consumed + 2)..<(consumed + 2 + len)])
            let tag = Data(bytes[(consumed + 2 + len)..<(consumed + total)])
            var c = inCount.littleEndian
            let nonce = Data(repeating: 0, count: 4) + withUnsafeBytes(of: &c) { Data($0) }
            if let box = try? ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonce), ciphertext: ct, tag: tag),
               let plain = try? ChaChaPoly.open(box, using: inKey, authenticating: lenData) {
                inCount &+= 1
                // The receiver pushes RTSP-style event requests; reply 200 OK
                // (echo CSeq) so it keeps the channel open. Silence → the ATV
                // hangs up (EOF), which may drop us out of play mode.
                respond200(toRequest: plain)
            }
            consumed += total
        }
        if consumed > 0 { bytes.removeFirst(consumed); inBuffer = Data(bytes) }
    }

    private func respond200(toRequest plain: Data) {
        let text = String(data: plain, encoding: .utf8) ?? ""
        var cseq = "0"
        for line in text.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("cseq:") {
                cseq = line.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "0"
            }
        }
        let reply = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nServer: AirTunes/550.10\r\nContent-Length: 0\r\nAudio-Latency: 0\r\n\r\n"
        sendEncrypted(Data(reply.utf8))
    }

    private func sendEncrypted(_ plaintext: Data) {
        guard let connection else { return }
        var lenLE = UInt16(plaintext.count).littleEndian
        let lenData = withUnsafeBytes(of: &lenLE) { Data($0) }
        var c = outCount.littleEndian
        let nonce = Data(repeating: 0, count: 4) + withUnsafeBytes(of: &c) { Data($0) }
        guard let box = try? ChaChaPoly.seal(plaintext, using: outKey,
                                             nonce: try ChaChaPoly.Nonce(data: nonce),
                                             authenticating: lenData) else { return }
        outCount &+= 1
        connection.send(content: lenData + box.ciphertext + box.tag, completion: .idempotent)
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }
}
