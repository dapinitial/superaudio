// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import AVFoundation
import AudioToolbox
import SuperAudioCore

/// Encodes incoming 48 kHz / float32 / stereo PCM (`AVAudioPCMBuffer`) to
/// **AAC-LC frames wrapped in ADTS headers**, suitable for streaming over
/// HTTP to a Sonos `SetAVTransportURI` consumer.
///
/// Why ADTS vs an M4A container:
///
///   - ADTS frames are self-contained (each has a 7-byte header naming
///     sample rate, channel count, and frame size). The receiver can
///     join a stream at any point and resynchronize on the next header
///     — exactly what we need for a continuous HTTP stream.
///   - M4A wraps AAC in an MP4 container with a 'moov' atom that
///     describes the entire file. Sonos accepts MP4-AAC but for
///     streaming it needs a `moov` atom up front, which a continuous
///     stream doesn't have a clean way to produce.
///
/// AVAudioConverter handles the actual encode. We append the ADTS
/// header per-frame on output.
///
/// Default config: AAC-LC, 48 kHz output (matches capture native rate
/// so no resampling), 2 channels, 192 kbps. Sonos accepts a wide range;
/// 192 kbps is a good "high quality without being wasteful" pick.
public final class AACEncoder: @unchecked Sendable {

    public enum AACEncoderError: Error, CustomStringConvertible {
        case converterInitFailed
        case conversionFailed(String)
        case producedNoOutput

        public var description: String {
            switch self {
            case .converterInitFailed:     return "AVAudioConverter init failed for PCM → AAC-LC"
            case .conversionFailed(let m): return "AAC encode failed: \(m)"
            case .producedNoOutput:        return "AAC encoder produced no output for the given input"
            }
        }
    }

    // Wire format constants for the ADTS header.
    public static let outputSampleRate: Double = 48000
    public static let outputChannels: Int = 2
    public static let framesPerAACPacket: Int = 1024     // AAC-LC standard frame size
    public static let bitRate: Int = 192_000             // 192 kbit/s

    public let inputFormat: AVAudioFormat
    public let aacFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(inputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat

        var aacASBD = AudioStreamBasicDescription(
            mSampleRate: Self.outputSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerAACPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.outputChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aacFmt = AVAudioFormat(streamDescription: &aacASBD) else {
            throw AACEncoderError.converterInitFailed
        }
        self.aacFormat = aacFmt

        guard let conv = AVAudioConverter(from: inputFormat, to: aacFmt) else {
            throw AACEncoderError.converterInitFailed
        }
        conv.bitRate = Self.bitRate
        // Low-latency mode: prefer minimal encoder priming for live streams.
        // Some toolchains expose this as a property; if unavailable it's
        // safe to skip — default behavior is fine for our latency tolerance.
        self.converter = conv

        Log.sonos.info("AACEncoder ready — input \(String(describing: inputFormat), privacy: .public) → AAC-LC \(Int(Self.outputSampleRate))Hz \(Self.outputChannels)ch @ \(Self.bitRate / 1000) kbps")
    }

    /// Encode one PCM buffer to zero-or-more ADTS-wrapped AAC frames.
    /// Returns the concatenated bytes; caller pumps them straight to the
    /// HTTP socket (`SonosStreamServer.append(_:)`).
    public func encode(_ pcm: AVAudioPCMBuffer) throws -> Data {
        guard pcm.frameLength > 0 else { return Data() }

        var output = Data()

        // The encoder may produce zero, one, or several AAC packets per
        // input call depending on internal buffering. Drain in a loop.
        var feed: AVAudioPCMBuffer? = pcm
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = feed {
                feed = nil
                status.pointee = .haveData
                return b
            }
            status.pointee = .noDataNow
            return nil
        }

        while true {
            let outBuf = AVAudioCompressedBuffer(
                format: aacFormat,
                packetCapacity: 1,
                maximumPacketSize: 4096
            )
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
            if let err {
                throw AACEncoderError.conversionFailed(err.localizedDescription)
            }
            if outBuf.packetCount == 0 {
                if status == .endOfStream || status == .inputRanDry { break }
                if feed == nil { break }
                continue
            }
            guard let pktDesc = outBuf.packetDescriptions else { continue }
            let byteSize = Int(pktDesc[0].mDataByteSize)
            let offset   = Int(pktDesc[0].mStartOffset)
            let aacBytes = Data(bytes: outBuf.data.advanced(by: offset), count: byteSize)

            // Prepend the 7-byte ADTS header so the consumer can sync
            // to frame boundaries without out-of-band format info.
            let header = adtsHeader(payloadBytes: aacBytes.count)
            output.append(header)
            output.append(aacBytes)
        }

        return output
    }

    /// Construct a 7-byte ADTS header for an AAC-LC frame.
    ///
    /// Bit layout (per ISO/IEC 13818-7):
    /// ```
    ///   syncword            12 bits  = 0xFFF
    ///   ID                   1 bit   = 0  (MPEG-4)
    ///   layer                2 bits  = 0
    ///   protection_absent    1 bit   = 1  (no CRC)
    ///   profile              2 bits  = 1  (AAC-LC, value 2 minus 1)
    ///   sampling_freq_index  4 bits  (= 3 for 48 kHz)
    ///   private              1 bit   = 0
    ///   channel_config       3 bits  = 2  (L+R stereo)
    ///   original/copy        1 bit   = 0
    ///   home                 1 bit   = 0
    ///   copyright_id_bit     1 bit   = 0
    ///   copyright_id_start   1 bit   = 0
    ///   frame_length        13 bits  (header + payload bytes)
    ///   buffer_fullness     11 bits  = 0x7FF
    ///   num_rdb_in_frame     2 bits  = 0  (1 RDB)
    /// ```
    private func adtsHeader(payloadBytes: Int) -> Data {
        let frameLength: UInt16 = UInt16(7 + payloadBytes)
        let profileMinus1: UInt8 = 1   // AAC-LC = 2; field is profile-1 = 1
        let samplingFreqIndex: UInt8 = 3   // 48 kHz
        let channelConfig: UInt8 = 2       // stereo

        var h = Data(count: 7)
        h[0] = 0xFF
        // syncword high 4 bits done; bits 4-7 of byte 1: syncword low 4 bits + ID=0 + layer=00 + protection_absent=1
        h[1] = 0xF1
        // byte 2: profile-1 (2 bits) << 6 | sampling_freq_index (4 bits) << 2 | channel_config high bit (1 bit)
        h[2] = (profileMinus1 << 6)
             | (samplingFreqIndex << 2)
             | ((channelConfig & 0b100) >> 2)
        // byte 3: channel_config low 2 bits (1 + 1) << 6 | originality+home+copyright bits (4 bits = 0) << 2 | frame_length high 2 bits
        h[3] = ((channelConfig & 0b011) << 6)
             | UInt8((frameLength >> 11) & 0x03)
        h[4] = UInt8((frameLength >> 3) & 0xFF)
        // byte 5: frame_length low 3 bits << 5 | buffer_fullness top 5 bits (we use 0x7FF, top 5 = 0x1F)
        h[5] = (UInt8(frameLength & 0x07) << 5) | 0x1F
        // byte 6: buffer_fullness low 6 bits (0x3F) << 2 | num_rdb_in_frame (2 bits = 0)
        h[6] = 0xFC
        return h
    }
}
