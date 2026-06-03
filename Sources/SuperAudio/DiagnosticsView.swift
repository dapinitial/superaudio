// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import SwiftUI
import AppKit
import SuperAudioCore

/// #102 / M6.3 — In-app diagnostics panel.
///
/// Read-only view that surfaces the most useful OSLog data inline so support
/// debugging stops requiring `log show` over the shoulder. Tonight's
/// scaffold: per-active-sink status (offset, volume, reconnecting/failed
/// flags), broadcaster capture state (running, gap count, largest gap),
/// calibration recency, and a "Copy diagnostic bundle" button that puts a
/// markdown summary on the clipboard for support tickets.
///
/// Built deliberately MINIMAL for tonight's autonomous run — the data
/// surface is there + the copy-to-clipboard works. Polish (auto-refresh,
/// pretty formatting, drift meter) follows when the user picks it up
/// tomorrow.
struct DiagnosticsView: View {

    let onDismiss: () -> Void

    @State private var refreshTick: Int = 0
    @State private var copyConfirmation: String = ""

    private let session = SessionState.shared
    private let broadcaster = AudioBroadcaster.shared
    private let discovered = DiscoveredSinks.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            scrollContents
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 420)
        // Tick the refresh state every 2 sec while the panel is open so
        // counters and timestamps stay roughly live. SwiftUI's @Observable
        // tracking handles the static reads; this just pokes the view.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTick &+= 1
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundStyle(.tint)
            Text("Diagnostics")
                .font(.headline)
            Spacer()
            Text("\(refreshTick == 0 ? "—" : "live")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scrollContents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pipelineSection
                Divider()
                calibrationSection
                Divider()
                sinksSection
                Divider()
                ultrasonicValidationButton
                Divider()
                copyButton
            }
        }
        .frame(maxHeight: 380)
    }

    // MARK: - M6.7 ultrasonic hardware-validation gate

    @State private var ultrasonicRunStatus: String = ""
    @State private var ultrasonicRunning: Bool = false

    private var ultrasonicValidationButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    Task { @MainActor in
                        ultrasonicRunning = true
                        ultrasonicRunStatus = "Running… check Console for === M6.7 === lines"
                        do {
                            let results = try await UltrasonicValidator.runFullValidation()
                            let sinkCount = Set(results.map(\.sinkLabel)).count
                            ultrasonicRunStatus = "Done — \(results.count) measurements across \(sinkCount) sink(s). See Console / OSLog for the verdict."
                        } catch {
                            ultrasonicRunStatus = "Failed: \(error)"
                        }
                        ultrasonicRunning = false
                    }
                } label: {
                    Label(ultrasonicRunning
                          ? "Running M6.7 validation…"
                          : "Run M6.7 ultrasonic validation",
                          systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                .disabled(ultrasonicRunning || !session.isAnyActive)
                Spacer()
            }
            if !ultrasonicRunStatus.isEmpty {
                Text(ultrasonicRunStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Plays pure tones at 1 kHz (reference) and 15–19.5 kHz (ultrasonic candidates) through each active sink. Mic captures, Goertzel extracts magnitude + SNR. Tells us whether M6.7 closed-loop continuous tracking is hardware-viable on your setup. Filter the log stream with the predicate `eventMessage CONTAINS \"M6.7\"` for the clean output.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pipeline section

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio pipeline")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            row("Capture", broadcaster.streamFormat != nil ? "running @ \(Int(broadcaster.streamFormat?.sampleRate ?? 0)) Hz" : "stopped")
            row("Subscribers", "\(broadcaster.subscriberCount)")
            row("Capture gaps", "\(broadcaster.captureGapCount) (worst \(broadcaster.largestCaptureGapMs) ms)")
            row("Chirp inject active", broadcaster.isChirpInjecting ? "yes" : "no")
            row("Anchor set", broadcaster.anchor != nil ? "yes" : "no")
        }
    }

    // MARK: - Calibration section

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calibration")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            row("Auto-calibrate on Play All", session.autoCalibrateOnPlayAll ? "on" : "off")
            row("Recent calibration <2 min", session.didRecentlyCalibrate ? "yes (active offsets trust)" : "no (next Play All will recalibrate)")
            row("Sonos headroom (personal)", "\(session.personalSonosHeadroomMs) ms")
        }
    }

    // MARK: - Per-sink section

    private var sinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active sinks (\(session.activeSinks.count))")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if session.activeSinks.isEmpty {
                Text("No sinks active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeDescriptors, id: \.id) { desc in
                    sinkRow(desc)
                }
            }
        }
    }

    private func sinkRow(_ desc: SinkDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(desc.displayName)
                    .font(.callout.bold())
                Text("[\(desc.protocolKind.rawValue)]")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.reconnecting[desc.id] != nil {
                    Text("RECONNECT")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                if let last = session.recentFailures[desc.id] {
                    let ago = Int(Date().timeIntervalSince(last))
                    Text("FAIL \(ago)s ago")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 12) {
                Text("vol \(session.volume(for: desc.id))%")
                Text("offset \(session.offset(for: desc.id)) ms")
                if let playStart = session.sonosPlayStartedAt[desc.id] {
                    let secs = Int(Date().timeIntervalSince(playStart))
                    Text("play+\(secs)s")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var activeDescriptors: [SinkDescriptor] {
        discovered.sinks.filter { session.activeSinks.contains($0.id) }
    }

    // MARK: - Copy diagnostic bundle

    private var copyButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    let bundle = generateDiagnosticBundle()
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(bundle, forType: .string)
                    copyConfirmation = "Copied at \(Date().formatted(date: .omitted, time: .standard))"
                } label: {
                    Label("Copy diagnostic bundle", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Spacer()
                if !copyConfirmation.isEmpty {
                    Text(copyConfirmation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Markdown summary of pipeline + per-sink state + calibration history. Paste into a GitHub issue or support email — replaces the need to grep OSLog.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    /// Build a one-page markdown summary suitable for pasting into a GitHub
    /// issue or support email. Contains exactly what a human triaging a sync
    /// complaint needs to ask the right next question.
    private func generateDiagnosticBundle() -> String {
        var s = ""
        s += "# SuperAudio Diagnostic Bundle\n"
        s += "Captured: \(Date().ISO8601Format())\n\n"

        s += "## Pipeline\n"
        if let fmt = broadcaster.streamFormat {
            s += "- Capture: **running** @ \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch\n"
        } else {
            s += "- Capture: **stopped**\n"
        }
        s += "- Subscribers: \(broadcaster.subscriberCount)\n"
        s += "- Capture gaps: \(broadcaster.captureGapCount) (worst \(broadcaster.largestCaptureGapMs) ms)\n"
        s += "- Chirp inject active: \(broadcaster.isChirpInjecting ? "yes" : "no")\n"
        s += "- Anchor set: \(broadcaster.anchor != nil ? "yes" : "no")\n\n"

        s += "## Calibration\n"
        s += "- Auto-calibrate on Play All: \(session.autoCalibrateOnPlayAll ? "on" : "off")\n"
        s += "- Recent calibration (<2 min): \(session.didRecentlyCalibrate ? "yes" : "no")\n"
        s += "- Personal Sonos headroom: \(session.personalSonosHeadroomMs) ms\n\n"

        s += "## Active sinks (\(session.activeSinks.count))\n"
        if session.activeSinks.isEmpty {
            s += "_None._\n"
        } else {
            for desc in activeDescriptors {
                s += "- **\(desc.displayName)** [\(desc.protocolKind.rawValue)]\n"
                s += "  - volume: \(session.volume(for: desc.id))%\n"
                s += "  - offset: \(session.offset(for: desc.id)) ms\n"
                if let playStart = session.sonosPlayStartedAt[desc.id] {
                    s += "  - sonos play start: \(playStart.formatted(date: .omitted, time: .standard)) (\(Int(Date().timeIntervalSince(playStart)))s ago)\n"
                }
                if session.reconnecting[desc.id] != nil {
                    s += "  - status: **RECONNECTING**\n"
                }
                if let f = session.recentFailures[desc.id] {
                    s += "  - status: **recent failure** \(Int(Date().timeIntervalSince(f)))s ago\n"
                }
            }
        }
        s += "\n## Reproduce / further data\n"
        s += "Full OSLog last 10 min:\n"
        s += "```\n"
        s += "/usr/bin/log show --predicate 'subsystem contains \"SuperAudio\"' --info --last 10m\n"
        s += "```\n"
        return s
    }
}
