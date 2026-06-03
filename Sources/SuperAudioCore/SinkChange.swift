// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

/// Discovery emits a stream of these. Consumers (menu bar UI, etc.) reduce
/// the stream into the current set of known sinks.
public enum SinkChange: Sendable {
    case added(SinkDescriptor)
    case updated(SinkDescriptor)
    case removed(SinkID)
}
