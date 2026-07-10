// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import AVFoundation
import SuperAudioCore

/// Encodes fixed `framesPerPacket`-sample int16 PCM frames into ALAC packets —
/// the payload format AirPlay 2 realtime (type 96) carries (same as AirPlay 1
/// RAOP). Uses Apple's built-in ALAC encoder via `AVAudioConverter`. Standard
/// 44100/16/2 / 352-frame parameters, which the AP2 `audioFormat 0x40000`
/// declaration implies to the receiver.
final class ALACFrameEncoder {

    private let framesPerPacket: AVAudioFrameCount
    private let pcmFormat: AVAudioFormat
    private let alacFormat: AVAudioFormat
    private let encoder: AVAudioConverter

    init?(sampleRate: Double, framesPerPacket: Int) {
        self.framesPerPacket = AVAudioFrameCount(framesPerPacket)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: sampleRate, channels: 2, interleaved: true) else { return nil }
        self.pcmFormat = pcm
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let alac = AVAudioFormat(streamDescription: &asbd),
              let enc = AVAudioConverter(from: pcm, to: alac) else { return nil }
        self.alacFormat = alac
        self.encoder = enc
    }

    /// Encode one `framesPerPacket`-sample interleaved-int16-stereo frame
    /// (`framesPerPacket * 2ch * 2B` bytes) into one ALAC packet. Returns nil
    /// on any encoder error (logged by the caller).
    func encode(_ pcmBytes: Data) -> Data? {
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: framesPerPacket) else { return nil }
        inBuf.frameLength = framesPerPacket
        if let dst = inBuf.audioBufferList.pointee.mBuffers.mData {
            pcmBytes.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(dst, base, min(pcmBytes.count, Int(inBuf.audioBufferList.pointee.mBuffers.mDataByteSize))) }
            }
        }
        let outBuf = AVAudioCompressedBuffer(format: alacFormat, packetCapacity: 1, maximumPacketSize: 2048)
        var feed: AVAudioPCMBuffer? = inBuf
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = feed { feed = nil; status.pointee = .haveData; return b }
            status.pointee = .noDataNow
            return nil
        }
        var err: NSError?
        _ = encoder.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
        guard err == nil, outBuf.packetCount >= 1, let desc = outBuf.packetDescriptions else { return nil }
        let size = Int(desc[0].mDataByteSize)
        let offset = Int(desc[0].mStartOffset)
        return Data(bytes: outBuf.data.advanced(by: offset), count: size)
    }
}
