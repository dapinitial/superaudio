// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

/// Each protocol module ships one of these. Registered with `SinkRegistry`
/// at app startup, gated by `LicenseManager.isEnabled(...)` for addon modules.
///
/// `start()` kicks off discovery (Bonjour, SSDP, etc.); `sinks` emits every
/// time a new device appears or its descriptor changes; `createSink(for:)`
/// instantiates an `AudioSink` ready to be connected.
public protocol SinkDiscoverer: AnyObject {
    var protocolKind: ProtocolKind { get }

    func start()
    func stop()

    /// Continuous stream of sink add/update/remove events.
    /// Consumers can `for await change in sinks { ... }` to maintain the UI.
    var sinks: AsyncStream<SinkChange> { get }

    /// Instantiate an `AudioSink` for a previously emitted descriptor.
    /// Caller is responsible for `connect()`.
    func createSink(for descriptor: SinkDescriptor) async throws -> AudioSink
}
