// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import Foundation
import AVFoundation
import Darwin

/// One shared `SystemAudioCapture`, fanned out to N subscribers via
/// independent `AsyncStream`s.
///
/// Each subscriber sees the **same `AudioChunk`** with the **same
/// `presentationHostTime`**, so per-sink clock translation can target a
/// single canonical "when should this sample hit the DAC" moment across
/// all active sinks. This is the architectural foundation for M5
/// sample-accurate multi-sink sync.
///
/// Today (pre-M5) each session creates its own `SystemAudioCapture` and
/// runs its own clock domain; sync is approximate at best because each
/// pipeline is anchored to a different starting moment. The broadcaster
/// replaces N captures with 1 — every active session reads from the same
/// stream of chunks and the same `presentationHostTime` reference frame.
///
/// Subscribers receive chunks via a per-subscriber `AsyncStream` with a
/// bounded buffer (`.bufferingNewest(20)` — ~230 ms at 48 kHz / 512-frame
/// chunks). A slow subscriber drops frames rather than backing up the
/// whole pipeline; per-sink frame-drop logging surfaces in OSLog.
///
/// Capture lifecycle is reference-counted: starts on first subscribe,
/// stops when the last subscriber unsubscribes. The underlying
/// `CATapDescription` is recreated each time so process-tap entitlements
/// re-evaluate cleanly — no zombie taps after long idle periods.
public final class AudioBroadcaster: @unchecked Sendable {

    public static let shared = AudioBroadcaster()

    /// Shared playback anchor — established when the first chunk flows
    /// after `startCaptureLocked`, fixed for the lifetime of that capture
    /// session. Every subscriber's protocol-side encoder (AirPlay 1 RTP
    /// timestamps, Sonos AAC stream-start time) uses this anchor so all
    /// receivers map the same `AudioChunk` onto the same wall-clock
    /// playback moment.
    ///
    /// `referenceHostTime` is the `mach_absolute_time` of the first
    /// captured chunk; `referenceWallTime` is the wall-clock `Date` at
    /// the same instant (captured back-to-back so they describe the
    /// same moment to within sub-millisecond accuracy); `referenceRTPTimestamp`
    /// is always 0.
    ///
    /// Sessions reading the anchor get both: mach time for `presentationHostTime`
    /// arithmetic (RTP computation), wall time for NTP sync packet content
    /// (so every session's sync packet carries the same NTP value across
    /// sinks → all receivers schedule playback to the same wall-clock moment).
    public struct PlaybackAnchor: Sendable {
        public let referenceHostTime: UInt64
        public let referenceWallTime: Date
        public let referenceRTPTimestamp: UInt32
    }

    /// Per-subscriber registration with a **per-sink delay queue**.
    ///
    /// `delayNanos > 0` triggers sender-side audio delay: each chunk gets
    /// a defensive copy + `presentationHostTime` rewrite, then enters the
    /// subscriber's `queue` with a `yieldDueHostTime`. A single
    /// per-subscriber `drainerTask` pops chunks in order and yields them
    /// when their due time arrives. RTPSender's downstream sync-NTP math
    /// lands in the present (because the rewrite adds `delayHostUnits` to
    /// the host time), so receivers accept the packets and play at
    /// near-real-time rate — but the content they play is `delayNanos`
    /// old. See DECISIONS.md 2026-05-17 (sender-side delay, take 2) +
    /// M6.3 #99 (real-time slider drag — the queue model replaces the
    /// per-chunk Task.detached so `setDelay` can re-time queued chunks).
    fileprivate final class Subscription: @unchecked Sendable {
        let continuation: AsyncStream<AudioChunk>.Continuation
        var delayNanos: UInt64
        var queue: [QueuedChunk] = []
        var drainerTask: Task<Void, Never>?
        init(continuation: AsyncStream<AudioChunk>.Continuation, delayNanos: UInt64) {
            self.continuation = continuation
            self.delayNanos = delayNanos
        }
    }

    /// One enqueued chunk awaiting yield-due time.
    fileprivate struct QueuedChunk {
        let chunk: AudioChunk
        /// `mach_absolute_time` units. Adjusted in-place by `setDelay`
        /// when the user drags the slider mid-stream.
        var yieldDueHostTime: UInt64
    }

    /// mach_absolute_time tick ratio. Captured once. `mach_timebase_info`
    /// returns the timebase as a fraction (numer/denom) where each tick
    /// equals (numer/denom) nanoseconds. On Apple Silicon this is
    /// typically 125/3 (so 1 nano ≈ 0.024 ticks). We need the inverse —
    /// ticks per nanosecond — to convert a delay-in-nanos into the host
    /// time delta we use to rewrite chunk timestamps.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Convert a nanosecond duration to mach_absolute_time host units.
    /// Used by the delayed-yield path to compute the timestamp rewrite
    /// (`originalHostTime + hostUnits(forNanoseconds: delay)`).
    private static func hostUnits(forNanoseconds nanos: UInt64) -> UInt64 {
        // host_units = nanos * denom / numer  (since 1 tick = numer/denom nanos)
        UInt64((Double(nanos) * Double(timebase.denom)) / Double(timebase.numer))
    }

    /// Inverse: mach_absolute_time host units to nanoseconds. Used by
    /// the per-subscriber drainer to convert a "until next due" duration
    /// into a `Task.sleep(nanoseconds:)` argument.
    private static func nanosForHostUnits(_ units: UInt64) -> UInt64 {
        UInt64((Double(units) * Double(timebase.numer)) / Double(timebase.denom))
    }

    /// Maximum a drainer task sleeps before re-evaluating its queue.
    /// Bounded so that `setDelay` changes are picked up within ~100 ms
    /// (otherwise a long-sleep drainer wouldn't see a queue retiming
    /// until its planned wake — which could be 5+ seconds away).
    private static let drainerMaxSleepNanos: UInt64 = 100_000_000  // 100 ms

    private let lock = NSLock()
    private var capture: SystemAudioCapture?
    private var captureTask: Task<Void, Never>?
    private var subscribers: [SinkID: Subscription] = [:]
    private var _anchor: PlaybackAnchor?

    /// Audio-gap telemetry — running counters tracking when the capture
    /// stream has delivered chunks at non-real-time pace. Threshold
    /// (100 ms) is chosen so normal scheduling jitter (≤30 ms) doesn't
    /// trip it but real source-side pauses (Spotify mid-track stalls,
    /// DRM-induced silences, capture stream interruptions) do.
    /// `largestGapMs` is the worst single gap observed since capture
    /// started. Reset on `stopCapture()`.
    public private(set) var captureGapCount: Int = 0
    public private(set) var largestCaptureGapMs: Int = 0
    private static let captureGapThresholdMs: Double = 100

    // MARK: - Reference signal tap (#105 mic calibration)

    /// Ring buffer of the most recent `referenceTapCapacitySec` seconds of
    /// broadcaster output, as mono float samples. Populated on every chunk
    /// arrival by the capture-task; consumed by mic calibration code which
    /// cross-correlates this against simultaneous mic samples to recover
    /// per-speaker total lag (broadcaster delay + receiver buffer + acoustic).
    ///
    /// Mono mixdown because cross-correlation doesn't need spatial info.
    /// Stored at the capture's native sample rate (48 kHz) — mic capture
    /// resamples to match before correlation.
    ///
    /// Thread safety: guarded by `referenceTapLock`. Append is O(durationSec)
    /// per chunk (~5 ms at 250 Hz chunk rate); reads are O(capacitySec).
    private var referenceTapBuffer: [Float] = []
    /// Wall time corresponding to `referenceTapBuffer[0]`. Each append
    /// advances this if the buffer is past capacity (older samples dropped).
    private var referenceTapHeadWallTime: TimeInterval = 0
    private let referenceTapLock = NSLock()
    /// Capacity in seconds — bounded so memory stays modest. 30 sec at
    /// 48 kHz mono float = ~6 MB. Set to 30 to support 20s mic captures
    /// (#98 measurement) with 5–10 sec extra headroom for finding peaks
    /// beyond the mic window (Sonos's ~4 sec internal lag).
    private static let referenceTapCapacitySec: Double = 30.0

    /// Snapshot the most recent `durationSec` of broadcaster output as a
    /// mono float array at the capture sample rate. Returns the captured
    /// samples plus the wall time corresponding to the first sample.
    /// Returns `nil` if the buffer hasn't accumulated enough samples yet.
    ///
    /// For mic-based calibration: call this AFTER `MicCapture.capture` has
    /// completed so both observations cover the same wall-clock window.
    /// Pair with the mic samples and feed both into `AudioCorrelation`.
    public func snapshotReferenceSamples(durationSec: Double) -> (samples: [Float], startWallTime: TimeInterval, sampleRate: Double)? {
        guard let sr = streamFormat?.sampleRate else { return nil }
        referenceTapLock.lock()
        defer { referenceTapLock.unlock() }
        let want = Int(durationSec * sr)
        guard referenceTapBuffer.count >= want, want > 0 else { return nil }
        let startIdx = referenceTapBuffer.count - want
        let slice = Array(referenceTapBuffer[startIdx..<referenceTapBuffer.count])
        // Wall time of the first sample of the slice. headWallTime is the
        // wall time of buffer[0]; the slice starts startIdx samples later.
        let startWall = referenceTapHeadWallTime + Double(startIdx) / sr
        return (slice, startWall, sr)
    }

    /// Append a captured chunk's PCM to the reference tap ring buffer.
    /// Called from the capture-task body. Downmixes to mono, drops oldest
    /// samples to stay within `referenceTapCapacitySec`.
    fileprivate func appendToReferenceTap(_ chunk: AudioChunk) {
        guard let channelData = chunk.pcm.floatChannelData else { return }
        let frameCount = Int(chunk.pcm.frameLength)
        if frameCount == 0 { return }
        let channelCount = Int(chunk.pcm.format.channelCount)
        let sampleRate = chunk.pcm.format.sampleRate

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameCount {
                mono[i] += ptr[i]
            }
        }
        if channelCount > 1 {
            let inv = 1.0 / Float(channelCount)
            for i in 0..<frameCount {
                mono[i] *= inv
            }
        }

        // Wall time of this chunk's first sample. The chunk's
        // `presentationHostTime` is mach time of when the first sample
        // should play; convert to wall time via the anchor or via
        // mach_continuous_time/timebase. For the reference tap we just
        // need a wall-time anchor that advances with each chunk; use the
        // capture-task arrival wall time as a close-enough approximation
        // (capture-to-process latency is sub-ms).
        let chunkWallTime = Date().timeIntervalSince1970 - Double(frameCount) / sampleRate

        referenceTapLock.lock()
        defer { referenceTapLock.unlock() }
        if referenceTapBuffer.isEmpty {
            referenceTapHeadWallTime = chunkWallTime
        }
        referenceTapBuffer.append(contentsOf: mono)

        // Trim to capacity.
        let cap = Int(Self.referenceTapCapacitySec * sampleRate)
        if referenceTapBuffer.count > cap {
            let drop = referenceTapBuffer.count - cap
            referenceTapBuffer.removeFirst(drop)
            referenceTapHeadWallTime += Double(drop) / sampleRate
        }
    }

    /// Clear the reference tap. Called on `stopCapture` and `start` so
    /// stale samples from a previous session don't contaminate a fresh
    /// calibration measurement.
    fileprivate func clearReferenceTap() {
        referenceTapLock.lock()
        defer { referenceTapLock.unlock() }
        referenceTapBuffer.removeAll(keepingCapacity: false)
        referenceTapHeadWallTime = 0
    }

    // MARK: - Chirp injection (#105 mic calibration)

    /// Mono chirp samples queued for injection. While non-empty, the
    /// capture-task replaces each incoming chunk's PCM data with the next
    /// `frameLength` samples of chirp (duplicated to stereo). When drained,
    /// reset to nil and normal capture resumes.
    ///
    /// Public-but-private-write: read via `isChirpInjecting`, set via
    /// `injectChirp(samples:)`. Guarded by `chirpLock`.
    private var pendingChirpSamples: [Float] = []
    private var chirpReadCursor: Int = 0
    private let chirpLock = NSLock()

    /// True if a chirp is currently overriding the capture stream.
    public var isChirpInjecting: Bool {
        chirpLock.lock(); defer { chirpLock.unlock() }
        return chirpReadCursor < pendingChirpSamples.count
    }

    /// Queue mono float chirp samples to replace captured audio for the
    /// next `samples.count / sampleRate` seconds. All subscribers (RTP
    /// pump for AP1, Sonos pump, reference tap) will see the chirp.
    ///
    /// Subsequent calls REPLACE the pending chirp (don't queue). Designed
    /// for one-shot mic-calibration: inject, record, correlate, done.
    public func injectChirp(samples: [Float]) {
        chirpLock.lock()
        pendingChirpSamples = samples
        chirpReadCursor = 0
        chirpLock.unlock()
        Log.core.notice("AudioBroadcaster ◆ chirp injection started — \(samples.count) samples queued")
    }

    /// Called from the capture-task to swap PCM data on each chunk while
    /// chirp is active. Returns `chunk` unchanged when no chirp is queued.
    fileprivate func applyChirpIfActive(_ chunk: AudioChunk) -> AudioChunk {
        chirpLock.lock()
        let cursor = chirpReadCursor
        let remaining = pendingChirpSamples.count - cursor
        if remaining <= 0 {
            chirpLock.unlock()
            return chunk
        }
        let frameCount = Int(chunk.pcm.frameLength)
        let take = min(frameCount, remaining)
        // Copy out the slice we need under lock, then release before
        // touching the AVAudioPCMBuffer (which doesn't need the lock).
        let slice = Array(pendingChirpSamples[cursor..<(cursor + take)])
        chirpReadCursor += take
        let drained = chirpReadCursor >= pendingChirpSamples.count
        chirpLock.unlock()

        // Build a new PCM buffer with chirp samples duplicated to all
        // channels. The capture format is float32 interleaved stereo
        // (in our project setup); the same layout works for chirp.
        let format = chunk.pcm.format
        guard let newPCM = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return chunk
        }
        newPCM.frameLength = AVAudioFrameCount(frameCount)
        guard let dst = newPCM.floatChannelData else { return chunk }
        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            let ptr = dst[ch]
            for i in 0..<take {
                ptr[i] = slice[i]
            }
            // If chirp slice is shorter than frameCount, pad with zeros.
            if take < frameCount {
                for i in take..<frameCount { ptr[i] = 0 }
            }
        }

        if drained {
            Log.core.notice("AudioBroadcaster ◆ chirp injection complete — resuming capture stream")
        }

        return AudioChunk(
            pcm: newPCM,
            sequence: chunk.sequence,
            presentationHostTime: chunk.presentationHostTime
        )
    }

    /// Current playback anchor. Nil before the first chunk flows; non-nil
    /// for the lifetime of the current shared capture. Sessions read this
    /// after subscribing (chunks arrive within ~10 ms of subscribe) and
    /// pass it into their protocol-side encoder.
    public var anchor: PlaybackAnchor? {
        lock.lock(); defer { lock.unlock() }
        return _anchor
    }

    private init() {}

    /// Format of the underlying capture stream. `nil` before the first
    /// `subscribe(id:)` completes. Sinks that need to spin up an
    /// `AVAudioConverter` (AirPlay 1: 48k f32 → 44.1k int16 → ALAC; Sonos:
    /// 48k f32 → AAC-LC) read this immediately after subscribing.
    public var streamFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return capture?.streamFormat
    }

    /// Active subscriber count. Drives `▶ Play All` UI state and OSLog
    /// telemetry. O(1).
    public var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    /// Register a new subscriber. Returns a per-subscriber `AsyncStream`
    /// of `AudioChunk`s. Throws if the underlying `SystemAudioCapture`
    /// fails to start (e.g., missing TCC audio-input permission).
    ///
    /// The capture is started lazily on the first subscriber and stopped
    /// when the last one leaves. Calling `subscribe` with the same ID
    /// twice replaces the previous subscription (the older `AsyncStream`
    /// is finished defensively).
    public func subscribe(id: SinkID, delaySeconds: Double = 0) throws -> AsyncStream<AudioChunk> {
        // Delayed subscribers use unbounded buffering because the
        // throttle is the per-subscriber drainer task, not the
        // AsyncStream's own buffer policy. Real-time subscribers stay
        // on the original .bufferingNewest(20) (~80 ms tolerance).
        let bufferingPolicy: AsyncStream<AudioChunk>.Continuation.BufferingPolicy =
            delaySeconds > 0 ? .unbounded : .bufferingNewest(20)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        let delayNanos = UInt64(max(0, delaySeconds) * 1_000_000_000)
        let subscription = Subscription(continuation: continuation, delayNanos: delayNanos)

        // Hold the lock across the entire register-and-maybe-start sequence
        // so two simultaneous Play-All subscribers can't both see
        // `capture == nil` and both spin up their own SystemAudioCapture
        // (which would deliver doubled audio to all sinks).
        lock.lock()
        let prior = subscribers.removeValue(forKey: id)
        subscribers[id] = subscription
        let countAfter = subscribers.count
        var startError: Error?
        if capture == nil {
            do {
                try startCaptureLocked()
            } catch {
                startError = error
                subscribers.removeValue(forKey: id)
            }
        }
        // Spawn the drainer task for delayed subscribers (must happen
        // inside the lock so it sees the just-inserted subscription).
        if delayNanos > 0 && startError == nil {
            subscription.drainerTask = Task { [weak self, weak subscription] in
                await self?.runDrainer(forSinkID: id, subscriptionRef: subscription)
            }
        }
        lock.unlock()

        // Defensively finish any prior stream with the same ID — an
        // earlier session that crashed before unsubscribing. Done outside
        // the lock because `.finish()` doesn't need broadcaster state.
        prior?.drainerTask?.cancel()
        prior?.continuation.finish()

        if let startError {
            continuation.finish()
            throw startError
        }
        if delayNanos > 0 {
            let delaySec = String(format: "%.3f", Double(delayNanos) / 1e9)
            Log.core.info("AudioBroadcaster ← subscribe \(id, privacy: .public) delay=\(delaySec, privacy: .public)s  (now \(countAfter) subscriber(s))")
        } else {
            Log.core.info("AudioBroadcaster ← subscribe \(id, privacy: .public)  (now \(countAfter) subscriber(s))")
        }
        return stream
    }

    /// Unregister a subscriber. Cancels the per-sink drainer task (if any)
    /// and stops the underlying capture when the last subscriber leaves.
    public func unsubscribe(id: SinkID) {
        lock.lock()
        let sub = subscribers.removeValue(forKey: id)
        let shouldStop = subscribers.isEmpty
        let countAfter = subscribers.count
        lock.unlock()

        sub?.drainerTask?.cancel()
        sub?.continuation.finish()
        Log.core.info("AudioBroadcaster ← unsubscribe \(id, privacy: .public)  (now \(countAfter) subscriber(s))")

        if shouldStop {
            stopCapture()
        }
    }

    /// Update the delay for an existing subscriber. Adjusts every queued
    /// chunk's `yieldDueHostTime` by the same delta and changes
    /// `delayNanos` so future enqueues use the new value. The drainer
    /// task will see the new times within `drainerMaxSleepNanos` (~100 ms).
    ///
    /// **Increasing delay**: queued chunks shift FORWARD in wall time.
    /// AP1 audio "pauses" briefly while the drainer's next-due times
    /// move past `now`.
    ///
    /// **Decreasing delay**: queued chunks shift BACKWARD. If any chunks
    /// now have `yieldDueHostTime` in the past, the drainer yields them
    /// in rapid succession (catching up). User hears a brief acceleration.
    ///
    /// For small slider ticks (5–10 ms), the perceptual effect is below
    /// audible threshold. Large jumps (e.g., from auto-calibration result)
    /// would benefit from a fade or full re-subscribe — see #99 design
    /// notes for the cancel+re-subscribe path used by Restart All.
    public func setDelay(_ newDelaySeconds: Double, for sinkID: SinkID) {
        let newDelayNanos = UInt64(max(0, newDelaySeconds) * 1_000_000_000)
        lock.lock()
        defer { lock.unlock() }
        guard let sub = subscribers[sinkID] else { return }
        let oldDelayNanos = sub.delayNanos
        if newDelayNanos == oldDelayNanos { return }
        let oldDelayHostUnits = Int64(Self.hostUnits(forNanoseconds: oldDelayNanos))
        let newDelayHostUnits = Int64(Self.hostUnits(forNanoseconds: newDelayNanos))
        let deltaHostUnits = newDelayHostUnits - oldDelayHostUnits
        // Walk the queue applying the delta. Saturating arithmetic so
        // a large negative delta can't underflow a small dueAt.
        for i in 0..<sub.queue.count {
            let currentDue = Int64(bitPattern: sub.queue[i].yieldDueHostTime)
            let adjusted = max(0, currentDue + deltaHostUnits)
            sub.queue[i].yieldDueHostTime = UInt64(adjusted)
        }
        sub.delayNanos = newDelayNanos
        Log.core.info("AudioBroadcaster: setDelay \(sinkID, privacy: .public) → \(String(format: "%.3f", Double(newDelayNanos) / 1e9), privacy: .public)s (retimed \(sub.queue.count) queued chunk(s))")
    }

    // MARK: - Capture lifecycle (private)

    /// Spin up a `SystemAudioCapture` and a task that drains chunks from
    /// its single-consumer stream into every subscriber's continuation.
    /// The yield is non-blocking; `.bufferingNewest(20)` per subscriber
    /// drops oldest chunks on slow consumers rather than back-pressuring
    /// the capture.
    ///
    /// **Must be called with `self.lock` already held.** The `Locked`
    /// suffix is the convention. The capture-task body locks separately
    /// because it runs asynchronously after this returns and never re-
    /// enters this function.
    private func startCaptureLocked() throws {
        let cap = SystemAudioCapture()
        try cap.start()
        capture = cap

        captureTask = Task { [weak self] in
            var lastChunkArrivalHost: UInt64 = 0
            for await rawChunk in cap.chunks {
                guard let self else { return }
                // #105 chirp injection — if a calibration chirp is queued,
                // replace this chunk's PCM data with the next slice of
                // chirp samples. Otherwise pass-through. Done at the top
                // so the gap-detection, anchor, reference tap, and
                // subscriber distribution downstream all see the chirp.
                let chunk = self.applyChirpIfActive(rawChunk)
                // Audio-gap detection (capture side). Measures wall-clock
                // delta between consecutive chunk arrivals. Big gaps
                // mean source-side stall — Spotify paused, capture got
                // interrupted, DRM-induced silence. We log and bump a
                // counter so the UI / soak tests can surface "audio
                // continuity broke at T+45m" as ground truth (vs the
                // softer "the speaker hiccuped" anecdote).
                let now = mach_absolute_time()
                if lastChunkArrivalHost != 0 {
                    let deltaHost = now &- lastChunkArrivalHost
                    let deltaMs = Double(deltaHost) * Double(Self.timebase.numer) / Double(Self.timebase.denom) / 1_000_000.0
                    if deltaMs > Self.captureGapThresholdMs {
                        self.captureGapCount += 1
                        let ms = Int(deltaMs.rounded())
                        if ms > self.largestCaptureGapMs {
                            self.largestCaptureGapMs = ms
                        }
                        Log.core.error("⚠ Capture gap detected: \(ms) ms (total gaps this session: \(self.captureGapCount), largest: \(self.largestCaptureGapMs) ms)")
                    }
                }
                lastChunkArrivalHost = now

                // #105 mic calibration — append mono mixdown to the
                // reference tap ring buffer BEFORE locking the main mutex
                // so the calibration code (which doesn't hold lock) can
                // read concurrently without contention.
                self.appendToReferenceTap(chunk)

                self.lock.lock()
                // Establish the playback anchor on the very first chunk.
                // Every subscriber's per-chunk RTP timestamp / per-session
                // sync packet content is derived from this anchor, so all
                // receivers map the same chunk to the same playback wall
                // time and arrive at sample-accurate (within ~30 ms of
                // each other) cross-sink sync.
                if self._anchor == nil {
                    // Capture mach time and wall time as close together as
                    // possible (consecutive instructions) so they describe
                    // the same instant. Sessions use mach time for chunk
                    // arithmetic, wall time for NTP-formatted sync packets.
                    let wall = Date()
                    self._anchor = PlaybackAnchor(
                        referenceHostTime: chunk.presentationHostTime,
                        referenceWallTime: wall,
                        referenceRTPTimestamp: 0
                    )
                    Log.core.info("AudioBroadcaster ⌖ anchor set — refHostTime=\(chunk.presentationHostTime) refWallTime=\(wall.timeIntervalSince1970) refRTP=0")
                }
                let nowHost = mach_absolute_time()
                for (_, sub) in self.subscribers {
                    if sub.delayNanos == 0 {
                        // Real-time — yield directly (no copy needed;
                        // consumer reads before the buffer recycles).
                        sub.continuation.yield(chunk)
                    } else {
                        // Delayed — defensive copy + presentationHostTime
                        // rewrite + enqueue. Per-subscriber drainer task
                        // pops and yields at the right wall moment.
                        let delayHostUnits = Self.hostUnits(forNanoseconds: sub.delayNanos)
                        let copied = chunk.makeCopy()
                        let rewrittenHostTime = copied.presentationHostTime &+ delayHostUnits
                        let toDeliver = AudioChunk(
                            pcm: copied.pcm,
                            sequence: copied.sequence,
                            presentationHostTime: rewrittenHostTime
                        )
                        let dueAt = nowHost &+ delayHostUnits
                        sub.queue.append(QueuedChunk(chunk: toDeliver, yieldDueHostTime: dueAt))
                    }
                }
                self.lock.unlock()
            }
            Log.core.info("AudioBroadcaster: capture stream ended")
        }
        Log.core.info("AudioBroadcaster ▶ shared capture started (\(cap.streamFormat?.sampleRate ?? 0) Hz)")
    }

    /// Per-subscriber drainer task body. Runs from subscribe() until
    /// unsubscribe() cancels it. Pops chunks from the subscriber's queue
    /// in due-time order and yields them to the AsyncStream continuation
    /// at their `yieldDueHostTime`. Bounded sleeps (max 100 ms) ensure
    /// `setDelay` re-timings get picked up promptly.
    private func runDrainer(forSinkID id: SinkID, subscriptionRef: Subscription?) async {
        while !Task.isCancelled {
            // Snapshot next chunk's due time + decide what to do
            // under lock; release before sleeping or yielding.
            lock.lock()
            guard let sub = subscriptionRef, subscribers[id] === sub else {
                // Unsubscribed or replaced — exit.
                lock.unlock()
                return
            }
            let firstDue = sub.queue.first?.yieldDueHostTime
            lock.unlock()

            guard let dueAt = firstDue else {
                // Queue empty — sleep briefly, re-check.
                try? await Task.sleep(nanoseconds: Self.drainerMaxSleepNanos)
                continue
            }
            let nowHost = mach_absolute_time()
            if dueAt > nowHost {
                let waitHost = dueAt &- nowHost
                let waitNanos = min(Self.nanosForHostUnits(waitHost), Self.drainerMaxSleepNanos)
                try? await Task.sleep(nanoseconds: waitNanos)
                continue
            }
            // Due now (or in the past) — pop and yield.
            lock.lock()
            guard let sub2 = subscriptionRef, subscribers[id] === sub2, !sub2.queue.isEmpty else {
                lock.unlock()
                continue
            }
            // Re-check the head's due time — setDelay may have retimed
            // queued chunks while we were sleeping. If the head's new
            // due time is in the future, drop back to wait.
            if sub2.queue[0].yieldDueHostTime > mach_absolute_time() {
                lock.unlock()
                continue
            }
            let popped = sub2.queue.removeFirst()
            let cont = sub2.continuation
            lock.unlock()
            cont.yield(popped.chunk)
        }
    }

    private func stopCapture() {
        captureTask?.cancel()
        captureTask = nil

        lock.lock()
        let cap = capture
        capture = nil
        _anchor = nil
        let gaps = captureGapCount
        let largest = largestCaptureGapMs
        captureGapCount = 0
        largestCaptureGapMs = 0
        lock.unlock()

        // Drop reference tap samples — stale data from a previous session
        // mustn't contaminate the next mic-calibration window.
        clearReferenceTap()
        // Cancel any in-flight chirp so the next session starts cleanly.
        chirpLock.lock()
        pendingChirpSamples.removeAll(keepingCapacity: false)
        chirpReadCursor = 0
        chirpLock.unlock()

        cap?.stop()
        if gaps > 0 {
            Log.core.info("AudioBroadcaster ■ shared capture stopped (anchor cleared) — \(gaps) gap(s) observed, largest \(largest) ms")
        } else {
            Log.core.info("AudioBroadcaster ■ shared capture stopped (anchor cleared) — zero gaps observed")
        }
    }
}
