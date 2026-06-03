// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import SuperAudioCore

/// **M6.7 hardware-validation gate** — before committing the ~3 weeks of
/// closed-loop continuous tracking implementation, validate that the
/// three load-bearing assumptions of the inaudible-ultrasonic approach
/// actually hold on the user's hardware:
///
/// 1. **Mac built-in mic captures 18-19 kHz cleanly.** Consumer mics
///    typically roll off at 16-18 kHz. If the mic dies above 17 kHz,
///    closed-loop tracking can't lock and M6.7 needs either external-mic
///    support or audible-signal fallback.
/// 2. **Speakers reproduce 18-19 kHz audibly at typical listening
///    distances.** B&W A5/A7 probably yes; Sonos varies; unknown brands
///    vary widely. Speakers may EQ aggressively at high frequencies.
/// 3. **The mic-at-listening-position can hear 18-19 kHz at typical
///    user distance.** Ultrasonic absorbs much faster in air and soft
///    furnishings than mid-range; range ~10-15 ft in normal rooms.
///
/// **Procedure**: for each active sink, play a sequence of pure sine
/// tones at frequencies spanning 1 kHz (mid-band reference) + 15 / 16 /
/// 17 / 17.5 / 18 / 18.5 / 19 / 19.5 kHz (ultrasonic candidate band).
/// Mic records during playback. Goertzel's algorithm extracts the
/// magnitude at exactly the test frequency (no full FFT needed) plus
/// the surrounding-bin noise floor for SNR.
///
/// **Output**: structured OSLog entries marked `=== M6.7 ===` so they
/// stand out in the log stream. Per-speaker per-frequency magnitude in
/// dB + SNR in dB + a final VIABLE / MARGINAL verdict per speaker
/// (any ultrasonic SNR >10 dB = viable for closed-loop tracking).
///
/// **Why Goertzel and not FFT**: we only need magnitude at exactly the
/// 9 test frequencies, not a full spectrum. Goertzel is O(N) per
/// frequency with no power-of-2 padding constraint. For 9 frequencies
/// across ~120k mic samples, total cost is ~1M ops — sub-millisecond.
@MainActor
enum UltrasonicValidator {

    /// One per-sink per-frequency measurement.
    struct FreqResponse {
        let sinkLabel: String
        let frequencyHz: Double
        /// Goertzel magnitude at the target frequency, in dB relative
        /// to a normalized reference. Negative = quieter than reference.
        /// Useful for comparing the SAME frequency across speakers; less
        /// useful for absolute SPL claims (mic gain is unknown).
        let magnitudeDb: Float
        /// Signal-to-noise ratio: target-frequency magnitude vs the
        /// average magnitude at ±500 Hz from the target. >10 dB = clean
        /// reproduction; <3 dB = signal lost in noise floor.
        let snrDb: Float
    }

    enum ValidatorError: Error, CustomStringConvertible {
        case nothingPlaying
        case micPermissionDenied

        var description: String {
            switch self {
            case .nothingPlaying:      return "No sinks active — start Play All before validating"
            case .micPermissionDenied: return "Microphone permission denied — grant in System Settings"
            }
        }
    }

    /// Frequencies tested per speaker. Narrowed 2026-05-30 (afternoon)
    /// to just the M6.7 candidate band: 1 kHz mid-band reference + the
    /// three viable ultrasonic carrier candidates (18 / 18.5 / 19 kHz).
    /// Skips 15-17.5 kHz which the first full pass already established
    /// are mostly redundant data — we know speaker rolloff begins around
    /// 16-17 kHz, the relevant question is which of 18/18.5/19 kHz has
    /// the best SNR for M6.7's continuous-tracking carrier. Restore the
    /// full list `[1000, 15000, 16000, 17000, 17500, 18000, 18500, 19000,
    /// 19500]` when we want a complete freq-response map.
    static let testFrequencies: [Double] = [1000, 18000, 18500, 19000]

    /// Volume floor applied to the target speaker during measurement.
    /// 70% gives enough headroom for clean SNR without blasting the room.
    /// Floor-only (never reduces a louder user setting).
    static let measurementVolumePercent = 70

    /// Pure-tone burst duration.
    static let toneDurationSec: Double = 2.0

    /// Mic capture window — slightly longer than the tone so we
    /// have margin for the tone to arrive at the mic plus its tail.
    static let micCaptureDurationSec: Double = 2.5

    /// Sample rate that matches the broadcaster's capture format.
    /// No resampling needed when we inject into the broadcaster.
    static let toneSampleRate: Double = 48000

    static func runFullValidation() async throws -> [FreqResponse] {
        let activeDescriptors = DiscoveredSinks.shared.sinks.filter { d in
            SessionState.shared.activeSinks.contains(d.id)
        }
        guard !activeDescriptors.isEmpty else {
            throw ValidatorError.nothingPlaying
        }
        let status = MicCapture.authorizationStatus
        if status == .denied || status == .restricted {
            throw ValidatorError.micPermissionDenied
        }

        Log.app.notice("=== M6.7 ULTRASONIC VALIDATION START ===")
        Log.app.notice("=== \(activeDescriptors.count) sink(s) × \(Self.testFrequencies.count) frequencies = \(activeDescriptors.count * Self.testFrequencies.count) measurements ===")
        Log.app.notice("=== Estimated duration: \(Int(Double(activeDescriptors.count * Self.testFrequencies.count) * (Self.micCaptureDurationSec + 0.5))) sec ===")

        // Mic-engine warmup (avoids the AVAudioEngine 3-sec first-init
        // quirk documented in gotcha #21).
        Log.app.info("M6.7: warming up audio engine (500ms throwaway)…")
        let warmup = MicCapture()
        _ = try? await warmup.capture(duration: 0.5)

        // Save current volumes so we can restore even on error.
        var savedVolumes: [SinkID: Int] = [:]
        for d in activeDescriptors {
            savedVolumes[d.id] = SessionState.shared.volume(for: d.id)
        }

        @Sendable func restoreAllVolumes() async {
            for (id, vol) in savedVolumes {
                await SessionState.shared.setVolumeImmediate(vol, for: id)
            }
            Log.app.notice("M6.7: volumes restored")
        }

        var allResults: [FreqResponse] = []

        do {
            for target in activeDescriptors {
                Log.app.notice("=== M6.7 TARGET: \(target.displayName, privacy: .public) ===")

                // Mute everyone except target so we measure THIS speaker's
                // contribution to the mic, not a mix.
                for d in activeDescriptors where d.id != target.id {
                    await SessionState.shared.setVolumeImmediate(0, for: d.id)
                }
                let targetSavedVolume = savedVolumes[target.id] ?? 50
                let targetMeasurementVolume = max(targetSavedVolume, Self.measurementVolumePercent)
                await SessionState.shared.setVolumeImmediate(targetMeasurementVolume, for: target.id)
                // **1500ms settle (extended 2026-05-30 afternoon)** —
                // AP1 SET_PARAMETER volume commands take time to propagate
                // over RTSP, and the previously-active speakers need time
                // for music playback to fully fade after muting. With
                // 500ms, the first speaker's music tail bled into the
                // next speaker's measurement window, contaminating SNR.
                // Spacelab Audio measured BLOCKED in a 4-speaker mix at
                // 500ms settle and MARGINAL solo — diagnosed as inter-
                // test acoustic interference.
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                for freq in Self.testFrequencies {
                    let result = try await measureOneFrequency(
                        sinkLabel: target.displayName,
                        frequencyHz: freq
                    )
                    allResults.append(result)
                    Log.app.notice("=== M6.7 \(target.displayName, privacy: .public) @ \(Int(freq)) Hz: mag=\(String(format: "%.1f", result.magnitudeDb), privacy: .public) dB | SNR=\(String(format: "%.1f", result.snrDb), privacy: .public) dB ===")
                }

                // Restore non-target volumes for next iteration's baseline.
                for d in activeDescriptors where d.id != target.id {
                    await SessionState.shared.setVolumeImmediate(savedVolumes[d.id] ?? 50, for: d.id)
                }
            }

            await restoreAllVolumes()

            // Final summary + verdict.
            Log.app.notice("=== M6.7 VALIDATION COMPLETE — \(allResults.count) measurements ===")
            Log.app.notice("=== M6.7 SUMMARY ===")
            for sinkLabel in Set(allResults.map(\.sinkLabel)) {
                let sinkResults = allResults.filter { $0.sinkLabel == sinkLabel }
                let reference = sinkResults.first(where: { $0.frequencyHz == 1000 })
                let referenceSnr = reference?.snrDb ?? 0
                let ultrasonic = sinkResults.filter { $0.frequencyHz >= 18000 }
                let maxUltrasonicSnr = ultrasonic.map(\.snrDb).max() ?? -Float.infinity
                let bestUltrasonicFreq = ultrasonic.max(by: { $0.snrDb < $1.snrDb })?.frequencyHz ?? 0
                let verdict: String
                if maxUltrasonicSnr > 10 {
                    verdict = "VIABLE — closed-loop tracking should work"
                } else if maxUltrasonicSnr > 3 {
                    verdict = "MARGINAL — closed-loop may work in quiet rooms; needs higher volume or closer mic"
                } else {
                    verdict = "BLOCKED — ultrasonic signal lost; speaker or mic doesn't reproduce 18+ kHz at this distance"
                }
                Log.app.notice("=== M6.7 VERDICT \(sinkLabel, privacy: .public): 1 kHz reference SNR=\(String(format: "%.1f", referenceSnr), privacy: .public) dB; best ultrasonic SNR=\(String(format: "%.1f", maxUltrasonicSnr), privacy: .public) dB @ \(Int(bestUltrasonicFreq)) Hz → \(verdict, privacy: .public) ===")
            }
            Log.app.notice("=== M6.7 END ===")

            return allResults
        } catch {
            await restoreAllVolumes()
            throw error
        }
    }

    // MARK: - Single-frequency measurement

    /// Play one pure tone, record the mic, return Goertzel magnitude + SNR
    /// at the target frequency.
    private static func measureOneFrequency(
        sinkLabel: String,
        frequencyHz: Double
    ) async throws -> FreqResponse {
        let tone = sineTone(
            frequencyHz: frequencyHz,
            duration: Self.toneDurationSec,
            sampleRate: Self.toneSampleRate
        )

        // Start mic capture FIRST, then inject tone after a short delay so
        // the mic engine is fully running when the tone arrives.
        let mic = MicCapture()
        async let micTask: MicCapture.CaptureResult = mic.capture(duration: Self.micCaptureDurationSec)

        try? await Task.sleep(nanoseconds: 150_000_000)  // mic startup grace
        AudioBroadcaster.shared.injectChirp(samples: tone)

        let micResult = try await micTask

        // Resample if needed (Mac mic typically 48 kHz, matches tone).
        let micSamples: [Float]
        let micSampleRate: Double
        if abs(micResult.sampleRate - Self.toneSampleRate) < 1.0 {
            micSamples = micResult.samples
            micSampleRate = micResult.sampleRate
        } else {
            // Tone analysis works at any sample rate — just use the mic's
            // native rate.
            micSamples = micResult.samples
            micSampleRate = micResult.sampleRate
        }

        let signalMag = goertzelMagnitude(
            samples: micSamples,
            frequencyHz: frequencyHz,
            sampleRate: micSampleRate
        )
        // Noise floor: average magnitude at ±500 Hz offsets (far enough
        // from the signal that spectral leakage from the tone doesn't
        // contaminate the noise estimate).
        let noiseLow = goertzelMagnitude(
            samples: micSamples,
            frequencyHz: max(20, frequencyHz - 500),
            sampleRate: micSampleRate
        )
        let noiseHigh = goertzelMagnitude(
            samples: micSamples,
            frequencyHz: frequencyHz + 500,
            sampleRate: micSampleRate
        )
        let noiseMag = (noiseLow + noiseHigh) / 2.0

        // Normalize magnitude by N so it's roughly comparable across
        // different mic durations.
        let normalizedSignalMag = signalMag / Float(micSamples.count)
        let magDb = 20 * log10(max(1e-9, normalizedSignalMag))
        let snrLinear = signalMag / max(1e-9, noiseMag)
        let snrDb = 20 * log10(max(1e-9, snrLinear))

        return FreqResponse(
            sinkLabel: sinkLabel,
            frequencyHz: frequencyHz,
            magnitudeDb: magDb,
            snrDb: snrDb
        )
    }

    // MARK: - Signal generation

    /// Generate a pure sine tone at `frequencyHz` for `duration` seconds.
    /// Applies a 20 ms Hann fade-in/out to suppress edge clicks (same
    /// shape as `ChirpGenerator`'s fade).
    private static func sineTone(
        frequencyHz: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = 0.5,
        fadeMs: Double = 20
    ) -> [Float] {
        let n = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: n)
        let fadeSamples = max(1, Int(fadeMs / 1000.0 * sampleRate))
        let omega = 2.0 * .pi * frequencyHz
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var sample = Float(sin(omega * t)) * amplitude
            if i < fadeSamples {
                let w = 0.5 * (1.0 - cos(.pi * Double(i) / Double(fadeSamples)))
                sample *= Float(w)
            } else if i >= n - fadeSamples {
                let pos = Double(n - 1 - i)
                let w = 0.5 * (1.0 - cos(.pi * pos / Double(fadeSamples)))
                sample *= Float(w)
            }
            samples[i] = sample
        }
        return samples
    }

    // MARK: - Goertzel single-frequency magnitude

    /// Goertzel's algorithm: compute the magnitude at exactly one frequency
    /// without a full FFT. O(N) with a tiny constant; ideal when we need
    /// magnitudes at only a handful of frequencies (here, 9 per speaker).
    ///
    /// Math:
    ///   ω = 2π·f / sampleRate
    ///   coef = 2·cos(ω)
    ///   s[n] = x[n] + coef·s[n-1] − s[n-2]
    ///   magnitude² = s[N-1]² + s[N-2]² − coef·s[N-1]·s[N-2]
    ///
    /// Returns the (unnormalized) magnitude — caller divides by N if
    /// duration-comparable values are needed.
    private static func goertzelMagnitude(
        samples: [Float],
        frequencyHz: Double,
        sampleRate: Double
    ) -> Float {
        let omega = 2.0 * .pi * frequencyHz / sampleRate
        let coef = Float(2.0 * cos(omega))
        var s1: Float = 0
        var s2: Float = 0
        for x in samples {
            let s0 = x + coef * s1 - s2
            s2 = s1
            s1 = s0
        }
        let magnitudeSquared = s1 * s1 + s2 * s2 - coef * s1 * s2
        return sqrt(max(0, magnitudeSquared))
    }
}
