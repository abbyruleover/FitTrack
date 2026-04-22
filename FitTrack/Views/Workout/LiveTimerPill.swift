import SwiftUI

/// Toolbar pill rendered in the leading slot of `WorkoutSessionView` while a
/// session is in progress. Replaces the bare elapsed-time `Text` that the
/// system was visually truncating to "00..." when the title was long.
///
/// The arc on the left fills from the user's session-length baseline (rolling
/// avg of recent finished sessions). Once `fraction` exceeds 1.0 the arc swaps
/// to pink and starts a second, overlaid loop — a visual hint that the user
/// has gone past their usual session length without making the pill resize.
///
/// A pulsing pink dot leads the pill so the user can tell at a glance that a
/// session is recording — earlier builds were too quiet and people lost track
/// of the live state.
struct LiveTimerPill: View {
    let elapsedLabel: String
    let fraction: Double

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            liveDot
            arc
            Text(elapsedLabel)
                .font(Theme.Fonts.mono(15))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Theme.Colors.accent.opacity(0.14))
        )
        .overlay(
            Capsule().stroke(Theme.Colors.accent.opacity(0.7), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var liveDot: some View {
        Circle()
            .fill(Theme.Colors.pink)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.45 : 1.0)
    }

    private var arc: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.accent.opacity(0.20), lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(
                    Theme.Colors.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(-90))
            if fraction > 1 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(fraction - 1, 1)))
                    .stroke(
                        Theme.Colors.pink,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        LiveTimerPill(elapsedLabel: "12:34", fraction: 0.4)
        LiveTimerPill(elapsedLabel: "45:00", fraction: 0.95)
        LiveTimerPill(elapsedLabel: "1:12:00", fraction: 1.4)
    }
    .padding()
    .background(Theme.Colors.background)
    .preferredColorScheme(.dark)
}
