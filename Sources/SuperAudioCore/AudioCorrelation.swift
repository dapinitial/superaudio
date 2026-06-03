// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import Accelerate

/// Cross-correlation engine for M11 Path A auto-calibration (#98).
///
/// Given a **reference signal** (what we played) and an **observed signal**
/// (what the Mac mic heard, after the audio traveled through speaker →
/// room → mic), recover the time-shift between them: the speaker's total
/// playback lag from "sample captured" to "sample heard at the mic."
///
/// **Approach**: FFT-based cross-correlation via `vDSP`. For two real
/// signals of length N, naive correlation is O(N²); FFT path is
/// O(N log N). At N = 144 000 (3 s @ 48 kHz), FFT path is ~1000× faster.
///
/// The peak of the cross-correlation function is at lag k that maximizes
/// `Σ(reference[i] × observed[i+k])`. Positive k means observed lags
/// reference by k samples (the speaker took k/sampleRate seconds to
/// play what reference said at time 0). That's our delay measurement.
///
/// Robustness notes (see `correlatedLag(reference:observed:)`):
/// - Both signals must be the same length and same sample rate. Caller
///   resamples / trims if needed.
/// - Length must be a power of 2 (vDSP FFT requirement) — we pad with
///   zeros (or trim) to the next power of 2.
/// - The reference is normalized to zero mean before correlation so a
///   DC offset in either signal doesn't pull the peak.
public enum AudioCorrelation {

    /// Result of one correlation: the recovered lag in samples + a
    /// confidence metric (peak height relative to mean correlation).
    public struct CorrelationResult {
        /// Lag in samples. Positive = observed lags reference by this
        /// many samples. To convert to seconds: `lagSamples / sampleRate`.
        public let lagSamples: Int
        /// Peak correlation value at `lagSamples`. Useful for sanity
        /// checks — a high peak relative to the mean correlation value
        /// indicates strong signal lock. A low peak suggests the
        /// reference and observed signals don't share a common signal
        /// (e.g., the mic captured silence or noise).
        public let peakValue: Float
        /// Mean of the absolute correlation function. Used to compute
        /// `signalToNoiseRatio` below.
        public let meanAbsValue: Float
        /// Heuristic: peak / mean(|corr|). >5.0 is strong lock, >10.0
        /// is excellent, <2.0 is weak / probably no signal.
        public var signalToNoiseRatio: Float {
            meanAbsValue > 0 ? abs(peakValue) / meanAbsValue : 0
        }
    }

    /// Compute the lag (in samples) that best aligns `observed` with
    /// `reference`. Both inputs are mono float32.
    ///
    /// `maxLagSamples`: if provided, search only the first N samples of
    /// the correlation result. Defaults to `reference.count` (find any
    /// positive lag up to the reference length). Pass a smaller value
    /// to constrain the search when you have prior knowledge.
    ///
    /// Returns `nil` if either input is empty.
    public static func correlatedLag(
        reference: [Float],
        observed: [Float],
        maxLagSamples: Int? = nil
    ) -> CorrelationResult? {
        guard !reference.isEmpty, !observed.isEmpty else { return nil }

        // For full cross-correlation length, we want N + M - 1 output
        // samples. Round up to power of 2 for the FFT.
        let n = reference.count
        let m = observed.count
        let outputLength = n + m - 1
        let log2N = Int(ceil(log2(Double(outputLength))))
        let fftSize = 1 << log2N

        // Zero-pad both inputs to fftSize.
        var refPadded = [Float](repeating: 0, count: fftSize)
        var obsPadded = [Float](repeating: 0, count: fftSize)
        // Reference is zero-meaned to suppress DC bias in the correlation.
        let refMean = reference.reduce(0, +) / Float(reference.count)
        for i in 0..<n { refPadded[i] = reference[i] - refMean }
        let obsMean = observed.reduce(0, +) / Float(observed.count)
        for i in 0..<m { obsPadded[i] = observed[i] - obsMean }

        // FFT setup. log2N must be in range [0, ~24].
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2N), FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Forward FFT of reference and observed → frequency domain.
        // vDSP works with split-complex; pack real input into the
        // interleaved real+imag layout.
        var refReal = [Float](repeating: 0, count: fftSize / 2)
        var refImag = [Float](repeating: 0, count: fftSize / 2)
        var obsReal = [Float](repeating: 0, count: fftSize / 2)
        var obsImag = [Float](repeating: 0, count: fftSize / 2)
        var prodReal = [Float](repeating: 0, count: fftSize / 2)
        var prodImag = [Float](repeating: 0, count: fftSize / 2)

        refReal.withUnsafeMutableBufferPointer { rrBuf in
        refImag.withUnsafeMutableBufferPointer { riBuf in
        obsReal.withUnsafeMutableBufferPointer { orBuf in
        obsImag.withUnsafeMutableBufferPointer { oiBuf in
        prodReal.withUnsafeMutableBufferPointer { prBuf in
        prodImag.withUnsafeMutableBufferPointer { piBuf in
            var refSplit = DSPSplitComplex(realp: rrBuf.baseAddress!, imagp: riBuf.baseAddress!)
            var obsSplit = DSPSplitComplex(realp: orBuf.baseAddress!, imagp: oiBuf.baseAddress!)
            var prodSplit = DSPSplitComplex(realp: prBuf.baseAddress!, imagp: piBuf.baseAddress!)

            refPadded.withUnsafeBufferPointer { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &refSplit, 1, vDSP_Length(fftSize / 2))
                }
            }
            obsPadded.withUnsafeBufferPointer { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &obsSplit, 1, vDSP_Length(fftSize / 2))
                }
            }
            vDSP_fft_zrip(fftSetup, &refSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_FORWARD))
            vDSP_fft_zrip(fftSetup, &obsSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_FORWARD))

            // Cross-correlation in frequency domain: conj(REF) * OBS.
            // vDSP_zvcmul does (a + bi)(c + di) → multiplied complex.
            // We need conj(REF) * OBS = (refR - i*refI)(obsR + i*obsI)
            //   = refR*obsR + refI*obsI + i(refR*obsI - refI*obsR)
            // Compute the conjugate of REF, then multiply.
            var negOne: Float = -1
            vDSP_vsmul(refSplit.imagp, 1, &negOne, refSplit.imagp, 1, vDSP_Length(fftSize / 2))
            vDSP_zvmul(&refSplit, 1, &obsSplit, 1, &prodSplit, 1, vDSP_Length(fftSize / 2), 1)

            // Inverse FFT → cross-correlation in time domain.
            vDSP_fft_zrip(fftSetup, &prodSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_INVERSE))
        }}}}}}

        // Convert split-complex back to interleaved real samples.
        var corr = [Float](repeating: 0, count: fftSize)
        refReal.withUnsafeMutableBufferPointer { _ in } // appease the compiler

        prodReal.withUnsafeBufferPointer { prBuf in
        prodImag.withUnsafeBufferPointer { piBuf in
            var prodSplit = DSPSplitComplex(
                realp: UnsafeMutablePointer(mutating: prBuf.baseAddress!),
                imagp: UnsafeMutablePointer(mutating: piBuf.baseAddress!)
            )
            corr.withUnsafeMutableBufferPointer { cBuf in
                cBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    vDSP_ztoc(&prodSplit, 1, complexPtr, 2, vDSP_Length(fftSize / 2))
                }
            }
        }}

        // Normalize by 1/fftSize (vDSP FFTs are unnormalized).
        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(corr, 1, &scale, &corr, 1, vDSP_Length(fftSize))

        // The full circular correlation. Positive lags 0..<N are in the
        // first half; negative lags are wrapped to the back. For our
        // use case (mic lags reference, so lag >= 0), search the
        // positive-lag range. Default to the full reference length so
        // callers with `reference` >> `observed` (mic vs longer ref tap)
        // can find lags beyond `observed.count`.
        let searchLength = min(maxLagSamples ?? n, fftSize)
        var peakIdx: vDSP_Length = 0
        var peakVal: Float = 0
        corr.withUnsafeBufferPointer { ptr in
            vDSP_maxvi(ptr.baseAddress!, 1, &peakVal, &peakIdx, vDSP_Length(searchLength))
        }

        // Mean absolute value of the correlation (for SNR metric).
        var meanAbs: Float = 0
        let absSlice = (0..<searchLength).map { abs(corr[$0]) }
        vDSP_meanv(absSlice, 1, &meanAbs, vDSP_Length(searchLength))

        return CorrelationResult(
            lagSamples: Int(peakIdx),
            peakValue: peakVal,
            meanAbsValue: meanAbs
        )
    }

    /// Convenience wrapper that returns the lag in seconds. Both signals
    /// must share `sampleRate`.
    public static func correlatedLagSeconds(
        reference: [Float],
        observed: [Float],
        sampleRate: Double,
        maxLagSeconds: Double? = nil
    ) -> (lagSeconds: Double, snr: Float)? {
        let maxSamples = maxLagSeconds.map { Int($0 * sampleRate) }
        guard let result = correlatedLag(reference: reference, observed: observed, maxLagSamples: maxSamples) else {
            return nil
        }
        return (Double(result.lagSamples) / sampleRate, result.signalToNoiseRatio)
    }
}
