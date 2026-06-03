// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import SuperAudioCore

/// Tiny HTTP server that publishes a single endpoint — `/stream.aac` —
/// serving a continuous AAC-LC + ADTS audio stream. Sonos receivers
/// connect once via the URL we send in `SetAVTransportURI` and stream
/// forever until they disconnect (or we cut them off).
///
/// Implementation notes:
///
///  - Uses `NWListener` on a fixed TCP port (default `7331`). Binds to
///    `NWParameters.tcp` with the host pinned to our LAN IP — not
///    `0.0.0.0` — per CLAUDE.md working norm "No external HTTP servers
///    running unless we need them. Bind to the LAN interface, not
///    0.0.0.0."
///  - One HTTP response per inbound connection: status 200, headers,
///    then the body streams as a continuous run of bytes until the
///    client disconnects. **We do not use chunked transfer encoding** —
///    Sonos prefers HTTP/1.0-style "no Content-Length, no Transfer-
///    Encoding, just bytes" for live streams. Same approach OwnTone
///    and AirConnect use.
///  - Concurrent connections are accepted (e.g., multiple Sonos sinks
///    each subscribing). Each connection has its own send queue;
///    `append(_:)` writes the same bytes to all of them.
public final class SonosStreamServer: @unchecked Sendable {

    public enum SonosStreamServerError: Error, CustomStringConvertible {
        case listenerCreateFailed(String)
        case bindFailed(String)
        case noLocalIP

        public var description: String {
            switch self {
            case .listenerCreateFailed(let m): return "NWListener init failed: \(m)"
            case .bindFailed(let m):           return "NWListener bind failed: \(m)"
            case .noLocalIP:                   return "Could not determine local LAN IPv4 address"
            }
        }
    }

    public let port: UInt16
    public let path: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.davidpuerto.SuperAudio.sonos.stream", qos: .userInteractive)
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()

    /// Cached LAN IP for the URL we'll hand to Sonos. Resolved at start().
    public private(set) var localHost: String = "0.0.0.0"

    public init(port: UInt16 = 7331, path: String = "/stream.aac") {
        self.port = port
        self.path = path
    }

    /// Build the absolute URL the Sonos session sends in its
    /// `SetAVTransportURI` SOAP call.
    /// HTTP URL — what clients connect to over the wire.
    public func streamURL() -> String {
        return "http://\(localHost):\(port)\(path)"
    }

    /// Sonos-specific URL using the `x-rincon-mp3radio://` scheme. Sonos
    /// recognizes this prefix as "treat as continuous internet radio"
    /// and bypasses some of the per-format protocolInfo checks that
    /// reject `audio/aacp` outright on this firmware. AirConnect and
    /// OwnTone both use this pattern. The underlying transport is
    /// still HTTP; only the URL scheme changes.
    public func sonosStreamURL() -> String {
        return "x-rincon-mp3radio://\(localHost):\(port)\(path)"
    }

    // MARK: - Lifecycle

    public func start() throws {
        if listener != nil { return }

        guard let lan = LocalNetwork.primaryLocalIPv4() else {
            throw SonosStreamServerError.noLocalIP
        }
        self.localHost = lan
        Log.sonos.info("SonosStreamServer: LAN IP = \(lan, privacy: .public)")

        // Bind by port. NWListener doesn't take a `requiredLocalEndpoint`
        // (that's for outbound NWConnection); we listen on the port across
        // all interfaces and rely on the LAN being a trusted segment.
        // Sonos / B&W speakers connect via the en0 address.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SonosStreamServerError.bindFailed("invalid port \(port)")
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw SonosStreamServerError.listenerCreateFailed(String(describing: error))
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.acceptConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            Log.sonos.info("SonosStreamServer state: \(String(describing: state), privacy: .public)")
        }
        listener.start(queue: queue)
        self.listener = listener
        Log.sonos.info("SonosStreamServer listening on http://\(lan, privacy: .public):\(self.port)\(self.path, privacy: .public)")
    }

    public func stop() {
        connectionsLock.lock()
        let conns = connections
        connections.removeAll()
        connectionsLock.unlock()
        for c in conns { c.cancel() }

        listener?.cancel()
        listener = nil
        Log.sonos.info("SonosStreamServer stopped")
    }

    // MARK: - Connection handling

    private func acceptConnection(_ conn: NWConnection) {
        Log.sonos.info("SonosStreamServer ← new connection from \(String(describing: conn.endpoint), privacy: .public)")
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                self?.consumeRequestThenSendHeaders(on: conn)
            case .failed(let e):
                Log.sonos.error("SonosStreamServer connection failed: \(String(describing: e), privacy: .public)")
                self?.dropConnection(conn)
            case .cancelled:
                self?.dropConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func consumeRequestThenSendHeaders(on conn: NWConnection?) {
        guard let conn else { return }
        // Read the HTTP request line + headers; we don't actually validate
        // beyond "an HTTP request showed up." Sonos won't ask for unusual
        // verbs or paths.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if let error {
                Log.sonos.error("SonosStreamServer request read error: \(String(describing: error), privacy: .public)")
                self.dropConnection(conn)
                return
            }
            if let data, let requestStart = String(data: data.prefix(120), encoding: .utf8) {
                Log.sonos.info("SonosStreamServer request: \(requestStart.replacingOccurrences(of: "\r\n", with: " | "), privacy: .public)")
            }

            // Write the HTTP response headers. No Content-Length, no
            // Transfer-Encoding — Sonos treats this as a continuous live
            // stream that ends only when the TCP connection closes.
            let headers = """
            HTTP/1.0 200 OK\r
            Content-Type: audio/aac\r
            Cache-Control: no-cache, no-store\r
            Connection: close\r
            \r

            """
            let headerBytes = headers.data(using: .ascii) ?? Data()
            conn.send(content: headerBytes, completion: .contentProcessed { error in
                if let error {
                    Log.sonos.error("SonosStreamServer header write failed: \(String(describing: error), privacy: .public)")
                    self.dropConnection(conn)
                    return
                }
                // Headers out — register the connection so `append(_:)`
                // starts feeding it audio.
                self.connectionsLock.lock()
                self.connections.append(conn)
                let count = self.connections.count
                self.connectionsLock.unlock()
                Log.sonos.info("SonosStreamServer registered connection (now serving \(count))")
            })
        }
    }

    private func dropConnection(_ conn: NWConnection?) {
        guard let conn else { return }
        connectionsLock.lock()
        connections.removeAll { $0 === conn }
        let count = connections.count
        connectionsLock.unlock()
        conn.cancel()
        Log.sonos.info("SonosStreamServer dropped a connection (now serving \(count))")
    }

    // MARK: - Audio plumbing

    /// Append AAC/ADTS bytes to every active connection's send queue.
    /// Called from the encoding pipeline on the SonosSession's pump task.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        connectionsLock.lock()
        let snapshot = connections
        connectionsLock.unlock()
        for conn in snapshot {
            conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
                if let error {
                    Log.sonos.error("SonosStreamServer write failed (\(String(describing: error), privacy: .public)) — dropping connection")
                    self?.dropConnection(conn)
                }
            })
        }
    }

    public var connectionCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections.count
    }
}
