// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CryptoKit
import SuperAudioCore

/// AirPlay 2 **RTSP SETUP** — the two-phase, binary-plist stream negotiation
/// that runs over the pair-verify-encrypted control channel.
///
///   Phase 1 (device/timing): POST SETUP { deviceID, sessionUUID,
///     timingProtocol, our timing port, … }  →  { eventPort, timingPort }
///   Phase 2 (stream):         POST SETUP { streams: [{ type=96 realtime,
///     audioFormat, spf, shk/shiv (our AES key), our controlPort, … }] }
///                             →  { streams: [{ dataPort, controlPort, … }] }
///
/// We target REALTIME (type 96) + NTP timing: it mirrors our working AirPlay 1
/// pipeline (push RTP in real time against a shared clock) and, by supplying
/// our own `shk`/`shiv`, uses plain AES audio encryption instead of FairPlay —
/// the shortest path to first audio. HAP/AirPlay-2 field names per the
/// openairplay airplay2-receiver reference; fresh Swift.
public enum AP2Setup {

    public static let realtimeType = 96
    public static let bplistContentType = "application/x-apple-binary-plist"

    /// The negotiated result of both SETUP phases: where we send audio, and
    /// the AES key material the RTP payload is encrypted under.
    public struct StreamSetup {
        public let dataPort: Int          // receiver's RTP audio port (we send here)
        public let controlPort: Int       // receiver's control port
        public let eventPort: Int          // receiver's event port (phase 1)
        public let timingPort: Int         // receiver's timing port (NTP)
        public let streamID: Int
        public let aesKey: Data            // 16B — shk we declared
        public let aesIV: Data             // 16B — shiv we declared
        public let sessionUUID: String
    }

    public enum SetupError: Error, CustomStringConvertible {
        case notOK(phase: String, status: String)
        case badPlist(String)
        case missingField(String)
        case transport(Error)

        public var description: String {
            switch self {
            case .notOK(let p, let s):   return "SETUP \(p) returned \(s)"
            case .badPlist(let m):       return "plist: \(m)"
            case .missingField(let f):   return "missing \(f) in SETUP response"
            case .transport(let e):      return "transport: \(e)"
            }
        }
    }

    // MARK: - Plist helpers

    static func encodePlist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    static func decodePlist(_ data: Data) throws -> [String: Any] {
        guard let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw SetupError.badPlist("response not a dict")
        }
        return obj
    }

    // MARK: - Run

    /// Runs both SETUP phases on an already-verified, encryption-enabled client.
    /// `ourTimingPort`/`ourControlPort` are the local UDP ports we will bind for
    /// the RTP/timing planes in the next step (declared here so the receiver
    /// knows where to reach us).
    public static func run(client: AP2RTSPClient,
                           spf: Int = 352,
                           sampleRate: Int = 44100,
                           ourTimingPort: Int,
                           ourControlPort: Int) async throws -> StreamSetup {
        let label = client.descriptor.displayName
        let sessionUUID = UUID().uuidString.uppercased()
        // Random 32-bit RTSP session id — used in the request-line URI and as
        // streamConnectionID, exactly as a real sender does.
        var sidBytes = [UInt8](repeating: 0, count: 4)
        _ = sidBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        let sessionID = sidBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let identity = AP2SenderIdentity.shared

        // ---- Phase 1: device / timing ---------------------------------
        // Present as an iPhone — real Apple TVs validate the shape of this
        // handshake against what actual senders send (fields per pyatv).
        // NOTE: modern tvOS (AirTunes/950.x) appears to reject the legacy NTP
        // realtime device-setup (400 after full processing). Trying PTP to
        // confirm the timing-protocol requirement — if this gets past phase 1,
        // the audio path needs a full PTP (IEEE-1588) implementation.
        let localIP = client.localHost
        let phase1: [String: Any] = [
            "deviceID": identity.deviceID,
            "macAddress": identity.deviceID,
            "sessionUUID": sessionUUID,
            "timingProtocol": "PTP",
            "timingPeerInfo": [
                "Addresses": [localIP],
                "ID": identity.deviceID,
            ],
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "groupUUID": UUID().uuidString.uppercased(),
            "model": "iPhone14,3",
            "name": identity.name,
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "osBuildVersion": "20F66",
            "senderSupportsRelay": false,
            "sourceVersion": "690.7.1",
            "statsCollectionEnabled": false,
        ]
        Log.airplay2.notice("SETUP[\(label, privacy: .public)] → phase 1 (device, timingProtocol=NTP, timingPort=\(ourTimingPort))")
        let r1 = try await post(client, phase1, session: sessionID, phase: "1(device)")
        let p1 = try decodePlist(r1.body)
        let eventPort = intField(p1, "eventPort") ?? 0
        let timingPort = intField(p1, "timingPort") ?? 0
        Log.airplay2.notice("SETUP[\(label, privacy: .public)] ← phase 1 ✓ eventPort=\(eventPort) timingPort=\(timingPort)")

        // ---- Phase 2: stream ------------------------------------------
        // shk is a per-stream AES key; the receiver treats it opaquely for
        // realtime, so a fresh random 32B key is fine (pyatv derives one but
        // notes it "could be hardcoded").
        var aesKey = Data(count: 32); _ = aesKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let stream: [String: Any] = [
            "type": realtimeType,               // 0x60
            "audioFormat": 0x40000,             // ALAC 44100/16/2 in Apple's table
            "audioMode": "default",
            "ct": 2,                            // compression type 2 = ALAC (type-96 realtime is ALAC, not raw PCM)
            "isMedia": true,
            "sr": sampleRate,
            "spf": spf,
            "latencyMin": 11025,
            "latencyMax": 88200,
            "shk": aesKey,
            "controlPort": ourControlPort,
            "supportsDynamicStreamID": false,
            "streamConnectionID": Int(bitPattern: UInt(sessionID)),
        ]
        let phase2: [String: Any] = ["streams": [stream]]
        Log.airplay2.notice("SETUP[\(label, privacy: .public)] → phase 2 (stream type=96 realtime, controlPort=\(ourControlPort))")
        let r2 = try await post(client, phase2, session: sessionID, phase: "2(stream)")
        let p2 = try decodePlist(r2.body)
        guard let streams = p2["streams"] as? [[String: Any]], let s0 = streams.first else {
            throw SetupError.missingField("streams[]")
        }
        guard let dataPort = intField(s0, "dataPort") else { throw SetupError.missingField("streams[0].dataPort") }
        let ctlPort = intField(s0, "controlPort") ?? 0
        let streamID = intField(s0, "streamID") ?? 0
        Log.airplay2.notice("SETUP[\(label, privacy: .public)] ← phase 2 ✓ dataPort=\(dataPort) controlPort=\(ctlPort) streamID=\(streamID)")

        return StreamSetup(
            dataPort: dataPort, controlPort: ctlPort, eventPort: eventPort,
            timingPort: timingPort, streamID: streamID,
            aesKey: aesKey, aesIV: Data(), sessionUUID: sessionUUID
        )
    }

    // MARK: - Internals

    private static func post(_ client: AP2RTSPClient, _ dict: [String: Any], session: UInt64, phase: String) async throws -> AP2RTSPClient.Response {
        let body: Data
        do { body = try encodePlist(dict) } catch { throw SetupError.badPlist("encode \(phase): \(error)") }
        // SETUP is an RTSP METHOD (not POST); the request-line URI is built from
        // OUR local IP (`rtsp://<local-ip>/<session-id>`), matching real
        // senders. IPv6 literals must be bracketed.
        var host = client.localHost.isEmpty ? client.remoteHost : client.localHost
        if host.contains(":") { host = "[\(host)]" }
        let uri = "rtsp://\(host)/\(session)"
        // Real AirPlay 2 receivers expect the DACP remote-control identifiers
        // on the streaming plane (matching pyatv's minimal header set).
        let headers = [
            "Active-Remote": String(AP2SenderIdentity.activeRemote),
            "DACP-ID": AP2SenderIdentity.shared.dacpID,
        ]
        let resp: AP2RTSPClient.Response
        do {
            resp = try await client.send(method: "SETUP", uri: uri, body: body, contentType: bplistContentType, extraHeaders: headers)
        } catch {
            throw SetupError.transport(error)
        }
        guard resp.isOK else {
            // Dump everything the receiver told us — status, all response
            // headers (Apple sometimes hints the reason), and any body bytes.
            let hdrs = resp.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " | ")
            let bodyHex = resp.body.prefix(64).map { String(format: "%02x", $0) }.joined()
            Log.airplay2.error("SETUP \(phase, privacy: .public) FAIL \(resp.statusLine, privacy: .public) — headers[\(hdrs, privacy: .public)] body=\(resp.body.count)B hex=\(bodyHex, privacy: .public)")
            Log.airplay2.error("SETUP \(phase, privacy: .public) sent URI=\(uri, privacy: .public) reqHeaders=\(headers.map { "\($0.key)=\($0.value)" }.joined(separator: ","), privacy: .public) bodyLen=\(body.count)")
            throw SetupError.notOK(phase: phase, status: resp.statusLine)
        }
        return resp
    }

    private static func intField(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? NSNumber { return n.intValue }
        return nil
    }

    /// AirPlay 2 `audioFormat` bitmask values (subset). The receiver uses this
    /// to size buffers and pick a decoder.
    public enum AudioFormat {
        case pcm(sampleRate: Int)
        public var rawValue: Int {
            // 0x40000 == PCM/16/2/44100 in Apple's audioFormat bitmask table.
            switch self {
            case .pcm(let sr): return sr == 48000 ? 0x80000 : 0x40000
            }
        }
    }
}

/// Persistent sender identity we present to AP2 receivers (a stable MAC-format
/// deviceID + friendly name). POC: UserDefaults.
public struct AP2SenderIdentity {
    public let deviceID: String   // "AA:BB:CC:DD:EE:FF"
    public let name: String
    public let model: String
    public let dacpID: String     // 16 hex chars — DACP remote-control ID

    static let key = "ap2.sender.deviceID"
    static let dacpKey = "ap2.sender.dacpID"

    /// Random per-launch Active-Remote token (matches DACP convention).
    public static let activeRemote: UInt32 = {
        var b = [UInt8](repeating: 0, count: 4)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }()

    public static let shared = load()

    static func load() -> AP2SenderIdentity {
        let d = UserDefaults.standard
        let id: String
        if let existing = d.string(forKey: key) {
            id = existing
        } else {
            var mac = [UInt8](repeating: 0, count: 6)
            _ = mac.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
            mac[0] = (mac[0] | 0x02) & 0xFE   // locally-administered unicast
            id = mac.map { String(format: "%02X", $0) }.joined(separator: ":")
            d.set(id, forKey: key)
        }
        let dacp: String
        if let existing = d.string(forKey: dacpKey) {
            dacp = existing
        } else {
            var b = [UInt8](repeating: 0, count: 8)
            _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            dacp = b.map { String(format: "%02X", $0) }.joined()
            d.set(dacp, forKey: dacpKey)
        }
        return AP2SenderIdentity(deviceID: id, name: "SuperAudio", model: "SuperAudio1,1", dacpID: dacp)
    }
}
