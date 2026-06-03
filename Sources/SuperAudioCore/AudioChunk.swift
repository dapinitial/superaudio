// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import AVFoundation

/// A fixed-duration block of PCM audio with a wall-clock time describing
/// when its first sample was captured (in `mach_absolute_time` units).
///
/// Mixer fans these out to every active sink. Each sink translates the
/// host time into its protocol's clock domain, adds per-sink latency, and
/// schedules delivery so the receiver plays it at the same moment.
///
/// `pcm` carries the sample data. The native capture format from CoreAudio
/// process taps is typically 48 kHz / float32 / stereo; sinks that need
/// other formats (e.g., AirPlay 1 RAOP expects 44.1 kHz / int16 ALAC)
/// run their own `AVAudioConverter` step on the way out.
///
/// `@unchecked Sendable` because `AVAudioPCMBuffer` isn't natively
/// Sendable, but we treat chunks as immutable after creation. Producers
/// must not mutate the buffer after yielding.
public struct AudioChunk: @unchecked Sendable {
    public let pcm: AVAudioPCMBuffer
    public let sequence: UInt32
    public let presentationHostTime: UInt64

    public init(pcm: AVAudioPCMBuffer, sequence: UInt32, presentationHostTime: UInt64) {
        self.pcm = pcm
        self.sequence = sequence
        self.presentationHostTime = presentationHostTime
    }

    /// Allocate a new `AudioChunk` with its own PCM memory, copying the
    /// samples from `self.pcm` byte-for-byte. Needed when a chunk must
    /// outlive the CoreAudio callback that produced it — e.g., when
    /// `AudioBroadcaster` schedules a delayed yield via `Task.detached`,
    /// the original buffer's backing memory may be recycled by CoreAudio
    /// before the delay elapses. Calling `makeCopy()` immediately on
    /// receipt guarantees the copy survives the sleep.
    ///
    /// `presentationHostTime` and `sequence` can optionally be overridden;
    /// otherwise they're preserved from the original. The override is the
    /// load-bearing piece for sender-side delay: after `Task.sleep`, the
    /// delayed yield site rewrites the host time to "original + delay" so
    /// downstream sync-NTP math lands in the present, not the past.
    public func makeCopy(
        rewritingPresentationHostTime newHostTime: UInt64? = nil,
        rewritingSequence newSequence: UInt32? = nil
    ) -> AudioChunk {
        let copy = AVAudioPCMBuffer(
            pcmFormat: pcm.format,
            frameCapacity: pcm.frameCapacity
        )!
        copy.frameLength = pcm.frameLength
        // Handle both interleaved (1 buffer) and non-interleaved (N
        // buffers per channel) layouts. Capture today is interleaved
        // 48k f32 stereo so N=1, but the loop costs nothing and
        // future-proofs against a planar capture path.
        let srcList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<srcList.count {
            let srcBuf = srcList[i]
            let dstBuf = dstList[i]
            if let src = srcBuf.mData, let dst = dstBuf.mData {
                memcpy(dst, src, Int(srcBuf.mDataByteSize))
            }
        }
        return AudioChunk(
            pcm: copy,
            sequence: newSequence ?? sequence,
            presentationHostTime: newHostTime ?? presentationHostTime
        )
    }
}
