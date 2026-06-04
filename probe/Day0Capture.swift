// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
// Day0Capture.swift
//
// SuperAudio Day 0 capture probe.
//
// Purpose: confirm that the macOS 14.4+ CoreAudio process tap API
// (`CATapDescription` + `AudioHardwareCreateProcessTap`) works under Free
// Apple ID / Personal Team signing — *before* scaffolding the full SPM
// workspace. This is the gate that decides Plan A (process tap) vs Plan B
// (BlackHole virtual audio device) for the entire project.
//
// Approach: a single-file Swift program compiled with `swiftc` and run from
// Terminal.app. TCC binds the audio-recording permission to Terminal (the
// parent process), so no `.app` bundle, no `Info.plist`, no entitlements
// file, and no code signing are required for this probe. (The eventual
// SuperAudio menu bar app will need all of those; the probe does not.)
//
// Build:
//   swiftc -O probe/Day0Capture.swift -o probe/Day0Capture
//
// Run:
//   ./probe/Day0Capture
//
// Expected: on first run, Terminal.app prompts "Terminal would like to record
// audio from other applications on your Mac." Grant it. Then play any system
// audio (Spotify, Safari, `say hello`) while the 5-second capture window is
// open. You should see callbacks logging non-zero `firstSample` values.
//
// If you see `AudioHardwareCreateProcessTap failed: ...`, fall back to Plan B
// (install BlackHole, capture from it as a regular input device) and record
// the decision in DECISIONS.md.
//
// Adapted in part from patterns in https://github.com/insidegui/AudioCap (MIT)
// and https://github.com/makeusabrew/audiotee (MIT). No code copied verbatim;
// see THIRD_PARTY_NOTICES.md.
//
// Copyright (c) 2026 David Puerto. Licensed under MIT — see LICENSE.

import Foundation
import CoreAudio
import AudioToolbox

private let log = { (msg: String) in
    FileHandle.standardError.write(Data("[probe] \(msg)\n".utf8))
}

// MARK: - Tap setup

private func createSystemTap() throws -> (tapID: AudioObjectID, tapUUID: UUID, asbd: AudioStreamBasicDescription) {
    let desc = CATapDescription()
    desc.name = "superaudio-day0-tap"
    desc.processes = []              // empty list + isExclusive=true => "exclude nothing" = tap everything
    desc.isExclusive = true
    desc.isMixdown = true            // single stereo mix, not per-process streams
    desc.isMono = false
    desc.isPrivate = true            // don't advertise to other clients
    desc.muteBehavior = .unmuted     // user still hears audio through speakers
    desc.deviceUID = nil             // follow default system output
    desc.stream = 0
    let tapUUID = desc.uuid

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(desc, &tapID)
    guard status == noErr else {
        throw ProbeError("AudioHardwareCreateProcessTap failed: OSStatus \(status)")
    }

    var fmtAddr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var sz   = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let fmtStatus = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &sz, &asbd)
    guard fmtStatus == noErr else {
        throw ProbeError("kAudioTapPropertyFormat read failed: OSStatus \(fmtStatus)")
    }

    return (tapID, tapUUID, asbd)
}

private func createAggregate(wrapping tapUUID: UUID) throws -> AudioObjectID {
    let aggUID = UUID().uuidString
    let dict: [String: Any] = [
        kAudioAggregateDeviceNameKey:         "superaudio-day0-aggregate",
        kAudioAggregateDeviceUIDKey:          aggUID,
        kAudioAggregateDeviceIsPrivateKey:    true,
        kAudioAggregateDeviceIsStackedKey:    false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]
        ],
    ]

    var aggID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
    guard status == noErr else {
        throw ProbeError("AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
    }
    return aggID
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

// MARK: - Main

do {
    log("starting Day 0 capture probe")

    let (tapID, tapUUID, asbd) = try createSystemTap()
    log("tap=\(tapID) sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) format=0x\(String(asbd.mFormatID, radix: 16)) flags=0x\(String(asbd.mFormatFlags, radix: 16))")

    let aggID = try createAggregate(wrapping: tapUUID)
    log("aggregate=\(aggID)")

    let ioQueue = DispatchQueue(label: "superaudio.probe.io", qos: .userInteractive)
    var callbackCount = 0
    var procID: AudioDeviceIOProcID?

    let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inInputData, _, _, _ in
        let bufferList = inInputData.pointee
        let buffer = bufferList.mBuffers
        let bytesPerFrame = max(asbd.mBytesPerFrame, 1)
        let frames = buffer.mDataByteSize / bytesPerFrame

        var firstSample: Float = 0
        if let dataPtr = buffer.mData, buffer.mDataByteSize >= 4 {
            firstSample = dataPtr.assumingMemoryBound(to: Float.self).pointee
        }

        callbackCount += 1
        if callbackCount == 1 || callbackCount % 20 == 0 {
            log("cb#\(callbackCount) frames=\(frames) ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize) firstSample=\(firstSample)")
        }
    }
    guard createStatus == noErr, let procID else {
        throw ProbeError("AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(createStatus)")
    }

    let startStatus = AudioDeviceStart(aggID, procID)
    guard startStatus == noErr else {
        throw ProbeError("AudioDeviceStart failed: OSStatus \(startStatus)")
    }

    log("capturing for 5 seconds — play some audio now…")
    Thread.sleep(forTimeInterval: 5.0)

    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)

    log("done. total callbacks=\(callbackCount)")
    if callbackCount == 0 {
        log("WARNING: zero callbacks fired. Either no audio was playing, or the tap is silently failing. Re-run with audio active before deciding Plan A vs Plan B.")
        exit(2)
    }
    exit(0)
} catch let error as ProbeError {
    log("FAILED: \(error.description)")
    log("If the error is from AudioHardwareCreateProcessTap, this likely means TCC permission denied (System Settings → Privacy & Security → Audio Recording → grant Terminal) or process tap is genuinely blocked on this machine. Plan B (BlackHole) is the documented fallback — see CLAUDE.md gotcha #3.")
    exit(1)
} catch {
    log("FAILED with unexpected error: \(error)")
    exit(1)
}
