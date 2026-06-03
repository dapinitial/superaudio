// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import Darwin
import Security
import SuperAudioCore

/// RTSP client for RAOP / AirPlay 1 receivers.
///
/// Holds a persistent `NWConnection` so the full RAOP handshake (OPTIONS
/// → ANNOUNCE → SETUP → RECORD → TEARDOWN) shares one TCP connection.
/// Most RAOP receivers correlate the session by connection, not just by
/// the `Session:` header.
///
/// Each request increments `CSeq` and includes the standard SuperAudio
/// client identification headers. Responses are returned with parsed
/// status line + header dictionary + body string.
///
/// Hand-rolled RTSP/1.0 framing. No GPL code copied — libraop and
/// shairport-sync are reference reading only (see THIRD_PARTY_NOTICES).
public final class RTSPClient: @unchecked Sendable {

    public struct Response: Sendable {
        public let statusLine: String       // e.g., "RTSP/1.0 200 OK"
        public let headers: [String: String]
        public let body: String

        public var statusCode: Int? {
            let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
            return parts.count >= 2 ? Int(parts[1]) : nil
        }

        public var isOK: Bool { statusCode == 200 }
    }

    public enum RTSPClientError: Error, CustomStringConvertible {
        case notConnected
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case parseFailed(String)
        case timeout
        case unexpectedStatus(String, body: String)

        public var description: String {
            switch self {
            case .notConnected:            return "RTSP not connected"
            case .connectFailed(let m):    return "RTSP connect failed: \(m)"
            case .sendFailed(let m):       return "RTSP send failed: \(m)"
            case .receiveFailed(let m):    return "RTSP receive failed: \(m)"
            case .parseFailed(let m):      return "RTSP parse failed: \(m)"
            case .timeout:                 return "RTSP timed out"
            case .unexpectedStatus(let s, let b): return "RTSP unexpected status: \(s) — body: \(b.prefix(200))"
            }
        }
    }

    public let descriptor: SinkDescriptor

    /// When `true`, ANNOUNCE advertises `et=1` with `a=rsaaeskey:` + `a=aesiv:`
    /// in the SDP, and the audio path AES-128-CBC encrypts RTP payloads with
    /// the session key. When `false`, ANNOUNCE uses `et=0` (no SDP crypto) and
    /// audio is sent in cleartext. Default is `true` for broader receiver
    /// compatibility. Disable during M3 bisects to bypass the encryption layer.
    public let useEncryption: Bool

    /// Session ID used in the ANNOUNCE / SETUP URLs and in some headers.
    /// shairport-sync senders use 9–10 digit decimal random numbers; we match.
    public let sessionID: String

    /// AES-128 session key (16 random bytes) generated at init. Sent
    /// RSA-OAEP-SHA1 encrypted in the et=1 ANNOUNCE SDP. The audio path
    /// (next sub-task) will reuse this for AES-128-CBC RTP-payload encryption.
    public let aesKey: Data

    /// AES IV (16 random bytes). Sent in ANNOUNCE SDP as `a=aesiv:`.
    /// Reset before encrypting each RTP audio packet — receivers expect
    /// per-packet IV reset, not chained.
    public let aesIV: Data

    /// Session token issued by the server in the SETUP response (`Session:`
    /// header). Required on subsequent RECORD / FLUSH / TEARDOWN requests.
    public private(set) var serverSession: String?

    /// UDP ports the server is listening on, populated after a successful
    /// SETUP. We send RTP audio to `serverAudioPort`, talk to/from
    /// `serverControlPort` for RTCP-style control, and use `serverTimingPort`
    /// for NTP-style clock sync.
    public struct ServerPorts: Sendable {
        public let audio: UInt16
        public let control: UInt16
        public let timing: UInt16
    }
    public private(set) var serverPorts: ServerPorts?

    /// Receiver's buffer depth in samples, parsed from the RECORD response's
    /// `Audio-Latency:` header. Typical AirPort-Express-derived hardware
    /// reports 4096 (≈ 93 ms at 44.1 kHz). The sender uses this to compute
    /// the "less latency" RTP timestamp in control-port sync packets.
    /// Defaults to 4096 if the header was absent or malformed.
    public private(set) var negotiatedAudioLatency: UInt32 = 4096

    /// Local UDP ports we bound during SETUP (we tell the server about these
    /// in the Transport header so it can send control/timing back to us).
    public struct LocalPorts: Sendable {
        public let control: UInt16
        public let timing: UInt16
    }
    public private(set) var localPorts: LocalPorts?

    /// Held to keep the local UDP ports reserved AND to receive incoming
    /// control/timing packets. NWListener+UDP turned out to silently swallow
    /// inbound datagrams in our setup (newConnectionHandler not firing for
    /// UDP flows that arrived on the bound port — confirmed by a 30-second
    /// pcap that showed the speaker sending 60+ NTP-style timing packets
    /// to our advertised timing port while our app logged zero received
    /// bytes). Switched to BSD sockets for determinism.
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?

    /// Unix timestamp (sub-second precision) of the most recent timing
    /// request received from the receiver. Updated by the timing socket's
    /// onReceive closure. **Used by AirPlay1Session's health monitor as
    /// the canonical "is the receiver still alive?" signal** — RAOP
    /// receivers send PT 0xD2 timing requests every ~1 sec during active
    /// playback; if we stop seeing them for >15 sec, the receiver has
    /// dropped off the network. This replaces the brittle TCP-OPTIONS-
    /// based health check that produced soak-test false positives
    /// (DECISIONS.md 2026-05-16 Saturday entry).
    ///
    /// 0 = never received any timing packet. `Double` (TimeInterval) is
    /// 8 bytes and atomic on Apple silicon; we don't need a lock.
    private var _lastTimingUnixTime: Double = 0
    public var lastTimingPacketUnixTime: Double { _lastTimingUnixTime }

    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.rtsp")
    private var connection: NWConnection?
    private var cseq: Int = 0

    public init(descriptor: SinkDescriptor, useEncryption: Bool = true) {
        self.descriptor = descriptor
        self.useEncryption = useEncryption
        self.sessionID = String(Int.random(in: 1_000_000_000...3_000_000_000))

        // Generate cryptographically random AES-128 key + IV via SecRandom.
        var key = Data(count: 16)
        var iv  = Data(count: 16)
        _ = key.withUnsafeMutableBytes { buf -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        _ = iv.withUnsafeMutableBytes { buf -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        self.aesKey = key
        self.aesIV  = iv
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - Connection lifecycle

    public func connect(timeout: TimeInterval = 5) async throws {
        if connection != nil { return }

        let endpoint: NWEndpoint = .service(
            name: descriptor.id,
            type: "_raop._tcp",
            domain: "local.",
            interface: nil
        )

        // TCP_KEEPALIVE — load-bearing for mid-stream session survival.
        // During an active RAOP session, audio flows over UDP and the
        // RTSP TCP socket goes idle for minutes at a time. Without
        // OS-level keepalive, the connection can be silently dropped by
        // NAT timeouts, Wi-Fi roams, or router housekeeping; we wouldn't
        // notice until we tried to send TEARDOWN (or our health-check
        // OPTIONS ping fails). Settings rationale:
        //   - keepaliveIdle = 30 s — first probe fires after 30 s of
        //     idle. RAOP audio doesn't traverse this socket so "idle"
        //     is the normal mid-stream state.
        //   - keepaliveInterval = 10 s — probes every 10 s if previous
        //     probe wasn't ACKed.
        //   - keepaliveCount = 3 — three unanswered probes (~30 s of
        //     unresponsive peer) and the OS declares the connection
        //     dead, surfacing as `.failed` on stateUpdateHandler.
        // Tuned 2026-05-16 after soak-test logs showed mid-stream
        // RTSP-OPTIONS timeouts. See DECISIONS.md 2026-05-16 (Saturday).
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: params)

        let label = descriptor.displayName
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:        cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(RTSPClientError.timeout))
            }
            connection.stateUpdateHandler = { state in
                Log.airplay1.info("RTSP[\(label, privacy: .public)] state=\(String(describing: state), privacy: .public)")
                switch state {
                case .ready:           resume(.success(()))
                case .failed(let e):   resume(.failure(RTSPClientError.connectFailed(String(describing: e))))
                case .cancelled:       resume(.failure(RTSPClientError.connectFailed("cancelled")))
                default:               break
                }
            }
            connection.start(queue: queue)
        }
        self.connection = connection
    }

    public func disconnect() {
        Log.airplay1.info("RTSP[\(self.descriptor.displayName, privacy: .public)] disconnect")
        connection?.cancel()
        connection = nil
        controlSocket?.close(); controlSocket = nil
        timingSocket?.close(); timingSocket = nil
    }

    /// Send a UDP datagram to `host:port` via the BSD `controlSocket` bound
    /// during SETUP. The source port is whatever we advertised in the
    /// Transport header — this is load-bearing because most RAOP receivers
    /// `connect()` their control/timing UDP sockets to that specific source
    /// port and ICMP-reject anything else. Confirmed via PortProbe on B&W
    /// A7 (2026-05-14): control port returns CLOSED to any other source.
    ///
    /// Returns `true` if `sendto()` reported writing all bytes.
    @discardableResult
    public func sendOnControlSocket(_ data: Data, toHost host: String, port: UInt16) -> Bool {
        guard let sock = controlSocket else {
            Log.airplay1.error("sendOnControlSocket: no controlSocket")
            return false
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Log.airplay1.error("sendOnControlSocket: invalid host \(host, privacy: .public)")
            return false
        }
        let n = sock.send(data, to: addr)
        if n != data.count {
            Log.airplay1.error("sendOnControlSocket: short write — wrote \(n) of \(data.count) bytes (errno=\(errno))")
        }
        return n == data.count
    }

    // MARK: - Requests

    /// `OPTIONS *` — protocol sanity check. Most RAOP receivers list every
    /// supported method in the `Public:` header.
    public func sendOptions(timeout: TimeInterval = 5) async throws -> Response {
        // No Apple-Challenge — Music.app's OPTIONS (captured 2026-05-12) does
        // not send this header. Sending it without being able to satisfy a
        // valid Apple-Response (which requires Apple's private RSA key) may
        // put the receiver into a "challenged but unverified" state.
        try await request(
            method: "OPTIONS",
            uri: "*",
            extraHeaders: [:],
            body: nil,
            contentType: nil,
            timeout: timeout
        )
    }

    /// `ANNOUNCE rtsp://<local-ip>/<session-id> RTSP/1.0` with an SDP body
    /// declaring ALAC, 44.1 kHz, 16-bit, stereo, **unencrypted** (et=0).
    /// Our target speakers (B&W A5/A7) advertise `et=0,4`, so we try clear
    /// audio first; only fall back to MFi/SAP (et=4) if we hit rejections.
    public func sendAnnounce(timeout: TimeInterval = 5) async throws -> Response {
        let localIP = Self.primaryLocalIPv4() ?? "0.0.0.0"
        let uri = "rtsp://\(localIP)/\(sessionID)"

        // Standard RAOP SDP for unencrypted ALAC.
        //
        // `c=IN IP4 <receiver-ip>` matches Music.app's wire behavior. Note this
        // deviates from standard SDP semantics (which would have `c=` carry the
        // sender's IP) but AirTunes wants the receiver's IP here.
        let receiverHost = descriptor.endpoint.metadata["host"] ?? Self.resolveServiceHost(for: descriptor) ?? localIP

        let sdp: String
        if useEncryption {
            // et=1 — encrypt the AES session key with Apple's AirPort Express
            // public RSA key. Confirmed working against B&W A5/A7 (2026-05-13).
            // The audio path AES-encrypts RTP payloads with the same key.
            let encryptedAESKey: Data
            do {
                encryptedAESKey = try AppleAirPortRSA.encryptSessionKey(aesKey)
            } catch {
                Log.airplay1.error("RSA encrypt of AES session key failed: \(String(describing: error), privacy: .public)")
                throw error
            }
            let rsaaeskeyB64 = encryptedAESKey.base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            let aesivB64 = aesIV.base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))

            sdp = """
            v=0\r
            o=iTunes \(sessionID) 0 IN IP4 \(localIP)\r
            s=iTunes\r
            c=IN IP4 \(receiverHost)\r
            t=0 0\r
            m=audio 0 RTP/AVP 96\r
            a=rtpmap:96 AppleLossless\r
            a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r
            a=rsaaeskey:\(rsaaeskeyB64)\r
            a=aesiv:\(aesivB64)\r

            """
        } else {
            // et=0 — no SDP crypto. Audio is cleartext on the wire. Used to
            // bisect "is the encryption the bug" during the M3 audio path
            // bringup. The receiver still accepts the session per the
            // 2026-05-13 handshake test where both et=0 and et=1 produced
            // RECORD ACK; only the audio behavior differs.
            sdp = """
            v=0\r
            o=iTunes \(sessionID) 0 IN IP4 \(localIP)\r
            s=iTunes\r
            c=IN IP4 \(receiverHost)\r
            t=0 0\r
            m=audio 0 RTP/AVP 96\r
            a=rtpmap:96 AppleLossless\r
            a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r

            """
        }
        let body = sdp.data(using: .utf8) ?? Data()

        return try await request(
            method: "ANNOUNCE",
            uri: uri,
            extraHeaders: [:],
            body: body,
            contentType: "application/sdp",
            timeout: timeout
        )
    }

    /// `SETUP` — allocate audio/control/timing channels. We bind local UDP
    /// listeners first to learn our own port numbers (the server sends
    /// control/timing packets back to those), then advertise them in the
    /// Transport header. The server's response Transport header carries
    /// its own audio/control/timing port numbers, which we parse and store.
    public func sendSetup(timeout: TimeInterval = 5) async throws -> Response {
        let (controlPort, timingPort) = try await bindLocalUDPListeners()
        self.localPorts = LocalPorts(control: controlPort, timing: timingPort)
        Log.airplay1.info("RTSP[\(self.descriptor.displayName, privacy: .public)] bound local UDP control=\(controlPort) timing=\(timingPort)")

        // `interleaved=0-1` matches Music.app's wire behavior. Even though
        // the session ends up using UDP (server_port comes back in the response),
        // the AirTunes parser appears to use this parameter as part of its
        // state-machine condition for what RECORD will accept.
        let transport = "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(controlPort);timing_port=\(timingPort)"
        let uri = "rtsp://\(Self.primaryLocalIPv4() ?? "0.0.0.0")/\(sessionID)"

        let response = try await request(
            method: "SETUP",
            uri: uri,
            extraHeaders: ["Transport": transport],
            body: nil,
            contentType: nil,
            timeout: timeout
        )

        if response.isOK {
            if let sessionHeader = response.headers["Session"] {
                self.serverSession = sessionHeader.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            if let transportHeader = response.headers["Transport"] {
                self.serverPorts = Self.parseTransport(transportHeader)
            }
            if let s = serverSession {
                Log.airplay1.info("RTSP[\(self.descriptor.displayName, privacy: .public)] session=\(s, privacy: .public)")
            }
            if let p = serverPorts {
                Log.airplay1.info("RTSP[\(self.descriptor.displayName, privacy: .public)] server ports audio=\(p.audio) control=\(p.control) timing=\(p.timing)")
            }
        }
        return response
    }

    /// `RECORD` — tell the server we're about to start sending audio.
    /// Range and RTP-Info headers carry the initial sequence number and
    /// presentation timestamp. The server replies with its audio buffer
    /// depth in the `Audio-Latency` header — useful for our latency model.
    public func sendRecord(initialSequence: UInt16 = UInt16.random(in: 1000...30000),
                           initialRTPTimestamp: UInt32 = UInt32.random(in: 1_000_000...3_000_000_000),
                           timeout: TimeInterval = 30) async throws -> Response {
        // Header order matches Music.app exactly: Session, Range, RTP-Info
        // before the identity headers. AirTunes/103.2's parser may be
        // order-sensitive — this is one of the few remaining unknowns left
        // after our pcap diff against Music.app.
        var orderedHeaders: [(String, String)] = []
        if let session = serverSession {
            orderedHeaders.append(("Session", session))
        }
        orderedHeaders.append(("Range", "npt=0-"))
        orderedHeaders.append(("RTP-Info", "seq=\(initialSequence);rtptime=\(initialRTPTimestamp)"))

        let response = try await request(
            method: "RECORD",
            uri: "rtsp://\(Self.primaryLocalIPv4() ?? "0.0.0.0")/\(sessionID)",
            extraHeaders: Dictionary(uniqueKeysWithValues: orderedHeaders),
            body: nil,
            contentType: nil,
            timeout: timeout
        )
        if let latencyHeader = response.headers["Audio-Latency"],
           let parsed = UInt32(latencyHeader.trimmingCharacters(in: .whitespaces)) {
            self.negotiatedAudioLatency = parsed
            Log.airplay1.info("RTSP[\(self.descriptor.displayName, privacy: .public)] negotiated Audio-Latency=\(parsed)")
        }
        return response
    }

    /// `SET_PARAMETER volume` — initialize the speaker's volume. Most
    /// AirTunes/RAOP receivers expect this between SETUP and RECORD; some
    /// silently refuse to ACK RECORD until they've seen a volume set.
    ///
    /// Volume is in dB, range -30 (effectively off) to 0 (full). The special
    /// value -144 means "muted" in the AirTunes protocol.
    public func sendSetVolume(level: Float = -20, timeout: TimeInterval = 5) async throws -> Response {
        let bodyText = "volume: \(String(format: "%.6f", level))\r\n"
        let body = bodyText.data(using: .utf8) ?? Data()
        var headers: [String: String] = [:]
        if let session = serverSession {
            headers["Session"] = session
        }
        return try await request(
            method: "SET_PARAMETER",
            uri: "rtsp://\(Self.primaryLocalIPv4() ?? "0.0.0.0")/\(sessionID)",
            extraHeaders: headers,
            body: body,
            contentType: "text/parameters",
            timeout: timeout
        )
    }

    /// `TEARDOWN` — cleanly close the session on the server side.
    public func sendTeardown(timeout: TimeInterval = 5) async throws -> Response {
        var headers: [String: String] = [:]
        if let session = serverSession {
            headers["Session"] = session
        }
        return try await request(
            method: "TEARDOWN",
            uri: "rtsp://\(Self.primaryLocalIPv4() ?? "0.0.0.0")/\(sessionID)",
            extraHeaders: headers,
            body: nil,
            contentType: nil,
            timeout: timeout
        )
    }

    // MARK: - Local UDP port reservation

    private func bindLocalUDPListeners() async throws -> (controlPort: UInt16, timingPort: UInt16) {
        guard let control = UDPSocket(label: "control"),
              let timing  = UDPSocket(label: "timing")
        else {
            throw RTSPClientError.connectFailed("failed to bind local UDP sockets")
        }

        // Speaker sends NTP-style timing requests (PT 0xD2) to our timing
        // port. We must reply (PT 0xD3) or RECORD never ACKs.
        //
        // We also record the arrival timestamp into `_lastTimingUnixTime`
        // — this is the canonical "receiver still alive" signal used by
        // AirPlay1Session's health monitor. Receivers send these every
        // ~1 sec while streaming; absence for >15 sec = network loss.
        timing.onReceive = { [weak timing, weak self] data, from in
            guard let timing else { return }
            guard data.count >= 2, data[1] == 0xD2 else { return }
            // Update presence timestamp before sending the reply — even
            // if our reply send fails, the receiver IS still reaching us.
            self?._lastTimingUnixTime = Date().timeIntervalSince1970
            let rxTime = RAOPTiming.nowNTP()
            let reply = RAOPTiming.buildResponse(forRequest: data, receivedAt: rxTime)
            let sent = timing.send(reply, to: from)
            Log.airplay1.info("UDP tx \(sent) bytes timing-reply to \(String(cString: inet_ntoa(from.sin_addr)), privacy: .public):\(UInt16(bigEndian: from.sin_port))")
        }

        control.startReceiving()
        timing.startReceiving()
        controlSocket = control
        timingSocket = timing
        return (control.port, timing.port)
    }

    /// Parse a Transport: header like
    ///   `RTP/AVP/UDP;unicast;mode=record;server_port=51234;control_port=51235;timing_port=51236`
    /// extracting the three port numbers.
    private static func parseTransport(_ header: String) -> ServerPorts? {
        var audio: UInt16?
        var control: UInt16?
        var timing: UInt16?
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "server_port":  audio   = UInt16(val)
            case "control_port": control = UInt16(val)
            case "timing_port":  timing  = UInt16(val)
            default: break
            }
        }
        guard let a = audio, let c = control, let t = timing else { return nil }
        return ServerPorts(audio: a, control: c, timing: t)
    }

    // MARK: - Core request mechanism

    private func request(
        method: String,
        uri: String,
        extraHeaders: [String: String],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval
    ) async throws -> Response {
        guard let connection else {
            throw RTSPClientError.notConnected
        }
        cseq += 1
        let currentCseq = cseq

        // Header order matches Music.app captured 2026-05-12:
        //   CSeq → (Content-Type/Length if body) → method-specific extras
        //   → identity headers (User-Agent, Client-Instance, DACP-ID, Active-Remote).
        // AirTunes/103.2 appears order-sensitive in its parser.
        var headers: [(String, String)] = [
            ("CSeq", String(currentCseq)),
        ]
        if let body, !body.isEmpty {
            if let ct = contentType {
                headers.append(("Content-Type", ct))
            }
            headers.append(("Content-Length", String(body.count)))
        }
        for (k, v) in extraHeaders {
            headers.append((k, v))
        }
        // Identity headers LAST — matches Music.app's wire ordering.
        headers.append(("User-Agent", "iTunes/10.6 (Macintosh; Intel Mac OS X 10.7.3)"))
        headers.append(("Client-Instance", staticClientInstance))
        headers.append(("DACP-ID", staticClientInstance))
        headers.append(("Active-Remote", String(Int.random(in: 1_000_000_000...3_000_000_000))))

        var requestText = "\(method) \(uri) RTSP/1.0\r\n"
        for (k, v) in headers {
            requestText += "\(k): \(v)\r\n"
        }
        requestText += "\r\n"

        var requestData = requestText.data(using: .utf8) ?? Data()
        if let body { requestData.append(body) }

        let label = descriptor.displayName

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            var resumed = false
            let resume: (Result<Response, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let r): cont.resume(returning: r)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(RTSPClientError.timeout))
            }

            Log.airplay1.info("RTSP[\(label, privacy: .public)] → \(method, privacy: .public) \(uri, privacy: .public) (CSeq \(currentCseq), \(requestData.count) bytes)")

            connection.send(content: requestData, completion: .contentProcessed { sendErr in
                if let sendErr {
                    resume(.failure(RTSPClientError.sendFailed(String(describing: sendErr))))
                    return
                }
                Self.receiveAll(connection: connection) { result in
                    switch result {
                    case .failure(let e):
                        resume(.failure(e))
                    case .success(let data):
                        do {
                            let response = try Self.parse(data: data)
                            Log.airplay1.info("RTSP[\(label, privacy: .public)] ← \(response.statusLine, privacy: .public)")
                            for (k, v) in response.headers {
                                Log.airplay1.info("RTSP[\(label, privacy: .public)]   \(k, privacy: .public): \(v, privacy: .public)")
                            }
                            resume(.success(response))
                        } catch {
                            resume(.failure(error))
                        }
                    }
                }
            })
        }
    }

    private static func receiveAll(
        connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error {
                completion(.failure(RTSPClientError.receiveFailed(String(describing: error))))
                return
            }
            var combined = accumulated
            if let data { combined.append(data) }

            if let response = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headerBytes = combined[..<response.upperBound]
                let bodyBytes   = combined[response.upperBound...]
                let headersStr  = String(data: headerBytes, encoding: .utf8) ?? ""
                let contentLength = parseContentLength(in: headersStr) ?? 0
                if bodyBytes.count >= contentLength {
                    completion(.success(combined))
                    return
                }
            }

            if isComplete {
                completion(.success(combined))
                return
            }

            receiveAll(connection: connection, accumulated: combined, completion: completion)
        }
    }

    private static func parseContentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(parts[1])
            }
        }
        return nil
    }

    private static func parse(data: Data) throws -> Response {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RTSPClientError.parseFailed("non-UTF-8 response")
        }
        guard let split = text.range(of: "\r\n\r\n") else {
            throw RTSPClientError.parseFailed("missing header terminator")
        }
        let headerBlock = String(text[..<split.lowerBound])
        let body        = String(text[split.upperBound...])

        var lines = headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else {
            throw RTSPClientError.parseFailed("empty header block")
        }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key   = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        return Response(statusLine: statusLine, headers: headers, body: body)
    }

    // MARK: - Static helpers

    /// Per-RTSPClient-instance client identifier (hex). Some RAOP receivers
    /// use `Client-Instance` / `DACP-ID` to identify a single controller
    /// across requests; sharing the same value between simultaneous sessions
    /// to different receivers risked the receiver firmware treating both
    /// connections as the same controller's split feed. Each RTSPClient
    /// now gets its own random ID — A5 and A7 sessions are seen as fully
    /// independent controllers by their respective speakers.
    ///
    /// Generated once at instance construction so it stays stable across
    /// every CSeq within the same session (some receivers do associate
    /// state by this value across the OPTIONS → ANNOUNCE → SETUP → RECORD
    /// sequence).
    private let staticClientInstance: String = {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }()

    private static func randomBase64Challenge(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Resolve a Bonjour service descriptor's underlying IPv4 address by
    /// doing a synchronous getaddrinfo on the service's `<hostname>.local.`
    /// form. We don't have it cached at discovery time (NWConnection
    /// resolves lazily); for the SDP `c=` line we need the explicit IP.
    /// Resolve the receiver's numeric IPv4 address by guessing the Bonjour
    /// hostname from the display name (RoomName.local.) and asking the system
    /// resolver. Best-effort. Returns `nil` if resolution fails.
    ///
    /// Public so the audio-path layer (`RTPSender`) can target the same host
    /// without re-implementing the lookup.
    public static func resolveServiceHost(for descriptor: SinkDescriptor) -> String? {
        // The service display name in Bonjour: `MAC@RoomName`. The hostname
        // the receiver registers in mDNS is typically `RoomName.local.`
        // (spaces replaced with dashes). Best effort.
        let display = descriptor.displayName
        let host = display.replacingOccurrences(of: " ", with: "-") + ".local."
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                          &hostname, socklen_t(hostname.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: hostname)
    }

    /// Best-effort primary IPv4 address on the active interface. Used in
    /// SDP `o=` / `c=` lines and the ANNOUNCE request URI. Many receivers
    /// don't strictly validate this against the actual TCP source IP, but
    /// providing a real address is better than `0.0.0.0`.
    private static func primaryLocalIPv4() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = ptr?.pointee {
            ptr = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isRunning = (flags & IFF_RUNNING) == IFF_RUNNING
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, isRunning, !isLoopback else { continue }
            guard let sa = interface.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
            if r == 0 {
                result = String(cString: hostname)
                break
            }
        }
        return result
    }
}

/// BSD-socket-based UDP receiver for our control/timing channels.
///
/// We learned the hard way that `NWListener` with `NWParameters.udp` silently
/// fails to deliver inbound datagrams in our setup — `newConnectionHandler`
/// never fires for UDP flows even when the kernel is clearly delivering
/// packets to the bound port (pcap-proven). Going directly to POSIX sockets
/// gives us deterministic behavior and a familiar `recvfrom` loop.
///
/// Phase 1 just logs incoming packets. Next sub-task adds NTP-style replies
/// on the timing channel so the speaker's RECORD ACK is unblocked.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let label: String
    private var running = true

    /// Optional handler invoked on the recv thread for each datagram.
    /// Set this before calling `startReceiving()` for it to take effect.
    var onReceive: ((Data, sockaddr_in) -> Void)?

    init?(label: String) {
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return nil }

        var yes: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0)   // INADDR_ANY
        addr.sin_port   = 0                    // OS-picked ephemeral

        let bindOK = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(s, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
        guard bindOK else {
            Log.airplay1.error("UDPSocket[\(label, privacy: .public)] bind failed errno=\(errno)")
            Darwin.close(s); return nil
        }

        var bound = sockaddr_in()
        var blen  = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(s, raw, &blen)
            }
        } == 0
        guard nameOK else {
            Log.airplay1.error("UDPSocket[\(label, privacy: .public)] getsockname failed errno=\(errno)")
            Darwin.close(s); return nil
        }

        self.fd    = s
        self.port  = UInt16(bigEndian: bound.sin_port)
        self.label = label
        Log.airplay1.info("UDPSocket[\(label, privacy: .public)] bound to port \(self.port)")
    }

    func startReceiving() {
        let fd    = self.fd
        let port  = self.port
        let label = self.label
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "superaudio.udp.\(label).\(port)"
            var buf = [UInt8](repeating: 0, count: 2048)
            while self?.running == true {
                var from = sockaddr_in()
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBufferPointer { bufPtr -> Int in
                    withUnsafeMutablePointer(to: &from) { fromPtr -> Int in
                        fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromRaw in
                            recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, fromRaw, &flen)
                        }
                    }
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EBADF { break }
                    Log.airplay1.error("UDPSocket[\(label, privacy: .public):\(port)] recvfrom errno=\(errno)")
                    break
                }
                if n == 0 { continue }
                let b0 = buf[0]
                let b1 = n >= 2 ? buf[1] : 0
                let fromIP = String(cString: inet_ntoa(from.sin_addr))
                let fromPort = UInt16(bigEndian: from.sin_port)
                Log.airplay1.info("UDP rx \(n) bytes on \(label, privacy: .public):\(port) from \(fromIP, privacy: .public):\(fromPort) header=[\(String(format: "0x%02X", b0), privacy: .public),\(String(format: "0x%02X", b1), privacy: .public)]")
                if let handler = self?.onReceive {
                    let chunk = Data(buf[0..<n])
                    handler(chunk, from)
                }
            }
            Log.airplay1.info("UDPSocket[\(label, privacy: .public):\(port)] recv loop exited")
        }
    }

    /// Send a datagram to a specific remote. Used by the timing-channel
    /// handler to reply to the speaker's NTP-style requests.
    @discardableResult
    func send(_ data: Data, to addr: sockaddr_in) -> Int {
        var a = addr
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            withUnsafePointer(to: &a) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Int in
                    Darwin.sendto(fd, buf.baseAddress, data.count, 0,
                                  raw, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        running = false
        Darwin.close(fd)
    }

    deinit { close() }
}

/// RAOP NTP-style timing protocol.
///
/// Receivers send 32-byte timing requests (RTP-shaped, payload type 0x52)
/// to the sender's advertised `timing_port` and require a matching response
/// (payload type 0x53) before they'll commit to RECORD's `200 OK`. Without
/// this round-trip the speaker silently waits.
///
/// Packet layout (32 bytes total, all big-endian):
///   bytes 0–3:   RTP header — `0x80 0xD2/D3 <2-byte seq>`
///   bytes 4–7:   reference time (uint32, mostly unused)
///   bytes 8–15:  origin timestamp  (NTP 64-bit format)
///   bytes 16–23: receive timestamp (NTP 64-bit format)
///   bytes 24–31: transmit timestamp (NTP 64-bit format)
///
/// NTP-64 = 32-bit seconds-since-1900 || 32-bit fractional-seconds.
enum RAOPTiming {

    /// 1970→1900 offset, the standard NTP epoch difference.
    private static let ntpEpochOffset: Double = 2_208_988_800

    /// Current time in NTP-64 format as (seconds, fraction).
    static func nowNTP() -> (seconds: UInt32, fraction: UInt32) {
        let unix = Date().timeIntervalSince1970
        let total = unix + ntpEpochOffset
        let seconds = UInt32(total)
        let fraction = UInt32((total - Double(seconds)) * Double(UInt32.max))
        return (seconds, fraction)
    }

    /// NTP-64 representation of "wall-clock time + `offset` seconds." Used
    /// to advance the sync packet's NTP reference into the near future so
    /// the receiver has time to fill its playback buffer before the
    /// scheduled start.
    static func nowNTPPlusSeconds(_ offset: Double) -> (seconds: UInt32, fraction: UInt32) {
        let unix = Date().timeIntervalSince1970 + offset
        let total = unix + ntpEpochOffset
        let seconds = UInt32(total)
        let fraction = UInt32((total - Double(seconds)) * Double(UInt32.max))
        return (seconds, fraction)
    }

    /// NTP-64 representation of `anchorDate + offset` seconds. Used in M5
    /// sync packets — every session computes the same NTP value because
    /// `anchorDate` comes from `AudioBroadcaster.shared.anchor`, shared
    /// across all subscribers. The receivers' clocks then align all
    /// audio packets (regardless of which session sent them) against the
    /// same wall-clock moment → sample-accurate cross-sink sync.
    static func ntpFor(date anchorDate: Date, plusSeconds offset: Double) -> (seconds: UInt32, fraction: UInt32) {
        let unix = anchorDate.timeIntervalSince1970 + offset
        let total = unix + ntpEpochOffset
        let seconds = UInt32(total)
        let fraction = UInt32((total - Double(seconds)) * Double(UInt32.max))
        return (seconds, fraction)
    }

    /// Build the 32-byte NTP TIME RESPONSE for the given request.
    /// `origin` is echoed verbatim from the request's transmit timestamp
    /// (bytes 24–31), giving the receiver enough info to compute round-trip.
    static func buildResponse(forRequest request: Data, receivedAt receiveTime: (UInt32, UInt32)) -> Data {
        var resp = Data(count: 32)
        // RTP-style header: version=2, marker=1, payload type=0x53 (NTP REPLY)
        resp[0] = 0x80
        resp[1] = 0xD3
        // Echo sequence number from the request
        resp[2] = request.count > 2 ? request[2] : 0x00
        resp[3] = request.count > 3 ? request[3] : 0x07
        // Reference time (we don't track one — zeros are accepted)
        resp[4] = 0; resp[5] = 0; resp[6] = 0; resp[7] = 0
        // Origin timestamp — copy of request's TRANSMIT timestamp (bytes 24..31)
        if request.count >= 32 {
            for i in 0..<8 {
                resp[8 + i] = request[24 + i]
            }
        }
        // Receive timestamp — when we got the request
        writeNTP(seconds: receiveTime.0, fraction: receiveTime.1, into: &resp, at: 16)
        // Transmit timestamp — right now
        let tx = nowNTP()
        writeNTP(seconds: tx.0, fraction: tx.1, into: &resp, at: 24)
        return resp
    }

    private static func writeNTP(seconds: UInt32, fraction: UInt32, into buf: inout Data, at offset: Int) {
        let s = seconds.bigEndian
        let f = fraction.bigEndian
        withUnsafeBytes(of: s) { for (i, b) in $0.enumerated() { buf[offset + i] = b } }
        withUnsafeBytes(of: f) { for (i, b) in $0.enumerated() { buf[offset + 4 + i] = b } }
    }
}
