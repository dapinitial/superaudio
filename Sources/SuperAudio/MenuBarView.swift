// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import SwiftUI
import AVFoundation
import SuperAudioCore
import SuperAudioAirPlay1
import SuperAudioAirPlay2
import SuperAudioSonos

/// Contents of the menu bar popover. Live-bound to `DiscoveredSinks.shared`
/// so devices appear and disappear in real time as discoverers emit events.
///
/// Hosted by `MenuBarExtra(.window)` — a proper SwiftUI popover, not a
/// classic menu. Full layout flexibility means per-sink Slider controls
/// work natively (sliders inside `.menu` fight the menu's internal event
/// loop and feel laggy). Required by the per-sink volume control shipped
/// 2026-05-15 and the per-sink offset slider arriving with M5.
///
/// Apple's discovery on macOS surfaces every Mac, iPhone, iPad, etc.
/// advertising RAOP — useful for diagnostics, noisy for normal use.
/// Default: show only dedicated speakers. The "Show all devices" toggle
/// reveals everything that was discovered.
struct MenuBarView: View {
    private let store = DiscoveredSinks.shared
    private let session = SessionState.shared
    private let groups = SpeakerGroups.shared
    private let topology = SonosTopology.shared

    @AppStorage("showAllDevices") private var showAllDevices: Bool = false
    @AppStorage("muteMacWhilePlaying") private var muteMacWhilePlaying: Bool = true
    @AppStorage("losslessMode") private var losslessMode: Bool = false
    // #110 M6.4 — auto-trigger Mic Calibrate on Play All when Sonos active.
    @AppStorage("autoCalibrateOnPlayAll") private var autoCalibrateOnPlayAll: Bool = true
    // Milestone 2 — when armed, the Passive Sync Monitor actually moves the
    // AirPlay offset to track Sonos (otherwise it only logs "would apply").
    @AppStorage("passiveSyncArmed") private var passiveSyncArmed: Bool = false
    // M3 hardening 2/2 — toggle ANNOUNCE et=1 (encrypted ALAC) for receiver
    // compat verification. Default off (et=0 confirmed working on B&W A5/A7).
    @AppStorage("useEncryptedAirPlay") private var useEncryptedAirPlay: Bool = false
    // #118 M6.4 — sine-sweep chirp vs MLS noise as calibration reference signal.
    // Default OFF = MLS (friendlier sound). ON = chirp (the alarm-tone sweep).
    @AppStorage("useChirpForCalibration") private var useChirpForCalibration: Bool = false
    // Quiet Mode removed 2026-05-16 — user feedback was "we wanted default
    // low, not a max cap." Replaced by SessionState.defaultVolumePercent = 15.

    @State private var showSaveGroupForm: Bool = false
    @State private var newGroupName: String = ""
    @FocusState private var saveGroupFieldFocused: Bool

    /// #105 Calibrate Sync — when not `nil`, popover content switches to
    /// the calibration view instead of the regular sink list. Set by the
    /// "Calibrate Sync" button, cleared by Done/Cancel.
    @State private var calibrationMode: CalibrationView.Mode?

    /// #102 Diagnostics panel — when true, popover content switches to the
    /// read-only diagnostics view (sink state, capture stats, calibration
    /// recency, Copy-diagnostic-bundle button).
    @State private var showingDiagnostics: Bool = false

    private var visibleSinks: [SinkDescriptor] {
        // Cross-protocol dedup first (hide a Sonos's redundant AirPlay face),
        // then the speaker/diagnostic filter.
        let base = store.deduplicated
        let speakerFiltered = showAllDevices ? base : base.filter(\.isLikelySpeaker)
        // "Show all devices" is the diagnostic escape hatch — reveal grouped
        // members too, so the user can see/inspect the full topology.
        guard !showAllDevices else { return speakerFiltered }
        // M6.6a — hide non-coordinator members of a Sonos group. We feed only
        // the coordinator; SonosNet relays to the rest (gotcha #24). Fail-open:
        // unknown topology hides nothing.
        let sonosHere = speakerFiltered.filter { $0.protocolKind == .sonos }
        let hidden = topology.hiddenMemberIDs(among: sonosHere)
        guard !hidden.isEmpty else { return speakerFiltered }
        return speakerFiltered.filter { !hidden.contains($0.id) }
    }

    private var airplay1Sinks: [SinkDescriptor] {
        visibleSinks.filter { $0.protocolKind == .airplay1 }
    }

    private var sonosSinks: [SinkDescriptor] {
        visibleSinks.filter { $0.protocolKind == .sonos }
    }

    /// Every sink we know how to stream Mac audio to — AirPlay 1 + Sonos.
    /// Order matters: AP1 first so its NTP-anchored sync starts before
    /// Sonos's slower-to-buffer HTTP stream catches up.
    private var allStreamableSinks: [SinkDescriptor] {
        airplay1Sinks + sonosSinks
    }

    var body: some View {
        if showingDiagnostics {
            DiagnosticsView(onDismiss: { showingDiagnostics = false })
        } else if let mode = calibrationMode {
            CalibrationView(
                mode: Binding(
                    get: { mode },
                    set: { calibrationMode = $0 }
                ),
                onDismiss: { calibrationMode = nil }
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider().padding(.vertical, 6)

                sinkList

                if !allStreamableSinks.isEmpty {
                    Divider().padding(.vertical, 6)
                    groupActions
                }

                if !groups.groups.isEmpty || session.isAnyActive {
                    Divider().padding(.vertical, 6)
                    savedGroups
                }

                Divider().padding(.vertical, 6)
                preferences

                Divider().padding(.vertical, 6)
                quitRow
            }
            .padding(14)
            .frame(width: 360)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.2")
                .imageScale(.medium)
                .foregroundStyle(.tint)
            Text("SuperAudio")
                .font(.headline)
            Spacer()
            if session.isAnyActive {
                let count = session.activeSinks.count
                Text("\(count) playing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var sinkList: some View {
        if visibleSinks.isEmpty {
            Text(String(localized: "No sinks connected"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleSinks) { descriptor in
                    sinkRow(descriptor)
                }
            }
        }
    }

    private func sinkRow(_ descriptor: SinkDescriptor) -> some View {
        let isActive = session.activeSinks.contains(descriptor.id)
        let reconnect = session.reconnecting[descriptor.id]
        let hasFailure = !isActive && reconnect == nil && session.hasRecentFailure(descriptor.id)
        let iconName: String = isActive
            ? "checkmark.circle.fill"
            : (reconnect != nil ? "arrow.clockwise.circle" : (hasFailure ? "xmark.circle.fill" : "circle"))
        let iconStyle: AnyShapeStyle = isActive
            ? AnyShapeStyle(.tint)
            : (reconnect != nil ? AnyShapeStyle(.orange) : (hasFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)))
        let isAirPlay1 = descriptor.protocolKind == .airplay1
        return VStack(alignment: .leading, spacing: 4) {
            // Row 1 — toggle + name + volume slider + volume readout
            HStack(spacing: 10) {
                Button {
                    handleSelection(descriptor)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName)
                            .imageScale(.medium)
                            .foregroundStyle(iconStyle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(descriptor.displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                            if let reconnect {
                                Text("reconnecting (attempt \(reconnect.attempt))…")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(subtitle(for: descriptor))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 150, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(session.volume(for: descriptor.id)) },
                        set: { session.setVolume(Int($0.rounded()), for: descriptor.id) }
                    ),
                    in: 0...Double(session.currentMaxVolume)
                )
                .controlSize(.small)
                .tint(isActive ? .accentColor : .secondary)

                Text("\(session.volume(for: descriptor.id))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            // Row 2 — per-sink offset.
            //
            // AirPlay 1: real sender-side delay (since 2026-05-16 night
            // take 2). The broadcaster holds chunks for the slider's ms
            // value before feeding them to the AP1 RTPSender. AP1 plays
            // delayed audio at the same wall time Sonos plays the same
            // chunk → cross-protocol sync. Slider value takes effect on
            // next play (mid-stream changes would glitch the audio).
            //
            // Sonos: no slider. Sonos's playback timing is protocol-
            // fixed (encrypted at UPnP, per svrooij/node-sonos-ts#139)
            // and even our prepend-silence trick would only delay it
            // further — wrong direction since Sonos is already the
            // slowest sink. Show an informational caption instead so
            // the user knows the AP1 sliders are the lever.
            if isAirPlay1 {
                HStack(spacing: 10) {
                    Text("Δ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 162, alignment: .trailing)
                        .help("Delay this speaker by N ms to match Sonos's natural lag. Applies on next Play.")

                    // Auto-calibration handles fine alignment; this slider is
                    // for coarse residual nudges by ear, so it steps in 25 ms
                    // increments rather than single milliseconds.
                    Slider(
                        value: Binding(
                            get: { Double(session.offset(for: descriptor.id)) },
                            set: { session.setOffset(Int($0.rounded()), for: descriptor.id) }
                        ),
                        in: Double(SessionState.offsetRangeMs.lowerBound)...Double(SessionState.offsetRangeMs.upperBound),
                        step: 25
                    )
                    .controlSize(.mini)
                    .tint(.accentColor.opacity(0.6))
                    .help("Drag right to delay this speaker. Applies on next Play.")

                    Text("+\(session.offset(for: descriptor.id)) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            } else {
                Text("~200 ms–2 s intrinsic delay · drag AP1 sliders ↑ to match")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .help("Sonos's playback timing is fixed by its protocol. To align with AirPlay 1 speakers, adjust the AP1 Δ sliders to match.")
            }
        }
    }

    private var groupActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always clickable now that startAll is idempotent — pressing
            // Play All when audio is already playing logs "N sink(s)
            // already running — skipping" and is a clean no-op. Far better
            // UX than the previous .disabled() state, which left the user
            // unable to "kick" the session if it ever got stuck.
            Button {
                Log.app.info("Group: Play All (\(self.allStreamableSinks.count) sink(s))")
                session.startAll(allStreamableSinks)
            } label: {
                Label(String(localized: "Play All"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if !airplay1Sinks.isEmpty {
                Button {
                    Log.app.info("Group: Play All AirPlay (\(self.airplay1Sinks.count) sink(s))")
                    session.startAll(airplay1Sinks)
                } label: {
                    Label(String(localized: "Play All AirPlay (no Sonos)"), systemImage: "play")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if session.isAnyActive {
                // Auto-Align — one-click sync using Sonos UPnP telemetry.
                // Reads Sonos's current playback position, computes its
                // lag vs wall-clock, and pushes that lag (minus AP1's
                // ~93 ms buffer) into every active AP1 sink's delay
                // slider. No microphone, no test tone.
                //
                // Gate: `sonosPlayStartedAt` non-empty (not just
                // `activeSonosDescriptors`). The Sonos session marks
                // itself "active" the moment its task starts, but SOAP
                // `Play` doesn't actually fire until *after* the start
                // barrier releases and the start-align defer expires —
                // typically 5–7 sec later. The auto-align math needs the
                // SOAP-Play wall-time anchor, so hide the button until
                // that exists.
                // #98 / #105 Mic Test (chirp) — single-shot diagnostic.
                // Records one measurement; useful for "what does the mic
                // currently see?" but doesn't apply offsets.
                Button {
                    runChirpMicMeasurement()
                } label: {
                    Label(String(localized: "Mic Test (chirp)"), systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Plays a 1-sec sine sweep through all speakers, records mic, measures arrival lag at this location. Briefly interrupts music.")

                // Passive Sync Monitor (beta) — Milestone 1, read-only. Loops
                // on the music already playing (no chirp), correlates the mic
                // against the known reference, and logs the per-speaker lags +
                // inter-speaker drift each round. Proof of the content-based
                // tracking thesis before we close the loop into setDelay.
                Button {
                    PassiveSyncMonitor.shared.toggle()
                } label: {
                    Label(
                        PassiveSyncMonitor.shared.isRunning
                            ? String(localized: "Stop Passive Sync Monitor")
                            : String(localized: "Passive Sync Monitor (beta)"),
                        systemImage: PassiveSyncMonitor.shared.isRunning ? "stop.circle" : "waveform.badge.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Listens to the music already playing and continuously logs how far apart your speakers are — no calibration tone. Read-only beta; watch Console for per-round readings.")

                // #109 Mic Calibrate (auto) — full sequential per-speaker
                // calibration. Mutes all but one speaker at a time, runs
                // chirp, measures lag, repeats for each. Computes new
                // AP1 offsets to align with Sonos. Persists + restarts.
                // Only meaningful when both AP1 + Sonos are active.
                if !airplay1Sinks.isEmpty && !session.sonosPlayStartedAt.isEmpty {
                    Button {
                        runMicAutoCalibration()
                    } label: {
                        Label(String(localized: "Mic Calibrate (auto)"), systemImage: "wand.and.stars.inverse")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Plays a chirp through each speaker in turn, measures arrival lag from your Mac's position, and adjusts AirPlay sync to match Sonos. ~30 sec total.")
                }

                if !session.sonosPlayStartedAt.isEmpty {
                    // #105 Calibrate Sync — the deliberate 30-sec ritual.
                    // Data from 2026-05-18: Sonos's UPnP RelTime needs
                    // ~30 sec of playback to settle. Make the wait visible
                    // UX instead of hoping a fixed auto-trigger gets it right.
                    Button {
                        startCalibrationRitual()
                    } label: {
                        Label(String(localized: "Calibrate Sync"), systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Listens to Sonos for 30 sec, then aligns AirPlay speakers to match. Re-run if sync drifts.")

                    // Auto-Align (quick) — instant action, uses current
                    // Sonos state. Less accurate than Calibrate Sync if
                    // Sonos is still settling. Power-user shortcut.
                    Button {
                        Log.app.info("Group: Auto-Align (quick)")
                        Task { @MainActor in
                            do {
                                let result = try await CalibrationCoordinator.runSonosPositionAutoAlign()
                                Log.app.notice("Auto-Align ✓ \(result.sonosSinkLabel, privacy: .public): lag \(String(format: "%.0f", result.sonosLagSec * 1000), privacy: .public) ms → AP1 offset \(result.appliedAP1OffsetMs) ms × \(result.ap1SinksUpdated) sink(s)")
                            } catch {
                                Log.app.error("Auto-Align failed: \(String(describing: error), privacy: .public)")
                            }
                        }
                    } label: {
                        Label(String(localized: "Auto-Align (quick)"), systemImage: "bolt")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Run Auto-Align immediately without waiting. Use Calibrate Sync if sync still feels off.")
                }

                // Restart All — snapshot wanted descriptors, stop
                // everything, brief wait for cleanup, then Play All
                // restores the same set. Useful when the user wants
                // to "kick" the sync (e.g., after Sonos has drifted
                // far behind and they want all speakers back in
                // lockstep from a known-good start).
                Button {
                    let wantedSnapshot = allStreamableSinks.filter {
                        session.wantedActive.contains($0.id)
                    }
                    Log.app.info("Group: Restart All (\(wantedSnapshot.count) wanted)")
                    session.stopAll()
                    Task { await session.stopAllSonos() }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        session.startAll(wantedSnapshot)
                    }
                } label: {
                    Label(String(localized: "Restart All"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    Log.app.info("Group: Stop All (\(self.session.activeSinks.count) active)")
                    session.stopAll()
                    Task { await session.stopAllSonos() }
                } label: {
                    Label(String(localized: "Stop All"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
    }

    /// Saved-groups section. Lists each saved group with a one-click play
    /// button + ✕ delete. Shows an inline TextField form when the user
    /// taps "Save current as group…" — needs at least one active sink.
    private var savedGroups: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Groups")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)

            ForEach(groups.groups) { group in
                HStack(spacing: 8) {
                    Button {
                        Log.app.notice("Group play: '\(group.name, privacy: .public)' (\(group.sinkIDs.count) sink(s))")
                        groups.play(group, discoveredSinks: store.sinks)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(.tint)
                            Text(group.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("· \(group.sinkIDs.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        groups.delete(group.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete group '\(group.name)'")
                }
            }

            if session.isAnyActive {
                if showSaveGroupForm {
                    HStack(spacing: 6) {
                        TextField("Group name", text: $newGroupName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($saveGroupFieldFocused)
                            .onSubmit { commitSaveGroup() }
                        Button("Save") { commitSaveGroup() }
                            .controlSize(.small)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            showSaveGroupForm = false
                            newGroupName = ""
                        }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                } else {
                    Button {
                        newGroupName = defaultGroupName()
                        showSaveGroupForm = true
                        // Defer focus so the TextField has rendered.
                        DispatchQueue.main.async { saveGroupFieldFocused = true }
                    } label: {
                        Label("Save current as group…", systemImage: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Suggests "Group N" where N is the next unused index after existing
    /// groups. User can edit before saving.
    private func defaultGroupName() -> String {
        let next = groups.groups.count + 1
        return "Group \(next)"
    }

    /// Pulls current active sink IDs in the same A5-A7-then-Sonos order
    /// we already use for fan-out (AP1 sinks first), saves under the
    /// entered name, collapses the form.
    private func commitSaveGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Preserve the visible-order of sinks (AP1 before Sonos) when
        // saving — start order matters for the M5 shared-capture pump.
        let activeOrdered = allStreamableSinks
            .filter { session.activeSinks.contains($0.id) }
            .map(\.id)
        guard !activeOrdered.isEmpty else { return }
        groups.save(name: name, sinkIDs: activeOrdered)
        newGroupName = ""
        showSaveGroupForm = false
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { muteMacWhilePlaying },
                set: { newValue in
                    muteMacWhilePlaying = newValue
                    session.muteMacWhilePlaying = newValue
                }
            )) {
                Text(String(localized: "Mute Mac speakers while playing"))
            }

            Toggle(isOn: Binding(
                get: { losslessMode },
                set: { newValue in
                    losslessMode = newValue
                    session.losslessMode = newValue
                }
            )) {
                Text(String(localized: "Lossless Mode (force 44.1 kHz output)"))
            }

            Toggle(isOn: $showAllDevices) {
                Text(String(localized: "Show all devices (incl. Macs / iPhones / iPads)"))
            }

            // #110 M6.4 — auto-trigger Mic Calibrate on Play All when
            // Sonos is in the active set. Default ON. Disable for testing
            // or if the brief chirp interruption during Play All bothers
            // the user. The "Mic Calibrate (auto)" button still works
            // manually with this off.
            Toggle(isOn: $autoCalibrateOnPlayAll) {
                Text(String(localized: "Auto-calibrate sync on Play All"))
            }

            // Milestone 2 — arm the Passive Sync Monitor to actually apply
            // corrections. Off = observe only (logs "would apply"). On = it
            // continuously nudges the AirPlay offset to track Sonos, with no
            // calibration tone, from the live music.
            Toggle(isOn: $passiveSyncArmed) {
                Text(String(localized: "Arm passive auto-correct (moves AirPlay offset)"))
            }
            .help("When on, the Passive Sync Monitor moves the AirPlay delay to keep it locked to Sonos — continuously, from the music already playing, no chirp. When off, it only measures and logs what it would do.")

            // M3 hardening 2/2 — toggle for verifying et=1 encrypted ALAC
            // on receivers that require it. Restart sessions after flipping
            // (the toggle is read when each AirPlay 1 session starts).
            Toggle(isOn: $useEncryptedAirPlay) {
                Text(String(localized: "AirPlay encrypted mode (et=1) — restart sessions to apply"))
            }
            .help("Sends ANNOUNCE with et=1 + RSA-OAEP encrypted session key + AES-128-CBC audio payload. Off = et=0 cleartext (default, works on B&W A5/A7). Turn on to test receivers that require encryption.")

            // #118 — switch calibration reference signal. Default off = MLS
            // (friendly brief static); on = the sine-sweep chirp ("wooop").
            Toggle(isOn: $useChirpForCalibration) {
                Text(String(localized: "Use sine-sweep chirp (vs MLS noise) for calibration"))
            }
            .help("Calibration plays a brief reference signal through each speaker to measure arrival lag. Default (off) = MLS — sounds like a half-second of TV static, mathematically optimal correlation. On = the original 200Hz→8kHz sine-sweep chirp.")
        }
        .font(.subheadline)
        .toggleStyle(.checkbox)
    }

    private var quitRow: some View {
        HStack {
            // #102 Diagnostics — opens read-only panel with pipeline state,
            // per-sink offsets/volumes/health, and a Copy-diagnostic-bundle
            // button. Replaces the need to grep OSLog for support triage.
            Button {
                showingDiagnostics = true
            } label: {
                Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
            }
            .controlSize(.small)
            Spacer()
            Button(String(localized: "Quit SuperAudio")) {
                Log.app.info("Quit requested via menu")
                session.stopAll()
                Task {
                    await session.stopAllSonos()
                    await MainActor.run { NSApp.terminate(nil) }
                }
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
    }

    /// Row subtitle: protocol name, plus — for a Sonos that coordinates a
    /// multi-speaker group (M6.6a) — the grouped members it relays to. The
    /// hidden members don't get their own rows, so this is where the user
    /// learns "playing this one also fills Den 2."
    private func subtitle(for descriptor: SinkDescriptor) -> String {
        let base = descriptor.protocolKind.displayName
        guard descriptor.protocolKind == .sonos else { return base }
        let grouped = topology.groupedMemberNames(forCoordinator: descriptor)
        guard !grouped.isEmpty else { return base }
        return "\(base) · group → +\(grouped.joined(separator: ", "))"
    }

    /// Click on a sink row → toggle the session. The slider next to it has
    /// its own gesture recognizer so dragging it does NOT trigger the
    /// toggle button; only clicks on the name/icon area do.
    private func handleSelection(_ descriptor: SinkDescriptor) {
        Log.app.info("Sink selected: \(descriptor.displayName, privacy: .public) (\(descriptor.protocolKind.rawValue, privacy: .public))")

        switch descriptor.protocolKind {
        case .airplay1, .sonos:
            // Unified toggle model — SessionState.toggle dispatches by
            // protocolKind into AirPlay1Session.run or SonosSession.run.
            SessionState.shared.toggle(descriptor)
        case .airplay2:
            // M12 WIP — clicking an AP2 device runs the pair-setup handshake
            // and logs the result. No streaming sink yet; this is the dev
            // test loop for the pairing sub-task. Watch the airplay2 log.
            Log.app.notice("AP2 pair-setup test → \(descriptor.displayName, privacy: .public)")
            Task { @MainActor in
                do {
                    let result = try await AP2PairSetup.run(descriptor: descriptor)
                    Log.app.notice("AP2 pair-setup ✓ \(descriptor.displayName, privacy: .public) — session key \(result.sessionKey.count)B established")
                } catch {
                    Log.app.error("AP2 pair-setup ✗ \(descriptor.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        default:
            Log.app.info("No-op selection — \(descriptor.protocolKind.rawValue, privacy: .public) connection lands in a later phase")
        }
    }

    // MARK: - #98 Mic measurement diagnostic

    private func runMicAutoCalibration() {
        Log.app.notice("Mic Calibrate (auto): starting full per-speaker calibration")
        Task { @MainActor in
            do {
                let result = try await MicCalibrator.runFullCalibration()
                SessionState.shared.markCalibratedNow()
                Log.app.notice("Mic Calibrate (auto) ✓ Sonos lag=\(String(format: "%.3f", result.sonosMeasurement.lagSec), privacy: .public)s; AP1 adjustments applied to \(result.ap1AdjustmentsMs.count) sink(s)")
                for m in result.ap1Measurements {
                    let delta = result.ap1AdjustmentsMs[m.sinkID] ?? 0
                    let new = result.appliedOffsetsMs[m.sinkID] ?? 0
                    Log.app.notice("Mic Calibrate (auto): \(m.label, privacy: .public) measured=\(String(format: "%.3f", m.lagSec), privacy: .public)s SNR=\(String(format: "%.1f", m.snr), privacy: .public) Δ=\(delta)ms → offset=\(new)ms")
                }
            } catch {
                Log.app.error("Mic Calibrate (auto) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func runChirpMicMeasurement() {
        Log.app.notice("Mic Test (chirp): hold Mac still near one speaker — sweep will play briefly")
        Task { @MainActor in
            do {
                let m = try await MicCalibrator.measureWithChirp(chirpDurationSec: 1.0, maxLagSec: 6.0)
                Log.app.notice("Mic Test (chirp) ✓ lag=\(String(format: "%.4f", m.lagSeconds), privacy: .public) s  SNR=\(String(format: "%.1f", m.snr), privacy: .public)")
            } catch {
                Log.app.error("Mic Test (chirp) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - #105 Calibration ritual

    /// Kick off the 30-sec Calibrate Sync ritual.
    ///
    /// Flow:
    ///  - Switch popover to CalibrationView (countdown state)
    ///  - Tick countdown every 1 sec
    ///  - At 0, run Auto-Align math (which restarts AP1 sinks cleanly)
    ///  - Show result OR error
    ///  - User clicks Done → calibrationMode = nil → popover returns
    private func startCalibrationRitual() {
        Log.app.notice("Calibrate Sync: ritual started")
        calibrationMode = .countdown(secondsRemaining: 30)
        Task { @MainActor in
            for s in stride(from: 29, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Bail if the user dismissed the sheet during countdown.
                guard case .countdown = calibrationMode else {
                    Log.app.info("Calibrate Sync: cancelled during countdown")
                    return
                }
                calibrationMode = .countdown(secondsRemaining: s)
            }
            // Bail again right before the measurement in case of late cancel.
            guard case .countdown = calibrationMode else { return }
            calibrationMode = .measuring
            do {
                let result = try await CalibrationCoordinator.runSonosPositionAutoAlign()
                guard calibrationMode != nil else { return }  // dismissed
                calibrationMode = .complete(
                    lagMs: Int(result.sonosLagSec * 1000),
                    ap1OffsetMs: result.appliedAP1OffsetMs,
                    sinkCount: result.ap1SinksUpdated
                )
                Log.app.notice("Calibrate Sync ✓ \(result.sonosSinkLabel, privacy: .public): lag \(Int(result.sonosLagSec * 1000)) ms → AP1 offset \(result.appliedAP1OffsetMs) ms × \(result.ap1SinksUpdated)")
            } catch {
                guard calibrationMode != nil else { return }
                calibrationMode = .failed(message: String(describing: error))
                Log.app.error("Calibrate Sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
