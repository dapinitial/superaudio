// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import AppKit
import Foundation
import SuperAudioCore

/// #105 / M11 Path A — Mic-based per-speaker calibration orchestrator.
///
/// **The fix UPnP-based calibration couldn't deliver**: measures actual
/// sound arriving at the Mac's microphone instead of Sonos's reported
/// RelTime. Sidesteps every Sonos buffer-variance problem we hit on
/// 2026-05-18 — the mic sees the DAC output directly, no UPnP indirection.
///
/// **What it measures**: total per-speaker lag at the mic location.
/// `lag = broadcaster_delay + receiver_buffer + acoustic_travel`. By
/// comparing per-speaker lags, we can adjust AP1 offsets so all speakers'
/// audio arrives at THIS LISTENING POSITION at the same wall moment.
///
/// **Method**: cross-correlate the recorded mic samples against the
/// reference audio that the broadcaster was sending during the same wall
/// window. Peak of the correlation = the lag in samples. Convert to ms.
///
/// **Tonight's MVP** (`measureCurrentMix`): records the full mix arriving
/// at the mic and returns ONE peak — the strongest arrival. Useful as a
/// diagnostic. Per-speaker isolation (mute others, measure one at a time)
/// comes next.
@MainActor
enum MicCalibrator {

    struct MixMeasurement {
        /// Lag of the strongest arrival in seconds. With multiple speakers
        /// playing the same content, this is dominated by the closest /
        /// loudest speaker — typically whichever the Mac is held near.
        let lagSeconds: Double
        /// Signal-to-noise ratio of the correlation peak. >5 = strong lock.
        let snr: Float
        /// Reference signal sample rate.
        let sampleRate: Double
        /// Mic capture sample rate (may differ — we resample for correlation).
        let micSampleRate: Double
        /// How many samples the correlator searched (mic length).
        let micSampleCount: Int
    }

    enum MicCalibratorError: Error, CustomStringConvertible {
        case micPermissionDenied
        case referenceTapEmpty
        case correlationFailed
        case nothingPlaying

        var description: String {
            switch self {
            case .micPermissionDenied: return "Microphone permission denied — grant in System Settings → Privacy & Security → Microphone"
            case .referenceTapEmpty:   return "No reference audio captured yet — start Play All and let audio play for a few seconds first"
            case .correlationFailed:   return "Cross-correlation failed — likely silent room or no signal"
            case .nothingPlaying:      return "No sinks active — start Play All before calibrating"
            }
        }
    }

    /// Record `durationSec` of mic audio + snapshot a LONGER window of
    /// broadcaster output (extended so peaks beyond the mic length, like
    /// Sonos's ~4 sec internal lag, are findable). Cross-correlate.
    /// Returns the strongest peak within `maxLagSec` seconds.
    ///
    /// **Use as a diagnostic** to confirm the pipeline works in your room:
    /// hold Mac near one speaker, run measurement, log result.
    /// Lag should equal (broadcaster_delay_for_that_sink + receiver_buffer
    /// + acoustic_distance / 340 m/s).
    static func measureCurrentMix(
        durationSec: Double = 20.0,
        maxLagSec: Double = 6.0
    ) async throws -> MixMeasurement {
        // Pre-flight: must have something playing to have a reference signal.
        guard SessionState.shared.isAnyActive else {
            throw MicCalibratorError.nothingPlaying
        }

        // Mic permission.
        let status = MicCapture.authorizationStatus
        if status == .denied || status == .restricted {
            throw MicCalibratorError.micPermissionDenied
        }

        Log.app.notice("MicCalibrator: starting \(String(format: "%.2f", durationSec), privacy: .public)s mic + reference capture")

        // Record mic. This blocks for durationSec.
        let mic = MicCapture()
        let micResult = try await mic.capture(duration: durationSec)

        // Snapshot a LONGER reference window than the mic recording.
        // The mic records mic_duration sec ending NOW. Speakers play
        // broadcaster content from `speaker_lag` sec ago. So the speakers'
        // mic-audible content corresponds to broadcaster output from
        // `mic_duration + speaker_lag` to `speaker_lag` sec ago. To
        // catch Sonos (lag ~4s), we need reference covering ~24s back.
        let refDuration = durationSec + maxLagSec
        guard let ref = AudioBroadcaster.shared.snapshotReferenceSamples(durationSec: refDuration) else {
            throw MicCalibratorError.referenceTapEmpty
        }

        Log.app.notice("MicCalibrator: mic=\(micResult.samples.count) samples @ \(micResult.sampleRate) Hz, ref=\(ref.samples.count) samples @ \(ref.sampleRate) Hz")

        // Resample mic to match reference sample rate if they differ.
        // Built-in Mac mic is typically 48 kHz; capture is 48 kHz; usually
        // no resampling needed. If they differ, do a simple linear resample.
        let micSamples: [Float]
        if abs(micResult.sampleRate - ref.sampleRate) < 1.0 {
            micSamples = micResult.samples
        } else {
            micSamples = linearResample(micResult.samples,
                                         from: micResult.sampleRate,
                                         to: ref.sampleRate)
            Log.app.info("MicCalibrator: resampled mic \(micResult.sampleRate)→\(ref.sampleRate) (\(micResult.samples.count)→\(micSamples.count) samples)")
        }

        guard let corr = AudioCorrelation.correlatedLagSeconds(
            reference: ref.samples,
            observed: micSamples,
            sampleRate: ref.sampleRate,
            maxLagSeconds: maxLagSec
        ) else {
            throw MicCalibratorError.correlationFailed
        }

        Log.app.notice("MicCalibrator ✓ lag=\(String(format: "%.4f", corr.lagSeconds), privacy: .public)s SNR=\(String(format: "%.1f", corr.snr), privacy: .public)")

        return MixMeasurement(
            lagSeconds: corr.lagSeconds,
            snr: corr.snr,
            sampleRate: ref.sampleRate,
            micSampleRate: micResult.sampleRate,
            micSampleCount: micSamples.count
        )
    }

    // MARK: - Chirp-based measurement (#105 — the one that actually works)

    /// Inject a calibration chirp into the broadcaster, record mic during
    /// the chirp's playback through speakers, cross-correlate mic samples
    /// against the known chirp signal. Returns the lag (sec) and SNR.
    ///
    /// **Why this beats ambient-music measurement** (verified 2026-05-18):
    /// chirps have flat autocorrelation. Music has rhythmic peaks every
    /// beat + harmonic peaks at chord intervals — the correlator picks the
    /// strongest peak, which for music isn't necessarily the true arrival
    /// lag. The mic-music path returned SNR=20 but lag values inconsistent
    /// with broadcaster_delay; the chirp path should give clean peaks that
    /// match (broadcaster_delay + receiver_buffer + acoustic).
    ///
    /// Procedure:
    ///   1. Generate chirp samples (1 sec, 200 Hz → 8 kHz)
    ///   2. Start mic recording for `chirpDurationSec + maxLagSec + margin`
    ///   3. Inject chirp into broadcaster — all speakers play it
    ///   4. Wait for mic to finish
    ///   5. Resample mic to broadcaster rate
    ///   6. Cross-correlate mic against the chirp reference
    ///   7. Return lag — distance from chirp injection to mic peak = total
    ///      per-speaker playback lag at the mic location
    ///
    /// Briefly interrupts music for chirp duration (~1 sec). User hears a
    /// sweep instead of music. Acceptable for occasional calibration.
    static func measureWithChirp(
        chirpDurationSec: Double = 1.0,
        maxLagSec: Double = 6.0
    ) async throws -> MixMeasurement {
        guard SessionState.shared.isAnyActive else {
            throw MicCalibratorError.nothingPlaying
        }
        let status = MicCapture.authorizationStatus
        if status == .denied || status == .restricted {
            throw MicCalibratorError.micPermissionDenied
        }

        // Total recording: chirp duration + max expected lag + small margin.
        // The chirp arrives at the mic anywhere from 0 to maxLagSec seconds
        // after injection; we want the entire chirp's tail in the recording.
        let micDurationSec = chirpDurationSec + maxLagSec + 0.5

        Log.app.notice("MicCalibrator(chirp): chirp=\(String(format: "%.2f", chirpDurationSec), privacy: .public)s mic=\(String(format: "%.2f", micDurationSec), privacy: .public)s")

        // Generate the reference signal. 48 kHz matches the broadcaster
        // capture format — no resampling needed before injection.
        //
        // **Default reverted to chirp 2026-05-29.** The MLS default
        // (M6.4 Phase 2b, 2026-05-21) had mathematically perfect
        // autocorrelation in theory but produced borderline SNR=7.8-9.7
        // measurements in real-room 4-speaker testing — the spread-
        // spectrum energy was too thin per-frequency at normal listening
        // volumes. The chirp's concentrated energy at the swept frequency
        // wins on real-world SNR even though its autocorrelation is only
        // approximately flat. The 2026-05-18 single-room 3-speaker test
        // with the chirp converged 1000ms → 12ms in 3 passes (SNR=20+);
        // the 2026-05-29 4-speaker MLS test produced inconsistent lags
        // and skipped half the measurements. SNR-limited regime: pick
        // the signal with more punch per moment, not the prettiest math.
        //
        // The `useChirpForCalibration` pref remains; flip to `false` to
        // test MLS specifically. See DECISIONS.md 2026-05-29 (afternoon).
        let chirpSampleRate: Double = 48000
        let useChirp = (UserDefaults.standard.object(forKey: "useChirpForCalibration") as? Bool) ?? true
        let chirp: [Float]
        let signalLabel: String
        if useChirp {
            chirp = ChirpGenerator.linearSweep(
                f0: 200,
                f1: 8000,
                duration: chirpDurationSec,
                sampleRate: chirpSampleRate
            )
            signalLabel = "chirp"
        } else {
            chirp = MLSGenerator.generate(
                durationSec: chirpDurationSec,
                sampleRate: chirpSampleRate
            )
            signalLabel = "MLS"
        }
        Log.app.info("MicCalibrator: reference signal = \(signalLabel, privacy: .public)")

        // Start mic capture in parallel. Take mic capture task FIRST so it's
        // running before we inject the chirp (avoids missing the chirp's
        // leading edge if injection lands ahead of mic startup).
        let mic = MicCapture()
        async let micTask: MicCapture.CaptureResult = mic.capture(duration: micDurationSec)

        // Give the mic engine ~150ms to spin up + flush its initial buffer
        // (AVAudioEngine has a startup transient). Then inject the chirp.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let injectionWallTime = Date()
        AudioBroadcaster.shared.injectChirp(samples: chirp)
        Log.app.notice("MicCalibrator(chirp): injection wall-time \(injectionWallTime.timeIntervalSince1970, privacy: .public)")

        // Wait for mic to complete.
        let micResult = try await micTask

        Log.app.notice("MicCalibrator(chirp): mic captured \(micResult.samples.count) samples @ \(micResult.sampleRate, privacy: .public) Hz")

        // Resample mic to chirp's sample rate if needed.
        let micSamples: [Float]
        if abs(micResult.sampleRate - chirpSampleRate) < 1.0 {
            micSamples = micResult.samples
        } else {
            micSamples = linearResample(micResult.samples,
                                         from: micResult.sampleRate,
                                         to: chirpSampleRate)
            Log.app.info("MicCalibrator(chirp): resampled mic \(micResult.sampleRate)→\(chirpSampleRate)")
        }

        // Correlate mic against the known chirp. The peak position in the
        // correlation = sample offset where the chirp lines up best inside
        // the mic recording. Convert to seconds.
        guard let corr = AudioCorrelation.correlatedLagSeconds(
            reference: chirp,
            observed: micSamples,
            sampleRate: chirpSampleRate,
            maxLagSeconds: maxLagSec
        ) else {
            throw MicCalibratorError.correlationFailed
        }

        // Subtract the mic engine startup grace (150ms) so the returned lag
        // represents speaker_play_lag, not speaker_lag + mic_startup_offset.
        let lagAdjusted = max(0, corr.lagSeconds - 0.150)

        Log.app.notice("MicCalibrator(chirp) ✓ lag=\(String(format: "%.4f", lagAdjusted), privacy: .public)s (raw \(String(format: "%.4f", corr.lagSeconds), privacy: .public)) SNR=\(String(format: "%.1f", corr.snr), privacy: .public)")

        return MixMeasurement(
            lagSeconds: lagAdjusted,
            snr: corr.snr,
            sampleRate: chirpSampleRate,
            micSampleRate: micResult.sampleRate,
            micSampleCount: micSamples.count
        )
    }

    // MARK: - Full auto-calibration (#109)

    struct SpeakerMeasurement {
        let sinkID: SinkID
        let label: String
        let lagSec: Double
        let snr: Float
    }

    /// SNR threshold below which a measurement is considered unreliable
    /// and its delta is NOT applied. Lowered from 10.0 → 7.0 on
    /// 2026-05-29 after real-room testing showed normal-volume same-room
    /// measurements landing at SNR=7.8-9.7 with mutually-consistent lags
    /// (three speakers all within 213ms of each other = strong evidence
    /// the correlation IS finding real peaks, not noise). The original
    /// 10.0 threshold was tuned against one outlier from 2026-05-18
    /// (side-room A7, SNR=5.6, wildly wrong lag) and over-rejected
    /// legitimate measurements in normal listening conditions.
    ///
    /// **Safety nets at the lower threshold:**
    /// 1. ±1000ms-per-pass delta clamp catches wild jumps from any
    ///    measurement that DID sneak through despite low confidence.
    /// 2. Cross-speaker inconsistency would be visible in logs (and
    ///    sound audibly wrong, prompting a re-calibration).
    /// 3. Sonos still uses multi-sample median which independently
    ///    filters outliers.
    static let snrAcceptanceThreshold: Float = 7.0

    /// Number of independent Sonos measurements to take per calibration
    /// pass. Sonos's hidden renderer buffer can shift WITHIN a session
    /// (observed 2026-05-21: Sonos lag varied 0.7s → 3.4s across two
    /// calibration passes minutes apart on the same hardware, with AP1
    /// restart cycles in between disrupting Sonos's pipeline). Single-
    /// shot measurement is fragile when the reference itself drifts.
    ///
    /// Solution: sample Sonos `sonosSampleCount` times across ~10 sec,
    /// take the median lag. Median is robust against an outlier in
    /// either direction without needing to know what "stable" looks
    /// like a priori.
    ///
    /// AP1 measurements stay single-shot because AP1's broadcaster
    /// delay is stable (it's a deterministic Mac-side number we set,
    /// not a hidden receiver buffer).
    static let sonosSampleCount = 3
    static let sonosSampleIntervalNs: UInt64 = 2_000_000_000  // 2 sec between samples

    /// Target speaker volume during chirp measurement. Loud enough that
    /// the Mac's built-in mic captures the chirp cleanly even when the
    /// speaker is in a side room or otherwise far from the Mac. **Applied
    /// only as a floor — never reduces a speaker's volume below its
    /// user-set level.** Original volume restored after measurement.
    ///
    /// Tuning history:
    /// - 2026-05-18 initial 85% — chose loud to fix A7-in-side-room low SNR
    /// - 2026-05-19 lowered to 50% after user reported Sonos chirp was
    ///   "super loud" when Sonos's listening volume was much lower than 85%.
    ///   85% boosts a 40%-listening Sonos by ~4x perceived loudness, which
    ///   startled the room.
    /// 50% trades a little SNR robustness for not-disturbing-the-neighbors.
    /// The SNR gate (>=10.0) catches genuine measurement failures and falls
    /// back to keeping the current offset.
    static let measurementVolumePercent: Int = 50

    struct AutoCalibrationResult {
        let ap1Measurements: [SpeakerMeasurement]
        let sonosMeasurement: SpeakerMeasurement
        /// Per-AP1: the delta (ms) added to the existing offset to align with Sonos.
        let ap1AdjustmentsMs: [SinkID: Int]
        /// Per-AP1: the final offset (ms) applied.
        let appliedOffsetsMs: [SinkID: Int]
    }

    /// Full sequential per-speaker mic calibration. Measures each active
    /// speaker in isolation (muting the others), then computes per-AP1
    /// offsets that align all speakers' DAC arrival times at the mic
    /// location to match Sonos's (the slowest sink). Persists + restarts.
    ///
    /// User procedure:
    ///   1. Place Mac at the desired listening position
    ///   2. Click "Mic Calibrate (auto)"
    ///   3. Each speaker plays a 1-sec chirp in turn — others stay muted
    ///   4. App computes offsets and restarts AP1 sinks in sync
    ///
    /// Requires: at least one active AP1 sink + Sonos in the wanted set.
    /// (Sonos is the reference because we can't shift its timing — AP1
    /// gets shifted to match Sonos's natural lag.)
    static func runFullCalibration() async throws -> AutoCalibrationResult {
        // Snapshot active descriptors.
        let allActive = DiscoveredSinks.shared.sinks.filter { d in
            SessionState.shared.activeSinks.contains(d.id)
        }
        let ap1Descriptors = allActive.filter { $0.protocolKind == .airplay1 }
        let sonosDescriptor = allActive.first(where: { $0.protocolKind == .sonos })

        guard let sonos = sonosDescriptor else {
            throw MicCalibratorError.nothingPlaying  // need Sonos as reference
        }
        guard !ap1Descriptors.isEmpty else {
            throw MicCalibratorError.nothingPlaying
        }
        let status = MicCapture.authorizationStatus
        if status == .denied || status == .restricted {
            notifyMicPermissionDeniedOnce()
            throw MicCalibratorError.micPermissionDenied
        }

        // **Concurrency lock** — refuse to start if a calibration is
        // already in flight. Without this, multiple entry points
        // (SonosSession auto-trigger, mid-session sink-add, manual
        // Calibrate button) could race; each runs its own mute/unmute
        // cycle and the resulting interleaved volume writes leave
        // speakers stuck silent. Diagnosed 2026-05-28 in real-room test
        // with 4 speakers — 9+ concurrent invocations, no sync.
        if SessionState.shared.isCalibrating {
            Log.app.notice("MicCalibrator(auto): another calibration already in flight — refusing to start")
            throw MicCalibratorError.nothingPlaying
        }

        Log.app.notice("MicCalibrator(auto): starting — \(ap1Descriptors.count) AP1 + 1 Sonos in active set")
        SessionState.shared.markCalibrationStarted()
        defer { SessionState.shared.markCalibrationEnded() }

        // **AVAudioEngine warmup** — the first time we query input format
        // on macOS, the system takes ~3 seconds to spin up the audio
        // subsystem. If we don't pre-warm it, the first calibration
        // measurement misses the chirp injection (the mic starts ~3 sec
        // late and only catches the tail of the chirp arrival, producing
        // a falsely-small lag). Diagnosed 2026-05-18 — pattern was
        // "first measurement always wrong, subsequent ones correct."
        // Throwaway 500ms capture warms the engine without measuring.
        Log.app.notice("MicCalibrator(auto): warming up audio engine (500ms throwaway)…")
        let warmup = MicCapture()
        _ = try? await warmup.capture(duration: 0.5)
        Log.app.notice("MicCalibrator(auto): warmup complete, starting real measurements")

        // Save current volumes so we can restore even on error.
        var savedVolumes: [SinkID: Int] = [:]
        for d in ap1Descriptors { savedVolumes[d.id] = SessionState.shared.volume(for: d.id) }
        savedVolumes[sonos.id] = SessionState.shared.volume(for: sonos.id)

        // Restore-on-exit guard. Uses a flag because Task in defer can't
        // be awaited from a non-async defer; we await before each return.
        @Sendable func restoreAllVolumes() async {
            for (id, vol) in savedVolumes {
                await SessionState.shared.setVolumeImmediate(vol, for: id)
            }
            Log.app.notice("MicCalibrator(auto): volumes restored")
        }

        var ap1Measurements: [SpeakerMeasurement] = []

        // Between-iteration abort check. If the user clicks Stop All
        // mid-calibration, `wantedActive` empties — abort cleanly,
        // restore volumes (via the `catch` path's restoreAllVolumes), do
        // not persist garbage offsets. Without this guard the loop runs
        // to completion against silent speakers, the SNR gate catches the
        // bad measurements, and offsets stay unchanged — but volumes
        // would only be restored once the orchestrator unwound naturally.
        func abortIfStopped() throws {
            if SessionState.shared.wantedActive.isEmpty {
                Log.app.notice("MicCalibrator(auto): Stop All detected mid-pass — aborting")
                throw MicCalibratorError.nothingPlaying
            }
        }

        do {
            // Measure each AP1 in isolation.
            for target in ap1Descriptors {
                try abortIfStopped()
                // **Respect "do not disturb" signal**: if the user explicitly
                // set this speaker's volume to 0%, treat that as a hard
                // request to leave the speaker silent — DO NOT boost it to
                // 85% for measurement. This bug surfaced 2026-05-19 when a
                // user muted A7 because their brother was sleeping in that
                // room; the calibrator boosted to 85% anyway and the chirp
                // blasted the room. Generalized rule: 0% saved volume = do
                // not measure this speaker, do not adjust its offset.
                let targetSavedVolume = savedVolumes[target.id] ?? 50
                if targetSavedVolume == 0 {
                    Log.app.notice("MicCalibrator(auto): SKIPPING \(target.displayName, privacy: .public) — user volume is 0% (intentional mute, leave alone)")
                    continue
                }

                // **Floor-only boost**: bump target speaker UP to
                // `measurementVolumePercent` (50%) only if it's currently
                // quieter. If user already has it at 70%, leave it at 70%.
                // Never reduces a user-chosen louder volume; never
                // overrides a user-chosen quieter-than-needed-for-SNR
                // value below the floor.
                let targetMeasurementVol = max(targetSavedVolume, Self.measurementVolumePercent)
                Log.app.notice("MicCalibrator(auto): measuring \(target.displayName, privacy: .public) (muting others; target volume \(targetSavedVolume)% → \(targetMeasurementVol)% for measurement)…")
                // Mute everyone except target.
                for d in ap1Descriptors where d.id != target.id {
                    await SessionState.shared.setVolumeImmediate(0, for: d.id)
                }
                await SessionState.shared.setVolumeImmediate(0, for: sonos.id)
                await SessionState.shared.setVolumeImmediate(targetMeasurementVol, for: target.id)
                // Let mutes propagate. Sonos SOAP can take ~100ms; AP1
                // SET_PARAMETER is near-instant; 500ms is safe.
                try? await Task.sleep(nanoseconds: 500_000_000)

                let m = try await measureWithChirp(chirpDurationSec: 1.0, maxLagSec: 6.0)
                ap1Measurements.append(SpeakerMeasurement(
                    sinkID: target.id,
                    label: target.displayName,
                    lagSec: m.lagSeconds,
                    snr: m.snr
                ))

                // Restore non-target volumes for next iteration.
                for d in ap1Descriptors where d.id != target.id {
                    await SessionState.shared.setVolumeImmediate(savedVolumes[d.id] ?? 50, for: d.id)
                }
                await SessionState.shared.setVolumeImmediate(savedVolumes[sonos.id] ?? 50, for: sonos.id)
            }

            try abortIfStopped()

            // Measure Sonos in isolation — same "respect 0%" guard.
            let sonosSavedVolume = savedVolumes[sonos.id] ?? 50
            if sonosSavedVolume == 0 {
                Log.app.notice("MicCalibrator(auto): SKIPPING Sonos \(sonos.displayName, privacy: .public) — user volume is 0% (cannot align AP1 to Sonos without measuring Sonos; aborting calibration cleanly)")
                await restoreAllVolumes()
                return AutoCalibrationResult(
                    ap1Measurements: ap1Measurements,
                    sonosMeasurement: SpeakerMeasurement(sinkID: sonos.id, label: sonos.displayName, lagSec: 0, snr: 0),
                    ap1AdjustmentsMs: [:],
                    appliedOffsetsMs: [:]
                )
            }
            // Same floor-only boost for Sonos.
            let sonosMeasurementVol = max(sonosSavedVolume, Self.measurementVolumePercent)
            Log.app.notice("MicCalibrator(auto): measuring \(sonos.displayName, privacy: .public) ×\(Self.sonosSampleCount) (muting AP1; Sonos volume \(sonosSavedVolume)% → \(sonosMeasurementVol)% for measurement; multi-sample median for drift robustness)…")
            for d in ap1Descriptors {
                await SessionState.shared.setVolumeImmediate(0, for: d.id)
            }
            await SessionState.shared.setVolumeImmediate(sonosMeasurementVol, for: sonos.id)
            try? await Task.sleep(nanoseconds: 500_000_000)

            // **Multi-sample Sonos**: take N measurements, return the median.
            // Filters out the kind of mid-session drift documented 2026-05-21
            // when Sonos's hidden buffer shifted 2.7 sec across passes 5 min
            // apart. Median is robust against single-sample outliers
            // without needing to model what "stable" means a priori.
            var sonosLagSamples: [Double] = []
            var sonosSnrSamples: [Float] = []
            for i in 0..<Self.sonosSampleCount {
                if i > 0 {
                    try? await Task.sleep(nanoseconds: Self.sonosSampleIntervalNs)
                    try abortIfStopped()
                }
                let sample = try await measureWithChirp(chirpDurationSec: 1.0, maxLagSec: 6.0)
                sonosLagSamples.append(sample.lagSeconds)
                sonosSnrSamples.append(sample.snr)
                Log.app.notice("MicCalibrator(auto): Sonos sample \(i + 1)/\(Self.sonosSampleCount) — lag=\(String(format: "%.3f", sample.lagSeconds), privacy: .public)s SNR=\(String(format: "%.1f", sample.snr), privacy: .public)")
            }
            let sortedLags = sonosLagSamples.sorted()
            let sortedSnrs = sonosSnrSamples.sorted()
            let medianLag = sortedLags[sortedLags.count / 2]
            let medianSnr = sortedSnrs[sortedSnrs.count / 2]
            let lagRange = (sortedLags.last ?? 0) - (sortedLags.first ?? 0)
            Log.app.notice("MicCalibrator(auto): Sonos median lag=\(String(format: "%.3f", medianLag), privacy: .public)s (range across samples: \(String(format: "%.3f", lagRange), privacy: .public)s — \(lagRange > 0.5 ? "DRIFT DETECTED" : "stable", privacy: .public))")
            let sonosMeasurement = SpeakerMeasurement(
                sinkID: sonos.id,
                label: sonos.displayName,
                lagSec: medianLag,
                snr: medianSnr
            )

            await restoreAllVolumes()

            // Compute per-AP1 adjustments. Target: all speakers DAC-arrive
            // at the mic at the same wall moment. Sonos is the slowest
            // (typically) and can't be shifted, so AP1 offsets bump UP to
            // match Sonos's lag.
            var adjustments: [SinkID: Int] = [:]
            var applied: [SinkID: Int] = [:]
            for m in ap1Measurements {
                let deltaSec = sonosMeasurement.lagSec - m.lagSec
                let deltaMs = Int((deltaSec * 1000).rounded())
                // **Read from `offset(for:)`, NOT `sinkOffsetsMs` directly.**
                // The in-memory dict is empty unless the user touched the
                // slider this session. The user's persisted offset lives
                // in UserDefaults; `offset(for:)` checks both. Bug found
                // 2026-05-18 — calibration reset A5/A7 from 3085 → tiny
                // values because it thought current=0.
                let currentOffsetMs = SessionState.shared.offset(for: m.sinkID)

                // **SNR gate** — skip applying adjustments from low-confidence
                // measurements. A weak chirp lock (SNR <10) means the
                // correlator barely found a peak; applying a delta based
                // on that produces wild offset jumps that don't reflect
                // reality. We KEEP the current offset (presumably tuned
                // from a previous high-SNR run) and log a warning so the
                // user knows the speaker wasn't refined this pass.
                // Either speaker is too quiet, mic too far, or room too
                // noisy — user can move the Mac closer and re-run, or
                // accept the prior calibration.
                if m.snr < Self.snrAcceptanceThreshold {
                    adjustments[m.sinkID] = 0
                    applied[m.sinkID] = currentOffsetMs
                    Log.app.error("MicCalibrator(auto): \(m.label, privacy: .public) SKIPPED — SNR=\(String(format: "%.1f", m.snr), privacy: .public) below \(Self.snrAcceptanceThreshold) threshold (measurement unreliable; keeping current offset \(currentOffsetMs)ms)")
                    continue
                }

                // Also clamp the delta itself. Even with strong SNR, a
                // single measurement nudging an offset by more than ±1500ms
                // is suspicious — likely Sonos's hidden buffer drifted
                // between this measurement and Sonos's own measurement,
                // not a real speaker-position change. Cap the bump to
                // prevent runaway accumulation across multiple passes.
                let clampedDeltaMs = max(-1000, min(1000, deltaMs))
                if clampedDeltaMs != deltaMs {
                    Log.app.notice("MicCalibrator(auto): \(m.label, privacy: .public) Δ clamped from \(deltaMs)ms to \(clampedDeltaMs)ms (cap ±1000ms per pass; suspected Sonos drift, not real shift)")
                }

                let newOffsetMs = max(0, currentOffsetMs + clampedDeltaMs)
                adjustments[m.sinkID] = clampedDeltaMs
                applied[m.sinkID] = newOffsetMs
                Log.app.notice("MicCalibrator(auto): \(m.label, privacy: .public) lag=\(String(format: "%.3f", m.lagSec), privacy: .public)s sonos=\(String(format: "%.3f", sonosMeasurement.lagSec), privacy: .public)s Δ=\(clampedDeltaMs)ms current=\(currentOffsetMs)ms → \(newOffsetMs)ms SNR=\(String(format: "%.1f", m.snr), privacy: .public)")
            }

            // Persist + restart AP1 sinks (same pattern as #104 Auto-Align).
            for (id, newOffsetMs) in applied {
                SessionState.shared.setOffset(newOffsetMs, for: id)
            }

            // M6.4 per-environment profile: snapshot the freshly-calibrated
            // offsets keyed on the active sink set. Next time the same set
            // goes active, `startAll` primes these offsets BEFORE any session
            // starts, so audio is in approximate sync from the first packet —
            // calibration then refines silently. Save the full active set
            // (AP1 + Sonos), not just AP1, so the key reflects what was
            // actually playing during calibration.
            var profileSinkSet = Set(ap1Descriptors.map(\.id))
            profileSinkSet.insert(sonos.id)
            SessionState.shared.saveCalibrationProfile(for: profileSinkSet)

            Log.app.notice("MicCalibrator(auto): restarting \(ap1Descriptors.count) AP1 sink(s)…")
            for d in ap1Descriptors {
                SessionState.shared.toggle(d)  // OFF
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for d in ap1Descriptors {
                SessionState.shared.toggle(d)  // ON
            }

            return AutoCalibrationResult(
                ap1Measurements: ap1Measurements,
                sonosMeasurement: sonosMeasurement,
                ap1AdjustmentsMs: adjustments,
                appliedOffsetsMs: applied
            )
        } catch {
            await restoreAllVolumes()
            throw error
        }
    }

    // MARK: - Internals

    /// **One-time NSAlert for mic-permission-denied (M6.4).** Auto-
    /// calibration silently relies on mic access; when it's denied, the
    /// user gets no UI feedback today — just an OSLog line they never
    /// see. Surface the issue ONCE per install via a non-modal NSAlert
    /// with a "Open System Settings" deep link, then suppress further
    /// alerts so we never spam. Re-shows if the user resets the flag in
    /// `defaults` (e.g., a "Re-show" diagnostic).
    private static func notifyMicPermissionDeniedOnce() {
        let key = "hasShownMicPermissionAlert"
        if UserDefaults.standard.bool(forKey: key) {
            Log.app.notice("Mic permission denied (alert already shown previously)")
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "SuperAudio needs microphone access to keep your speakers in sync."
        alert.informativeText = "Auto-calibration listens for the calibration signal from each speaker to measure their relative timing. Without mic access, sync can only be tuned manually.\n\nGrant access in System Settings → Privacy & Security → Microphone, then click Play All again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Simple linear interpolation resample. Adequate for cross-correlation
    /// (we care about peak position, not spectral fidelity). For higher
    /// quality, replace with `AVAudioConverter`-based resampling.
    private static func linearResample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        if srcRate == dstRate { return input }
        let ratio = dstRate / srcRate
        let outCount = Int(Double(input.count) * ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let lo = Int(srcIdx.rounded(.down))
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(srcIdx - Double(lo))
            out[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return out
    }
}
