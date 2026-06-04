// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Reusable system audio capture via the macOS 14.4+ CoreAudio process tap API.
///
/// Wraps the Day 0 probe's flow as a real long-running class:
///   1. Create a system-wide `CATapDescription` (empty `processes` array +
///      `isExclusive = true` ⇒ "exclude nothing" ⇒ tap everything).
///   2. `AudioHardwareCreateProcessTap` → tap object.
///   3. Read `kAudioTapPropertyFormat` to learn the native stream format.
///   4. `AudioHardwareCreateAggregateDevice` wrapping the tap.
///   5. Install an IO proc on the aggregate, start the device.
///   6. Each IO callback yields an `AudioChunk` into the `chunks` stream.
///
/// Consumers (mixer / sink encoders) read the `chunks` stream:
/// ```
/// for await chunk in capture.chunks {
///     // SRC + ALAC + RTP packetize for each active AirPlay 1 sink, etc.
/// }
/// ```
///
/// **Real-time safety caveat (v1 POC):** the IO callback allocates an
/// `AVAudioPCMBuffer` per chunk and yields into a Swift `AsyncStream`.
/// Both are non-zero work for an RT thread. In practice at typical
/// 512-frame / ~10.7 ms callback periods this is fine; under heavy load
/// we may see glitches. A future pass will pool buffers and use a
/// lock-free SPSC ring instead. Documented gotcha, not a v1 blocker.
public final class SystemAudioCapture: @unchecked Sendable {

    public enum CaptureError: Error, CustomStringConvertible {
        case tapCreateFailed(OSStatus)
        case formatReadFailed(OSStatus)
        case aggregateCreateFailed(OSStatus)
        case ioProcCreateFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case unsupportedFormat

        public var description: String {
            switch self {
            case .tapCreateFailed(let s):       return "AudioHardwareCreateProcessTap failed: OSStatus \(s)"
            case .formatReadFailed(let s):      return "kAudioTapPropertyFormat read failed: OSStatus \(s)"
            case .aggregateCreateFailed(let s): return "AudioHardwareCreateAggregateDevice failed: OSStatus \(s)"
            case .ioProcCreateFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(s)"
            case .deviceStartFailed(let s):     return "AudioDeviceStart failed: OSStatus \(s)"
            case .unsupportedFormat:            return "Capture format not representable as AVAudioFormat"
            }
        }
    }

    /// PCM format CoreAudio reported for the tap. Available after `start()`.
    public private(set) var streamFormat: AVAudioFormat?

    /// Continuous stream of captured audio chunks. Subscribe before `start()`.
    public let chunks: AsyncStream<AudioChunk>

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let ioQueue = DispatchQueue(label: "com.davidpuerto.SuperAudio.capture.io", qos: .userInteractive)

    private var asbd = AudioStreamBasicDescription()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID: UUID?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sequence: UInt32 = 0
    private var isRunning = false

    public init() {
        var continuation: AsyncStream<AudioChunk>.Continuation!
        self.chunks = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        Log.capture.info("SystemAudioCapture.start")

        // 1. Tap description (system-wide).
        let desc = CATapDescription()
        desc.name = "superaudio-capture-tap"
        desc.processes = []
        desc.isExclusive = true
        desc.isMixdown = true
        desc.isMono = false
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.deviceUID = nil
        desc.stream = 0
        let uuid = desc.uuid
        self.tapUUID = uuid

        // 2. Install the tap.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr else {
            throw CaptureError.tapCreateFailed(tapStatus)
        }
        self.tapID = newTapID

        // 3. Read the tap's native stream format.
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(newTapID, &fmtAddr, 0, nil, &fmtSize, &asbd)
        guard fmtStatus == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw CaptureError.formatReadFailed(fmtStatus)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw CaptureError.unsupportedFormat
        }
        self.streamFormat = format
        Log.capture.info("Capture format: sr=\(self.asbd.mSampleRate) ch=\(self.asbd.mChannelsPerFrame) bytesPerFrame=\(self.asbd.mBytesPerFrame) flags=0x\(String(self.asbd.mFormatFlags, radix: 16))")

        // 4. Aggregate device wrapping the tap.
        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey:         "superaudio-capture-aggregate",
            kAudioAggregateDeviceUIDKey:          aggUID,
            kAudioAggregateDeviceIsPrivateKey:    true,
            kAudioAggregateDeviceIsStackedKey:    false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAggID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw CaptureError.aggregateCreateFailed(aggStatus)
        }
        self.aggregateID = newAggID

        // 5. Install IO proc.
        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, ioQueue) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handleIOCallback(inInputData: inInputData, inInputTime: inInputTime)
        }
        guard createStatus == noErr, let createdProcID = newProcID else {
            AudioHardwareDestroyAggregateDevice(newAggID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw CaptureError.ioProcCreateFailed(createStatus)
        }
        self.procID = createdProcID

        // 6. Start.
        let startStatus = AudioDeviceStart(newAggID, createdProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(newAggID, createdProcID)
            AudioHardwareDestroyAggregateDevice(newAggID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw CaptureError.deviceStartFailed(startStatus)
        }
        isRunning = true
        Log.capture.info("SystemAudioCapture running — aggregate=\(self.aggregateID) tap=\(self.tapID)")
    }

    public func stop() {
        guard isRunning else { return }
        Log.capture.info("SystemAudioCapture.stop")
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    // MARK: - IO callback

    private func handleIOCallback(
        inInputData: UnsafePointer<AudioBufferList>,
        inInputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let format = streamFormat else { return }

        let bufferList = inInputData.pointee
        let buffer = bufferList.mBuffers
        let bytesPerFrame = max(asbd.mBytesPerFrame, 1)
        let frameCount = buffer.mDataByteSize / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        // Copy interleaved/packed bytes from CoreAudio into the PCM buffer's
        // first-channel data pointer. AVAudioPCMBuffer treats this as
        // interleaved if the format is interleaved.
        if let dest = pcm.audioBufferList.pointee.mBuffers.mData,
           let src  = buffer.mData {
            memcpy(dest, src, Int(buffer.mDataByteSize))
        }

        sequence &+= 1
        let chunk = AudioChunk(
            pcm: pcm,
            sequence: sequence,
            presentationHostTime: inInputTime.pointee.mHostTime
        )
        continuation.yield(chunk)
    }
}
