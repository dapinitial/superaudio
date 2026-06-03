// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import CoreAudio
import SuperAudioCore

/// Mutes the Mac's default output device (built-in speakers / headphones).
/// Used when the user prefers AirPlay-only audio — without this, the
/// process tap captures system audio AND the system audio continues to
/// play through the Mac's speakers, creating a ~93 ms echo with the
/// AirPlay-buffered remote playback.
///
/// We track whether *we* muted the device so we can restore on session
/// end without disturbing the user's manual mute state. If the user
/// manually unmutes while a session is active, we don't fight them.
enum MacAudioMute {

    private static var weMutedIt: Bool = false

    /// Mute the Mac's default output. Remembers that *we* did it so the
    /// matching `restore()` only unmutes if we initiated the mute.
    static func muteDefaultOutput() {
        guard let device = defaultOutputDevice() else {
            Log.app.error("MacAudioMute: no default output device")
            return
        }
        let wasMuted = isMuted(device: device)
        guard !wasMuted else {
            // Already muted by user — leave alone. Logged so the gate
            // state is visible during diagnosis (was silently returning
            // before, which produced zero output when investigating
            // "why didn't my MacBook mute").
            Log.app.info("MacAudioMute: device \(device) is already muted — no-op")
            return
        }
        if setMuted(true, on: device) {
            weMutedIt = true
            Log.app.info("MacAudioMute: muted default output device \(device)")
        } else {
            Log.app.error("MacAudioMute: failed to mute default output")
        }
    }

    /// Undo our mute. No-op if user-muted or never muted.
    static func restoreDefaultOutput() {
        guard weMutedIt, let device = defaultOutputDevice() else { return }
        if setMuted(false, on: device) {
            Log.app.info("MacAudioMute: restored default output device \(device)")
        } else {
            Log.app.error("MacAudioMute: failed to unmute default output")
        }
        weMutedIt = false
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

    private static func isMuted(device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    @discardableResult
    private static func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else {
            Log.app.error("MacAudioMute: device \(device) has no mute property")
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        return status == noErr
    }
}
