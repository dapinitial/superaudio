// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation
import Observation
import SuperAudioCore

/// **Passive sync auto-corrector with a chirp-anchored start — Milestone 2.**
///
/// SuperAudio already knows the exact waveform sent to each speaker (the
/// broadcaster reference tap). Correlating the Mac mic against that reference
/// recovers each speaker's true playback lag. The correction rule is fixed by
/// physics: every lever only *adds* delay (you can't un-buffer a receiver, and
/// Sonos timing can't be pulled forward — gotcha #17), so **the slowest sink is
/// the reference and every faster controllable sink is delayed up to match it.**
///
/// **Why a chirp at the start (and only the start).** Real-hardware testing
/// 2026-06-03 showed passive *acquisition* from music is ambiguous: quiet
/// content gives no lock, and loud beat-heavy content makes the correlation
/// spike at the musical period, not the speaker lag — you can't tell which peak
/// is a speaker. So we **acquire once with a single 1-second chirp through the
/// AirPlay sink in isolation** (clean, unambiguous lag + identity), then hand
/// off to **silent passive tracking** for continuous drift correction, which
/// only ever needs to follow sub-beat changes where there's no ambiguity. One
/// beep when you start, then nothing — versus the old repeated chirp rituals.
///
/// Controllable today = AirPlay 1. AirPlay 2 joins when M12 ships (low-latency,
/// fully delay-controllable). Legacy Sonos is delay-only/coarse, so its role is
/// the reference; if it's *faster* than the slowest sink the corrector reports
/// the limitation rather than mis-correcting (until a Sonos feed-delay exists).
///
/// Robustness: SNR gate, median smoothing, step clamp, deadband, post-shift
/// settle, and brief-loss coasting before re-anchoring. Two modes via
/// `passiveSyncArmed`: observe (logs geometry + "would apply") and armed
/// (applies via `SessionState.setOffset` — persists, retimes live, snoozes the
/// health monitor so the shift isn't misread as a dropout).
@MainActor
@Observable
final class PassiveSyncMonitor {

    static let shared = PassiveSyncMonitor()
    private init() {}

    struct Reading {
        let peakLagsSec: [Double]
        let airplayLagSec: Double?
        let referenceLagSec: Double?
        let appliedOffsetMs: Int?
        let armed: Bool
        let iteration: Int
        let status: String
    }

    private(set) var isRunning = false
    private(set) var lastReading: Reading?
    private var loopTask: Task<Void, Never>?

    /// Learned intrinsic lag of the controllable AirPlay sink (receiver buffer
    /// + acoustic travel), i.e. its measured lag minus its commanded offset.
    /// `nil` ⇒ needs (re-)acquisition via chirp.
    private var airplayBufferSec: Double?
    /// Anchored lag of the reference (slowest, uncontrollable) sink — the
    /// Sonos. Like the AirPlay buffer, it's learned by chirp and then tracked
    /// in a focused window, so PHAT's sharpened reflection peaks can't
    /// masquerade as the reference. `nil` ⇒ needs (re-)acquisition.
    private var referenceAnchorLag: Double?
    /// Consecutive passive rounds where we couldn't re-find the AirPlay peak.
    /// Brief losses coast; a sustained loss forces a fresh chirp anchor.
    private var lostCount = 0
    private var errorWindowMs: [Double] = []
    /// Hysteresis latch: true once locked. Holds (no offset changes) until
    /// Sonos drifts past `reengageThresholdMs`, so noise can't cause endless
    /// re-timing. Reset on start and whenever we re-anchor.
    private var converged = false

    // MARK: - Tuning

    // Longer window = more integration = higher correlation SNR. Worth the
    // slower cadence since Sonos drift is seconds-over-minutes; 10 s reliably
    // lifts weak music peaks above the gate where 6 s left them marginal.
    private let micWindowSec = 10.0
    private let maxLagSec = 6.0
    private let snrGate: Float = 5.0
    private let peakCount = 3
    private let minPeakSeparationSec = 0.3
    /// Window (± this) around `offset + buffer` to re-find the AirPlay peak.
    private let trackTolSec = 0.30
    /// Wider focused-search window for the reference — Sonos drifts more than
    /// the deterministic AirPlay delay, so give it room to follow.
    private let referenceTolSec = 0.5
    /// SNR floor for the *focused* AirPlay re-find. Lower than the broad gate:
    /// we already know where the peak is (from the chirp anchor), so a quiet
    /// peak in the right place is still trustworthy — this stops the softer
    /// AirPlay music peak from constantly "dropping out" and forcing re-chirps.
    private let trackGate: Float = 3.5
    /// Sustained-loss rounds before we re-anchor with a chirp.
    private let lostThreshold = 5
    /// Floor volume for the isolated AirPlay sink during chirp acquisition.
    private let acquireVolumeFloor = 50
    // Coarsened from 40 ms: sub-~120 ms is imperceptible, and a tight deadband
    // made the loop chase per-round measurement noise. `reengage` adds
    // hysteresis so a locked sync only re-corrects on genuine Sonos drift.
    private let deadbandMs = 120.0
    private let reengageThresholdMs = 250.0
    private let maxStepMs = 2000.0
    private let minSamplesToApply = 3
    private let windowCap = 7
    private let interRoundGapSec = 1.0

    private var armed: Bool { UserDefaults.standard.bool(forKey: "passiveSyncArmed") }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        guard SessionState.shared.isAnyActive else {
            Log.app.notice("PassiveSyncMonitor: nothing playing — start Play All first")
            return
        }
        isRunning = true
        errorWindowMs.removeAll()
        lostCount = 0
        airplayBufferSec = nil   // always re-anchor with a chirp on a fresh start
        referenceAnchorLag = nil
        converged = false
        Log.app.notice("PassiveSyncMonitor ▶ started (\(self.armed ? "ARMED — will move offsets" : "observe only", privacy: .public)) — will chirp-anchor once, then track silently")
        loopTask = Task { @MainActor [weak self] in await self?.runLoop() }
    }

    func stop() {
        guard isRunning else { return }
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        Log.app.notice("PassiveSyncMonitor ■ stopped")
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: - Loop

    private func runLoop() async {
        var iteration = 0
        while !Task.isCancelled {
            guard SessionState.shared.isAnyActive else {
                Log.app.notice("PassiveSyncMonitor: playback stopped — ending")
                break
            }
            iteration += 1
            var extraSettleSec = 0.0
            do {
                extraSettleSec = try await tick(iteration: iteration)
            } catch is CancellationError {
                break
            } catch {
                Log.app.error("PassiveSyncMonitor round \(iteration, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64((interRoundGapSec + extraSettleSec) * 1_000_000_000))
        }
        isRunning = false
    }

    /// One round: acquire (chirp) if we have no anchor, otherwise passively
    /// measure and correct. Returns extra settle seconds.
    private func tick(iteration: Int) async throws -> Double {
        let active = DiscoveredSinks.deduplicate(DiscoveredSinks.shared.sinks).filter { SessionState.shared.activeSinks.contains($0.id) }
        guard let airplay = active.first(where: { $0.protocolKind == .airplay1 }) else {
            Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): no controllable AirPlay sink active")
            return 0
        }
        guard active.count >= 2 else {
            Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): only one sink active — nothing to align")
            return 0
        }

        // Acquire anchors with chirps if we don't have both (AirPlay + reference).
        if airplayBufferSec == nil || referenceAnchorLag == nil {
            let ok = await acquireWithChirp(airplay: airplay, others: active.filter { $0.id != airplay.id }, iteration: iteration)
            lostCount = 0
            return ok ? 1.0 : 1.5   // settle, then track (or retry the chirp)
        }

        return try await trackAndCorrect(airplay: airplay, iteration: iteration)
    }

    // MARK: - Chirp acquisition (once at start, or to re-anchor after loss)

    /// Play a single 1-second chirp through the AirPlay sink **in isolation**
    /// (others muted) and measure its lag — unambiguous identity + coarse lag.
    /// Sets `airplayBufferSec`. Restores volumes. Returns success.
    private func acquireWithChirp(airplay: SinkDescriptor, others: [SinkDescriptor], iteration: Int) async -> Bool {
        let status = MicCapture.authorizationStatus
        if status == .denied || status == .restricted {
            Log.app.error("PassiveSyncMonitor #\(iteration, privacy: .public): mic permission denied — cannot chirp-anchor")
            return false
        }

        // Save + mute others, boost AirPlay to a measurement floor.
        var saved: [SinkID: Int] = [:]
        saved[airplay.id] = SessionState.shared.volume(for: airplay.id)
        for d in others { saved[d.id] = SessionState.shared.volume(for: d.id) }
        for d in others { await SessionState.shared.setVolumeImmediate(0, for: d.id) }
        let airVol = max(saved[airplay.id] ?? acquireVolumeFloor, acquireVolumeFloor)
        await SessionState.shared.setVolumeImmediate(airVol, for: airplay.id)
        try? await Task.sleep(nanoseconds: 500_000_000)   // let mutes propagate

        // Warm the audio engine (first mic use has a ~3 s spin-up; a throwaway
        // capture avoids the chirp landing before the mic is live).
        _ = try? await MicCapture().capture(duration: 0.5)

        let offsetSec = Double(SessionState.shared.offset(for: airplay.id)) / 1000.0

        // --- Chirp 1: AirPlay in isolation (others already muted) → its buffer.
        Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): ◆ chirp-anchoring \(airplay.displayName, privacy: .public) (others muted)…")
        var airOK = false
        do {
            let m = try await MicCalibrator.measureWithChirp(chirpDurationSec: 1.0, maxLagSec: maxLagSec)
            if m.snr >= snrGate {
                let buffer = max(0, m.lagSeconds - offsetSec)
                airplayBufferSec = buffer
                Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): ✓ anchored \(airplay.displayName, privacy: .public) lag=\(String(format: "%.3f", m.lagSeconds), privacy: .public)s (SNR \(String(format: "%.1f", m.snr), privacy: .public)) → buffer \(String(format: "%.3f", buffer), privacy: .public)s")
                airOK = true
            } else {
                Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): AirPlay chirp weak (SNR \(String(format: "%.1f", m.snr), privacy: .public)) — will retry")
            }
        } catch {
            Log.app.error("PassiveSyncMonitor #\(iteration, privacy: .public): AirPlay chirp failed: \(String(describing: error), privacy: .public)")
        }

        // --- Chirp 2: reference (Sonos) in isolation → its lag. Mute AirPlay,
        //     un-mute the others (the Sonos zones).
        await SessionState.shared.setVolumeImmediate(0, for: airplay.id)
        for d in others { await SessionState.shared.setVolumeImmediate(max(saved[d.id] ?? acquireVolumeFloor, acquireVolumeFloor), for: d.id) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): ◆ chirp-anchoring reference (Sonos; AirPlay muted)…")
        var refOK = false
        do {
            let m = try await MicCalibrator.measureWithChirp(chirpDurationSec: 1.0, maxLagSec: maxLagSec)
            if m.snr >= snrGate {
                referenceAnchorLag = m.lagSeconds
                Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): ✓ anchored reference (Sonos) lag=\(String(format: "%.3f", m.lagSeconds), privacy: .public)s (SNR \(String(format: "%.1f", m.snr), privacy: .public))")
                refOK = true
            } else {
                Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): reference chirp weak (SNR \(String(format: "%.1f", m.snr), privacy: .public)) — will retry")
            }
        } catch {
            Log.app.error("PassiveSyncMonitor #\(iteration, privacy: .public): reference chirp failed: \(String(describing: error), privacy: .public)")
        }

        // Restore all volumes.
        for (id, v) in saved { await SessionState.shared.setVolumeImmediate(v, for: id) }
        return airOK && refOK
    }

    // MARK: - Passive tracking + correction

    private func trackAndCorrect(airplay: SinkDescriptor, iteration: Int) async throws -> Double {
        // 1. Record + reference.
        let mic = MicCapture()
        let micResult = try await mic.capture(duration: micWindowSec)
        try Task.checkCancellation()
        guard let ref = AudioBroadcaster.shared.snapshotReferenceSamples(durationSec: micWindowSec + maxLagSec) else {
            Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): reference tap empty")
            return 0
        }
        let micSamples: [Float] = abs(micResult.sampleRate - ref.sampleRate) < 1.0
            ? micResult.samples
            : Self.linearResample(micResult.samples, from: micResult.sampleRate, to: ref.sampleRate)

        // 2. Peaks + gate.
        let allPeaks = AudioCorrelation.topCorrelatedLags(
            reference: ref.samples, observed: micSamples, sampleRate: ref.sampleRate,
            maxLagSeconds: maxLagSec, peakCount: peakCount, minSeparationSeconds: minPeakSeparationSec,
            phat: true
        )
        let peaks = allPeaks.filter { $0.snr >= snrGate }
        let geom = allPeaks.map { "\(String(format: "%.3f", $0.lagSeconds))s(SNR \(String(format: "%.1f", $0.snr)))" }.joined(separator: " · ")
        Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public) peaks: \(geom, privacy: .public)")

        let currentOffsetMs = SessionState.shared.offset(for: airplay.id)
        let currentOffsetSec = Double(currentOffsetMs) / 1000.0

        // 3. AirPlay position is KNOWN by construction: its lag = commanded
        //    offset + the buffer measured at the chirp anchor. We deliberately
        //    do NOT re-measure it acoustically — near alignment its peak merges
        //    with the Sonos's, and resolving the two against each other was the
        //    source of the runaway (phantom errors → endless re-timing → the
        //    receiver never actually plays). Trust the geometry.
        let buffer = airplayBufferSec ?? 0
        let airplayLag = currentOffsetSec + buffer

        // 4. Reference (Sonos) — FOCUSED window search near its anchored lag,
        //    exactly like AirPlay. PHAT sharpens room reflections into strong
        //    spurious peaks, so "slowest peak wins" grabs junk; a focused
        //    window around the anchor ignores them. Update the anchor each
        //    round so it follows Sonos's drift.
        let refExpected = referenceAnchorLag ?? 0
        let refHit = AudioCorrelation.strongestPeak(
            reference: ref.samples, observed: micSamples, sampleRate: ref.sampleRate,
            loSeconds: max(0, refExpected - referenceTolSec), hiSeconds: refExpected + referenceTolSec, phat: true)
        guard let refHit, refHit.snr >= trackGate else {
            lostCount += 1
            if lostCount >= lostThreshold {
                referenceAnchorLag = nil; airplayBufferSec = nil   // re-anchor both next round
                return record(iteration, peaks: peaks, airplayLag: airplayLag, status: "lost Sonos reference \(lostCount)× — re-anchoring next round")
            }
            return record(iteration, peaks: peaks, airplayLag: airplayLag, status: "Sonos peak not found near \(String(format: "%.3f", refExpected))s (\(lostCount)/\(lostThreshold)) — coast")
        }
        let referenceLag = refHit.lagSeconds
        referenceAnchorLag = referenceLag   // track drift

        // 5. True floor only if AirPlay's intrinsic buffer exceeds the
        //    reference even at offset 0 — then it can't be sped up.
        if buffer >= referenceLag - (minPeakSeparationSec / 2) {
            errorWindowMs.removeAll()
            return record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                          status: "AirPlay's intrinsic buffer (\(String(format: "%.3f", buffer))s) ≥ reference (\(String(format: "%.3f", referenceLag))s) — true floor; would need to delay the others (no Sonos delay yet), holding.")
        }

        // 6. Move AirPlay toward the reference. error is SIGNED: negative ⇒
        //    AirPlay overshot (reduce offset); positive ⇒ behind (add delay).
        let errorMs = (referenceLag - airplayLag) * 1000
        errorWindowMs.append(errorMs)
        if errorWindowMs.count > windowCap { errorWindowMs.removeFirst() }
        let median = Self.median(errorWindowMs)

        guard errorWindowMs.count >= minSamplesToApply else {
            return record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                          status: "correcting toward \(String(format: "%.3f", referenceLag))s · err=\(Int(errorMs))ms median=\(Int(median))ms · accumulating (\(errorWindowMs.count)/\(minSamplesToApply))")
        }
        // Hysteresis latch — THE runaway fix. Once locked, HOLD and stop
        // touching the offset; only re-engage when Sonos has genuinely drifted
        // past `reengageThresholdMs`. Without this, measurement noise larger
        // than the tiny deadband triggered a correction every round, and each
        // correction re-timed (and silenced) the AirPlay receiver — forever.
        if converged {
            if abs(median) < reengageThresholdMs {
                return record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                              status: "✓ locked — holding (median \(Int(median))ms, within ±\(Int(reengageThresholdMs))ms)")
            }
            converged = false   // real drift — act again
        }
        if abs(median) < deadbandMs {
            converged = true
            errorWindowMs.removeAll()
            return record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                          status: "✓ converged — locked (median \(Int(median))ms)")
        }

        let stepMs = max(-maxStepMs, min(maxStepMs, median))
        let newOffsetMs = max(0, Int((Double(currentOffsetMs) + stepMs).rounded()))
        if armed {
            SessionState.shared.setOffset(newOffsetMs, for: airplay.id)
            errorWindowMs.removeAll()
            _ = record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                       appliedOffsetMs: newOffsetMs, status: "✓ APPLIED offset \(currentOffsetMs)→\(newOffsetMs)ms (median \(Int(median))ms)")
            return abs(stepMs) / 1000.0 + 1.0
        } else {
            return record(iteration, peaks: peaks, airplayLag: airplayLag, referenceLag: referenceLag,
                          status: "○ would apply offset \(currentOffsetMs)→\(newOffsetMs)ms (median \(Int(median))ms) — arm to enable")
        }
    }

    // MARK: - Internals

    @discardableResult
    private func record(_ iteration: Int, peaks: [(lagSeconds: Double, snr: Float)], airplayLag: Double? = nil,
                        referenceLag: Double? = nil, appliedOffsetMs: Int? = nil, status: String) -> Double {
        lastReading = Reading(peakLagsSec: peaks.map(\.lagSeconds), airplayLagSec: airplayLag,
                              referenceLagSec: referenceLag, appliedOffsetMs: appliedOffsetMs,
                              armed: armed, iteration: iteration, status: status)
        Log.app.notice("PassiveSyncMonitor #\(iteration, privacy: .public): \(status, privacy: .public)")
        return 0
    }

    private static func nearest(_ xs: [Double], to target: Double, within tol: Double) -> Double? {
        xs.filter { abs($0 - target) <= tol }.min(by: { abs($0 - target) < abs($1 - target) })
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static func linearResample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        if srcRate == dstRate { return input }
        let ratio = dstRate / srcRate
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 0 else { return [] }
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
