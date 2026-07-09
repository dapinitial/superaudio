// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Darwin
import SuperAudioCore

/// AirPlay 2 **PTP grandmaster** (IEEE-1588, Apple vendor profile). In AirPlay 2
/// the *sender* is the grandmaster and receivers slave to it; modern tvOS
/// requires this (it rejects the legacy NTP path — see gotcha #29).
///
/// Profile facts (from nqptp, read-only GPL reference; fresh Swift): domain 0,
/// two-step, End-to-End delay, UNICAST on ports 319 (event: Sync/Delay_Req) and
/// 320 (general: Announce/Follow_Up/Delay_Resp). We emit Announce @1 s and
/// Sync + matching Follow_Up @125 ms carrying the Sync's egress time as a
/// 48-bit-seconds / 32-bit-nanoseconds `preciseOriginTimestamp`, and answer any
/// Delay_Req with a Delay_Resp. `clockIdentity` = the sender MAC with 0xFFFE
/// inserted (EUI-48 → EUI-64).
///
/// POSIX UDP (not Network.framework) because PTP requires send-port == recv-port
/// symmetry on 319/320 — cleanest with a plain bound datagram socket. NOTE: 319
/// and 320 are privileged (<1024); binding them needs root, so the dev loop must
/// run the binary with sudo. Binding failure is logged, not fatal.
public final class AP2PTP: @unchecked Sendable {

    public let clockIdentity: Data     // 8-byte EUI-64
    private let peerHost: String       // receiver IP (unicast target)
    private let domain: UInt8 = 0

    private var eventFD: Int32 = -1    // port 319
    private var generalFD: Int32 = -1  // port 320
    private var peerAddr: sockaddr_in = sockaddr_in()

    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.ptp")
    private var timer: DispatchSourceTimer?
    private var eventSource: DispatchSourceRead?
    private var running = false

    private var announceSeq: UInt16 = 0
    private var syncSeq: UInt16 = 0
    private var tickCount: UInt64 = 0
    private var rxLogCount: UInt64 = 0

    // Monotonic PTP clock. Epoch is arbitrary (receiver treats it as a timeline);
    // SETRATEANCHORTIME must anchor against THIS same clock.
    private static var timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()
    public static func nowPTPNanos() -> UInt64 {
        let t = mach_absolute_time()
        return t &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public init(senderMAC: String, peerHost: String) {
        self.peerHost = peerHost
        self.clockIdentity = Self.eui64(fromMAC: senderMAC)
    }

    /// MAC "AA:BB:CC:DD:EE:FF" → EUI-64 AA BB CC FF FE DD EE FF.
    static func eui64(fromMAC mac: String) -> Data {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return Data(repeating: 0, count: 8) }
        return Data([bytes[0], bytes[1], bytes[2], 0xFF, 0xFE, bytes[3], bytes[4], bytes[5]])
    }

    // MARK: - Lifecycle

    public func start() throws {
        eventFD = try Self.bindUDP(port: 319)
        generalFD = try Self.bindUDP(port: 320)
        peerAddr = Self.makeSockaddr(host: peerHost, port: 319)
        running = true

        // Read Delay_Req on the event socket (319) and answer with Delay_Resp.
        let src = DispatchSource.makeReadSource(fileDescriptor: eventFD, queue: queue)
        src.setEventHandler { [weak self] in self?.handleEventReadable() }
        src.resume()
        eventSource = src

        // 125 ms Sync/Follow_Up cadence; Announce every 8th tick (~1 s).
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(125))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        let (ph, cid) = (peerHost, clockIdentity.map { String(format: "%02x", $0) }.joined())
        Log.airplay2.notice("AP2 PTP grandmaster started — peer \(ph, privacy: .public), clockID \(cid, privacy: .public)")
    }

    public func stop() {
        running = false
        timer?.cancel(); timer = nil
        eventSource?.cancel(); eventSource = nil
        if eventFD >= 0 { close(eventFD); eventFD = -1 }
        if generalFD >= 0 { close(generalFD); generalFD = -1 }
    }

    private func tick() {
        guard running else { return }
        // Announce once per ~1 s (every 8th 125 ms tick).
        if tickCount % 8 == 0 { sendAnnounce() }
        sendSyncAndFollowUp()
        tickCount &+= 1
    }

    // MARK: - Message emission

    private func header(type: UInt8, length: UInt16, seq: UInt16, control: UInt8, logInterval: Int8, flags: UInt16) -> Data {
        var h = Data(count: 34)
        h[0] = 0x10 | (type & 0x0F)          // transportSpecific | messageType
        h[1] = 0x02                          // versionPTP 2
        h[2] = UInt8(length >> 8); h[3] = UInt8(length & 0xFF)
        h[4] = domain
        h[6] = UInt8(flags >> 8); h[7] = UInt8(flags & 0xFF)
        // correctionField (8) @8, reserved(4) @16 — left zero.
        h.replaceSubrange(20..<28, with: clockIdentity)
        h[28] = 0x00; h[29] = 0x01           // sourcePortID = 1
        h[30] = UInt8(seq >> 8); h[31] = UInt8(seq & 0xFF)
        h[32] = control
        h[33] = UInt8(bitPattern: logInterval)
        return h
    }

    /// 10-byte PTP timestamp: 48-bit seconds (BE) + 32-bit nanoseconds (BE).
    private func ptpTimestamp(_ ns: UInt64) -> Data {
        let secs = ns / 1_000_000_000
        let nanos = UInt32(ns % 1_000_000_000)
        var d = Data(count: 10)
        d[0] = UInt8((secs >> 40) & 0xFF); d[1] = UInt8((secs >> 32) & 0xFF)
        d[2] = UInt8((secs >> 24) & 0xFF); d[3] = UInt8((secs >> 16) & 0xFF)
        d[4] = UInt8((secs >> 8) & 0xFF);  d[5] = UInt8(secs & 0xFF)
        d[6] = UInt8((nanos >> 24) & 0xFF); d[7] = UInt8((nanos >> 16) & 0xFF)
        d[8] = UInt8((nanos >> 8) & 0xFF);  d[9] = UInt8(nanos & 0xFF)
        return d
    }

    private func sendSyncAndFollowUp() {
        // Sync on 319 (two-step: origin timestamp zeroed, real time in Follow_Up).
        var sync = header(type: 0x0, length: 44, seq: syncSeq, control: 0x00, logInterval: -3, flags: 0x0200)
        sync.append(Data(count: 10))                 // zero originTimestamp
        let egress = Self.nowPTPNanos()
        sendPacket(sync, fd: eventFD, port: 319)

        // Follow_Up on 320 with the Sync's egress time.
        var fu = header(type: 0x8, length: 44, seq: syncSeq, control: 0x02, logInterval: -3, flags: 0x0000)
        fu.append(ptpTimestamp(egress))
        sendPacket(fu, fd: generalFD, port: 320)
        syncSeq &+= 1
    }

    private func sendAnnounce() {
        var a = header(type: 0xB, length: 64, seq: announceSeq, control: 0x05, logInterval: 0, flags: 0x0408)
        var body = Data()
        body.append(ptpTimestamp(Self.nowPTPNanos()))    // originTimestamp
        body.append(contentsOf: [0x00, 0x25])            // currentUtcOffset = 37
        body.append(0x00)                                // reserved
        body.append(248)                                 // grandmasterPriority1
        body.append(contentsOf: [0xF8, 0xFE, 0x43, 0x6A])// grandmasterClockQuality
        body.append(248)                                 // grandmasterPriority2
        body.append(clockIdentity)                       // grandmasterIdentity
        body.append(contentsOf: [0x00, 0x00])            // stepsRemoved
        body.append(0xA0)                                // timeSource = internal osc
        a.append(body)
        sendPacket(a, fd: generalFD, port: 320)
        announceSeq &+= 1
    }

    // MARK: - Delay_Req → Delay_Resp

    private func handleEventReadable() {
        var buf = [UInt8](repeating: 0, count: 128)
        var from = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(eventFD, &buf, buf.count, 0, sa, &fromLen)
            }
        }
        guard n >= 34 else { return }
        let msgType = buf[0] & 0x0F
        // Log the first few receipts only (Sync arrives ~8×/s — full logging is
        // 125/s noise). The receiver asserting its own Sync is gotcha #33.
        rxLogCount &+= 1
        let c = rxLogCount
        if c <= 4 {
            Log.airplay2.info("AP2 PTP ← rx type=0x\(String(msgType, radix: 16), privacy: .public) len=\(n) on :319 (#\(c))")
        }
        guard msgType == 0x1 else { return }             // Delay_Req only
        let rxTime = Self.nowPTPNanos()
        let reqSeq = (UInt16(buf[30]) << 8) | UInt16(buf[31])
        let reqPortIdentity = Data(buf[20..<30])          // clockId(8) + portId(2)

        var resp = header(type: 0x9, length: 54, seq: reqSeq, control: 0x03, logInterval: 0x7F, flags: 0x0000)
        resp.append(ptpTimestamp(rxTime))                 // receiveTimestamp
        resp.append(reqPortIdentity)                      // requestingPortIdentity
        sendPacket(resp, fd: generalFD, port: 320)
    }

    // MARK: - UDP plumbing

    private func sendPacket(_ data: Data, fd: Int32, port: UInt16) {
        guard fd >= 0 else { return }
        var addr = Self.makeSockaddr(host: peerHost, port: port)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func bindUDP(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PTPError.socket("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = port.bigEndian
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else {
            close(fd)
            throw PTPError.bind("bind() to \(port) failed (errno \(errno)) — ports 319/320 are privileged; run the binary with sudo for PTP")
        }
        return fd
    }

    private static func makeSockaddr(host: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return addr
    }

    public enum PTPError: Error, CustomStringConvertible {
        case socket(String), bind(String)
        public var description: String {
            switch self { case .socket(let m), .bind(let m): return m }
        }
    }
}
