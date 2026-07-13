// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Network
import CryptoKit
import SuperAudioCore

/// AirPlay 2 realtime (type 96) RTP audio sender. Pushes raw-PCM frames to the
/// receiver's negotiated `dataPort`, each frame in one ChaCha20-Poly1305-sealed
/// RTP packet.
///
/// Packet wire layout (per the openairplay airplay2-receiver reference; facts,
/// fresh Swift):
///
///   [12B RTP header][ciphertext][16B Poly1305 tag][8B nonce]
///
///   RTP header: 0x80 | 0x60(+marker) | seq(2, BE) | timestamp(4, BE) | ssrc(4, BE)
///   AAD  = header[4..12]  (timestamp ‖ ssrc)
///   nonce(12) = 4 zero bytes ‖ the 8 trailing packet bytes (matches control-
///               channel convention; the exact padding is a hardware-tuned knob)
///
/// The RTP timestamp advances by `spf` (352) samples per packet; the receiver
/// maps it to the PTP timeline anchored by SETRATEANCHORTIME.
public final class AP2RTPSender: @unchecked Sendable {

    public struct Config {
        public let host: String
        public let dataPort: Int
        public let key: Data          // shk from SETUP phase 2 (32B)
        public let ssrc: UInt32
        public let spf: Int           // samples per frame (352)
        public init(host: String, dataPort: Int, key: Data, ssrc: UInt32, spf: Int = 352) {
            self.host = host; self.dataPort = dataPort; self.key = key; self.ssrc = ssrc; self.spf = spf
        }
    }

    private let config: Config
    private let symKey: SymmetricKey
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.rtp")
    private var connection: NWConnection?

    private var sequence: UInt16 = 0
    private var rtpTimestamp: UInt32
    private var packetCount: UInt64 = 0
    private var firstPacket = true

    /// Nonce padding variant — the 8-byte packet nonce is padded to ChaCha's
    /// 12 bytes. Leading zeros (4 zero bytes ‖ counter) matches the control
    /// channel's proven convention; that's the default now that the PTP clock
    /// is fixed (trailing zeros gave silence).
    public var nonceZerosLeadPadding = true

    public init(config: Config, startTimestamp: UInt32) {
        self.config = config
        self.symKey = SymmetricKey(data: config.key)
        self.rtpTimestamp = startTimestamp
    }

    public func connect() async throws {
        let ep = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: UInt16(config.dataPort))!
        )
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: ep, using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { st in
                guard !resumed else { return }
                switch st {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            conn.start(queue: queue)
        }
        self.connection = conn
        let (h, p, sr, ts) = (config.host, config.dataPort, config.ssrc, rtpTimestamp)
        Log.airplay2.notice("AP2 RTP → udp \(h, privacy: .public):\(p) ssrc=\(sr) startTS=\(ts)")
    }

    /// Send one PCM frame (`spf` samples, 16-bit stereo interleaved) as one RTP
    /// packet. Advances sequence + timestamp.
    public func sendFrame(_ pcm: Data) {
        guard let connection else { return }
        var header = Data(count: 12)
        header[0] = 0x80
        // PT 97 (0x61) — Apple's AirPlay 2 realtime ALAC uses payload type 97,
        // NOT 96 (confirmed from a working macOS-sender capture). Marker bit on
        // the first packet.
        header[1] = firstPacket ? 0xE1 : 0x61
        firstPacket = false
        header[2] = UInt8(sequence >> 8); header[3] = UInt8(sequence & 0xFF)
        let ts = rtpTimestamp
        header[4] = UInt8((ts >> 24) & 0xFF); header[5] = UInt8((ts >> 16) & 0xFF)
        header[6] = UInt8((ts >> 8) & 0xFF); header[7] = UInt8(ts & 0xFF)
        let s = config.ssrc
        header[8] = UInt8((s >> 24) & 0xFF); header[9] = UInt8((s >> 16) & 0xFF)
        header[10] = UInt8((s >> 8) & 0xFF); header[11] = UInt8(s & 0xFF)

        let aad = header.subdata(in: 4..<12)

        // 8-byte packet nonce (big-endian counter), padded to 12 for ChaChaPoly.
        var counter = packetCount.bigEndian
        let nonce8 = withUnsafeBytes(of: &counter) { Data($0) }
        let nonce12 = nonceZerosLeadPadding ? (Data(repeating: 0, count: 4) + nonce8) : (nonce8 + Data(repeating: 0, count: 4))

        do {
            let box = try ChaChaPoly.seal(pcm, using: symKey,
                                          nonce: try ChaChaPoly.Nonce(data: nonce12),
                                          authenticating: aad)
            var packet = header
            packet.append(box.ciphertext)
            packet.append(box.tag)          // 16B
            packet.append(nonce8)           // 8B trailing nonce
            connection.send(content: packet, completion: .idempotent)
        } catch {
            Log.airplay2.error("AP2 RTP seal failed: \(String(describing: error), privacy: .public)")
        }

        sequence &+= 1
        rtpTimestamp &+= UInt32(config.spf)
        packetCount &+= 1
        if packetCount % 200 == 0 {
            // ALAC payload size is the silent-vs-real-audio tell: silence
            // compresses to ~tens of bytes, real music is hundreds+.
            let (pc, sz) = (packetCount, pcm.count)
            let kind = sz < 64 ? "SILENT SOURCE (nothing playing on the Mac?)" : "real audio"
            Log.airplay2.notice("AP2 RTP sent \(pc) packets — last ALAC payload \(sz)B → \(kind, privacy: .public)")
        }
    }

    public var currentTimestamp: UInt32 { rtpTimestamp }

    public func stop() {
        connection?.cancel()
        connection = nil
    }
}
