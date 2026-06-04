// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation

/// #105 — Reference signal generator for mic-based room tuning.
///
/// **The problem**: ambient music can't be used as the reference signal for
/// cross-correlation latency measurement. Music's rhythmic and harmonic
/// structure produces spurious correlation peaks (every beat, every repeat
/// in a chord progression) that confuse the algorithm. We learned this the
/// hard way on 2026-05-18 — proved the correlator worked (SNR 20+) but the
/// peaks it locked onto weren't the real speaker arrivals.
///
/// **The fix**: use a linear sine sweep (chirp). Chirps have near-flat
/// autocorrelation — their correlation function has ONE clean peak at zero
/// lag and small ripple everywhere else. This makes the cross-correlation
/// with a recorded version unambiguous: peak = true lag, no spurious peaks.
///
/// This is the standard reference signal in acoustic measurement tools
/// (Smaart, REW, AKG, ARTA). 1 second at 200 Hz → 8 kHz covers most of
/// the speech/music band with enough bandwidth to anchor the correlation
/// without being grating to the listener.
public enum ChirpGenerator {

    /// Generate a linear sine sweep from `f0` to `f1` Hz over `duration`
    /// seconds at `sampleRate` samples/sec. Returns mono float samples in
    /// the range roughly [-amplitude, +amplitude].
    ///
    /// The sweep uses a linear frequency law:
    ///   f(t) = f0 + (f1 - f0) * (t / duration)
    /// Phase is integrated as:
    ///   φ(t) = 2π * (f0 * t + (f1 - f0) * t² / (2 * duration))
    /// This produces a continuous instantaneous frequency rising from f0
    /// at t=0 to f1 at t=duration. The starting and ending samples are at
    /// phase 0 and a clean value, but a brief cosine fade-in / fade-out
    /// envelope (`fadeMs`) suppresses any click artifact at the edges.
    public static func linearSweep(
        f0: Double = 200,
        f1: Double = 8000,
        duration: Double = 1.0,
        sampleRate: Double = 48000,
        amplitude: Float = 0.6,
        fadeMs: Double = 10
    ) -> [Float] {
        let n = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: n)
        let fadeSamples = max(1, Int(fadeMs / 1000.0 * sampleRate))
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * .pi * (f0 * t + (f1 - f0) * t * t / (2.0 * duration))
            var sample = Float(sin(phase)) * amplitude
            // Fade-in/out window (Hann half-cycles) to suppress edge clicks.
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

    /// Convenience: the canonical SuperAudio calibration chirp.
    /// 1 sec, 200 Hz → 8 kHz, 48 kHz, amplitude 0.6, 10 ms fades.
    /// Matches the default broadcaster capture format so it slots in
    /// without resampling.
    public static var defaultCalibrationChirp: [Float] {
        linearSweep()
    }
}
