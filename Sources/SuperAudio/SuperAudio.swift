// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import SwiftUI

@main
struct SuperAudio: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarIcon()
        }
        // `.window` style hosts the menu as a SwiftUI popover with full
        // layout support (HStack, Slider, etc.) instead of the traditional
        // menu where only Button/Toggle work cleanly. Required for the
        // per-sink volume sliders shipped 2026-05-15. Also unlocks the
        // per-sink offset slider (M5) and the EQ visualization (M11)
        // without further refactor.
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar icon. Static `hifispeaker.2` glyph at all times so the menu
/// bar stays calm; when any sink is active, a small **pulsing accent dot**
/// overlays the bottom-right corner so the user has a passive cue that
/// audio is flowing. Matches Apple's own menu-bar conservatism (icon
/// itself doesn't animate; the dot is the active-state signal).
///
/// Dot color = SuperAudio brand accent (orange). Visible enough to spot
/// without being alarm-red. Pulses via SF Symbol's `.pulse` effect on a
/// `circle.fill` glyph — battery-friendly, no Timer needed, the OS
/// schedules the animation efficiently.
///
/// Driven by `SessionState.shared.isAnyActive`. When the active set
/// transitions from empty to non-empty, the dot appears; transitions
/// back, the dot disappears.
struct MenuBarIcon: View {
    private let session = SessionState.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "hifispeaker.2")
            if session.isAnyActive {
                // Calibrating: blue ring overlay around the active dot.
                // Visually distinct from the steady-state orange pulse —
                // the user sees "something extra is happening" without a
                // modal. Reverts to plain orange dot when calibration ends.
                if session.isCalibrating {
                    Image(systemName: "circle")
                        .resizable()
                        .frame(width: 9, height: 9)
                        .foregroundStyle(Color(red: 0.25, green: 0.58, blue: 1.0))
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                        .offset(x: -1, y: -1)
                }
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.24))
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityLabel(
            session.isCalibrating ? Text("SuperAudio — calibrating sync")
            : session.isAnyActive ? Text("SuperAudio — playing")
            : Text("SuperAudio — idle")
        )
    }
}
