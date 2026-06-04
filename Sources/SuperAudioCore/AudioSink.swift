// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

/// The stable contract every protocol module implements for an active,
/// connected device. Returned from `SinkDiscoverer.createSink(for:)`.
///
/// Adding a new protocol family means writing a new `AudioSink` (and a
/// `SinkDiscoverer` for finding devices). Code outside the protocol module
/// must not need to know which protocol it's talking to.
public protocol AudioSink: AnyObject {
    var id: SinkID { get }
    var displayName: String { get }
    var protocolKind: ProtocolKind { get }

    /// Round-trip latency plus the receiver's internal buffer depth, in
    /// milliseconds. Measured at connect time; may be re-measured later.
    var measuredLatencyMs: Int { get }

    /// User-tunable fine offset, added on top of `measuredLatencyMs`.
    /// Persisted per sink in `UserDefaults`.
    var manualOffsetMs: Int { get set }

    func connect() async throws
    func enqueue(_ chunk: AudioChunk, scheduledHostTime: UInt64) async throws
    func disconnect() async
}
