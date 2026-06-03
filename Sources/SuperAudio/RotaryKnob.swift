// SuperAudio © 2026 David Puerto. MIT licensed — see LICENSE.md.

import SwiftUI

/// #100 / M6.3 — Rotary knob for fine-tuning the per-sink delay offset.
///
/// User feedback 2026-05-17 / 18: the linear 0–6000ms slider is "too
/// finicky" — a single pixel of horizontal drag covers 50–100 ms which
/// is wider than the human flam threshold (~30 ms). A rotary knob trades
/// pixel-distance-per-millisecond for angle-distance-per-millisecond,
/// which is intrinsically finer because a finger can rotate further than
/// it can slide in a constrained menu width.
///
/// Behavior:
/// - **Drag**: rotate clockwise to add delay, counter-clockwise to subtract.
///   Each full revolution = `revolutionMs` (default 500 ms — empirically
///   readable + ergonomic).
/// - **⌥ (Option/Alt) modifier**: enter fine mode while held; each
///   revolution covers `revolutionMs / 10` instead. For sub-perceptual nudges.
/// - **Double-click**: reset to `defaultValue` (typically 0 or an
///   auto-aligned baseline).
/// - **Bounds**: clamped to `range` (matches the slider's 0–6000 ms).
///
/// Visual: a circle with a small notch indicator that always points at
/// the current rotational position modulo 360°. Numeric label below
/// shows the absolute ms value. Accent color when active (hover/drag).
struct RotaryKnob: View {

    @Binding var value: Int
    let range: ClosedRange<Int>
    var revolutionMs: Int = 500
    var defaultValue: Int = 0
    var diameter: CGFloat = 36

    /// Accumulated rotation angle in radians. Each cumulative 2π → revolutionMs.
    /// Tracks the FULL rotational displacement across multiple revolutions —
    /// the visual notch is `% 2π` but the value isn't.
    @State private var accumulatedAngle: Double = 0
    @State private var dragStartAngle: Double?
    @State private var dragStartValue: Int = 0
    @State private var isHovering: Bool = false
    @State private var fineModifierHeld: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Outer circle.
                Circle()
                    .strokeBorder(isHovering ? Color.accentColor : Color(white: 0.4), lineWidth: 1.5)
                    .background(Circle().fill(Color(white: 0.15)))
                    .frame(width: diameter, height: diameter)

                // Notch indicator — small line from center toward outer edge,
                // rotated to the current "modulo 360°" angle. Always visible
                // so the user knows which way they're spinning.
                Capsule()
                    .fill(isHovering ? Color.accentColor : Color(white: 0.7))
                    .frame(width: 2, height: diameter * 0.35)
                    .offset(y: -diameter * 0.3)
                    .rotationEffect(.radians(notchAngle))

                // Inner dot for visual anchor.
                Circle()
                    .fill(Color(white: 0.35))
                    .frame(width: 4, height: 4)
            }
            .contentShape(Circle())
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                value = clamp(defaultValue)
                accumulatedAngle = angleForValue(value)
            }
            .onHover { isHovering = $0 }
            .help("Drag to dial in delay. ⌥-drag for fine mode (10× slower). Double-click to reset.")

            Text("+\(value) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isHovering ? Color.accentColor : .secondary)
        }
        .onAppear {
            accumulatedAngle = angleForValue(value)
        }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let pointAngle = angle(from: CGPoint(x: diameter / 2, y: diameter / 2),
                                       to: drag.location)
                if dragStartAngle == nil {
                    dragStartAngle = pointAngle
                    dragStartValue = value
                    // Detect ⌥ modifier at gesture start — we don't track it
                    // mid-drag because NSEvent.modifierFlags polling here is
                    // best-effort. SwiftUI macOS 14+ would have a better way
                    // via the .modifierKeyAlternate hook; for now first-tick
                    // capture is enough since users typically hold the key
                    // before dragging.
                    fineModifierHeld = NSEvent.modifierFlags.contains(.option)
                }
                let delta = unwrapDelta(pointAngle - (dragStartAngle ?? 0))
                let effectiveRev = fineModifierHeld ? Double(revolutionMs) / 10.0 : Double(revolutionMs)
                let msDelta = Int((delta / (2 * .pi) * effectiveRev).rounded())
                let newValue = clamp(dragStartValue + msDelta)
                value = newValue
                accumulatedAngle = angleForValue(newValue)
            }
            .onEnded { _ in
                dragStartAngle = nil
                fineModifierHeld = false
            }
    }

    /// Visual notch angle (0…2π). Wraps within a single revolution but
    /// the underlying value tracks the full accumulated delta.
    private var notchAngle: Double {
        accumulatedAngle.truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Compute the angle from `center` to `point` in radians, with 0 at
    /// the 12-o'clock position and increasing clockwise.
    private func angle(from center: CGPoint, to point: CGPoint) -> Double {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        // atan2 returns radians from +x axis CCW; convert to clockwise from 12 o'clock.
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        return a
    }

    /// Map an absolute value into a full-revolution-tracking angle so the
    /// notch starts at the right visual position on first appear.
    private func angleForValue(_ v: Int) -> Double {
        Double(v) / Double(revolutionMs) * 2 * .pi
    }

    /// Avoid wraparound jumps when the drag crosses the 0/2π seam.
    /// If the raw delta is more than ±π, the user actually rotated the
    /// short way around — fix it up.
    private func unwrapDelta(_ raw: Double) -> Double {
        var d = raw
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    private func clamp(_ v: Int) -> Int {
        max(range.lowerBound, min(range.upperBound, v))
    }
}
