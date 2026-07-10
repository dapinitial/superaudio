// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Darwin
import SuperAudioCore

/// AirPlay 2 realtime **control-port RTCP sender**. Periodically sends
/// `TIME_ANNOUNCE_PTP` (RTCP type 0xD7, 28 bytes) to the receiver's control
/// port — the ongoing "RTP timestamp X corresponds to PTP time T" mapping the
/// receiver needs to actually render the audio. SETRATEANCHORTIME is the
/// one-shot anchor; this is the continuous sync. Without it the receiver can
/// accept the stream but never start playback.
///
/// Packet layout (from the openairplay receiver's parser; facts, fresh Swift):
///   [0]=0x80 [1]=0xD7 [2:4]=0x0006 (dwords) [4:8]=senderRtpTimestamp (BE u32)
///   [8:16]=monotonic_ns / PTP time (BE u64) [16:20]=playAtRtpTimestamp (BE u32)
///   [20:28]=PTP grandmaster clockIdentity (8B)
public final class AP2ControlSender: @unchecked Sendable {

    private let peerHost: String
    private let peerPort: UInt16          // receiver's controlPort
    private let localPort: UInt16         // our declared controlPort
    private let clockID: Data             // PTP GM clock identity (8B)
    private let bufferSamples: UInt32     // playback lag (sender is ahead by this)

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.control")
    private var timer: DispatchSourceTimer?
    private var currentRTP: () -> UInt32  // live read of the RTP sender's timestamp

    public init(peerHost: String, peerControlPort: Int, localControlPort: Int,
                clockIdentity: Data, bufferSamples: UInt32,
                currentRTPTimestamp: @escaping () -> UInt32) {
        self.peerHost = peerHost
        self.peerPort = UInt16(peerControlPort)
        self.localPort = UInt16(localControlPort)
        self.clockID = clockIdentity
        self.bufferSamples = bufferSamples
        self.currentRTP = currentRTPTimestamp
    }

    public func start() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 {
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = INADDR_ANY
            addr.sin_port = localPort.bigEndian
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        // Send one immediately, then ~4×/sec (matches PTP sync cadence).
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.sendTimeAnnounce() }
        t.resume()
        timer = t
        let (h, p) = (peerHost, peerPort)
        Log.airplay2.notice("AP2 control RTCP → \(h, privacy: .public):\(p) (TIME_ANNOUNCE_PTP @4Hz)")
    }

    private func sendTimeAnnounce() {
        let sender = currentRTP()
        let playAt = sender &- bufferSamples
        let ptp = AP2PTP.nowPTPNanos()

        var pkt = Data(count: 28)
        pkt[0] = 0x80; pkt[1] = 0xD7
        pkt[2] = 0x00; pkt[3] = 0x06                      // length = 6 dwords → 28B
        putBE32(&pkt, 4, sender)                          // senderRtpTimestamp
        putBE64(&pkt, 8, ptp)                             // monotonic_ns (PTP time)
        putBE32(&pkt, 16, playAt)                         // playAtRtpTimestamp
        pkt.replaceSubrange(20..<28, with: clockID)       // PTP GM clockIdentity

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = peerPort.bigEndian
        inet_pton(AF_INET, peerHost, &addr.sin_addr)
        _ = pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, pkt.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func putBE32(_ d: inout Data, _ off: Int, _ v: UInt32) {
        d[off] = UInt8((v >> 24) & 0xFF); d[off+1] = UInt8((v >> 16) & 0xFF)
        d[off+2] = UInt8((v >> 8) & 0xFF); d[off+3] = UInt8(v & 0xFF)
    }
    private func putBE64(_ d: inout Data, _ off: Int, _ v: UInt64) {
        for i in 0..<8 { d[off+i] = UInt8((v >> (56 - i*8)) & 0xFF) }
    }
}
