// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import AVFoundation
import SuperAudioCore

/// Orchestrates a full AirPlay 2 realtime audio session end-to-end:
///
///   pair-verify + encrypted channel  (AP2PairVerify.establish)
///   → two-phase RTSP SETUP           (AP2Setup.run — gives dataPort + shk)
///   → PTP grandmaster starts         (AP2PTP)
///   → SETPEERS / RECORD / SETRATEANCHORTIME  (RTSP control, over the cipher)
///   → subscribe to AudioBroadcaster, convert 48k f32 → 44.1k s16, packetize
///     into `spf`-sample frames, encrypt + push RTP to the dataPort  (AP2RTPSender)
///
/// This is the first end-to-end AP2 audio path. It's structured for hardware
/// bring-up: each stage logs a clear gate, and the ambiguous bytes (nonce
/// padding, anchor lead, SETPEERS shape) are isolated knobs.
public final class AP2AudioSession: @unchecked Sendable {

    public static let spf = 352
    public static let outSampleRate: Double = 44100

    private let descriptor: SinkDescriptor
    private var live: AP2PairVerify.LiveSession?
    private var setup: AP2Setup.StreamSetup?
    private var ptp: AP2PTP?
    private var rtp: AP2RTPSender?
    private var pumpTask: Task<Void, Never>?
    private let ssrc: UInt32

    public init(descriptor: SinkDescriptor) {
        self.descriptor = descriptor
        var s = [UInt8](repeating: 0, count: 4)
        _ = s.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        self.ssrc = s.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public func start() async throws {
        // 1–2. verify + encrypted channel + SETUP
        let live = try await AP2PairVerify.establish(descriptor: descriptor)
        self.live = live
        let client = live.client
        let setup = try await AP2Setup.run(client: client, spf: Self.spf,
                                            sampleRate: Int(Self.outSampleRate),
                                            ourTimingPort: 319, ourControlPort: 7011)
        self.setup = setup
        let receiverIP = client.remoteHost
        let senderIP = client.localHost
        Log.airplay2.notice("AP2 audio: SETUP ok — dataPort=\(setup.dataPort) receiver=\(receiverIP, privacy: .public) sender=\(senderIP, privacy: .public)")

        // 3. PTP grandmaster (must be running before RECORD so the receiver slaves)
        let ptp = AP2PTP(senderMAC: AP2SenderIdentity.shared.deviceID, peerHost: receiverIP)
        do {
            try ptp.start()
            self.ptp = ptp
        } catch {
            Log.airplay2.error("AP2 PTP start failed: \(String(describing: error), privacy: .public) — audio needs PTP; run with sudo to bind 319/320")
            throw error
        }

        // 4. SETPEERS → SET_PARAMETER volume → SETRATEANCHORTIME (over the cipher).
        // NOTE: RECORD is deliberately NOT sent. The modern Apple TV never
        // responds to it (it times out every time), and worse, a late/absent
        // RECORD response desyncs the encrypted RTSP channel and makes the
        // subsequent volume/anchor requests time out too — the intermittent
        // "RTSP timed out" session failures. Skipping it makes the flow reliable.
        try await sendPeers(client: client, addresses: [senderIP, receiverIP].filter { !$0.isEmpty })

        // 5. RTP audio sender + anchor
        let startTS: UInt32 = 0
        let rtp = AP2RTPSender(config: .init(host: receiverIP, dataPort: setup.dataPort,
                                             key: setup.aesKey, ssrc: ssrc, spf: Self.spf),
                               startTimestamp: startTS)
        try await rtp.connect()
        self.rtp = rtp

        // Set stream volume BEFORE the anchor — AirPlay streams can default to
        // muted (-144 dB); without this the receiver plays silence even though
        // everything else is correct. 0.0 dB = max (the TV's own volume still
        // governs actual loudness).
        try? await sendVolume(client: client, db: 0.0)

        // Anchor: sample `startTS` plays at PTP time (now + lead). Give ~1.5 s of
        // runway so the first packets arrive before their play time.
        let anchorLeadNs: UInt64 = 1_500_000_000
        let anchorPTP = AP2PTP.nowPTPNanos() &+ anchorLeadNs
        try await sendAnchor(client: client, rtpTime: UInt64(startTS), ptpNanos: anchorPTP,
                             timelineID: ptp.clockIdentity)

        // 6. pump audio
        startPump()
        let (dn, dp) = (descriptor.displayName, setup.dataPort)
        Log.airplay2.notice("AP2 audio: streaming started to \(dn, privacy: .public) — dataPort \(dp), anchor +\(anchorLeadNs/1_000_000)ms")
    }

    public func stop() {
        pumpTask?.cancel(); pumpTask = nil
        rtp?.stop(); rtp = nil
        ptp?.stop(); ptp = nil
        live?.client.disconnect(); live = nil
        AudioBroadcaster.shared.unsubscribe(id: descriptor.id)
    }

    // MARK: - Audio pump (48k f32 → 44.1k s16 → spf-frame RTP)

    private func startPump() {
        let sinkID = descriptor.id
        pumpTask = Task.detached { [weak self] in
            guard let self, let rtp = self.rtp else { return }
            let stream: AsyncStream<AudioChunk>
            do {
                stream = try AudioBroadcaster.shared.subscribe(id: sinkID, delaySeconds: 0)
            } catch {
                Log.airplay2.error("AP2 audio: broadcaster subscribe failed: \(String(describing: error), privacy: .public)")
                return
            }
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.outSampleRate, channels: 2, interleaved: true)!
            var converter: AVAudioConverter?
            var pending = Data()                 // leftover int16 bytes < one frame
            let frameBytes = Self.spf * 2 * 2    // spf samples * 2ch * 2 bytes
            guard let alacEncoder = ALACFrameEncoder(sampleRate: Self.outSampleRate, framesPerPacket: Self.spf) else {
                Log.airplay2.error("AP2 pump: ALAC encoder init failed — cannot stream")
                return
            }
            Log.airplay2.notice("AP2 pump: subscribed, waiting for chunks…")
            var chunkCount = 0, convertFails = 0, alacFails = 0

            for await chunk in stream {
                if Task.isCancelled { break }
                chunkCount += 1
                if chunkCount == 1 {
                    Log.airplay2.notice("AP2 pump: first chunk — inFmt sr=\(chunk.pcm.format.sampleRate) ch=\(chunk.pcm.format.channelCount) frames=\(chunk.pcm.frameLength)")
                }
                if converter == nil || converter!.inputFormat != chunk.pcm.format {
                    converter = AVAudioConverter(from: chunk.pcm.format, to: outFormat)
                }
                guard let converter, let s16 = Self.convert(chunk.pcm, using: converter, to: outFormat) else {
                    convertFails += 1
                    if convertFails == 1 { Log.airplay2.error("AP2 pump: convert returned nil (first)") }
                    continue
                }
                pending.append(s16)
                while pending.count >= frameBytes {
                    let frame = Data(pending.prefix(frameBytes))
                    pending.removeFirst(frameBytes)
                    // type-96 realtime payload is ALAC, not raw PCM.
                    if let alac = alacEncoder.encode(frame) {
                        rtp.sendFrame(alac)
                    } else {
                        alacFails += 1
                        if alacFails == 1 { Log.airplay2.error("AP2 pump: ALAC encode returned nil (first)") }
                    }
                }
                if chunkCount % 100 == 0 { Log.airplay2.info("AP2 pump: \(chunkCount) chunks, \(convertFails) convert-fails, \(alacFails) alac-fails, pending=\(pending.count)B") }
            }
            Log.airplay2.notice("AP2 pump: stream ended after \(chunkCount) chunks")
        }
    }

    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter, to outFormat: AVAudioFormat) -> Data? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return input
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2 * 2)  // interleaved stereo s16
    }

    // MARK: - RTSP control (binary plists over the encrypted channel)

    private func sendPeers(client: AP2RTSPClient, addresses: [String]) async throws {
        // SETPEERS body is a flat array of IP strings (the PTP peer addresses).
        let arrayPlist = try PropertyListSerialization.data(fromPropertyList: addresses, format: .binary, options: 0)
        let uri = "rtsp://\(bracket(client.localHost.isEmpty ? client.remoteHost : client.localHost))/\(sessionSeed())"
        let resp = try await client.send(method: "SETPEERS", uri: uri, body: arrayPlist,
                                         contentType: AP2Setup.bplistContentType, extraHeaders: dacpHeaders())
        Log.airplay2.notice("AP2 SETPEERS → \(addresses.joined(separator: ","), privacy: .public) ← \(resp.statusLine, privacy: .public)")
    }

    private func sendRecord(client: AP2RTSPClient) async throws {
        let uri = "rtsp://\(bracket(client.localHost.isEmpty ? client.remoteHost : client.localHost))/\(sessionSeed())"
        let resp = try await client.send(method: "RECORD", uri: uri, body: Data(),
                                         extraHeaders: dacpHeaders(), timeout: 4)
        Log.airplay2.notice("AP2 RECORD ← \(resp.statusLine, privacy: .public) (Audio-Latency \(resp.headers["Audio-Latency"] ?? "?", privacy: .public))")
    }

    /// SET_PARAMETER volume, in dB (0.0 = max, -30 ≈ quietest, -144 = mute).
    /// Text body `volume: <f>\r\n`, same as AirPlay 1 RAOP, over the cipher.
    private func sendVolume(client: AP2RTSPClient, db: Float) async throws {
        let body = Data("volume: \(String(format: "%.6f", db))\r\n".utf8)
        let uri = "rtsp://\(bracket(client.localHost.isEmpty ? client.remoteHost : client.localHost))/\(sessionSeed())"
        let resp = try await client.send(method: "SET_PARAMETER", uri: uri, body: body,
                                         contentType: "text/parameters", extraHeaders: dacpHeaders())
        Log.airplay2.notice("AP2 SET_PARAMETER volume=\(db)dB ← \(resp.statusLine, privacy: .public)")
    }

    private func sendAnchor(client: AP2RTSPClient, rtpTime: UInt64, ptpNanos: UInt64, timelineID: Data) async throws {
        let secs = ptpNanos / 1_000_000_000
        let frac = UInt64((Double(ptpNanos % 1_000_000_000) / 1_000_000_000.0) * Double(UInt64.max))
        let plist: [String: Any] = [
            "rate": 1,
            "rtpTime": Int(bitPattern: UInt(rtpTime)),
            "networkTimeSecs": Int(bitPattern: UInt(secs)),
            "networkTimeFrac": Int(bitPattern: UInt(frac)),
            "networkTimeTimelineID": timelineID,
            "networkTimeFlags": 0,
        ]
        let body = try AP2Setup.encodePlist(plist)
        let uri = "rtsp://\(bracket(client.localHost.isEmpty ? client.remoteHost : client.localHost))/\(sessionSeed())"
        let resp = try await client.send(method: "SETRATEANCHORTIME", uri: uri, body: body,
                                         contentType: AP2Setup.bplistContentType, extraHeaders: dacpHeaders())
        Log.airplay2.notice("AP2 SETRATEANCHORTIME → rate=1 rtpTime=\(rtpTime) ptpSecs=\(secs) ← \(resp.statusLine, privacy: .public)")
    }

    // MARK: - helpers

    private func dacpHeaders() -> [String: String] {
        ["Active-Remote": String(AP2SenderIdentity.activeRemote), "DACP-ID": AP2SenderIdentity.shared.dacpID]
    }
    private func bracket(_ h: String) -> String { h.contains(":") ? "[\(h)]" : h }
    private func sessionSeed() -> String { setup?.sessionUUID ?? UUID().uuidString }
}
