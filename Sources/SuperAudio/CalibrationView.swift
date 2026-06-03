// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import SwiftUI
import SuperAudioCore

/// #105 Calibrate Sync — deliberate 30-sec ritual that takes the
/// guesswork out of Auto-Align. Born from 2026-05-18 debugging session
/// (see [[project-sonos-30s-settling]]): Sonos's UPnP `RelTime` needs
/// ~30 sec of playback to settle into steady-state. Auto-triggering at
/// fixed delays <30s consistently failed; manual clicks after waiting
/// 30+ sec consistently nailed sync. Make the wait visible UX, capture
/// user verification, refine per-environment headroom over time.
///
/// **Phase 1+2 (this commit)**: countdown + apply + result display.
/// Verification feedback (Phase 3) and pre-flight wait (Phase 4) follow.
///
/// **Future hook**: This same sheet pattern serves M11 mic-based Room
/// Tuning. The countdown becomes "Recording mic for N seconds"; the
/// measurement step swaps `runSonosPositionAutoAlign` for the cross-
/// correlation engine (#98). Same UX gesture, more accurate physics.
struct CalibrationView: View {

    enum Mode: Equatable {
        case countdown(secondsRemaining: Int)
        case measuring
        case complete(lagMs: Int, ap1OffsetMs: Int, sinkCount: Int)
        case failed(message: String)
    }

    @Binding var mode: Mode

    /// Closure invoked when the user dismisses the sheet (Done / Cancel).
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity)

            Divider()

            footer
        }
        .padding(18)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
            Text("Calibrate Sync")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .countdown(let s):
            countdownView(secondsRemaining: s)
        case .measuring:
            measuringView
        case .complete(let lagMs, let ap1OffsetMs, let sinkCount):
            completeView(lagMs: lagMs, ap1OffsetMs: ap1OffsetMs, sinkCount: sinkCount)
        case .failed(let msg):
            failedView(message: msg)
        }
    }

    private func countdownView(secondsRemaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep audio playing — listening to Sonos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Sonos's clock needs ~30 sec of playback to settle. Calibration runs automatically when ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ProgressView(value: Double(30 - secondsRemaining), total: 30)
                    .progressViewStyle(.linear)
                Text("\(secondsRemaining)s")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.top, 4)
        }
    }

    private var measuringView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Measuring Sonos position…")
                    .font(.subheadline)
            }
            Text("Querying UPnP, computing offset, restarting AirPlay sinks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func completeView(lagMs: Int, ap1OffsetMs: Int, sinkCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Sync calibrated")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            HStack {
                Text("Sonos lag")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(lagMs) ms")
                    .monospacedDigit()
            }
            .font(.caption)

            HStack {
                Text("AirPlay 1 offset")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ap1OffsetMs) ms × \(sinkCount)")
                    .monospacedDigit()
            }
            .font(.caption)

            Text("Listen for a moment — verify everything sounds in sync. Re-run if it drifts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Calibration failed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch mode {
            case .countdown, .measuring:
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
            case .complete:
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button("Close", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
    }
}
