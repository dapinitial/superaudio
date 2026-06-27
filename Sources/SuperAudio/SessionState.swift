// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import SwiftUI
import SuperAudioCore
import SuperAudioSonos

/// Live state for "what's currently playing." Bound to the menu bar UI:
/// each entry in `MenuBarView` shows a checkmark when its sink id is in
/// `activeSinks`, and the menu-bar icon pulses while `isAnyActive` is true.
///
/// The set holds sink IDs — supports multi-sink fan-out (M5) without
/// further changes. For the M3 single-sink session model, the set has
/// at most one member at any moment.
@MainActor
@Observable
final class SessionState {
    static let shared = SessionState()

    private(set) var activeSinks: Set<SinkID> = []

    /// When true, the Mac's built-in speakers are muted while any session
    /// is active. Eliminates the ~93 ms echo between Mac-direct playback
    /// and the AirPlay-buffered remote playback. Persisted in UserDefaults.
    ///
    /// **Default: true.** Matches the MenuBarView's `@AppStorage` default
    /// (was previously skewed because `UserDefaults.bool(forKey:)` returns
    /// `false` for missing keys, while @AppStorage's `Bool = true` returns
    /// `true` — they disagreed silently until the user clicked the toggle.
    /// Fixed 2026-05-16 night.) On first launch, missing key → `true`;
    /// once user toggles, the value is persisted explicitly.
    var muteMacWhilePlaying: Bool = (UserDefaults.standard.object(forKey: "muteMacWhilePlaying") as? Bool ?? true) {
        didSet {
            UserDefaults.standard.set(muteMacWhilePlaying, forKey: "muteMacWhilePlaying")
            applyMuteIfNeeded()
        }
    }

    /// When true, the Mac's default output device is forced to 44.1 kHz
    /// while any session is active. Aligns the system audio engine with
    /// AirPlay 1's native wire rate, so 44.1/16 source material (Apple
    /// Music Lossless standard) reaches the speaker bit-perfect with no
    /// intermediate resampling. Persisted in UserDefaults.
    var losslessMode: Bool = UserDefaults.standard.bool(forKey: "losslessMode") {
        didSet {
            UserDefaults.standard.set(losslessMode, forKey: "losslessMode")
            applyLosslessIfNeeded()
        }
    }

    // Quiet Mode removed 2026-05-16. The 18% cap got real-world user
    // feedback: "we wanted default low, not a max cap." The new default
    // (15%) handles "never blaring" without restricting the slider's
    // ceiling. The 'quietMode' UserDefaults key is now ignored — leaving
    // stale values from prior installs is harmless.

    /// Per-sink user-facing volume, 0–100 integer percentage. Persisted in
    /// UserDefaults keyed by `sinkVolume.<rawSinkID>`. Set via the slider in
    /// the menu; read at session start so the saved level is applied before
    /// any audio flows.
    ///
    /// **Default for a sink with no saved value: 70**. Comfortable on B&W
    /// A5/A7 per real-device testing (~−9 dB on the AirPlay 1 scale).
    private(set) var sinkVolumes: [SinkID: Int] = [:]

    /// Per-sink manual playback offset in milliseconds, 0–500 ms. Pushes
    /// the sink's audio LATER by the given amount — used to balance
    /// against Sonos's intrinsic buffer floor (~200–500 ms behind AP1).
    /// Persisted in UserDefaults keyed by `sinkOffset.<sinkID>`.
    ///
    /// AirPlay 1 sinks apply the offset by shifting sync-packet NTP into
    /// the future; the receiver's scheduling math pushes playback by that
    /// amount. Sonos sinks persist the value but its effect is informational
    /// for now — Sonos has no per-packet timing channel; adjusting AP1
    /// sinks UP to match Sonos's natural lag is the balance mechanism.
    private(set) var sinkOffsetsMs: [SinkID: Int] = [:]

    /// Volume setters registered by live sessions. The closure is called
    /// every time the user adjusts the slider for that sink, so volume
    /// changes hit the speaker mid-stream without restarting the session.
    /// Keyed by sink ID.
    private var volumeSetters: [SinkID: @Sendable (Int) async -> Void] = [:]

    /// Pending debounced volume-send tasks keyed by sink ID. A rapid slider
    /// drag fires `setVolume` many times per second; if every tick hit
    /// SET_PARAMETER over RTSP/TCP, the control socket gets saturated and
    /// a slow response cascades into "RTSP timed out" → spurious session
    /// teardown. We coalesce: each setVolume cancels any pending send and
    /// schedules a fresh one 250 ms in the future. Only the FINAL value
    /// at drag-end actually hits the wire. See DECISIONS.md 2026-05-16
    /// (Saturday-night reliability triple).
    private var pendingVolumeTasks: [SinkID: Task<Void, Never>] = [:]
    private static let volumeDebounceNanos: UInt64 = 250_000_000  // 250 ms

    /// Pending debounced offset-update tasks. Same pattern as
    /// `pendingVolumeTasks`: rapid slider drags coalesce so the live
    /// `AudioBroadcaster.setDelay` only fires after the user stops
    /// moving. Critical because each `setDelay` retimes EVERY chunk
    /// in the per-subscriber queue (M6.3 #99); applying that on every
    /// pixel of drag produces a slow-motion / pause artifact while the
    /// queue head is continuously pushed past the drainer's wait
    /// boundary. Debounced, only the final settled value retimes the
    /// queue — exactly ONE pause/jump artifact per drag instead of
    /// continuous slow-motion.
    private var pendingOffsetTasks: [SinkID: Task<Void, Never>] = [:]
    private static let offsetDebounceNanos: UInt64 = 250_000_000  // 250 ms

    /// Offset setters registered by live AirPlay 1 sessions. Closure
    /// writes the new ms value into `RTPSender.manualOffsetSeconds`; the
    /// next periodic sync packet picks it up. Sonos sessions don't
    /// register here — Sonos's playback timing is fixed by its internal
    /// buffer floor and can't be shifted via protocol.
    private var offsetSetters: [SinkID: @Sendable (Int) -> Void] = [:]

    /// Per-sink "snooze the health monitor for N seconds" closure. Registered
    /// by AP1 sessions; invoked by `setOffset` when the delay bump is large
    /// enough that the receiver would go silent and trip the timing-packet
    /// staleness check. The closure body lives in AirPlay1Session and just
    /// pushes a future timestamp into the session's `HealthSnooze` handle.
    private var healthSnoozers: [SinkID: @Sendable (Double) -> Void] = [:]

    /// Delay-delta (in ms) above which `setOffset` snoozes the health
    /// monitor. Anything under this is small enough that the receiver
    /// won't go fully silent (~93ms AP1 buffer absorbs sub-100ms jumps).
    /// 300ms picked as a conservative floor — the soak-test threshold
    /// for timing-packet absence is 15 sec, so any bump over ~3 sec is
    /// catastrophic; anything under 300ms is invisible.
    private static let healthSnoozeThresholdMs: Int = 300

    /// Sinks that failed their most recent session attempt. UI shows an
    /// `xmark.circle.fill` icon for these for `failureDisplayDuration`
    /// seconds, then falls back to the idle circle. Lets the user see
    /// that a click did try (and failed) rather than silently doing
    /// nothing. Cleared automatically after the display window.
    private(set) var recentFailures: [SinkID: Date] = [:]

    /// How long a failure icon stays visible.
    private static let failureDisplayDuration: TimeInterval = 6

    /// Per-session entry. The `nonce` lets a finished task tell whether it
    /// is still the "current" session for that sink — without this, a rapid
    /// off→on toggle has the OLD task's continuation clobber the NEW task's
    /// dict entry, leaving the UI thinking the speaker is idle when it
    /// isn't.
    private struct Session {
        let nonce: UUID
        let task: Task<Void, Never>
    }
    private var sessionTasks: [SinkID: Session] = [:]

    /// **Wanted-active set** — sinks the user has explicitly turned ON
    /// (separate from `activeSinks`, which reflects "currently playing
    /// audio right now"). When a session fails (network blip, handshake
    /// exhaustion, etc.) the sink stays in `wantedActive` and the M6
    /// supervisor keeps retrying with exponential backoff until either
    /// the session re-establishes OR the user explicitly toggles off
    /// (removing it from `wantedActive`).
    ///
    /// Distinct from `activeSinks` because the two diverge during a
    /// reconnect window: user still wants the sink, but it's not
    /// playing right now. UI can use this distinction to show
    /// "Spacelab Audio — reconnecting…" instead of the bare red ✗.
    private(set) var wantedActive: Set<SinkID> = []

    /// Per-sink supervisor retry tracking. Surfaced in OSLog and
    /// (eventually) the menu badge. Cleared when a session re-establishes
    /// or the user toggles the sink off.
    public struct ReconnectInfo {
        public let attempt: Int
        public let nextAttemptDelaySec: Int
    }
    private(set) var reconnecting: [SinkID: ReconnectInfo] = [:]

    /// Backoff schedule. Each entry is the seconds to wait BEFORE the
    /// Nth attempt (0-indexed). After the last entry, the supervisor
    /// repeats the final value forever (60 s) — failures don't burn
    /// CPU but also don't give up if the network eventually recovers.
    ///
    /// **EXCEPT** for sinks that have never successfully produced audio
    /// in any attempt of the current supervisor cycle — those give up
    /// after `maxFailedBeforeAudio` attempts (see SessionExitReason +
    /// superviseSession). This stops the infinite-retry storm for
    /// unaccepted AirPlay receivers (e.g., Derek's MacBook Air being
    /// in `wantedActive` but never having a user prompt accepted).
    private static let reconnectBackoffSeconds: [Int] = [2, 5, 15, 30, 60]
    private static let maxFailedBeforeAudio: Int = 3

    /// What happened in a single session-run attempt. The supervisor
    /// uses this to decide whether to retry, give up, or exit cleanly.
    public enum SessionExitReason {
        /// Task was cancelled (user toggled off, stopAll, etc.) — no
        /// retry needed, exit supervisor loop.
        case cleanExit
        /// Mid-stream health flag tripped while audio was flowing —
        /// transient network issue, retry indefinitely.
        case networkLost
        /// Session never reached the "audio flowing" state. Handshake
        /// failed, RTPSender connect threw, etc. Counted against the
        /// `maxFailedBeforeAudio` cap.
        case failedBeforeAudio
        /// Session reached audio but later threw (catch path post-
        /// `reachedLiveStream`). Treated like `networkLost` — retry.
        case failedAfterAudio
    }

    /// Seconds Sonos sessions should defer their `Play` (and the rest of
    /// their session-start sequence) when AP1 sinks are also active in
    /// the wanted set. Computed by `startAll` from the max AP1 offset
    /// slider value across the wanted batch:
    ///
    ///     defer = max(0, maxAirPlay1OffsetSec − estimatedSonosSetupSec)
    ///
    /// Rationale: AP1 produces its first audio at roughly `(handshake +
    /// user_offset)` after session start. Sonos naturally takes
    /// `~estimatedSonosSetupSec` from `Play` to first sound. Deferring
    /// `Play` by the difference puts both first-sound moments at
    /// approximately the same wall time.
    ///
    /// **Tuned 2.0 → 2.5 (2026-05-17)** after live test with sliders at
    /// 5 s showed Sonos arriving 500 ms behind AP1 at 2.0 — bumping the
    /// constant reduces defer by the same 500 ms, pulling Sonos earlier.
    /// Hardware/network-dependent; tune further if needed.
    private(set) var currentSonosStartDeferSec: Double = 0
    private static let estimatedSonosSetupSec: Double = 2.5

    /// **Handshake barrier** — sinks whose RTSP handshake we're still
    /// waiting on before the AP1 + Sonos sessions all subscribe to the
    /// broadcaster at the same wall moment. Eliminates the per-sink
    /// start-time skew caused by handshake-speed variance (A7 was 4 s
    /// late vs A5 in the 2026-05-17 test because A7's TCP responses
    /// crawled in under contention from 4 simultaneous handshakes).
    ///
    /// Populated by `armStartBarrier` from `startAll`. Drained by
    /// `markHandshakeComplete` from AirPlay1Session after RECORD ✓ (or
    /// after handshake exhausts retries — either way, that sink is no
    /// longer "pending"). When empty, all `barrierWaiters` resume.
    /// `barrierTimeoutSec` is the fallback: if some sink never reports,
    /// the barrier force-releases after 10 s so other sinks proceed.
    private var pendingHandshakes: Set<SinkID> = []
    private var barrierWaiters: [CheckedContinuation<Void, Never>] = []
    private static let barrierTimeoutSec: Double = 10.0

    /// True while `startAll` is iterating its descriptor batch and calling
    /// `toggle` for each. Suppresses the mid-session sink-add recalibrate
    /// trigger inside `toggle` — without this, the 2nd/3rd/4th descriptor
    /// in a Play All batch sees `activeSinks` already populated by the
    /// previous iterations and falsely fires `scheduleMidSessionRecalibrate`.
    /// The cold-start calibration is owned by `SonosSession.markSonosPlayStarted`;
    /// mid-session add only fires for true post-batch user clicks. Discovered
    /// 2026-05-28 in real-room test: 4-speaker Play All produced 3 stacked
    /// false-mid-session calibrations on top of the cold-start one, racing
    /// each other and never converging to sync.
    private var isInBatchStart: Bool = false

    /// Active Sonos sinks tracked separately because Sonos doesn't use a
    /// `Task` lifecycle — clicking sends `SetAVTransportURI` + `Play` and
    /// the speaker streams autonomously. Stored as full descriptors so
    /// `stopAllSonos()` can dispatch SOAP `Stop` without going back through
    /// discovery.
    private(set) var activeSonosDescriptors: [SinkID: SinkDescriptor] = [:]

    /// Wall-clock time when each active Sonos sink's SOAP `Play` was
    /// successfully sent. Used by Sonos-position auto-align (#104) to
    /// compute Sonos's actual lag as `(now - playStartTime) - GetPositionInfo.RelTime`.
    /// Cleared when the sink stops.
    private(set) var sonosPlayStartedAt: [SinkID: Date] = [:]

    var isAnyActive: Bool { !activeSinks.isEmpty }

    /// #110 (M6.4) Painless auto-calibrate — when true (default), the
    /// SonosSession auto-triggers `MicCalibrator.runFullCalibration` ~5
    /// sec after SOAP Play succeeds (when AP1 sinks are in the mix).
    /// User can disable via the menu's Preferences toggle.
    var autoCalibrateOnPlayAll: Bool {
        get {
            let key = "autoCalibrateOnPlayAll"
            if UserDefaults.standard.object(forKey: key) != nil {
                return UserDefaults.standard.bool(forKey: key)
            }
            return true  // default ON
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoCalibrateOnPlayAll")
        }
    }

    /// Wall-clock time of the last successful auto-calibration. Used to
    /// suppress re-triggering within a 2-minute window so rapid Stop/Play
    /// All cycles don't redundantly recalibrate. Not persisted (resets
    /// across app launches by design — each launch should recalibrate).
    private var lastCalibrationAt: Date?

    /// True while a `MicCalibrator.runFullCalibration` pass is in flight.
    /// Drives the menu-bar icon's calibration-specific signal (M6.4) so
    /// the user has a passive cue that calibration is running, separate
    /// from the always-on "audio is flowing" pulse. Set true on entry,
    /// false in the orchestrator's exit path (success OR error).
    private(set) var isCalibrating: Bool = false

    /// Set by `MicCalibrator` at the start of a full-calibration pass.
    func markCalibrationStarted() {
        isCalibrating = true
    }

    /// Set by `MicCalibrator` when the pass ends (success or failure).
    func markCalibrationEnded() {
        isCalibrating = false
    }

    /// True if a calibration completed within the last 120 seconds.
    var didRecentlyCalibrate: Bool {
        guard let last = lastCalibrationAt else { return false }
        return Date().timeIntervalSince(last) < 120.0
    }

    /// Stamp the time of a successful calibration. Called by MicCalibrator
    /// and CalibrationCoordinator on successful completion.
    func markCalibratedNow() {
        lastCalibrationAt = Date()
    }

    /// Pending mid-session recalibrate task. Holds the LATEST scheduled
    /// 8-sec timer; any new sink-add cancels the prior one and replaces
    /// it. Coalesces rapid multi-sink additions into a single calibration
    /// pass that fires once the user has stopped adding sinks.
    private var pendingMidSessionRecalibrateTask: Task<Void, Never>?

    /// **Mid-session sink-add trigger (M6.4).** Wait for the new session to
    /// reach steady-state (~8 sec), then run `MicCalibrator.runFullCalibration`
    /// if AP1 + Sonos are both in the active set. Detached so toggle returns
    /// immediately.
    ///
    /// **Coalescing**: rapid sink additions cancel-and-replace the prior
    /// pending task — only the LAST add fires (8 sec after the user stops
    /// adding). Without this, each sink-add scheduled its own task and they
    /// all fired in cascade, producing N concurrent `runFullCalibration`
    /// invocations stomping on each other's mute/measure cycles. Diagnosed
    /// 2026-05-28 in real-room test with 4 speakers: logs showed 9+
    /// stacked recalibrates within 0.5 sec.
    ///
    /// **`lastCalibrationAt` is NOT reset here** (the prior version cleared
    /// it at schedule time, which defeated the `didRecentlyCalibrate`
    /// guard for queued tasks). The 2-min window still applies — if a
    /// calibration just ran, the mid-session task is a no-op.
    private func scheduleMidSessionRecalibrate(forNewSink descriptor: SinkDescriptor) {
        guard autoCalibrateOnPlayAll else {
            Log.app.info("Mid-session recalibrate: pref off — skipping")
            return
        }
        pendingMidSessionRecalibrateTask?.cancel()
        let newSinkID = descriptor.id
        pendingMidSessionRecalibrateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            // Recheck preconditions — user may have toggled off, stopped,
            // or the new sink may have failed in the interim.
            guard self.activeSinks.contains(newSinkID) else {
                Log.app.info("Mid-session recalibrate: new sink \(newSinkID, privacy: .public) no longer active — skipping")
                return
            }
            if self.isCalibrating {
                Log.app.info("Mid-session recalibrate: calibration already in flight — skipping")
                return
            }
            if self.didRecentlyCalibrate {
                Log.app.info("Mid-session recalibrate: recent calibration <2 min ago — skipping")
                return
            }
            let hasAP1 = self.activeSinks.contains { id in
                DiscoveredSinks.shared.sinks.first(where: { $0.id == id })?.protocolKind == .airplay1
            }
            let hasSonos = !self.activeSonosDescriptors.isEmpty
            guard hasAP1 && hasSonos else {
                Log.app.info("Mid-session recalibrate: need both AP1+Sonos active — skipping (hasAP1=\(hasAP1) hasSonos=\(hasSonos))")
                return
            }
            do {
                Log.app.notice("Mid-session recalibrate (M6.4): running per-speaker calibration silently after sink-add…")
                let result = try await MicCalibrator.runFullCalibration()
                self.markCalibratedNow()
                Log.app.notice("Mid-session recalibrate ✓ Sonos lag=\(String(format: "%.3f", result.sonosMeasurement.lagSec), privacy: .public)s; \(result.ap1AdjustmentsMs.count) AP1 sink(s) adjusted")
            } catch {
                Log.app.error("Mid-session recalibrate failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Per-environment calibration profiles (M6.4)

    /// Snapshot of "the right offsets for this set of speakers."
    /// Keyed on the SORTED set of active sink IDs so adding/removing a
    /// sink keys to a different profile. Persisted JSON-encoded in
    /// UserDefaults under `calibrationProfile.<sortedKey>`.
    private struct CalibrationProfile: Codable {
        let offsetsMs: [String: Int]      // SinkID raw → offset ms
        let savedAt: Date
    }

    /// Build the profile key from the wanted-active set: sorted, joined
    /// by `+`. Sorting matters so {A5, A7, Sonos} == {Sonos, A7, A5}.
    private func profileKey(for ids: Set<SinkID>) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids.sorted().joined(separator: "+")
    }

    /// Save the current per-sink offsets for the given sink set as a
    /// profile. Called by `MicCalibrator.runFullCalibration` after a
    /// successful pass — captures "Sonos+A5+A7 align at these offsets
    /// in this room." Next time the same set goes active, `primeOffsets`
    /// writes these values back before any session starts.
    func saveCalibrationProfile(for ids: Set<SinkID>) {
        guard let key = profileKey(for: ids) else { return }
        var offsets: [String: Int] = [:]
        for id in ids {
            offsets[id] = offset(for: id)
        }
        let profile = CalibrationProfile(offsetsMs: offsets, savedAt: Date())
        guard let data = try? JSONEncoder().encode(profile) else {
            Log.app.error("saveCalibrationProfile: encode failed for key=\(key, privacy: .public)")
            return
        }
        UserDefaults.standard.set(data, forKey: "calibrationProfile.\(key)")
        Log.app.notice("saveCalibrationProfile: \(key, privacy: .public) — \(offsets.count) offset(s)")
    }

    /// Load and apply the saved profile for the given sink set, if one
    /// exists. Writes each offset via `setOffset` (which also persists
    /// the per-sink value), so AP1 sessions started after this call use
    /// the primed values from their first sync packet — audio is in
    /// approximate sync immediately, before calibration even runs.
    ///
    /// **User-set offsets are NEVER overridden** (load-bearing fix
    /// 2026-05-30). A profile is treated as a "default for sinks the
    /// user hasn't tuned yet," not as an authoritative override of
    /// user input. Otherwise: user drags slider to 3000ms → clicks
    /// Restart All → `startAll` calls this function → stale profile
    /// (from a previous calibration pass, possibly buggy) overrides
    /// the freshly-dragged value back to the old saved number. That's
    /// exactly the bug observed in real-room testing — a profile from
    /// an earlier failed calibration kept clobbering manual slider
    /// values on every Restart All until the profile was manually
    /// nuked from UserDefaults.
    ///
    /// Returns true if at least one offset was primed (not the same
    /// as "profile exists"; a profile of 4 entries where 4 user-set
    /// offsets already exist returns false because nothing was primed).
    @discardableResult
    func primeOffsetsFromProfile(for ids: Set<SinkID>) -> Bool {
        guard let key = profileKey(for: ids) else { return false }
        guard let data = UserDefaults.standard.data(forKey: "calibrationProfile.\(key)"),
              let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data)
        else {
            Log.app.info("primeOffsetsFromProfile: no profile for key=\(key, privacy: .public)")
            return false
        }
        var primedCount = 0
        var skippedCount = 0
        for (sinkID, ms) in profile.offsetsMs {
            if hasUserSetOffset(for: sinkID) {
                skippedCount += 1
                continue
            }
            setOffset(ms, for: sinkID)
            primedCount += 1
        }
        Log.app.notice("primeOffsetsFromProfile: \(key, privacy: .public) — primed \(primedCount), skipped \(skippedCount) user-set (saved \(profile.savedAt))")
        return primedCount > 0
    }

    /// Per-environment Sonos rendering headroom in milliseconds — the
    /// correction applied to `sonos_lag` measurements to get the AP1
    /// offset that actually sounds in sync. Defaults to 500ms (centers
    /// on user-empirical data from 2026-05-18 testing). Persisted in
    /// UserDefaults so each install/room/Sonos combo self-tunes via the
    /// #105 Calibrate Sync verification step.
    ///
    /// **Math**: `ap1_offset = (sonos_lag * 1000) - 93 - personalSonosHeadroomMs`
    ///
    /// **Bounds**: 0–2000ms. 0 = "Sonos reports exactly the DAC position"
    /// (unrealistic); 2000ms = "Sonos buffers 2 sec beyond reported position"
    /// (also unrealistic). Real values cluster 400–800ms.
    var personalSonosHeadroomMs: Int {
        get {
            let key = "personalSonosHeadroomMs"
            if UserDefaults.standard.object(forKey: key) != nil {
                return UserDefaults.standard.integer(forKey: key)
            }
            return 500  // default from 2026-05-18 empirical
        }
        set {
            let clamped = max(0, min(2000, newValue))
            UserDefaults.standard.set(clamped, forKey: "personalSonosHeadroomMs")
        }
    }

    private init() {}

    /// Toggle a sink: start a session if idle, send TEARDOWN if currently
    /// running. The session runs until cancelled — clicking the same item
    /// again is the cancel. UI state updates synchronously so the click
    /// feels instant even though TEARDOWN takes a moment.
    ///
    /// **M6 supervisor**: when ON, the sink is added to `wantedActive`.
    /// If the session ends without user intent (network blip, handshake
    /// exhausted, receiver reboot), the supervisor loop restarts the
    /// session with exponential backoff until either it succeeds OR the
    /// user toggles off. Bonjour disappearance does NOT remove the sink
    /// from wantedActive — the supervisor will retry when the sink
    /// reappears in discovery.
    func toggle(_ descriptor: SinkDescriptor) {
        let id = descriptor.id
        let label = descriptor.displayName

        // OFF path: remove from wantedActive + clear UI + cancel running
        // task. wantedActive removal is what tells the supervisor loop
        // (still alive inside the Task) to STOP retrying.
        if let existing = sessionTasks.removeValue(forKey: id) {
            Log.app.notice("Toggle OFF: \(label, privacy: .public)")
            wantedActive.remove(id)
            activeSinks.remove(id)
            reconnecting.removeValue(forKey: id)
            // Drain any pending barrier entry — a cancelled sink shouldn't
            // stall the rest of the batch.
            markHandshakeComplete(id)
            existing.task.cancel()
            return
        }

        // ON path: add to wantedActive, start the supervisor Task.
        Log.app.notice("Toggle ON:  \(label, privacy: .public)")
        // **Mid-session sink-add detection (M6.4)** — if the user is adding
        // this sink while others are ALREADY playing, the SonosSession
        // calibration trigger won't fire (Sonos session is already past
        // its `markSonosPlayStarted` point). Schedule a fresh calibration
        // from here so the new sink-set converges to sync silently.
        //
        // **Suppressed during `startAll`**: when Play All iterates 4
        // descriptors, the 1st toggle fills `activeSinks`, then the 2nd
        // through 4th would falsely see `!activeSinks.isEmpty` and
        // schedule N-1 stacked recalibrates on top of the cold-start
        // SonosSession trigger. `isInBatchStart` gates them off — the
        // SonosSession path owns the cold-start case end-to-end.
        let isMidSessionAdd = !activeSinks.isEmpty && !isInBatchStart
        wantedActive.insert(id)
        let nonce = UUID()
        activeSinks.insert(id)
        recentFailures.removeValue(forKey: id)
        reconnecting.removeValue(forKey: id)
        if isMidSessionAdd {
            scheduleMidSessionRecalibrate(forNewSink: descriptor)
        }
        let task = Task { [weak self] in
            await self?.superviseSession(descriptor: descriptor, nonce: nonce)
            // Clean up sessionTasks. We compare nonces because a rapid
            // off→on may have started a new Task with a fresh nonce
            // before this one's body finished; don't clobber the new
            // entry.
            await MainActor.run {
                guard let self else { return }
                if let current = self.sessionTasks[id], current.nonce == nonce {
                    self.sessionTasks.removeValue(forKey: id)
                }
            }
        }
        sessionTasks[id] = Session(nonce: nonce, task: task)
    }

    /// Supervisor loop. Runs one session attempt, then — based on the
    /// session's exit reason — decides whether to retry, give up, or
    /// exit cleanly. Cancellation of the wrapping Task (toggle OFF /
    /// stopAll) exits the loop immediately.
    ///
    /// **Failed-before-audio cap**: a session that never reached the
    /// "audio flowing" state counts against `maxFailedBeforeAudio` (3).
    /// After hitting the cap, the supervisor removes the sink from
    /// `wantedActive`, marks it as a recent failure, and exits — the
    /// user must manually click to retry. Stops infinite-retry storms
    /// on AirPlay receivers that never accept (e.g., other people's
    /// Macs in discovery with no user prompt acknowledged).
    /// Sessions that reach audio reset the failure counter (the cap
    /// is for "can't connect" not "can connect but unstable").
    private func superviseSession(descriptor: SinkDescriptor, nonce: UUID) async {
        let id = descriptor.id
        let label = descriptor.displayName
        var attempt = 0
        var consecutiveFailedBeforeAudio = 0

        while !Task.isCancelled {
            attempt += 1
            await MainActor.run { self.reconnecting.removeValue(forKey: id) }

            let reason: SessionExitReason
            switch descriptor.protocolKind {
            case .airplay1:
                reason = await AirPlay1Session.run(descriptor: descriptor, duration: nil)
            case .sonos:
                reason = await SonosSession.run(descriptor: descriptor, duration: nil)
            default:
                Log.app.error("superviseSession: unsupported protocol \(descriptor.protocolKind.rawValue, privacy: .public)")
                return
            }

            if Task.isCancelled { return }

            switch reason {
            case .cleanExit:
                Log.app.notice("Supervisor: \(label, privacy: .public) clean exit (user-cancelled)")
                return
            case .networkLost, .failedAfterAudio:
                // We had audio at some point — keep trying indefinitely.
                consecutiveFailedBeforeAudio = 0
                Log.app.notice("Supervisor: \(label, privacy: .public) lost mid-stream (\(String(describing: reason))) — will retry")
            case .failedBeforeAudio:
                consecutiveFailedBeforeAudio += 1
                Log.app.error("Supervisor: \(label, privacy: .public) failed before reaching audio (\(consecutiveFailedBeforeAudio)/\(Self.maxFailedBeforeAudio))")
                if consecutiveFailedBeforeAudio >= Self.maxFailedBeforeAudio {
                    Log.app.error("Supervisor: \(label, privacy: .public) gave up after \(Self.maxFailedBeforeAudio) consecutive failed-before-audio attempts — removing from wanted set. Manual click required to retry.")
                    await MainActor.run {
                        self.wantedActive.remove(id)
                        self.reconnecting.removeValue(forKey: id)
                        self.recordFailure(id)
                    }
                    return
                }
            }

            let stillWanted = await MainActor.run { self.wantedActive.contains(id) }
            guard stillWanted else {
                Log.app.notice("Supervisor: \(label, privacy: .public) session ended and not wanted — clean exit")
                return
            }
            let backoffIdx = min(attempt - 1, Self.reconnectBackoffSeconds.count - 1)
            let backoffSec = Self.reconnectBackoffSeconds[backoffIdx]
            await MainActor.run {
                self.reconnecting[id] = ReconnectInfo(attempt: attempt, nextAttemptDelaySec: backoffSec)
            }
            Log.app.notice("Supervisor: \(label, privacy: .public) retrying in \(backoffSec)s (attempt \(attempt))")
            try? await Task.sleep(nanoseconds: UInt64(backoffSec) * 1_000_000_000)
            if Task.isCancelled { return }
            let stillWantedAfterSleep = await MainActor.run { self.wantedActive.contains(id) }
            guard stillWantedAfterSleep else {
                Log.app.notice("Supervisor: \(label, privacy: .public) user toggled off during backoff — clean exit")
                await MainActor.run { self.reconnecting.removeValue(forKey: id) }
                return
            }
            Log.app.notice("Supervisor: \(label, privacy: .public) restarting session (attempt \(attempt + 1))")
        }
    }

    /// Returns the current session nonce for this sink, or `nil` if no
    /// session is registered. AirPlay1Session captures this at the top of
    /// `run()` so its defer can detect "am I the stale session being
    /// replaced by a newer one for the same sink?" — and skip wiping
    /// shared state (volume setter, offset setter, activeSinks, failure
    /// mark) that the newer session now owns.
    func currentNonce(for sinkID: SinkID) -> UUID? {
        sessionTasks[sinkID]?.nonce
    }

    /// Called from AirPlay1Session's `defer` block. Wipes session-side
    /// state ONLY IF the caller's nonce matches the current sessionTasks
    /// entry (or no entry exists — the caller is the last session out).
    /// If a newer session has taken over this sink, this is a no-op
    /// — preserves the new session's setters and active flag.
    ///
    /// Fixes the race that produced the "A5 unchecked but still playing"
    /// observation: a stale session's slow async cleanup wiped the fresh
    /// session's registered state. See DECISIONS.md 2026-05-16 (night).
    func endSessionIfStillCurrent(sinkID: SinkID, nonce: UUID, wasSuccess: Bool) {
        if let current = sessionTasks[sinkID], current.nonce != nonce {
            Log.app.info("endSession: stale defer for \(sinkID, privacy: .public) (newer session in flight) — skipping cleanup")
            return
        }
        unregisterVolumeSetter(for: sinkID)
        unregisterOffsetSetter(for: sinkID)
        unregisterHealthSnoozer(for: sinkID)
        if !wasSuccess {
            recordFailure(sinkID)
        }
        markInactive(sinkID)
    }

    // Called from AirPlay1Session inside its `defer` block.
    func markActive(_ id: SinkID) {
        activeSinks.insert(id)
        Log.app.info("SessionState: active \(self.activeSinks.count) sink(s)")
        applyMuteIfNeeded()
        applyLosslessIfNeeded()
    }

    func markInactive(_ id: SinkID) {
        activeSinks.remove(id)
        Log.app.info("SessionState: active \(self.activeSinks.count) sink(s)")
        applyMuteIfNeeded()
        applyLosslessIfNeeded()
    }

    /// Start a session on every descriptor in the list that doesn't already
    /// have a running Task. **Idempotent**: pressing Play All while audio is
    /// already playing is a no-op for those sinks — no teardown-and-restart
    /// race. (Filter on `sessionTasks`, not `activeSinks`, because the
    /// latter can be transiently empty during a session's defer-cleanup
    /// while the Task itself is still alive. See DECISIONS.md 2026-05-16
    /// for the bug this prevents: rapid Play All clicks producing
    /// overlapping sessions whose cleanups raced each other.)
    ///
    /// Also: (a) computes `currentSonosStartDeferSec` from the max AP1
    /// offset in this batch, (b) arms the **handshake barrier** for the
    /// new AP1 sinks — sessions hold off on broadcaster-subscribe until
    /// every AP1 sink in the batch has either finished its RTSP
    /// handshake or hit the 10 s timeout. Eliminates the skew where a
    /// slow-handshake sink (e.g., A7 took 5 s under TCP contention vs
    /// A5's 750 ms) produces its first audio seconds after the others.
    func startAll(_ descriptors: [SinkDescriptor]) {
        let alreadyRunning = descriptors.filter { sessionTasks[$0.id] != nil }
        if !alreadyRunning.isEmpty {
            Log.app.info("Play All: \(alreadyRunning.count) sink(s) already running — skipping (idempotent)")
        }

        // Prime offsets from the saved per-environment profile BEFORE any
        // session starts. If this exact sink set has been calibrated before,
        // each AP1 session picks up its primed offset on first sync packet
        // — audio approximates sync immediately, then `MicCalibrator.run-
        // FullCalibration` (auto-triggered ~5 sec later via SonosSession)
        // refines silently.
        let fullSet = Set(descriptors.map(\.id))
        primeOffsetsFromProfile(for: fullSet)

        // Compute Sonos start defer from max AP1 offset in this batch.
        // Has no effect if no AP1 in the batch (defer = 0).
        let newAP1Descriptors = descriptors.filter {
            $0.protocolKind == .airplay1 && sessionTasks[$0.id] == nil
        }
        let maxAP1OffsetMs = newAP1Descriptors
            .map { effectiveOffsetForAirPlay1(sinkID: $0.id, label: $0.displayName) }
            .max() ?? 0
        currentSonosStartDeferSec = max(0, Double(maxAP1OffsetMs) / 1000.0 - Self.estimatedSonosSetupSec)
        if currentSonosStartDeferSec > 0 {
            Log.app.notice("Start-align: Sonos Play deferred by \(String(format: "%.2f", self.currentSonosStartDeferSec))s to match AP1 first-audio (max AP1 offset = \(maxAP1OffsetMs) ms)")
        }

        // Arm the handshake barrier for the new AP1 sinks in this batch.
        armStartBarrier(forAP1Sinks: Set(newAP1Descriptors.map(\.id)))

        // Suppress the per-toggle mid-session-add recalibrate trigger for
        // the duration of this loop. SonosSession owns cold-start
        // calibration; the mid-session trigger is only correct when the
        // user clicks a single sink to add it AFTER a batch has settled.
        isInBatchStart = true
        defer { isInBatchStart = false }
        for d in descriptors where sessionTasks[d.id] == nil {
            toggle(d)
        }
    }

    // MARK: - Handshake barrier (M6 — auto-aligned start times)

    /// Record the set of AP1 sinks whose handshake we'll wait on before
    /// any session (AP1 or Sonos) is allowed past `awaitStartBarrier`.
    /// Spawns a fallback timeout Task that force-releases the barrier
    /// after `barrierTimeoutSec` so a stuck/dead sink can't stall the
    /// rest. Called by `startAll` and (optionally) `toggle` for the
    /// single-sink case where we want consistent semantics — though a
    /// solo toggle effectively no-ops because pendingHandshakes becomes
    /// just that one sink and resolves immediately on its own handshake.
    func armStartBarrier(forAP1Sinks ids: Set<SinkID>) {
        pendingHandshakes = ids
        guard !ids.isEmpty else { return }
        Log.app.notice("Start-barrier armed for \(ids.count) AP1 sink(s)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.barrierTimeoutSec * 1_000_000_000))
            guard let self else { return }
            if !self.pendingHandshakes.isEmpty {
                Log.app.error("Start-barrier timeout — releasing with \(self.pendingHandshakes.count) sink(s) still pending")
                self.releaseBarrier()
            }
        }
    }

    /// Called by `AirPlay1Session` after RTSP RECORD success (or after
    /// handshake exhausts retries — either way, that sink is no longer
    /// "pending" for the barrier). When the pending set empties, every
    /// waiter resumes simultaneously.
    func markHandshakeComplete(_ id: SinkID) {
        guard pendingHandshakes.contains(id) else { return }
        pendingHandshakes.remove(id)
        Log.app.notice("Handshake complete: \(id, privacy: .public) — \(self.pendingHandshakes.count) AP1 sink(s) remaining")
        if pendingHandshakes.isEmpty {
            Log.app.notice("Start-barrier released — all AP1 sinks ready")
            releaseBarrier()
        }
    }

    /// Called by every session (AP1 + Sonos) before subscribing to the
    /// `AudioBroadcaster`. Returns immediately if no AP1 handshakes are
    /// pending — e.g., Sonos-only batch, or barrier already released.
    /// Otherwise blocks until `markHandshakeComplete` drains the set
    /// (or `barrierTimeoutSec` force-releases).
    func awaitStartBarrier() async {
        if pendingHandshakes.isEmpty { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            barrierWaiters.append(c)
        }
    }

    private func releaseBarrier() {
        let waiters = barrierWaiters
        barrierWaiters.removeAll()
        pendingHandshakes.removeAll()
        for c in waiters { c.resume() }
    }

    /// Cancel every running session and clear the wanted-active set.
    /// UI state clears synchronously; each session's `defer` runs its
    /// TEARDOWN asynchronously. Clearing `wantedActive` is what stops
    /// the supervisor loops — without that, the supervisor would
    /// schedule retries for every cancelled session. Also force-releases
    /// any pending start barrier so waiting sessions unblock and exit.
    func stopAll() {
        let ids = Array(sessionTasks.keys)
        wantedActive.removeAll()
        reconnecting.removeAll()
        for id in ids {
            if let s = sessionTasks.removeValue(forKey: id) {
                activeSinks.remove(id)
                s.task.cancel()
            }
        }
        if !pendingHandshakes.isEmpty || !barrierWaiters.isEmpty {
            Log.app.info("stopAll: force-releasing start-barrier")
            releaseBarrier()
        }
        Log.app.info("SessionState: stopAll cancelled \(ids.count) session(s)")
    }

    // MARK: - Sonos session tracking

    /// Marks a Sonos sink as actively streaming our session. Drives the
    /// menu's checkmark indicator and lets `stopAllSonos()` send `Stop`
    /// to every sink we started on app quit / Stop All / SIGTERM.
    func markSonosActive(_ descriptor: SinkDescriptor) {
        activeSonosDescriptors[descriptor.id] = descriptor
        activeSinks.insert(descriptor.id)
        Log.app.info("SessionState: marked Sonos active — \(descriptor.displayName, privacy: .public)")
        applyMuteIfNeeded()
        applyLosslessIfNeeded()
    }

    func markSonosInactive(_ id: SinkID) {
        activeSonosDescriptors.removeValue(forKey: id)
        sonosPlayStartedAt.removeValue(forKey: id)
        activeSinks.remove(id)
        applyMuteIfNeeded()
        applyLosslessIfNeeded()
    }

    /// Snapshot wall-clock time at the moment SOAP `Play` was confirmed.
    /// Called by `SonosSession` right after `client.play()` returns OK.
    /// Pairs with `GetPositionInfo.RelTime` polling for #104 auto-align.
    func markSonosPlayStarted(_ id: SinkID, at time: Date = Date()) {
        sonosPlayStartedAt[id] = time
        Log.app.info("SessionState: Sonos play-start snapshot — \(id, privacy: .public) at \(time.timeIntervalSince1970)")
    }

    /// Sends SOAP `Stop` to every Sonos sink we've marked active. Called
    /// from the Stop All button, app quit, and the SIGTERM/SIGINT handlers.
    /// Awaitable so the shutdown path can wait briefly for stops to land.
    func stopAllSonos() async {
        let descriptors = Array(activeSonosDescriptors.values)
        activeSonosDescriptors.removeAll()
        for desc in descriptors {
            activeSinks.remove(desc.id)
        }
        Log.app.info("SessionState: stopAllSonos sending Stop to \(descriptors.count) sink(s)")
        await withTaskGroup(of: Void.self) { group in
            for desc in descriptors {
                group.addTask {
                    let client = SonosClient(descriptor: desc)
                    _ = try? await client.stop()
                    Log.app.info("Sonos Stop sent → \(desc.displayName, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Per-sink volume

    /// Default volume applied to a sink that has no saved value yet.
    /// Low-by-default (~−25.5 dB AirPlay scale) — chosen 2026-05-16 so
    /// new sessions never blare. User drags up freely from here; no
    /// cap. Previously 70 (loud); replaced after the original Quiet
    /// Mode capped-at-18% design got user feedback "we wanted default
    /// low, not a max cap."
    static let defaultVolumePercent: Int = 15

    /// Slider's effective maximum. Always 100; no cap behavior.
    /// (Previously gated by Quiet Mode at 18; removed 2026-05-16.)
    var currentMaxVolume: Int { 100 }

    /// Returns the saved volume for a sink, falling back to the
    /// default (15% — quiet-by-default; user drags up). Pure read.
    func volume(for sinkID: SinkID) -> Int {
        if let cached = sinkVolumes[sinkID] {
            return cached
        }
        let key = "sinkVolume.\(sinkID)"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.integer(forKey: key)
        }
        return Self.defaultVolumePercent
    }

    /// User adjusted the slider. Clamps to 0–100 (no artificial cap),
    /// persists, updates observable state, dispatches to live session via
    /// a 250 ms debounce (see `pendingVolumeTasks` comment).
    func setVolume(_ percent: Int, for sinkID: SinkID) {
        let clamped = max(0, min(100, percent))
        sinkVolumes[sinkID] = clamped
        UserDefaults.standard.set(clamped, forKey: "sinkVolume.\(sinkID)")
        guard let setter = volumeSetters[sinkID] else { return }
        // Cancel any pending send for this sink — newer value supersedes.
        pendingVolumeTasks[sinkID]?.cancel()
        pendingVolumeTasks[sinkID] = Task {
            try? await Task.sleep(nanoseconds: Self.volumeDebounceNanos)
            if Task.isCancelled { return }
            await setter(clamped)
        }
    }

    /// Calibration helper: push a volume directly to the live setter,
    /// bypassing both the 250ms debounce AND the UserDefaults persistence.
    /// Used by mic calibration (#109) to mute/restore sinks for isolated
    /// measurement without polluting the user's saved volume preference.
    /// Volume changes apply immediately when the setter awaits return.
    func setVolumeImmediate(_ percent: Int, for sinkID: SinkID) async {
        let clamped = max(0, min(100, percent))
        pendingVolumeTasks[sinkID]?.cancel()
        if let setter = volumeSetters[sinkID] {
            await setter(clamped)
        }
    }

    /// Live session announces it is ready to receive volume updates. Called
    /// from the session's setup phase. The closure is invoked every time the
    /// user adjusts the slider for this sink.
    func registerVolumeSetter(_ setter: @escaping @Sendable (Int) async -> Void, for sinkID: SinkID) {
        volumeSetters[sinkID] = setter
    }

    /// Live session tearing down — drop the setter so the slider stops
    /// trying to push updates to a disconnected client.
    func unregisterVolumeSetter(for sinkID: SinkID) {
        volumeSetters.removeValue(forKey: sinkID)
    }

    /// Record a session failure for a sink. Surfaces as a brief red ❌ in
    /// the menu so the user can see "you clicked, we tried, it didn't
    /// work" instead of "your click did nothing." Cleared automatically
    /// after `failureDisplayDuration`. Re-clicking the sink to start a
    /// new session also clears the failure mark.
    func recordFailure(_ sinkID: SinkID) {
        recentFailures[sinkID] = Date()
        Log.app.info("SessionState: failure recorded for \(sinkID, privacy: .public)")
        // Auto-clear after the display window. Snapshot the recording
        // moment so a fresh failure within the window resets the timer
        // (the new entry's Date supersedes this clear-task's check).
        let recordedAt = recentFailures[sinkID]
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.failureDisplayDuration * 1_000_000_000))
            guard let self else { return }
            if self.recentFailures[sinkID] == recordedAt {
                self.recentFailures.removeValue(forKey: sinkID)
            }
        }
    }

    /// True if a sink failed recently (within `failureDisplayDuration`).
    /// Drives the red ❌ icon in the menu.
    func hasRecentFailure(_ sinkID: SinkID) -> Bool {
        guard let when = recentFailures[sinkID] else { return false }
        return Date().timeIntervalSince(when) < Self.failureDisplayDuration
    }

    // MARK: - Per-sink offset

    /// Range allowed on the offset slider. 0 = baseline. **Expanded to
    /// 6000 ms 2026-05-16 (Saturday night, third bump)** after real-world
    /// testing showed Sonos lagging 4+ sec under loaded Wi-Fi with
    /// concurrent multi-sink streaming. 6 sec gives diagnostic headroom
    /// for measuring Sonos's true buffer floor; if 6 s still isn't
    /// enough, the bug is upstream (mid-stream NTP jumps rejected by
    /// RAOP receivers, or an offset path that never reaches the wire)
    /// not a slider-range issue.
    static let offsetRangeMs: ClosedRange<Int> = 0...6000

    /// Returns the saved offset (ms) for a sink, falling back to 0.
    /// Pure read — no side effects (same `@Observable` pattern as `volume(for:)`).
    func offset(for sinkID: SinkID) -> Int {
        if let cached = sinkOffsetsMs[sinkID] {
            return cached
        }
        let key = "sinkOffset.\(sinkID)"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.integer(forKey: key)
        }
        return 0
    }

    /// True iff the user has explicitly set an offset for this sink (either
    /// in this session via the slider, or persisted from a previous run).
    /// Used by `effectiveOffsetForAirPlay1` to gate the Sonos auto-align
    /// default — once the user has touched the slider, their value wins
    /// over the auto-default forever.
    func hasUserSetOffset(for sinkID: SinkID) -> Bool {
        if sinkOffsetsMs[sinkID] != nil { return true }
        return UserDefaults.standard.object(forKey: "sinkOffset.\(sinkID)") != nil
    }

    /// Auto-align default applied to AirPlay 1 sinks at session start when
    /// Sonos is in the active set AND the user hasn't touched this sink's
    /// offset slider yet. Matches the typical Sonos intrinsic buffer floor
    /// observed in our soak tests. **Bumped 2000 → 3025 ms (2026-06-04)**:
    /// across repeated real-hardware sessions (B&W A5 "Spacelab" + Sonos),
    /// the A5 offset that actually lands in sync settles in the ~3025–3100 ms
    /// band — the Sonos's real buffer floor on this LAN is ~3 s, not the 2 s
    /// earlier guess. 3025 is the best-sounding value dialed in by ear.
    /// M11 Room Tuning will eventually replace this fixed guess with a
    /// measured value via iPhone mic.
    static let sonosAutoAlignOffsetMs: Int = 3025

    /// True iff at least one Sonos sink is currently in the active set.
    var isAnySonosActive: Bool {
        !activeSonosDescriptors.isEmpty
    }

    /// Compute the offset (ms) to apply at AirPlay 1 session start.
    /// Returns the user-set value if the slider has ever been touched;
    /// otherwise auto-aligns to Sonos's intrinsic floor if Sonos is
    /// active; otherwise 0. Logs the decision so the auto-align path
    /// is observable in the logs.
    func effectiveOffsetForAirPlay1(sinkID: SinkID, label: String) -> Int {
        if hasUserSetOffset(for: sinkID) {
            return offset(for: sinkID)
        }
        if isAnySonosActive {
            Log.app.notice("Auto-align: \(label, privacy: .public) starting offset = \(Self.sonosAutoAlignOffsetMs) ms (Sonos active, user has not touched slider)")
            return Self.sonosAutoAlignOffsetMs
        }
        return 0
    }

    /// User adjusted the offset slider. Clamps to the configured range,
    /// persists immediately, and dispatches to the live session via a
    /// 250 ms debounce. The debounce is load-bearing: each setter call
    /// runs `AudioBroadcaster.setDelay` which retimes the entire
    /// per-subscriber queue, and applying that on every pixel of drag
    /// produces a slow-motion / pause artifact (#99 testing observation,
    /// 2026-05-18). Debounced — only the final settled value reaches
    /// the broadcaster, producing one pause/jump artifact instead of
    /// continuous slow-motion.
    func setOffset(_ ms: Int, for sinkID: SinkID) {
        let previousMs = sinkOffsetsMs[sinkID] ?? 0
        let clamped = max(Self.offsetRangeMs.lowerBound, min(Self.offsetRangeMs.upperBound, ms))
        sinkOffsetsMs[sinkID] = clamped
        UserDefaults.standard.set(clamped, forKey: "sinkOffset.\(sinkID)")

        // Snooze the health monitor BEFORE the setter fires (after debounce),
        // so we cover the full window from now through when the receiver
        // resumes emitting timing packets. The receiver goes silent for
        // (deltaMs ÷ 1000) seconds while it waits out the new future-
        // scheduled audio; add a generous grace period to be safe.
        let deltaMs = abs(clamped - previousMs)
        if deltaMs > Self.healthSnoozeThresholdMs, let snoozer = healthSnoozers[sinkID] {
            let snoozeSec = Double(deltaMs) / 1000.0 + 8.0  // delay-gap + 8 sec grace
            Log.app.info("setOffset: \(sinkID, privacy: .public) delta \(deltaMs)ms — snoozing health monitor for \(String(format: "%.1f", snoozeSec))s")
            snoozer(snoozeSec)
        }

        guard let setter = offsetSetters[sinkID] else { return }
        pendingOffsetTasks[sinkID]?.cancel()
        pendingOffsetTasks[sinkID] = Task {
            try? await Task.sleep(nanoseconds: Self.offsetDebounceNanos)
            if Task.isCancelled { return }
            setter(clamped)
        }
    }

    /// Live session announces it can receive offset updates. Called from
    /// AirPlay 1 sessions just after RTPSender is connected. The closure
    /// writes the new ms value into the sender's `manualOffsetSeconds`
    /// property — read on the next sync packet emission.
    func registerOffsetSetter(_ setter: @escaping @Sendable (Int) -> Void, for sinkID: SinkID) {
        offsetSetters[sinkID] = setter
    }

    /// Drop the offset setter on session teardown.
    func unregisterOffsetSetter(for sinkID: SinkID) {
        offsetSetters.removeValue(forKey: sinkID)
    }

    /// AP1 sessions register a snoozer alongside the offset setter. The
    /// snoozer accepts seconds-from-now and pauses the session's health
    /// monitor until that wall-time. See `setOffset` for when it fires.
    func registerHealthSnoozer(_ snoozer: @escaping @Sendable (Double) -> Void, for sinkID: SinkID) {
        healthSnoozers[sinkID] = snoozer
    }

    /// Drop the snoozer on session teardown. The snoozer holds a weak
    /// reference to its session's HealthSnooze handle, so a forgotten
    /// entry would silently no-op rather than leak, but clean unregister
    /// keeps the map size bounded.
    func unregisterHealthSnoozer(for sinkID: SinkID) {
        healthSnoozers.removeValue(forKey: sinkID)
    }

    /// AirPlay 1 SET_PARAMETER volume scale conversion. AirPlay's range is
    /// [-30, 0] dB plus the special value -144 = muted. We map 0% → -144
    /// (full mute) and 1–100% linearly across [-30, 0] dB.
    ///
    /// `nonisolated` because `SessionState` is `@MainActor`, but this is a
    /// pure function with no shared state — the volume-setter closures
    /// registered by live sessions need to call this off the main actor.
    /// Map the 0–100 % user slider to the receiver's dB volume. The dB range
    /// and "muted" sentinel come from the device profile's `volumeScale` when a
    /// dB-type scale is available (M5.5); otherwise fall back to the AirTunes
    /// defaults (−30…0 dB, −144 = muted) — identical to the pre-M5.5 behavior,
    /// and identical to what the B&W A5/A7 profiles declare.
    nonisolated static func airplay1Volume(
        fromPercent percent: Int,
        scale: DeviceProfile.SinkRole.VolumeScale? = nil
    ) -> Float {
        let clamped = max(0, min(100, percent))
        // Only dB-type scales are usable here (sendSetVolume speaks dB).
        let dbScale = (scale?.type == .dB) ? scale : nil
        let minDB = Float(dbScale?.min ?? -30.0)
        let maxDB = Float(dbScale?.max ?? 0.0)
        let mutedDB = Float(dbScale?.muted ?? -144.0)
        if clamped == 0 { return mutedDB }
        return minDB + (Float(clamped) / 100.0) * (maxDB - minDB)
    }

    private func applyMuteIfNeeded() {
        // Diagnostic — silent failures of `muteDefaultOutput` are hard
        // to debug otherwise. Logs the gate state on every active-sinks
        // change so we can correlate UI expectation vs. actual behavior.
        Log.app.info("applyMuteIfNeeded: muteFlag=\(self.muteMacWhilePlaying) isAnyActive=\(self.isAnyActive) activeCount=\(self.activeSinks.count)")
        if muteMacWhilePlaying && isAnyActive {
            MacAudioMute.muteDefaultOutput()
        } else {
            MacAudioMute.restoreDefaultOutput()
        }
    }

    private func applyLosslessIfNeeded() {
        if losslessMode && isAnyActive {
            LosslessMode.forceMacOutputTo44100()
        } else {
            LosslessMode.restore()
        }
    }
}
