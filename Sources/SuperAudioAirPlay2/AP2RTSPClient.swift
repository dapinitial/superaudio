// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore

/// Minimal control-channel client for AirPlay 2 receivers — a persistent TCP
/// connection to `_airplay._tcp` carrying RTSP/1.0-framed requests with
/// **binary** bodies. Pairing (`/pair-setup`, `/pair-verify`) and later the
/// RTSP SETUP/RECORD plane ride this connection.
///
/// Distinct from AirPlay 1's `RTSPClient`: AP2 pairing bodies are raw TLV8
/// (and later binary plists / encrypted blobs), so request + response bodies
/// are `Data`, never `String`. Fresh Swift; shairport-sync `rtsp.c` and
/// `lmcgartland/airplay2-rs` read as protocol reference only.
public final class AP2RTSPClient: @unchecked Sendable {

    public struct Response: Sendable {
        public let statusLine: String        // e.g. "RTSP/1.0 200 OK"
        public let headers: [String: String]
        public let body: Data                 // binary (TLV8 for pairing)

        public var statusCode: Int? {
            let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
            return parts.count >= 2 ? Int(parts[1]) : nil
        }
        public var isOK: Bool { statusCode == 200 }
    }

    public enum AP2RTSPError: Error, CustomStringConvertible {
        case notConnected
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case parseFailed(String)
        case timeout

        public var description: String {
            switch self {
            case .notConnected:         return "AP2 RTSP not connected"
            case .connectFailed(let m): return "AP2 RTSP connect failed: \(m)"
            case .sendFailed(let m):    return "AP2 RTSP send failed: \(m)"
            case .receiveFailed(let m): return "AP2 RTSP receive failed: \(m)"
            case .parseFailed(let m):   return "AP2 RTSP parse failed: \(m)"
            case .timeout:              return "AP2 RTSP timed out"
            }
        }
    }

    public let descriptor: SinkDescriptor

    /// The Bonjour `_airplay._tcp` instance name to connect to. The AP2
    /// SinkID is `ap2:<deviceid>` (stable hardware ID), but `NWConnection`
    /// resolves by the *service instance name*, which is the display name.
    private let serviceName: String

    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.airplay2.rtsp")
    private var connection: NWConnection?
    private var cseq: Int = 0

    /// Stable per-session client identifiers AP2 receivers expect.
    private let clientID: String

    public init(descriptor: SinkDescriptor) {
        self.descriptor = descriptor
        self.serviceName = descriptor.displayName
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8.random(in: 0...255) }
        self.clientID = bytes.map { String(format: "%02X", $0) }.joined()
    }

    deinit { connection?.cancel() }

    // MARK: - Connection

    public func connect(timeout: TimeInterval = 6) async throws {
        if connection != nil { return }

        let endpoint: NWEndpoint = .service(
            name: serviceName,
            type: "_airplay._tcp",
            domain: "local.",
            interface: nil
        )
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
                resume(.failure(AP2RTSPError.timeout))
            }
            connection.stateUpdateHandler = { state in
                Log.airplay2.info("AP2 RTSP[\(label, privacy: .public)] state=\(String(describing: state), privacy: .public)")
                switch state {
                case .ready:         resume(.success(()))
                case .failed(let e): resume(.failure(AP2RTSPError.connectFailed(String(describing: e))))
                case .cancelled:     resume(.failure(AP2RTSPError.connectFailed("cancelled")))
                default:             break
                }
            }
            connection.start(queue: queue)
        }
        self.connection = connection
    }

    public func disconnect() {
        Log.airplay2.info("AP2 RTSP[\(self.descriptor.displayName, privacy: .public)] disconnect")
        connection?.cancel()
        connection = nil
    }

    // MARK: - POST

    /// POST a binary body to `path` (e.g. `/pair-setup`). Returns the parsed
    /// response with its binary body intact.
    public func post(path: String,
                     body: Data,
                     contentType: String = "application/octet-stream",
                     timeout: TimeInterval = 8) async throws -> Response {
        try await request(method: "POST", path: path, body: body, contentType: contentType, timeout: timeout)
    }

    /// `GET /info` — AirPlay 2 capability negotiation. Most receivers require
    /// this on the connection before they'll honor `/pair-setup`; the response
    /// is a binary plist describing features, flags, supported pairing, `pk`,
    /// etc. Body may be empty (some receivers want an empty-plist request body).
    public func get(path: String, timeout: TimeInterval = 8) async throws -> Response {
        try await request(method: "GET", path: path, body: Data(), contentType: "application/octet-stream", timeout: timeout)
    }

    private func request(method: String,
                         path: String,
                         body: Data,
                         contentType: String,
                         timeout: TimeInterval) async throws -> Response {
        guard let connection else { throw AP2RTSPError.notConnected }
        cseq += 1
        let currentCseq = cseq

        var head = "\(method) \(path) RTSP/1.0\r\n"
        head += "CSeq: \(currentCseq)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "User-Agent: AirPlay/665.13.1\r\n"
        head += "X-Apple-Client-Name: SuperAudio\r\n"
        head += "Client-Instance: \(clientID)\r\n"
        head += "\r\n"

        var requestData = head.data(using: .utf8) ?? Data()
        requestData.append(body)

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
                resume(.failure(AP2RTSPError.timeout))
            }
            Log.airplay2.info("AP2 RTSP[\(label, privacy: .public)] → \(method, privacy: .public) \(path, privacy: .public) (CSeq \(currentCseq), body \(body.count)B)")
            connection.send(content: requestData, completion: .contentProcessed { sendErr in
                if let sendErr {
                    resume(.failure(AP2RTSPError.sendFailed(String(describing: sendErr))))
                    return
                }
                Self.receiveAll(connection: connection) { result in
                    switch result {
                    case .failure(let e):
                        resume(.failure(e))
                    case .success(let data):
                        do {
                            let response = try Self.parse(data: data)
                            Log.airplay2.info("AP2 RTSP[\(label, privacy: .public)] ← \(response.statusLine, privacy: .public) (body \(response.body.count)B)")
                            resume(.success(response))
                        } catch {
                            resume(.failure(error))
                        }
                    }
                }
            })
        }
    }

    // MARK: - Receive / parse (binary-body-safe)

    private static func receiveAll(connection: NWConnection,
                                   accumulated: Data = Data(),
                                   completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error {
                completion(.failure(AP2RTSPError.receiveFailed(String(describing: error))))
                return
            }
            var combined = accumulated
            if let data { combined.append(data) }

            if let terminator = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headerBytes = combined[..<terminator.lowerBound]
                let bodyBytes = combined[terminator.upperBound...]
                let headersStr = String(data: headerBytes, encoding: .utf8) ?? ""
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
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw AP2RTSPError.parseFailed("missing header terminator")
        }
        let headerBytes = data[..<terminator.lowerBound]
        let body = Data(data[terminator.upperBound...])
        guard let headerBlock = String(data: headerBytes, encoding: .utf8) else {
            throw AP2RTSPError.parseFailed("non-UTF-8 header block")
        }
        var lines = headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else {
            throw AP2RTSPError.parseFailed("empty header block")
        }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        return Response(statusLine: statusLine, headers: headers, body: body)
    }
}
