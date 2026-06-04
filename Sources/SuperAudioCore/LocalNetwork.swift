// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Darwin

/// Shared LAN networking utilities used by every protocol module.
public enum LocalNetwork {

    /// Best-effort primary LAN IPv4 address on the active interface.
    /// Used in SDP `o=` / `c=` lines for AirPlay 1, and in the
    /// `SetAVTransportURI` URL for Sonos. Returns the first non-loopback
    /// IPv4 address found across all enabled interfaces.
    ///
    /// Skips `lo*`, `awdl*`, `llw*`, `utun*`, `bridge*` — these are
    /// loopback/AirDrop/VPN/Thunderbolt-bridge interfaces that won't be
    /// reachable from a Sonos / B&W speaker on the home WiFi.
    public static func primaryLocalIPv4() -> String? {
        var result: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor {
            cursor = iface.pointee.ifa_next
            guard let addr = iface.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let nameC = iface.pointee.ifa_name
            let name = nameC.map { String(cString: $0) } ?? ""
            // Skip interfaces that can't reach the home LAN.
            if name.hasPrefix("lo") { continue }
            if name.hasPrefix("awdl") { continue }
            if name.hasPrefix("llw") { continue }
            if name.hasPrefix("utun") { continue }
            if name.hasPrefix("bridge") { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let ip = String(cString: host)
                // Prefer the first interface we find; usually en0.
                if result == nil {
                    result = ip
                }
            }
        }
        return result
    }
}
