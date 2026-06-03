// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import SuperAudioCore

/// Minimal UPnP/SOAP client for Sonos devices.
///
/// Phase 1 sub-task: implements only `GetTransportInfo` for a protocol-sanity
/// check (equivalent to RAOP's `OPTIONS` — "are you reachable, awake, and
/// responsive"). Phase 3 sub-tasks add `SetAVTransportURI`, `Play`, `Pause`,
/// `Stop`, and the local HTTP audio server feeding the actual stream.
///
/// SOAP envelopes are lifted verbatim from SoCo (MIT — see THIRD_PARTY_NOTICES).
public final class SonosClient: @unchecked Sendable {

    public struct TransportInfo: Sendable {
        public let currentTransportState: String      // e.g., "STOPPED", "PLAYING"
        public let currentTransportStatus: String     // e.g., "OK"
        public let currentSpeed: String               // e.g., "1"
        public let raw: String                        // full XML body, for debugging
    }

    /// Result of `getPositionInfo()` — what AVTransport says about the
    /// current playback position. For continuous internet-radio streams
    /// (our `x-rincon-mp3radio://` URI scheme), `relTimeSeconds` is the
    /// number of seconds the Sonos has been actively playing audio,
    /// resetting to 0 on each new `SetAVTransportURI` + `Play`.
    ///
    /// Used by M11 Path A sibling — Sonos-position auto-align (#104).
    /// `sonos_actual_lag = (wall_now - playStartTime) - relTimeSeconds`.
    public struct PositionInfo: Sendable {
        public let relTimeSeconds: Double      // parsed from <RelTime>HH:MM:SS</RelTime>
        public let trackURI: String            // parsed from <TrackURI>
        public let raw: String                 // full XML body, for debugging
    }

    public enum SonosClientError: Error, CustomStringConvertible {
        case missingHost
        case httpError(Int, String)
        case transportFailed(String)
        case parseFailed(String)

        public var description: String {
            switch self {
            case .missingHost:           return "Sonos sink has no host in its descriptor"
            case .httpError(let c, let b): return "Sonos HTTP \(c): \(b)"
            case .transportFailed(let m): return "Sonos transport failed: \(m)"
            case .parseFailed(let m):    return "Sonos parse failed: \(m)"
            }
        }
    }

    public let descriptor: SinkDescriptor

    public init(descriptor: SinkDescriptor) {
        self.descriptor = descriptor
    }

    /// Point the speaker at an HTTP audio URL. For Internet radio streams,
    /// prefix with `x-rincon-mp3radio:` so Sonos treats it as a continuous
    /// stream rather than a finite track.
    @discardableResult
    public func setAVTransportURI(_ uri: String, metadata: String = "", timeout: TimeInterval = 5) async throws -> TransportInfo {
        // Escape XML special chars in the URI to keep the SOAP envelope valid.
        let escapedURI = uri
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escapedURI)</CurrentURI>
              <CurrentURIMetaData>\(metadata)</CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        return try await sendSOAP(action: "SetAVTransportURI", body: body, timeout: timeout)
    }

    /// Start playback of whatever URI was last `SetAVTransportURI`'d.
    @discardableResult
    public func play(speed: String = "1", timeout: TimeInterval = 5) async throws -> TransportInfo {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <Speed>\(speed)</Speed>
            </u:Play>
          </s:Body>
        </s:Envelope>
        """
        return try await sendSOAP(action: "Play", body: body, timeout: timeout)
    }

    /// Set the speaker's master volume to a 0–100 integer percentage. Sonos's
    /// `RenderingControl::SetVolume` action lives on a different service path
    /// than the `AVTransport` actions above (Sonos exposes multiple services
    /// off the same `/MediaRenderer/...` host).
    ///
    /// Safe to call mid-stream — Sonos accepts volume changes while audio is
    /// flowing and applies them within ~50 ms (audible step) without
    /// interrupting the stream.
    @discardableResult
    public func setVolume(_ percent: Int, channel: String = "Master", timeout: TimeInterval = 5) async throws -> TransportInfo {
        let clamped = max(0, min(100, percent))
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>\(channel)</Channel>
              <DesiredVolume>\(clamped)</DesiredVolume>
            </u:SetVolume>
          </s:Body>
        </s:Envelope>
        """
        return try await sendRenderingControl(action: "SetVolume", body: body, timeout: timeout)
    }

    /// Stop playback. The transport state goes back to STOPPED.
    @discardableResult
    public func stop(timeout: TimeInterval = 5) async throws -> TransportInfo {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:Stop>
          </s:Body>
        </s:Envelope>
        """
        return try await sendSOAP(action: "Stop", body: body, timeout: timeout)
    }

    /// Query the Sonos's current playback position via AVTransport.
    /// `RelTime` is the elapsed playback time within the current stream
    /// (HH:MM:SS). For continuous internet-radio URIs, it resets on each
    /// new `SetAVTransportURI + Play` and ticks up at real-time rate.
    ///
    /// Used to measure Sonos's actual playback lag without a microphone:
    /// `sonos_lag = (now - play_wall_time) - relTimeSeconds`.
    public func getPositionInfo(timeout: TimeInterval = 5) async throws -> PositionInfo {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetPositionInfo>
          </s:Body>
        </s:Envelope>
        """
        guard !descriptor.endpoint.host.isEmpty else {
            throw SonosClientError.missingHost
        }
        let urlString = "http://\(descriptor.endpoint.host):\(descriptor.endpoint.port)/MediaRenderer/AVTransport/Control"
        guard let url = URL(string: urlString) else {
            throw SonosClientError.missingHost
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)

        let label = descriptor.displayName
        Log.sonos.info("SOAP[\(label, privacy: .public)] → GetPositionInfo")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SonosClientError.parseFailed("non-HTTP response")
        }
        let respBody = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw SonosClientError.httpError(http.statusCode, respBody)
        }
        let relTimeStr = extractField("RelTime", from: respBody) ?? "0:00:00"
        let trackURI = extractField("TrackURI", from: respBody) ?? ""
        let relSec = Self.parseHHMMSS(relTimeStr) ?? 0
        Log.sonos.info("SOAP[\(label, privacy: .public)] ← GetPositionInfo 200 OK relTime=\(relTimeStr, privacy: .public) (\(String(format: "%.3f", relSec), privacy: .public)s)")
        return PositionInfo(relTimeSeconds: relSec, trackURI: trackURI, raw: respBody)
    }

    /// Parse `HH:MM:SS` (or `H:MM:SS`, occasionally fractional) into seconds.
    /// Sonos returns `0:00:00` before playback starts, ticks up from there.
    static func parseHHMMSS(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Sends `GetTransportInfo` against the Sonos's `AVTransport` service.
    /// Returns the current playback state. No audio implied — just confirms
    /// our SOAP envelope is correct and the speaker is responsive.
    public func getTransportInfo(timeout: TimeInterval = 5) async throws -> TransportInfo {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetTransportInfo>
          </s:Body>
        </s:Envelope>
        """
        return try await sendSOAP(action: "GetTransportInfo", body: body, timeout: timeout)
    }

    /// Shared SOAP POST helper. All `AVTransport:1` actions on Sonos go to
    /// `/MediaRenderer/AVTransport/Control` with a `SOAPAction` header
    /// naming the action.
    private func sendSOAP(action: String, body: String, timeout: TimeInterval) async throws -> TransportInfo {
        try await postSOAP(
            servicePath: "/MediaRenderer/AVTransport/Control",
            serviceURN: "urn:schemas-upnp-org:service:AVTransport:1",
            action: action,
            body: body,
            timeout: timeout
        )
    }

    /// Twin of `sendSOAP` for the `RenderingControl:1` service. Same envelope
    /// shape, different service path + URN.
    private func sendRenderingControl(action: String, body: String, timeout: TimeInterval) async throws -> TransportInfo {
        try await postSOAP(
            servicePath: "/MediaRenderer/RenderingControl/Control",
            serviceURN: "urn:schemas-upnp-org:service:RenderingControl:1",
            action: action,
            body: body,
            timeout: timeout
        )
    }

    /// Underlying SOAP POST. Both AVTransport and RenderingControl share this.
    private func postSOAP(servicePath: String, serviceURN: String, action: String, body: String, timeout: TimeInterval) async throws -> TransportInfo {
        guard !descriptor.endpoint.host.isEmpty else {
            throw SonosClientError.missingHost
        }
        let urlString = "http://\(descriptor.endpoint.host):\(descriptor.endpoint.port)\(servicePath)"
        guard let url = URL(string: urlString) else {
            throw SonosClientError.missingHost
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceURN)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)

        let label = descriptor.displayName
        Log.sonos.info("SOAP[\(label, privacy: .public)] → \(action, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SonosClientError.parseFailed("non-HTTP response")
        }
        let respBody = String(data: data, encoding: .utf8) ?? ""

        guard http.statusCode == 200 else {
            throw SonosClientError.httpError(http.statusCode, respBody)
        }

        let state  = extractField("CurrentTransportState", from: respBody)  ?? "?"
        let status = extractField("CurrentTransportStatus", from: respBody) ?? "?"
        let speed  = extractField("CurrentSpeed", from: respBody)            ?? "?"

        Log.sonos.info("SOAP[\(label, privacy: .public)] ← \(action, privacy: .public) 200 OK state=\(state, privacy: .public)")

        return TransportInfo(
            currentTransportState: state,
            currentTransportStatus: status,
            currentSpeed: speed,
            raw: respBody
        )
    }

    private func extractField(_ field: String, from xml: String) -> String? {
        let pattern = "<\(field)>(.*?)</\(field)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let r = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
