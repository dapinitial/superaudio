// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.
//
// LosslessVerify — bit-exact ALAC round-trip test that gates the public
// "lossless to AirPlay 1" marketing claim (per RISK_REGISTER risk T8 and
// ROADMAP M3c).
//
// Build + run:
//   swiftc -O probe/LosslessVerify.swift -o probe/LosslessVerify
//   probe/LosslessVerify
//
// What it does:
//   1. Synthesizes 1 second of a 1 kHz sine wave as 44.1 kHz / 16-bit
//      stereo interleaved PCM (the AirPlay 1 wire format).
//   2. Encodes it with AVAudioConverter, using the exact same ALAC
//      output format `RTPSender` uses in production
//      (kAudioFormatAppleLossless, 16-bit source, 352 frames per packet).
//   3. Decodes the resulting ALAC packets back to PCM with another
//      AVAudioConverter going the opposite direction.
//   4. Compares the decoded PCM bytes to the input bytes via SHA-256.
//      Bit-identical SHA-256 → ALAC compression is genuinely lossless.
//      Any divergence → the claim doesn't ship.
//
// The principle: ALAC is mathematically lossless compression. If we
// configure the encoder correctly and feed it real PCM, the decoded
// output of that encoder MUST be bit-identical to the input. This test
// proves our use of AVAudioConverter satisfies that property; combined
// with Lossless Mode (output rate matched to source so the system
// engine doesn't resample), it proves the end-to-end audio path is
// lossless on the sender side.

import Foundation
import AVFoundation
import CryptoKit
import AudioToolbox

let sampleRate: Double = 44100
let channels: AVAudioChannelCount = 2
let frameCount: AVAudioFrameCount = 44100   // 1 second
let framesPerPacket: UInt32 = 352

print("LosslessVerify — bit-exact ALAC round-trip")
print(String(repeating: "─", count: 64))

// MARK: - 1. Build the input PCM buffer

guard let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: sampleRate,
    channels: channels,
    interleaved: true
) else {
    print("FAIL: could not build PCM format")
    exit(1)
}

guard let inputBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
    print("FAIL: could not allocate input buffer")
    exit(1)
}
inputBuf.frameLength = frameCount

let amplitude: Double = 10_000     // ~30% of int16 range; comfortably mid-scale
let radiansPerSample = 2.0 * Double.pi * 1000.0 / sampleRate

if let dst = inputBuf.audioBufferList.pointee.mBuffers.mData {
    let samples = dst.assumingMemoryBound(to: Int16.self)
    for i in 0..<Int(frameCount) {
        let v = Int16(amplitude * sin(radiansPerSample * Double(i)))
        samples[i * 2]     = v
        samples[i * 2 + 1] = v
    }
}

let inputByteCount = Int(frameCount) * Int(channels) * 2
let inputData = Data(
    bytes: inputBuf.audioBufferList.pointee.mBuffers.mData!,
    count: inputByteCount
)
let inputHash = SHA256.hash(data: inputData)
    .map { String(format: "%02x", $0) }
    .joined()

print("Input PCM:        \(frameCount) frames × \(channels) ch × 16-bit = \(inputByteCount) bytes")
print("Input SHA-256:    \(inputHash)")

// MARK: - 2. Build the ALAC output format

var alacASBD = AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatAppleLossless,
    mFormatFlags: AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData),
    mBytesPerPacket: 0,
    mFramesPerPacket: framesPerPacket,
    mBytesPerFrame: 0,
    mChannelsPerFrame: UInt32(channels),
    mBitsPerChannel: 0,
    mReserved: 0
)
guard let alacFormat = AVAudioFormat(streamDescription: &alacASBD) else {
    print("FAIL: could not build ALAC format")
    exit(1)
}

// MARK: - 3. Encode PCM → ALAC

guard let encoder = AVAudioConverter(from: pcmFormat, to: alacFormat) else {
    print("FAIL: could not init encoder")
    exit(1)
}

// Snapshot the encoder's magic cookie. The decoder needs it to know
// the precise ALAC parameters (pb / mb / kb / max_run / max_frame_bytes /
// avg_bit_rate) the encoder chose. Without it, decoder fails with
// OSStatus 560226676 ("encoder/decoder configs don't match").
let encoderMagicCookie = encoder.value(forKey: "magicCookie") as? Data
print("Magic cookie:     \(encoderMagicCookie?.count ?? 0) bytes")

var alacPackets: [Data] = []
var encodeFeed: AVAudioPCMBuffer? = inputBuf

while true {
    let outBuf = AVAudioCompressedBuffer(
        format: alacFormat,
        packetCapacity: 1,
        maximumPacketSize: 4096
    )
    let inputBlock: AVAudioConverterInputBlock = { _, status in
        if let b = encodeFeed {
            encodeFeed = nil
            status.pointee = .haveData
            return b
        }
        // .endOfStream tells the encoder to flush any partial last packet
        // (the 100-frame tail when 44100 doesn't divide evenly by 352).
        // .noDataNow holds them indefinitely and we lose the tail.
        status.pointee = .endOfStream
        return nil
    }
    var err: NSError?
    let outStatus = encoder.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
    if let err {
        print("FAIL: ALAC encode error: \(err.localizedDescription)")
        exit(1)
    }
    if outBuf.packetCount == 0 {
        if outStatus == .endOfStream || outStatus == .inputRanDry { break }
        if encodeFeed == nil { break }
        continue
    }
    guard let pktDesc = outBuf.packetDescriptions else {
        print("FAIL: encoder produced packet without descriptions")
        exit(1)
    }
    let byteSize = Int(pktDesc[0].mDataByteSize)
    let offset   = Int(pktDesc[0].mStartOffset)
    let pkt = Data(bytes: outBuf.data.advanced(by: offset), count: byteSize)
    alacPackets.append(pkt)
}

let alacTotalBytes = alacPackets.reduce(0) { $0 + $1.count }
let compressionRatio = Double(alacTotalBytes) / Double(inputByteCount)
print("ALAC encoded:     \(alacPackets.count) packets, \(alacTotalBytes) bytes (compression ratio \(String(format: "%.2f", compressionRatio))×)")

guard alacPackets.count > 0 else {
    print("FAIL: encoder produced no ALAC packets")
    exit(1)
}

// MARK: - 4. Decode ALAC → PCM via AudioConverter C API
//
// `AVAudioConverter`'s `magicCookie` property is read-only on the
// Obj-C bridge (`setValue(_:forKey:"magicCookie")` silently fails —
// verified empirically: read-after-write returns nil). The C-API
// `AudioConverter` exposes the cookie via `AudioConverterSetProperty
// (..., kAudioConverterDecompressionMagicCookie, ...)`, which is the
// only working path for an ALAC decoder.

// Build the PCM output ASBD (must match pcmFormat's stream description).
var outASBD = pcmFormat.streamDescription.pointee

// Build the ALAC input ASBD (same as the encoder's output).
var inASBD = alacASBD

// Create the converter.
var converterRef: AudioConverterRef?
let createStatus = AudioConverterNew(&inASBD, &outASBD, &converterRef)
guard createStatus == noErr, let converter = converterRef else {
    print("FAIL: AudioConverterNew failed: OSStatus \(createStatus)")
    exit(1)
}
defer { AudioConverterDispose(converter) }

// Apply the magic cookie from the encoder.
if let cookie = encoderMagicCookie {
    let setStatus = cookie.withUnsafeBytes { buf -> OSStatus in
        guard let base = buf.baseAddress else { return -1 }
        return AudioConverterSetProperty(
            converter,
            kAudioConverterDecompressionMagicCookie,
            UInt32(cookie.count),
            base
        )
    }
    if setStatus != noErr {
        print("FAIL: setting decompression magic cookie failed: OSStatus \(setStatus)")
        exit(1)
    }
    print("Decoder cookie set:    ✓ \(cookie.count) bytes")
}

// State for the input data callback. Holds the packet array + cursor;
// the callback returns one packet per invocation and reports EOF when
// the cursor advances past the array.
final class DecodeFeedContext {
    let packets: [Data]
    var cursor: Int = 0
    // Each call hands the converter pointers that must remain valid
    // until the NEXT call. We pin (a) the current packet's bytes by
    // holding the Data, and (b) the description struct in a heap-
    // allocated buffer addressable as UnsafeMutablePointer.
    var currentPacketBytes: Data? = nil
    let descriptionPtr: UnsafeMutablePointer<AudioStreamPacketDescription> =
        .allocate(capacity: 1)

    init(_ packets: [Data]) {
        self.packets = packets
        descriptionPtr.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0
        )
    }
    deinit { descriptionPtr.deallocate() }
}

let feedContext = DecodeFeedContext(alacPackets)
let feedPointer = Unmanaged.passUnretained(feedContext).toOpaque()

let inputCallback: AudioConverterComplexInputDataProc = {
    _, ioNumDataPackets, ioData, outDataPacketDescription, inUserData in

    guard let userData = inUserData else { return -50 /* kAudio_ParamError */ }
    let ctx = Unmanaged<DecodeFeedContext>.fromOpaque(userData).takeUnretainedValue()

    guard ctx.cursor < ctx.packets.count else {
        // No more packets — tell the converter EOF.
        ioNumDataPackets.pointee = 0
        return noErr
    }

    let pkt = ctx.packets[ctx.cursor]
    ctx.cursor += 1
    ctx.currentPacketBytes = pkt

    // The converter expects the bytes to remain valid until the next
    // call — Data's contiguous storage backs `currentPacketBytes`, so
    // we hand out a pointer to that storage.
    pkt.withUnsafeBytes { src in
        if let base = src.baseAddress {
            let buf = UnsafeMutableAudioBufferListPointer(ioData)
            buf[0].mNumberChannels = 2
            buf[0].mData = UnsafeMutableRawPointer(mutating: base)
            buf[0].mDataByteSize = UInt32(pkt.count)
        }
    }
    ctx.descriptionPtr.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: UInt32(pkt.count)
    )

    ioNumDataPackets.pointee = 1
    if let descPtr = outDataPacketDescription {
        descPtr.pointee = ctx.descriptionPtr
    }
    return noErr
}

// Output PCM buffer — 1 second's worth of int16 stereo plus headroom.
let decodedFrameCapacity = Int(frameCount) + 4096
let decodedByteCapacity = decodedFrameCapacity * Int(channels) * 2
let decodedBytes = UnsafeMutablePointer<Int16>.allocate(capacity: decodedByteCapacity / 2)
defer { decodedBytes.deallocate() }

var outputBufferList = AudioBufferList(
    mNumberBuffers: 1,
    mBuffers: AudioBuffer(
        mNumberChannels: UInt32(channels),
        mDataByteSize: UInt32(decodedByteCapacity),
        mData: UnsafeMutableRawPointer(decodedBytes)
    )
)

var producedPCMFrames: Int = 0
while true {
    // For PCM output, one "packet" = one frame (the format is
    // non-compressed). Ask for one ALAC frame's worth of PCM frames per
    // call — 352 — so the converter pulls exactly one input packet at
    // a time. The PCM output buffer holds enough headroom for that.
    var ioOutputDataPacketSize: UInt32 = UInt32(framesPerPacket)

    let remainingBytes = decodedByteCapacity - producedPCMFrames * Int(channels) * 2
    if remainingBytes <= 0 { break }
    outputBufferList.mBuffers.mData = UnsafeMutableRawPointer(
        decodedBytes.advanced(by: producedPCMFrames * Int(channels))
    )
    outputBufferList.mBuffers.mDataByteSize = UInt32(remainingBytes)

    let fillStatus = AudioConverterFillComplexBuffer(
        converter,
        inputCallback,
        feedPointer,
        &ioOutputDataPacketSize,
        &outputBufferList,
        nil
    )
    if fillStatus != noErr {
        // Likely "no more input"; we end up here when the callback
        // returned ioNumDataPackets=0 because all packets are consumed.
        // Treat as graceful stop.
        break
    }
    // PCM: 1 frame per packet, so producedThisIter == ioOutputDataPacketSize.
    let producedThisIter = Int(ioOutputDataPacketSize)
    if producedThisIter == 0 { break }
    producedPCMFrames += producedThisIter
    if producedPCMFrames >= Int(frameCount) {
        // We have at least one second of decoded audio — input must be
        // exhausted or about to be. Stop.
        break
    }
}

let decodedByteCount = producedPCMFrames * Int(channels) * 2
let decodedData = Data(bytes: decodedBytes, count: decodedByteCount)
let decodedHash = SHA256.hash(data: decodedData)
    .map { String(format: "%02x", $0) }
    .joined()

print("Decoded PCM:      \(producedPCMFrames) frames, \(decodedByteCount) bytes")
print("Decoded SHA-256:  \(decodedHash)")
print(String(repeating: "─", count: 64))

// MARK: - 5. Compare

if inputHash == decodedHash && decodedByteCount == inputByteCount {
    print("✅ BIT-EXACT — ALAC round-trip is lossless. Cleared to ship 'lossless' marketing claim.")
    exit(0)
} else {
    print("❌ FAIL — ALAC round-trip is NOT bit-exact.")
    if let inB = inputBuf.audioBufferList.pointee.mBuffers.mData?
        .assumingMemoryBound(to: Int16.self)
    {
        let n = min(producedPCMFrames, Int(frameCount)) * Int(channels)
        for i in 0..<n {
            if inB[i] != decodedBytes[i] {
                print("  first divergence at sample \(i): input=\(inB[i]), decoded=\(decodedBytes[i])")
                break
            }
        }
    }
    exit(1)
}
