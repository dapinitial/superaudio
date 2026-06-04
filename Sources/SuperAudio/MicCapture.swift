// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import AVFoundation
import SuperAudioCore

/// Captures audio from the Mac's default input device (built-in mic in the
/// common case) for a bounded duration. **One-shot**: start → buffer for N
/// seconds → return the captured PCM.
///
/// Used by M11 Path A auto-calibration (#98): play a known reference signal
/// through one speaker, capture from the mic, cross-correlate captured mic
/// audio vs the broadcaster's known-good chunks → recover the speaker's
/// total round-trip lag. Per-speaker lag → auto-aligned per-sink offset.
///
/// Lifecycle:
/// - `requestPermission()` triggers TCC mic prompt if not yet decided.
/// - `capture(duration:)` records for `duration` seconds, returns the
///   accumulated PCM buffer. Throws if permission denied or capture fails.
///
/// **Not connected to `SystemAudioCapture` / `AudioBroadcaster`** — that
/// path captures system output (process tap). This path captures input
/// (microphone). Completely separate audio engines.
@MainActor
final class MicCapture {

    enum MicCaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case engineStartFailed(String)
        case captureFailed(String)

        var description: String {
            switch self {
            case .permissionDenied:           return "Microphone permission denied"
            case .engineStartFailed(let m):   return "AVAudioEngine.start() failed: \(m)"
            case .captureFailed(let m):       return "Mic capture failed: \(m)"
            }
        }
    }

    /// Result of one capture: the raw float32 PCM samples + the format
    /// metadata. Stereo input is downmixed to mono by averaging channels —
    /// for cross-correlation we don't need spatial info.
    struct CaptureResult {
        /// Mono float samples, sample rate = `sampleRate`.
        let samples: [Float]
        let sampleRate: Double
        let durationSeconds: Double
    }

    /// Request microphone permission. Returns when the user has decided
    /// (granted or denied). Idempotent — safe to call repeatedly.
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Capture `duration` seconds of audio from the default input device.
    /// Returns the captured PCM as a mono float32 array.
    ///
    /// Implementation notes:
    /// - Uses `AVAudioEngine` with the input node's native format (typically
    ///   48 kHz f32 stereo for the MacBook built-in mic).
    /// - Installs a tap on the input node that appends each buffer's
    ///   samples to an in-memory accumulator.
    /// - Stops the engine after `duration` seconds and returns.
    func capture(duration: TimeInterval) async throws -> CaptureResult {
        let status = Self.authorizationStatus
        guard status == .authorized || status == .notDetermined else {
            throw MicCaptureError.permissionDenied
        }
        if status == .notDetermined {
            let granted = await Self.requestPermission()
            guard granted else { throw MicCaptureError.permissionDenied }
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)

        Log.app.notice("MicCapture: input format = \(sampleRate, privacy: .public) Hz, \(channelCount) channel(s), \(String(describing: format.commonFormat), privacy: .public)")

        // Accumulator — protected by a serial queue so the tap callback
        // and the await-completion path don't race.
        var accumulator: [Float] = []
        accumulator.reserveCapacity(Int(sampleRate * duration) + 1024)
        let accumQueue = DispatchQueue(label: "com.davidpuerto.SuperAudio.MicCapture.accum")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Downmix to mono by averaging channels. AVAudioPCMBuffer
            // exposes channel data as a pointer-to-pointer of Float32.
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: frameCount)
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<frameCount {
                    mono[i] += ptr[i]
                }
            }
            if channelCount > 1 {
                let inv = 1.0 / Float(channelCount)
                for i in 0..<frameCount {
                    mono[i] *= inv
                }
            }
            accumQueue.sync {
                accumulator.append(contentsOf: mono)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError.engineStartFailed(String(describing: error))
        }

        Log.app.notice("MicCapture: capturing for \(String(format: "%.2f", duration), privacy: .public) s ...")
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        input.removeTap(onBus: 0)
        engine.stop()

        let samples = accumQueue.sync { accumulator }
        let actualDuration = Double(samples.count) / sampleRate
        Log.app.notice("MicCapture: captured \(samples.count) samples (\(String(format: "%.3f", actualDuration), privacy: .public) s)")

        return CaptureResult(samples: samples, sampleRate: sampleRate, durationSeconds: actualDuration)
    }
}
