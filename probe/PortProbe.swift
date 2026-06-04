// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
//
// PortProbe — fan out UDP probes to a list of ports on a target host and
// classify each one as open / closed / filtered based on ICMP feedback.
//
// Build + run:
//   swiftc -O probe/PortProbe.swift -o probe/PortProbe
//   probe/PortProbe 192.168.1.105 1269 1270 1271 5000 7000
//
// How UDP port classification works (the BSD socket trick — no sudo needed):
//   1. Create a UDP socket, `connect()` it to the destination. This makes the
//      kernel deliver ICMP errors back to *this* socket.
//   2. Send a probe payload.
//   3. Set a short receive timeout. Try to recv():
//        bytes returned        → speaker responded — port is "open + replying"
//        errno = ECONNREFUSED  → kernel delivered ICMP unreachable — "closed"
//        errno = EAGAIN/TIMEDOUT → nothing came back — "open|filtered"
//                                  (typical AirPlay 1 / RAOP listeners)
//   The "open|filtered" result is what we expect for valid RAOP UDP ports
//   that silently swallow our probe. The "closed" result is the smoking gun
//   we're looking for.

import Foundation
import Darwin

// MARK: - Args

guard CommandLine.arguments.count >= 3 else {
    print("usage: PortProbe <host> <port1> [port2] [port3] ...")
    print("example: PortProbe 192.168.1.105 1269 1270 1271 5000 7000")
    exit(2)
}
let host = CommandLine.arguments[1]
let ports: [UInt16] = CommandLine.arguments.dropFirst(2).compactMap { UInt16($0) }
guard !ports.isEmpty else { print("no valid ports"); exit(2) }

print("Probing UDP on \(host) for ports: \(ports.map(String.init).joined(separator: ", "))")
print(String(repeating: "─", count: 80))

// MARK: - NTP-style probe payload (PT 0xD2 timing request, 32 bytes)
//
// The B&W A7's timing port (1271) is known to accept this exact packet
// shape during normal RAOP operation. Sending it to other RAOP-related
// ports either gets silently swallowed (port is open) or rejected via
// ICMP unreachable (port is closed). Audio/control ports will swallow,
// not reply — that's still the "open|filtered" diagnostic.

func ntpProbePayload() -> Data {
    var p = Data(count: 32)
    p[0] = 0x80                   // RTP V2
    p[1] = 0xD2                   // PT 0x52 (TIMING_REQ) with marker bit set
    p[2] = 0x00; p[3] = 0x07      // sequence number (arbitrary)
    // The rest can be zero — receiver only reads the transmit timestamp
    // at offset 24..31 for round-trip computation, but probe doesn't need it.
    return p
}

let payload = ntpProbePayload()
let recvTimeoutSec: Int = 1

// MARK: - Per-port probe

enum Result { case openReplied(Int), filteredSilent, closedICMP, sendFailed(String), bindFailed(String) }

func probe(host: String, port: UInt16) -> Result {
    let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard sock >= 0 else { return .bindFailed("socket() failed: errno=\(errno)") }
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
        return .bindFailed("invalid host \(host)")
    }

    // connect() so kernel delivers ICMP unreachable back to this socket.
    let connectOK = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            Darwin.connect(sock, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectOK == 0 else { return .sendFailed("connect() failed: errno=\(errno)") }

    // Set receive timeout.
    var tv = timeval(tv_sec: recvTimeoutSec, tv_usec: 0)
    _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Send probe.
    let sent = payload.withUnsafeBytes { buf -> Int in
        Darwin.send(sock, buf.baseAddress, payload.count, 0)
    }
    guard sent > 0 else { return .sendFailed("send() failed: errno=\(errno)") }

    // Try to receive. ICMP errors flow through to the connected UDP socket
    // as errno == ECONNREFUSED on the next recv().
    var rxBuf = [UInt8](repeating: 0, count: 256)
    let n = rxBuf.withUnsafeMutableBufferPointer { buf -> Int in
        Darwin.recv(sock, buf.baseAddress, buf.count, 0)
    }

    if n > 0 {
        return .openReplied(n)
    }
    // n == -1 from recv()
    switch errno {
    case ECONNREFUSED:                 return .closedICMP
    case EAGAIN, EWOULDBLOCK, ETIMEDOUT: return .filteredSilent
    default:                           return .sendFailed("recv() failed: errno=\(errno)")
    }
}

// MARK: - Print results

func render(_ result: Result) -> String {
    switch result {
    case .openReplied(let n):       return "✓ OPEN — got \(n)-byte reply"
    case .filteredSilent:           return "◌ open|filtered — silent (likely listening, no reply)"
    case .closedICMP:               return "✗ CLOSED — ICMP port unreachable"
    case .sendFailed(let m):        return "! send error — \(m)"
    case .bindFailed(let m):        return "! setup error — \(m)"
    }
}

for port in ports {
    let result = probe(host: host, port: port)
    let line = String(format: "  UDP %5d  %@", Int(port), render(result) as CVarArg)
    print(line)
}

print(String(repeating: "─", count: 80))
print("Legend:")
print("  ✓ OPEN          — speaker replied to our probe (timing/RTSP-like)")
print("  ◌ open|filtered — silent acceptance (typical RAOP audio/control)")
print("  ✗ CLOSED        — speaker said 'no listener here' — SMOKING GUN")
