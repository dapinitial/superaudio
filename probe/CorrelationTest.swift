// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.
//
// CorrelationTest — validates the cross-correlation engine in
// `Sources/SuperAudioCore/AudioCorrelation.swift` by feeding it
// synthetic signals with known time-shifts and verifying the recovered
// lag matches.
//
// Build + run:
//   swiftc -O probe/CorrelationTest.swift -o probe/CorrelationTest
//   probe/CorrelationTest
//
// Gates: M11 Path A auto-calibration (#98). Run this before relying on
// the correlation output to set real per-sink offsets. If it fails on
// synthetic input, the live mic path will be worse.

import Foundation
import Accelerate

// ─────────────────────────────────────────────────────────────────────
// Inlined copy of AudioCorrelation.correlatedLag for standalone build.
// Keep in sync with Sources/SuperAudioCore/AudioCorrelation.swift.
// ─────────────────────────────────────────────────────────────────────

struct CorrelationResult {
    let lagSamples: Int
    let peakValue: Float
    let meanAbsValue: Float
    var snr: Float { meanAbsValue > 0 ? abs(peakValue) / meanAbsValue : 0 }
}

func correlatedLag(reference: [Float], observed: [Float]) -> CorrelationResult? {
    guard !reference.isEmpty, !observed.isEmpty else { return nil }
    let n = reference.count
    let m = observed.count
    let outputLength = n + m - 1
    let log2N = Int(ceil(log2(Double(outputLength))))
    let fftSize = 1 << log2N

    var refPadded = [Float](repeating: 0, count: fftSize)
    var obsPadded = [Float](repeating: 0, count: fftSize)
    let refMean = reference.reduce(0, +) / Float(reference.count)
    for i in 0..<n { refPadded[i] = reference[i] - refMean }
    let obsMean = observed.reduce(0, +) / Float(observed.count)
    for i in 0..<m { obsPadded[i] = observed[i] - obsMean }

    guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2N), FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var refReal = [Float](repeating: 0, count: fftSize / 2)
    var refImag = [Float](repeating: 0, count: fftSize / 2)
    var obsReal = [Float](repeating: 0, count: fftSize / 2)
    var obsImag = [Float](repeating: 0, count: fftSize / 2)
    var prodReal = [Float](repeating: 0, count: fftSize / 2)
    var prodImag = [Float](repeating: 0, count: fftSize / 2)
    var corr = [Float](repeating: 0, count: fftSize)

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
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                vDSP_ctoz(cp, 2, &refSplit, 1, vDSP_Length(fftSize / 2))
            }
        }
        obsPadded.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                vDSP_ctoz(cp, 2, &obsSplit, 1, vDSP_Length(fftSize / 2))
            }
        }
        vDSP_fft_zrip(fftSetup, &refSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_FORWARD))
        vDSP_fft_zrip(fftSetup, &obsSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_FORWARD))

        var negOne: Float = -1
        vDSP_vsmul(refSplit.imagp, 1, &negOne, refSplit.imagp, 1, vDSP_Length(fftSize / 2))
        vDSP_zvmul(&refSplit, 1, &obsSplit, 1, &prodSplit, 1, vDSP_Length(fftSize / 2), 1)
        vDSP_fft_zrip(fftSetup, &prodSplit, 1, vDSP_Length(log2N), FFTDirection(FFT_INVERSE))

        corr.withUnsafeMutableBufferPointer { cBuf in
            cBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                vDSP_ztoc(&prodSplit, 1, cp, 2, vDSP_Length(fftSize / 2))
            }
        }
    }}}}}}

    var scale = 1.0 / Float(fftSize)
    vDSP_vsmul(corr, 1, &scale, &corr, 1, vDSP_Length(fftSize))

    let searchLength = m
    var peakIdx: vDSP_Length = 0
    var peakVal: Float = 0
    corr.withUnsafeBufferPointer { ptr in
        vDSP_maxvi(ptr.baseAddress!, 1, &peakVal, &peakIdx, vDSP_Length(searchLength))
    }

    var meanAbs: Float = 0
    let absSlice = (0..<searchLength).map { abs(corr[$0]) }
    vDSP_meanv(absSlice, 1, &meanAbs, vDSP_Length(searchLength))

    return CorrelationResult(lagSamples: Int(peakIdx), peakValue: peakVal, meanAbsValue: meanAbs)
}

// ─────────────────────────────────────────────────────────────────────
// Test harness
// ─────────────────────────────────────────────────────────────────────

let sampleRate: Double = 48000

/// Make a noisy sine + click reference. Realistic-ish: room mic captures
/// a mix of the test signal + noise. We use a swept frequency for
/// uniqueness — pure sine is symmetric and creates a comb of peaks.
func makeReference(duration: Double, seed: UInt32) -> [Float] {
    let n = Int(duration * sampleRate)
    var out = [Float](repeating: 0, count: n)
    var rng = SystemRandomNumberGenerator()
    _ = seed
    // Chirp from 200 Hz to 4 kHz over duration — distinct autocorrelation peak.
    let f0: Double = 200, f1: Double = 4000
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let f = f0 + (f1 - f0) * t / duration
        let phase = 2 * Double.pi * f0 * t + Double.pi * (f1 - f0) * t * t / duration
        out[i] = Float(0.5 * sin(phase))
        // Small additive noise to keep numerics realistic.
        let noise = Float(Int.random(in: -1000...1000, using: &rng)) / 1_000_000.0
        out[i] += noise
    }
    return out
}

/// Shift a signal by `lagSamples` (positive = pad zeros at front).
/// Truncate to the same length so reference and observed match in size.
func shifted(_ signal: [Float], by lagSamples: Int) -> [Float] {
    let n = signal.count
    var out = [Float](repeating: 0, count: n)
    if lagSamples >= 0 {
        for i in lagSamples..<n {
            out[i] = signal[i - lagSamples]
        }
    } else {
        let shift = -lagSamples
        for i in 0..<(n - shift) {
            out[i] = signal[i + shift]
        }
    }
    return out
}

/// Add white noise.
func addNoise(_ signal: [Float], amplitude: Float) -> [Float] {
    var out = signal
    var rng = SystemRandomNumberGenerator()
    for i in 0..<out.count {
        let n = Float(Int.random(in: -10000...10000, using: &rng)) / 10000.0
        out[i] += n * amplitude
    }
    return out
}

// ─────────────────────────────────────────────────────────────────────
// Test cases
// ─────────────────────────────────────────────────────────────────────

print("CorrelationTest — synthetic-signal validation")
print("Sample rate: \(sampleRate) Hz")
print()

var failures = 0
var passes = 0

func runCase(_ name: String, duration: Double, knownLagMs: Double, noise: Float = 0) {
    let ref = makeReference(duration: duration, seed: 42)
    let lagSamples = Int(knownLagMs / 1000.0 * sampleRate)
    var obs = shifted(ref, by: lagSamples)
    if noise > 0 {
        obs = addNoise(obs, amplitude: noise)
    }
    guard let result = correlatedLag(reference: ref, observed: obs) else {
        print("✗ \(name): correlation returned nil")
        failures += 1
        return
    }
    let recoveredMs = Double(result.lagSamples) / sampleRate * 1000.0
    let errMs = abs(recoveredMs - knownLagMs)
    let ok = errMs < 1.0  // within 1 ms tolerance
    let mark = ok ? "✓" : "✗"
    print("\(mark) \(name)")
    print("    known lag: \(String(format: "%6.2f", knownLagMs)) ms")
    print("    recovered: \(String(format: "%6.2f", recoveredMs)) ms  (err \(String(format: "%5.2f", errMs)) ms)")
    print("    SNR:       \(String(format: "%5.1f", result.snr))  peak=\(String(format: "%.3f", result.peakValue))  mean|c|=\(String(format: "%.3f", result.meanAbsValue))")
    if ok { passes += 1 } else { failures += 1 }
    print()
}

// Sanity: zero lag
runCase("zero lag, clean",       duration: 1.0, knownLagMs: 0,    noise: 0)
// Typical AP1 lag
runCase("100 ms lag, clean",     duration: 1.0, knownLagMs: 100,  noise: 0)
// Typical Sonos lag
runCase("2000 ms lag, clean",    duration: 3.0, knownLagMs: 2000, noise: 0)
// Worst-case Sonos lag observed in M6 testing
runCase("4000 ms lag, clean",    duration: 6.0, knownLagMs: 4000, noise: 0)
// With realistic room noise
runCase("2000 ms lag, noisy",    duration: 3.0, knownLagMs: 2000, noise: 0.1)
runCase("2000 ms lag, v noisy",  duration: 3.0, knownLagMs: 2000, noise: 0.5)
// Sub-perceptible drift (M11 has to detect this)
runCase("5 ms lag, clean",       duration: 1.0, knownLagMs: 5,    noise: 0)

print("─────────────────────────────────────")
print("Result: \(passes) passed, \(failures) failed")
exit(failures > 0 ? 1 : 0)
