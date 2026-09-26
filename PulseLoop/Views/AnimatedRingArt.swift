import SwiftUI

/// The pairing flow's living ring: `RingArtView` that floats, breathes an accent glow and carries a light
/// sweep orbiting its band. Mirrors Android `AnimatedRingArt` (same phases, periods and amplitudes).
///
/// * idle — float ±4 pt (3 s each way, ease-in-out), glow opacity 0.25↔0.5 (2.4 s each way), one sweep
///   pass every 2.8 s;
/// * searching — glow and sweep run at double speed (the float keeps its pace);
/// * paired — one settle pulse (scale 1.0 → 1.08 → 1.0) with a success-tint ring flash, then idle motion;
/// * Reduce Motion — static ring, static soft glow, no sweep (paired shows a steady success ring instead).
///
/// App-only (lives in `Views/`, not `DesignSystem/`), so the widget extensions never compile it.
struct AnimatedRingArt: View {
    enum Phase: Equatable {
        case idle, searching, paired
    }

    var tint: Color
    var size: CGFloat = 180
    var imageName: String? = nil
    var phase: Phase = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The glow + sweep clock runs at 1× or 2×. It is integrated (anchor + elapsed × rate) rather than
    /// computed as `now × rate`, so switching speed never makes the sweep jump.
    @State private var clockAnchorDate = Date().timeIntervalSinceReferenceDate
    @State private var clockAnchorValue: Double = 0
    @State private var settleTrigger = 0

    // Motion constants — keep equal to Android.
    static let floatAmplitude: CGFloat = 4
    static let floatHalfPeriod: Double = 3.0
    static let glowRange: ClosedRange<Double> = 0.25...0.5
    static let glowHalfPeriod: Double = 2.4
    static let sweepPeriod: Double = 2.8
    static let settleScale: CGFloat = 1.08
    static let staticGlow: Double = 0.35

    static func speed(for phase: Phase) -> Double { phase == .searching ? 2 : 1 }

    var body: some View {
        Group {
            if reduceMotion {
                layers(float: 0, glow: Self.staticGlow, sweepDegrees: nil)
            } else {
                TimelineView(.animation) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let fast = clockValue(at: now)
                    layers(
                        float: Self.floatOffset(at: now),
                        glow: Self.glowOpacity(at: fast),
                        sweepDegrees: Self.sweepDegrees(at: fast)
                    )
                }
            }
        }
        .keyframeAnimator(initialValue: SettleFrame(), trigger: settleTrigger) { content, frame in
            content
                .scaleEffect(frame.scale)
                .overlay {
                    Circle()
                        .strokeBorder(AgaraColors.success, lineWidth: 3)
                        .scaleEffect(frame.ringScale)
                        .opacity(frame.flash)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(1.0)
                SpringKeyframe(Self.settleScale, duration: 0.22, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
            }
            KeyframeTrack(\.flash) {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.12)
                LinearKeyframe(0, duration: 0.6)
            }
            KeyframeTrack(\.ringScale) {
                MoveKeyframe(1.0)
                CubicKeyframe(1.14, duration: 0.72)
            }
        }
        .overlay {
            if reduceMotion && phase == .paired {
                Circle().strokeBorder(AgaraColors.success, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            if phase == .paired { settle() }
        }
        .onChange(of: phase) { old, new in
            let now = Date().timeIntervalSinceReferenceDate
            clockAnchorValue += (now - clockAnchorDate) * Self.speed(for: old)
            clockAnchorDate = now
            if new == .paired { settle() }
        }
    }

    private func settle() {
        guard !reduceMotion else { return }
        settleTrigger += 1
    }

    private func clockValue(at now: TimeInterval) -> Double {
        clockAnchorValue + max(0, now - clockAnchorDate) * Self.speed(for: phase)
    }

    // MARK: - Motion curves (pure, so they are testable)

    /// Sinusoidal ease-in-out between -amplitude (up) and +amplitude over `2 × floatHalfPeriod`.
    static func floatOffset(at t: TimeInterval) -> CGFloat {
        -floatAmplitude * CGFloat(sin(2 * .pi * t / (2 * floatHalfPeriod)))
    }

    /// Breathes between the ends of `glowRange`, one breath every `2 × glowHalfPeriod` of clock time.
    static func glowOpacity(at clock: Double) -> Double {
        let unit = 0.5 - 0.5 * cos(2 * .pi * clock / (2 * glowHalfPeriod))
        return glowRange.lowerBound + (glowRange.upperBound - glowRange.lowerBound) * unit
    }

    /// Sweep angle in degrees, one full orbit per `sweepPeriod` of clock time.
    static func sweepDegrees(at clock: Double) -> Double {
        (clock / sweepPeriod).truncatingRemainder(dividingBy: 1) * 360
    }

    // MARK: - Layers

    private func layers(float: CGFloat, glow: Double, sweepDegrees: Double?) -> some View {
        ZStack {
            // Breathing accent glow behind the platter.
            Circle()
                .fill(AgaraColors.accent)
                .frame(width: size * 1.02, height: size * 1.02)
                .blur(radius: size * 0.16)
                .opacity(glow)

            RingArtView(tint: tint, size: size, imageName: imageName)
                .overlay {
                    if let sweepDegrees {
                        // A short bright arc riding the platter's rim: the "light sweep".
                        Circle()
                            .strokeBorder(
                                AngularGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0), location: 0),
                                        .init(color: Color.white.opacity(0), location: 0.72),
                                        .init(color: AgaraColors.accent.opacity(0.55), location: 0.9),
                                        .init(color: Color.white.opacity(0.95), location: 0.98),
                                        .init(color: Color.white.opacity(0), location: 1),
                                    ],
                                    center: .center
                                ),
                                lineWidth: max(2, size * 0.03)
                            )
                            .rotationEffect(.degrees(sweepDegrees))
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                }
        }
        .offset(y: float)
    }
}

private struct SettleFrame {
    var scale: CGFloat = 1
    var flash: Double = 0
    var ringScale: CGFloat = 1
}
