// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Network
import AVFoundation
import CommonCrypto
import SuperAudioCore

/// RTP audio sender for AirPlay 1 (RAOP) receivers.
///
/// Consumes `AudioChunk`s from a `SystemAudioCapture` stream, converts them
/// to the RAOP wire format (44.1 kHz / 16-bit / stereo), wraps each
/// 352-sample frame in an ALAC verbatim (escape-mode) element, encrypts
/// whole 16-byte blocks of the payload with AES-128-CBC using the
/// session key + IV from `RTSPClient`, builds a 12-byte RTP header, and
/// sends one packet per frame over UDP to the receiver's `server_port`.
///
/// **M3a — verbatim ALAC mode.** The payload is an uncompressed ALAC
/// element (escape flag set, raw 16-bit PCM bit-shifted into the stream).
/// Bandwidth ~1.4 Mbps. Lossless. M3b will swap in Apple's open-source
/// ALAC encoder (Apache 2.0) for ~700 kbps with identical audible quality.
///
/// **AES encryption rule:** IV resets to the session `aesIV` before
/// each packet — receivers expect per-packet IV reset, not CBC chaining.
/// Only whole 16-byte blocks of the payload are encrypted; trailing bytes
/// stay in cleartext. This is the documented RAOP behavior across every
/// reference implementation.
///
/// **No GPL code copied** — libraop and shairport-sync are reference
/// reading only (see THIRD_PARTY_NOTICES). The bit layouts below are
/// derived from the published Apple ALAC specification.
public final class RTPSender: @unchecked Sendable {

    // MARK: - Errors

    public enum RTPSenderError: Error, CustomStringConvertible {
        case udpConnectFailed(String)
        case converterInitFailed
        case conversionFailed(String)
        case notConnected
        case sendFailed(String)

        public var description: String {
            switch self {
            case .udpConnectFailed(let m): return "RTP UDP connect failed: \(m)"
            case .converterInitFailed:     return "AVAudioConverter init failed"
            case .conversionFailed(let m): return "Sample rate conversion failed: \(m)"
            case .notConnected:            return "RTP sender not connected"
            case .sendFailed(let m):       return "RTP send failed: \(m)"
            }
        }
    }

    // MARK: - Wire-format constants (must match ANNOUNCE SDP fmtp)

    /// Samples per channel per ALAC frame. Declared in the SDP fmtp line
    /// (`a=fmtp:96 352 ...`). Every RTP packet carries exactly one frame.
    public static let framesPerPacket: UInt32 = 352

    /// 44.1 kHz / 16-bit / stereo — the RAOP wire format.
    public static let wireSampleRate: Double = 44100
    public static let wireChannels: Int = 2
    public static let wireBitDepth: Int = 16

    /// Bytes of raw PCM per frame: 352 × 2 ch × 2 bytes = 1408.
    public static let pcmBytesPerFrame: Int =
        Int(framesPerPacket) * wireChannels * (wireBitDepth / 8)

    /// RTP payload type 96 (dynamic). Declared in SDP `m=audio 0 RTP/AVP 96`.
    public static let payloadType: UInt8 = 96

    // MARK: - Session-immutable state

    public let host: String
    public let audioPort: UInt16
    public let controlPort: UInt16
    public let audioLatency: UInt32   // typically 4096, from RECORD's Audio-Latency header
    public let aesKey: Data
    public let aesIV: Data
    public let useEncryption: Bool
    public let initialSequence: UInt16
    public let initialRTPTimestamp: UInt32
    public let ssrc: UInt32

    // MARK: - Pipeline state (sender-thread only)

    /// Caller-supplied sender for control-port packets (sync, retransmit
    /// responses). Must dispatch the data from the same local UDP source
    /// port we advertised in the SETUP Transport header — receivers
    /// `connect()` their control socket to that specific source and drop
    /// anything else with ICMP unreachable. See
    /// `RTSPClient.sendOnControlSocket(_:toHost:port:)`.
    public typealias ControlPacketSender = (Data) -> Void

    private var connection: NWConnection?
    private let controlPacketSender: ControlPacketSender
    private let sendQueue = DispatchQueue(label: "com.davidpuerto.SuperAudio.rtp.send", qos: .userInteractive)
    private var hasSentFirstSync: Bool = false

    private let inputFormat: AVAudioFormat        // capture native (48k f32 stereo)
    private let pcmOutputFormat: AVAudioFormat    // 44.1k int16 stereo PCM
    private let alacOutputFormat: AVAudioFormat   // 44.1k ALAC stereo 16-bit
    private let rateConverter: AVAudioConverter   // f32@48k → int16@44.1k
    private let alacEncoder: AVAudioConverter     // int16@44.1k → ALAC

    /// Accumulator for PCM bytes that haven't filled a full 1408-byte frame yet.
    /// Each `enqueue(_:)` call appends; whenever we have ≥ 1408 bytes, we emit
    /// packets and shrink the carry.
    private var pcmCarry: Data = Data()

    /// Per-packet RTP state.
    private var nextSequence: UInt16
    private var nextRTPTimestamp: UInt32
    private var packetsSent: UInt32 = 0
    private var isFirstPacket: Bool = true

    /// Wall-clock + mach-time anchor pair for the M5c per-chunk sync-NTP
    /// mechanism. Shared across all active sessions via `AudioBroadcaster.shared.anchor`.
    /// Sync packets compute NTP as
    /// `anchorWall + (lastChunkHostTime - anchorHost) * mach_to_seconds + 0.2 s`.
    /// Nil → fall back to per-session `Date() + 200 ms` (pre-M5 behavior).
    private let playbackAnchorWallTime: Date?
    private let playbackAnchorHostTime: UInt64?

    /// Additional manual playback delay in seconds (e.g., 0.250 to delay
    /// by 250 ms). Added to the sync-packet NTP pre-roll so the receiver
    /// schedules audio that much later. Used to balance against Sonos's
    /// ~200–500 ms buffer-floor lag — push AP1 sinks UP by the measured
    /// gap, all three speakers play in audible sync.
    public var manualOffsetSeconds: Double = 0

    /// Host time (`mach_absolute_time`) of the most recently enqueued chunk.
    /// Updated on every `enqueue(_:)` call. Used to compute sync NTP as
    /// "current chunk's wall time + 200 ms pre-roll" — deterministic across
    /// sessions encoding the same chunk, always in the near future.
    private var lastChunkHostTime: UInt64 = 0

    /// Mach time units per second, derived from `mach_timebase_info` once.
    /// Multiply a `mach_absolute_time` delta by this to get seconds.
    private static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }()

    // MARK: - Init

    /// - Parameters:
    ///   - host:                 receiver's IP (e.g., `192.168.1.105`)
    ///   - audioPort:            `server_port` from the M2 SETUP response
    ///   - aesKey / aesIV:       16-byte session key + IV from RTSPClient
    ///   - initialSequence:      sequence number declared in the RECORD `RTP-Info: seq=` header
    ///   - initialRTPTimestamp:  timestamp declared in the RECORD `RTP-Info: rtptime=` header
    ///   - inputFormat:          capture's native AVAudioFormat (typically 48k f32 stereo)
    ///   - playbackAnchorWallTime / playbackAnchorHostTime: the wall-clock
    ///     `Date` and `mach_absolute_time` (paired, describing the same
    ///     instant) from `AudioBroadcaster.shared.anchor`, shared across
    ///     every active session. Sync packets compute their NTP value as
    ///     `anchorWall + (lastChunkHostTime - anchorHost) * mach_to_seconds + 0.2 s` —
    ///     **deterministic across sessions** (same chunk → same NTP) and
    ///     **always in the (near) future** (last chunk's host time is
    ///     approximately "now"). M5c sample-accurate-sync mechanism. Pass
    ///     `nil` for either to fall back to per-session `Date() + 200 ms`
    ///     (pre-M5 behavior).
    public init(
        host: String,
        audioPort: UInt16,
        controlPort: UInt16,
        audioLatency: UInt32 = 4096,
        aesKey: Data,
        aesIV: Data,
        useEncryption: Bool = true,
        initialSequence: UInt16,
        initialRTPTimestamp: UInt32,
        inputFormat: AVAudioFormat,
        playbackAnchorWallTime: Date? = nil,
        playbackAnchorHostTime: UInt64? = nil,
        controlPacketSender: @escaping ControlPacketSender
    ) throws {
        self.host = host
        self.audioPort = audioPort
        self.controlPort = controlPort
        self.audioLatency = audioLatency
        self.aesKey = aesKey
        self.aesIV = aesIV
        self.useEncryption = useEncryption
        self.initialSequence = initialSequence
        self.initialRTPTimestamp = initialRTPTimestamp
        self.nextSequence = initialSequence
        self.nextRTPTimestamp = initialRTPTimestamp
        self.ssrc = UInt32.random(in: 1...UInt32.max)
        self.controlPacketSender = controlPacketSender
        self.playbackAnchorWallTime = playbackAnchorWallTime
        self.playbackAnchorHostTime = playbackAnchorHostTime

        self.inputFormat = inputFormat

        // Stage 1: rate-convert + format-convert capture audio to 44.1 kHz
        // int16 stereo PCM, the canonical AppleLossless source format.
        guard let pcmFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.wireSampleRate,
            channels: AVAudioChannelCount(Self.wireChannels),
            interleaved: true
        ) else { throw RTPSenderError.converterInitFailed }
        self.pcmOutputFormat = pcmFmt
        guard let rc = AVAudioConverter(from: inputFormat, to: pcmFmt) else {
            throw RTPSenderError.converterInitFailed
        }
        self.rateConverter = rc

        // Stage 2: int16 PCM → compressed ALAC. The receiver requires real
        // compressed ALAC; the verbatim escape path (M3a) is silently
        // dropped by B&W A7/A5 firmware. Confirmed via Music.app pcap diff:
        // Music.app emits 642–1117 byte audio packets (compressed); our
        // verbatim mode emits fixed 1412 bytes which the receiver rejects.
        var alacASBD = AudioStreamBasicDescription(
            mSampleRate: Self.wireSampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData),
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.wireChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let alacFmt = AVAudioFormat(streamDescription: &alacASBD) else {
            throw RTPSenderError.converterInitFailed
        }
        self.alacOutputFormat = alacFmt
        guard let enc = AVAudioConverter(from: pcmFmt, to: alacFmt) else {
            throw RTPSenderError.converterInitFailed
        }
        self.alacEncoder = enc

        Log.airplay1.info("RTPSender init: capture=\(String(describing: inputFormat), privacy: .public) → pcm44k16=\(String(describing: pcmFmt), privacy: .public) → ALAC")
        if abs(inputFormat.sampleRate - Self.wireSampleRate) < 1.0 {
            Log.airplay1.info("◆ LOSSLESS PASS-THROUGH — capture is already 44.1 kHz; no rate conversion before ALAC")
        } else {
            Log.airplay1.info("rate conversion active: \(inputFormat.sampleRate) → \(Self.wireSampleRate) — turn on Lossless Mode for bit-perfect 44.1/16 sources")
        }
        Log.airplay1.info("RTPSender init: dst=\(host, privacy: .public):\(audioPort) initSeq=\(initialSequence) initTS=\(initialRTPTimestamp) ssrc=\(self.ssrc) encryption=\(useEncryption ? "et=1 AES" : "et=0 cleartext", privacy: .public)")

        // Read the encoder's magic cookie — the binary blob that records
        // every ALAC parameter the encoder chose (pb / mb / kb / max_run /
        // max_frame_bytes / bit rate). The receiver in our SDP fmtp line
        // expects (pb=40, mb=10, kb=14); if AVAudioConverter picked
        // different defaults, the decoder on the receiver side will
        // misinterpret the bit stream and silently drop everything.
        if let cookieData = enc.value(forKey: "magicCookie") as? Data {
            let hex = cookieData.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            Log.airplay1.info("ALAC encoder magic cookie (\(cookieData.count) bytes): \(hex, privacy: .public)")
        } else {
            Log.airplay1.info("ALAC encoder magic cookie: <not exposed via KVC>")
        }
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - Connection lifecycle

    public func connect(timeout: TimeInterval = 5) async throws {
        if connection != nil { return }

        // Audio UDP connection — RTP packets go here. The receiver's audio
        // socket accepts any source port (verified via PortProbe).
        self.connection = try await openUDP(port: audioPort, label: "RTP audio", timeout: timeout)

        // Sync packets for the control port do NOT get their own NWConnection
        // because the receiver `connect()`s its control socket to the source
        // port we advertised during SETUP — anything from a different source
        // gets ICMP-rejected. Instead sync packets are dispatched via the
        // caller's `controlPacketSender` closure, which routes them through
        // RTSPClient's BSD socket bound to that advertised port.
    }

    private func openUDP(port: UInt16, label: String, timeout: TimeInterval) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RTPSenderError.udpConnectFailed("invalid \(label) port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(to: endpoint, using: params)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            sendQueue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(RTPSenderError.udpConnectFailed("\(label) timeout")))
            }
            conn.stateUpdateHandler = { state in
                Log.airplay1.info("\(label, privacy: .public) UDP state=\(String(describing: state), privacy: .public)")
                switch state {
                case .ready:         resume(.success(()))
                case .failed(let e): resume(.failure(RTPSenderError.udpConnectFailed(String(describing: e))))
                case .cancelled:     resume(.failure(RTPSenderError.udpConnectFailed("\(label) cancelled")))
                default: break
                }
            }
            conn.start(queue: sendQueue)
        }
        return conn
    }

    public func disconnect() {
        Log.airplay1.info("RTPSender disconnect — \(self.packetsSent) packets sent")
        connection?.cancel()
        connection = nil
    }

    // MARK: - Main pump

    /// Feed a captured chunk through the pipeline. May emit zero, one, or
    /// multiple RTP packets depending on how many full 352-sample frames
    /// accumulate after conversion.
    ///
    /// This method blocks the caller on `sendQueue` only briefly — packet
    /// dispatch goes through `NWConnection.send` which queues internally.
    private var enqueueCallsCount: UInt32 = 0
    private var zeroFramePCMCount: UInt32 = 0

    public func enqueue(_ chunk: AudioChunk) throws {
        // Track the most recent chunk's host time — used by `sendSyncPacket`
        // to compute the chunk-anchored NTP wall time (M5c sync mechanism).
        // Every session encoding the same chunk records the same value here,
        // so periodic sync packets across sessions converge on the same NTP.
        lastChunkHostTime = chunk.presentationHostTime
        enqueueCallsCount &+= 1
        if enqueueCallsCount == 1 {
            Log.airplay1.info("enqueue: FIRST chunk received — frames=\(chunk.pcm.frameLength) hostTime=\(chunk.presentationHostTime)")
        }
        if enqueueCallsCount % 250 == 0 {
            Log.airplay1.info("enqueue: \(self.enqueueCallsCount) chunks received, \(self.zeroFramePCMCount) zero-frame PCM results, pcmCarry=\(self.pcmCarry.count) bytes")
        }

        // 1. Rate-convert capture chunk → 44.1k int16 stereo PCM.
        let pcmBuffer = try convertToPCM(chunk.pcm)
        guard pcmBuffer.frameLength > 0 else {
            zeroFramePCMCount &+= 1
            return
        }

        // 2. Append the converted PCM bytes to the carry buffer.
        let byteCount = Int(pcmBuffer.frameLength) * Self.wireChannels * 2
        if let src = pcmBuffer.audioBufferList.pointee.mBuffers.mData {
            pcmCarry.append(Data(bytes: src, count: byteCount))
        }

        // 3. While we have enough PCM for at least one 352-frame ALAC packet,
        //    encode & emit. AVAudioConverter compresses 352 stereo int16
        //    samples (1408 bytes raw) into a variable-length ALAC frame
        //    (typically 700–1100 bytes for music, smaller for silence).
        while pcmCarry.count >= Self.pcmBytesPerFrame {
            let frameBytes = pcmCarry.prefix(Self.pcmBytesPerFrame)
            pcmCarry.removeSubrange(0..<Self.pcmBytesPerFrame)
            let alacBytes = try encodeALAC(pcmBytes: Data(frameBytes))
            try sendOneFrame(alacBytes: alacBytes)
        }
    }

    // MARK: - Conversion

    /// Stage 1: rate-convert capture chunk (48k f32) to 44.1k int16 stereo PCM.
    private func convertToPCM(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFrames = AVAudioFrameCount(input.frameLength)
        let ratio = pcmOutputFormat.sampleRate / inputFormat.sampleRate
        let expected = AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up)) + 32

        guard let out = AVAudioPCMBuffer(pcmFormat: pcmOutputFormat, frameCapacity: expected) else {
            throw RTPSenderError.conversionFailed("pcm buffer alloc failed")
        }
        out.frameLength = 0

        var feed: AVAudioPCMBuffer? = input
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = feed { feed = nil; status.pointee = .haveData; return b }
            status.pointee = .noDataNow
            return nil
        }
        var err: NSError?
        let outStatus = rateConverter.convert(to: out, error: &err, withInputFrom: inputBlock)
        if let err {
            throw RTPSenderError.conversionFailed("PCM convert: \(err.localizedDescription) (status=\(outStatus.rawValue))")
        }
        return out
    }

    /// Stage 2: ALAC-encode exactly one 352-frame block (1408 bytes int16
    /// stereo PCM) into a compressed ALAC frame. Output is variable length.
    private func encodeALAC(pcmBytes: Data) throws -> Data {
        // Wrap the input bytes in an AVAudioPCMBuffer at our pcm format.
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: pcmOutputFormat,
                                            frameCapacity: Self.framesPerPacket)
        else { throw RTPSenderError.conversionFailed("alac input buf alloc failed") }
        inBuf.frameLength = Self.framesPerPacket
        if let dst = inBuf.audioBufferList.pointee.mBuffers.mData {
            pcmBytes.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(dst, base, pcmBytes.count)
                }
            }
        }

        // AVAudioCompressedBuffer for ALAC output. Allocate generously — a
        // 352-frame ALAC packet is bounded by raw PCM size (1408 bytes) plus
        // a small header overhead; 2048 is plenty.
        let outBuf = AVAudioCompressedBuffer(
            format: alacOutputFormat,
            packetCapacity: 1,
            maximumPacketSize: 2048
        )

        var feed: AVAudioPCMBuffer? = inBuf
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = feed { feed = nil; status.pointee = .haveData; return b }
            status.pointee = .noDataNow
            return nil
        }
        var err: NSError?
        let outStatus = alacEncoder.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
        if let err {
            throw RTPSenderError.conversionFailed("ALAC encode: \(err.localizedDescription) (status=\(outStatus.rawValue))")
        }
        guard outBuf.packetCount >= 1,
              let pktDesc = outBuf.packetDescriptions
        else {
            throw RTPSenderError.conversionFailed("ALAC encode produced no packets")
        }
        let byteSize = Int(pktDesc[0].mDataByteSize)
        let offset = Int(pktDesc[0].mStartOffset)
        return Data(bytes: outBuf.data.advanced(by: offset), count: byteSize)
    }

    // MARK: - Per-packet emission

    /// Build and send a single RTP packet for one compressed ALAC frame.
    private func sendOneFrame(alacBytes: Data) throws {
        let alacPayload = alacBytes

        // Encrypt the payload — AES-128-CBC, IV reset to session IV,
        // whole 16-byte blocks only, trailing bytes left in cleartext.
        // When `useEncryption=false` we send cleartext (et=0 in SDP).
        let encrypted: Data = useEncryption
            ? aes128CBCEncryptWholeBlocks(alacPayload, key: aesKey, iv: aesIV)
            : alacPayload

        // 3. Build the 12-byte RTP header.
        let header = buildRTPHeader(
            sequence: nextSequence,
            timestamp: nextRTPTimestamp,
            ssrc: ssrc,
            marker: isFirstPacket
        )

        // 4. Concatenate and send.
        var packet = Data(capacity: header.count + encrypted.count)
        packet.append(header)
        packet.append(encrypted)

        // First-packet wire diagnostic.
        if isFirstPacket {
            let hex = { (d: Data, n: Int) -> String in
                d.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
            }
            Log.airplay1.info("WIRE diag — RTP header (12 bytes): \(hex(header, 12), privacy: .public)")
            Log.airplay1.info("WIRE diag — ALAC frame size = \(alacPayload.count) bytes (compressed, variable)")
            Log.airplay1.info("WIRE diag — ALAC first 16 bytes: \(hex(alacPayload, 16), privacy: .public)")
            Log.airplay1.info("WIRE diag — Encrypted first 16 bytes: \(hex(encrypted, 16), privacy: .public)")
            Log.airplay1.info("WIRE diag — Total wire size = \(packet.count) bytes")
        }

        guard let conn = connection else {
            throw RTPSenderError.notConnected
        }
        conn.send(content: packet, completion: .contentProcessed { error in
            if let error {
                Log.airplay1.error("RTP send failed: \(String(describing: error), privacy: .public)")
            }
        })

        // 5. Advance state.
        nextSequence &+= 1
        nextRTPTimestamp &+= Self.framesPerPacket
        packetsSent &+= 1
        isFirstPacket = false

        // Periodic heartbeat log + sync packet emission (every ~1 second @
        // ~125 packets/sec). Sync packets are mandatory for the receiver to
        // schedule playback — without them, audio buffers fill but never play.
        if packetsSent % 125 == 0 {
            Log.airplay1.info("RTP heartbeat: \(self.packetsSent) packets sent, seq=\(self.nextSequence) ts=\(self.nextRTPTimestamp) lastAlacBytes=\(alacBytes.count)")
            sendSyncPacket(markerFirst: false)
        }
    }

    /// Emit the initial sync packet burst on the control channel. We send
    /// three packets in rapid succession (Music.app's wire behavior) so
    /// the receiver has multiple `(RTP, NTP)` data points to lock its
    /// playback clock before audio arrives.
    ///
    /// If `seedingFirstChunkHostTime` is provided, `lastChunkHostTime` is
    /// pre-seeded so `sendSyncPacket` takes the anchor-branch path and
    /// computes NTP from chunk wall time (instead of `nowNTPPlusSeconds`).
    /// **Required when broadcaster-side delay is in play** — without it,
    /// the initial sync is sent at session start (with NTP = now + 0.2 s)
    /// but the first RTP audio packet doesn't arrive until N seconds later
    /// (broadcaster delay), so the receiver's playback schedule wedges.
    /// With the seed, sendInitialSync is called from the pump task on
    /// receipt of the first chunk → NTP = chunk_wall + 0.2 s = real_wall
    /// + 0.2 s, aligned with when audio actually starts flowing.
    public func sendInitialSync(seedingFirstChunkHostTime: UInt64 = 0) {
        if seedingFirstChunkHostTime != 0 {
            lastChunkHostTime = seedingFirstChunkHostTime
        }
        for _ in 0..<3 {
            sendSyncPacket(markerFirst: true)
        }
        hasSentFirstSync = true
    }

    /// Build and dispatch a 20-byte RAOP sync packet on the control UDP.
    ///
    /// Layout (from shairport-sync's `rtp.c` control-port receiver):
    /// ```
    /// offset  size  field
    /// 0       1     0x80 — RTP V2, no P/X/CC
    /// 1       1     0xd4 first sync (marker bit set), 0x54 subsequent
    /// 2-3     2     flags (big-endian, 0x0007 = +11,025-frame latency offset)
    /// 4-7     4     RTP timestamp "less latency" (current - audioLatency)
    /// 8-11    4     NTP seconds
    /// 12-15   4     NTP fraction
    /// 16-19   4     RTP timestamp (primary — what the NTP time corresponds to)
    /// ```
    private func sendSyncPacket(markerFirst: Bool) {
        let nowRTP = nextRTPTimestamp
        let lessLatencyRTP = nowRTP &- audioLatency
        // M5c sync NTP — per-chunk wall-time:
        //
        //   chunkWallTime = anchorWall + (lastChunkHostTime - anchorHost) * machToSeconds
        //   syncNTP = chunkWallTime + 0.2 s pre-roll
        //
        // Every active session encoding the same chunk computes the SAME
        // `chunkWallTime` (because the anchor is shared from
        // `AudioBroadcaster.shared.anchor` and `lastChunkHostTime` comes
        // from the broadcast chunk's `presentationHostTime`). Their sync
        // packets carry the same NTP → every receiver schedules the same
        // chunk's audio at the same wall time → sample-accurate cross-sink
        // sync.
        //
        // Always in the near future because `lastChunkHostTime` is set on
        // each `enqueue()` and corresponds to "audio captured just now."
        // Late subscribers (e.g., A7 finishing its RTSP handshake ~300 ms
        // after A5) compute the same NTP using the SAME current chunk —
        // no stale past-anchor problem.
        //
        // Fall back to per-session `now + 200 ms` (a) before the first
        // chunk is enqueued (initial sync burst pre-audio) and (b) when
        // anchor isn't provided (pre-M5 callers).
        let ntp: (seconds: UInt32, fraction: UInt32)
        if let anchorWall = playbackAnchorWallTime,
           let anchorHost = playbackAnchorHostTime,
           lastChunkHostTime != 0 {
            // mach time only moves forward, so the subtraction is safe
            // for lastChunkHostTime ≥ anchorHost (which it always is —
            // anchor is set on the first chunk that flows; subsequent
            // chunks have monotonically increasing host times).
            let deltaMach = lastChunkHostTime >= anchorHost
                ? lastChunkHostTime &- anchorHost
                : 0
            let deltaSeconds = Double(deltaMach) * Self.machToSeconds
            let chunkWallTime = anchorWall.addingTimeInterval(deltaSeconds)
            // 200 ms baseline pre-roll + user-configured manual offset
            // (M5d per-sink offset slider). Reading via `self.` so live
            // slider changes from the menu take effect on the next sync
            // packet emission (~1 s cadence).
            ntp = RAOPTiming.ntpFor(date: chunkWallTime, plusSeconds: 0.2 + self.manualOffsetSeconds)
        } else {
            ntp = RAOPTiming.nowNTPPlusSeconds(0.2 + self.manualOffsetSeconds)
        }

        var pkt = Data(count: 20)
        pkt[0]  = 0x80
        pkt[1]  = markerFirst ? 0xd4 : 0x54
        // Flags 0x0000 — no fixed-latency offset. shairport-sync's flag=7
        // ("add 11,025 frames") is for very old AppleTV-1 behavior; modern
        // and 3rd-party AP1 receivers expect 0.
        pkt[2]  = 0x00
        pkt[3]  = 0x00
        pkt[4]  = UInt8((lessLatencyRTP >> 24) & 0xff)
        pkt[5]  = UInt8((lessLatencyRTP >> 16) & 0xff)
        pkt[6]  = UInt8((lessLatencyRTP >>  8) & 0xff)
        pkt[7]  = UInt8( lessLatencyRTP        & 0xff)
        pkt[8]  = UInt8((ntp.seconds >> 24) & 0xff)
        pkt[9]  = UInt8((ntp.seconds >> 16) & 0xff)
        pkt[10] = UInt8((ntp.seconds >>  8) & 0xff)
        pkt[11] = UInt8( ntp.seconds        & 0xff)
        pkt[12] = UInt8((ntp.fraction >> 24) & 0xff)
        pkt[13] = UInt8((ntp.fraction >> 16) & 0xff)
        pkt[14] = UInt8((ntp.fraction >>  8) & 0xff)
        pkt[15] = UInt8( ntp.fraction        & 0xff)
        pkt[16] = UInt8((nowRTP >> 24) & 0xff)
        pkt[17] = UInt8((nowRTP >> 16) & 0xff)
        pkt[18] = UInt8((nowRTP >>  8) & 0xff)
        pkt[19] = UInt8( nowRTP        & 0xff)

        // Dispatch via the caller-supplied closure (routes through RTSPClient's
        // BSD socket bound to our advertised local control port).
        controlPacketSender(pkt)
        Log.airplay1.info("SYNC tx \(markerFirst ? "first" : "tick", privacy: .public) — rtp=\(nowRTP) lessLatencyRTP=\(lessLatencyRTP) ntp=\(ntp.seconds).\(ntp.fraction)")
    }

    // MARK: - RTP header

    /// Build the 12-byte RTP header.
    ///
    /// Byte 0:  V=2, P=0, X=0, CC=0           → 0x80
    /// Byte 1:  M=marker, PT=96               → 0xE0 (marker set, first packet) or 0x60
    /// Bytes 2-3:  sequence number, big-endian
    /// Bytes 4-7:  RTP timestamp, big-endian
    /// Bytes 8-11: SSRC, big-endian
    private func buildRTPHeader(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool) -> Data {
        var h = Data(count: 12)
        h[0] = 0x80
        h[1] = (marker ? 0x80 : 0x00) | (Self.payloadType & 0x7F)
        h[2] = UInt8((sequence >> 8) & 0xFF)
        h[3] = UInt8(sequence & 0xFF)
        h[4] = UInt8((timestamp >> 24) & 0xFF)
        h[5] = UInt8((timestamp >> 16) & 0xFF)
        h[6] = UInt8((timestamp >> 8)  & 0xFF)
        h[7] = UInt8(timestamp & 0xFF)
        h[8]  = UInt8((ssrc >> 24) & 0xFF)
        h[9]  = UInt8((ssrc >> 16) & 0xFF)
        h[10] = UInt8((ssrc >> 8)  & 0xFF)
        h[11] = UInt8(ssrc & 0xFF)
        return h
    }

    // MARK: - PCM endianness conversion

    /// AVAudioConverter outputs int16 samples in host byte order (little-endian
    /// on Apple silicon and Intel). ALAC's wire format expects samples to be
    /// MSB-first when written into the bit-packed frame. Swap each 16-bit
    /// pair before handing to `ALACVerbatimFrame.build(...)`.
    private func convertHostToBigEndian16(_ data: Data) -> Data {
        var swapped = Data(count: data.count)
        data.withUnsafeBytes { src in
            swapped.withUnsafeMutableBytes { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                let n = data.count / 2
                let src16 = s.assumingMemoryBound(to: UInt16.self)
                let dst16 = d.assumingMemoryBound(to: UInt16.self)
                for i in 0..<n {
                    dst16[i] = src16[i].bigEndian
                }
            }
        }
        return swapped
    }
}

// MARK: - AES-128-CBC (whole-block-only) helper

/// Encrypts the leading `data.count - (data.count % 16)` bytes of `data`
/// with AES-128-CBC. Trailing bytes are appended in cleartext.
///
/// **No padding** (kCCOptionPKCS7Padding NOT set). **No CBC chaining
/// across calls** — the caller's `iv` is used verbatim and is reset for
/// every call. RAOP receivers expect this exact behavior.
@usableFromInline
internal func aes128CBCEncryptWholeBlocks(_ data: Data, key: Data, iv: Data) -> Data {
    precondition(key.count == kCCKeySizeAES128, "AES-128 key must be 16 bytes")
    precondition(iv.count == kCCBlockSizeAES128, "AES-128 IV must be 16 bytes")

    let toEncryptLength = (data.count / 16) * 16
    let tailLength = data.count - toEncryptLength
    if toEncryptLength == 0 {
        return data
    }

    var encrypted = Data(count: toEncryptLength)
    var bytesWritten = 0
    let status = encrypted.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
        data.withUnsafeBytes { inBuf in
            key.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(0),                // no padding, no ECB
                        keyBuf.baseAddress, kCCKeySizeAES128,
                        ivBuf.baseAddress,
                        inBuf.baseAddress, toEncryptLength,
                        outBuf.baseAddress, toEncryptLength,
                        &bytesWritten
                    )
                }
            }
        }
    }
    if status != kCCSuccess {
        Log.airplay1.error("CCCrypt AES-128-CBC failed: status=\(status)")
        return data  // fall through unencrypted; receiver will likely reject, but we'll see it in logs
    }

    if tailLength > 0 {
        encrypted.append(data.suffix(tailLength))
    }
    return encrypted
}

// MARK: - ALAC verbatim (escape) frame builder

/// Builds an Apple Lossless verbatim frame from raw 16-bit big-endian
/// interleaved PCM samples.
///
/// Frame structure (bit-level, MSB-first within each byte):
///
///   3 bits:  element_id        = 0b001 (ID_CPE — Channel Pair Element)
///   4 bits:  element_instance_tag = 0
///   12 bits: unused             = 0
///   1 bit:   has_size_explicit  = 0  (use frame_length from MagicCookie, declared in SDP fmtp)
///   2 bits:  wasted_bytes       = 0
///   1 bit:   is_not_compressed  = 1  ← escape flag: raw PCM follows
///   N bits:  raw PCM samples, MSB-first, interleaved L/R, channel bit-depth from MagicCookie
///   3 bits:  ID_END             = 0b111
///   pad:     zero bits to next byte boundary
///
/// For our case (stereo, 16-bit, 352 samples per channel):
///   Header bits:  23
///   PCM bits:     352 × 2 × 16 = 11264
///   ID_END bits:  3
///   Total bits:   11290
///   Bytes:        1412 (with 6 bits of zero padding)
///
/// The receiver's ALAC decoder reads bits sequentially regardless of byte
/// alignment, so the PCM data ends up bit-shifted by 1 within the byte
/// stream. This is normal and correct.
internal enum ALACVerbatimFrame {

    static func build(pcmInterleaved16BE pcm: Data) -> Data {
        precondition(pcm.count == RTPSender.pcmBytesPerFrame,
                     "expected \(RTPSender.pcmBytesPerFrame) bytes of PCM, got \(pcm.count)")

        // Final size: 1412 bytes (1408 bytes PCM × 8 = 11264 bits + 23 header bits + 3 end bits = 11290; round up to 1412).
        var bw = BitWriter()
        bw.reserve(bytes: 1412)

        // Header (23 bits).
        bw.writeBits(value: 0b001, width: 3)       // element_id = ID_CPE
        bw.writeBits(value: 0,     width: 4)       // element_instance_tag
        bw.writeBits(value: 0,     width: 12)      // unused
        bw.writeBits(value: 0,     width: 1)       // has_size_explicit
        bw.writeBits(value: 0,     width: 2)       // wasted_bytes
        bw.writeBits(value: 1,     width: 1)       // is_not_compressed (escape)

        // Raw PCM samples — 11264 bits, MSB-first. The input is already 16-bit
        // big-endian interleaved, so we can fast-path the byte stream into the
        // BitWriter eight bits at a time.
        pcm.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<pcm.count {
                bw.writeBits(value: UInt32(base[i]), width: 8)
            }
        }

        // Trailer.
        bw.writeBits(value: 0b111, width: 3)       // ID_END
        bw.padToByteBoundary()

        return bw.finalize()
    }
}

// MARK: - Bit writer (MSB-first)

/// Tiny MSB-first bit writer. Bits are accumulated into a byte and flushed
/// when the byte is full. `padToByteBoundary()` fills any partial trailing
/// byte with zero bits.
internal struct BitWriter {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var bitsInCurrent: Int = 0

    mutating func reserve(bytes count: Int) { bytes.reserveCapacity(count) }

    mutating func writeBits(value: UInt32, width: Int) {
        precondition(width >= 0 && width <= 32, "width must be 0…32")
        var remaining = width
        while remaining > 0 {
            let take = min(8 - bitsInCurrent, remaining)
            let shift = remaining - take
            let bits = UInt8((value >> shift) & ((1 << take) - 1))
            current = current | (bits << (8 - bitsInCurrent - take))
            bitsInCurrent += take
            remaining -= take
            if bitsInCurrent == 8 {
                bytes.append(current)
                current = 0
                bitsInCurrent = 0
            }
        }
    }

    mutating func padToByteBoundary() {
        if bitsInCurrent > 0 {
            bytes.append(current)
            current = 0
            bitsInCurrent = 0
        }
    }

    func finalize() -> Data {
        return Data(bytes)
    }
}
