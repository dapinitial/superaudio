// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import CoreAudio
import SuperAudioCore

/// Forces the macOS default output device's nominal sample rate to a
/// specific value (44.1 kHz, matching AirPlay 1's wire format) while a
/// session is active, then restores the original rate on session end.
///
/// **Why this exists.** The macOS audio engine has a single output sample
/// rate; every app that wants to play audio gets resampled to that rate
/// before reaching the system mixer. By default macOS leaves this at
/// 48 kHz. When we capture system audio via the process tap, we see
/// whatever the engine rate is — not the source app's native rate.
///
/// For Apple Music Lossless 44.1/16 content this is the difference
/// between bit-perfect and lossy:
///
///   - Default 48 kHz output: Apple Music decodes 44.1 → engine upsamples
///     to 48 → our tap captures at 48 → we downsample back to 44.1 for
///     the AirPlay 1 wire format. Two rate conversions; not bit-perfect.
///
///   - Force 44.1 kHz output: Apple Music decodes 44.1 → engine passes
///     through at 44.1 → our tap captures at 44.1 → no rate conversion
///     before ALAC encode → bit-perfect on the wire.
///
/// The same trick Music.app uses when "auto-switch sample rate" is on.
/// We track whether *we* changed the rate so cleanup doesn't disturb a
/// user-initiated rate change.
enum LosslessMode {

    /// Target rate for AirPlay 1 (matches our SDP `a=fmtp:` declaration).
    static let targetSampleRate: Double = 44100

    /// Pair of (deviceID, originalRate) when we've forced a change.
    private static var weChangedTo: (device: AudioObjectID, originalRate: Double)?

    static func forceMacOutputTo44100() {
        guard let device = defaultOutputDevice() else {
            Log.app.error("LosslessMode: no default output device")
            return
        }
        guard let current = currentSampleRate(device: device) else {
            Log.app.error("LosslessMode: couldn't read current sample rate")
            return
        }
        // Allow tiny floating-point slop; CoreAudio sometimes reports
        // 44100.0 as 44099.9... in practice.
        if abs(current - targetSampleRate) < 1.0 {
            Log.app.info("LosslessMode: device already at 44.1 kHz — no change")
            return
        }
        if setSampleRate(targetSampleRate, on: device) {
            weChangedTo = (device, current)
            Log.app.info("LosslessMode: output device sample rate \(current) → \(Self.targetSampleRate)")
        } else {
            Log.app.error("LosslessMode: failed to set sample rate (device may not support 44.1)")
        }
    }

    /// Restore the rate we changed from. No-op if we never changed it
    /// or the user manually changed it in between.
    static func restore() {
        guard let (device, original) = weChangedTo else { return }
        if setSampleRate(original, on: device) {
            Log.app.info("LosslessMode: restored output sample rate → \(original)")
        }
        weChangedTo = nil
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : nil
    }

    private static func currentSampleRate(device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    @discardableResult
    private static func setSampleRate(_ rate: Double, on device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: Float64 = rate
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &value
        )
        return status == noErr
    }
}
