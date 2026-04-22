import SwiftUI

/// Hevy-style floating mini-pill shown across all tabs while a workout is in
/// flight but the full session view is minimized. Tap the pill to resume
/// (re-presents the cover); tap the trash icon to discard the session and any
/// logged sets.
///
/// Lives in `ContentView` as a safe-area inset so it sits above the tab bar
/// regardless of which tab is foreground.
struct MinimizedSessionPill: View {
    @ObservedObject var service = ActiveSessionService.shared

    var body: some View {
        if let store = service.current, !service.isPresentingSession {
            pill(store: store)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func pill(store: SessionStore) -> some View {
        Button {
            AppLogger.shared.log("Mini-pill tapped → resuming session", category: "ui")
            service.resume()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Colors.background)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.Colors.accent))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Workout")
                            .font(Theme.Fonts.header(13))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(store.elapsedLabel)
                            .font(Theme.Fonts.mono(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    Text(store.currentExerciseName)
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    AppLogger.shared.log("Mini-pill trash tapped → discarding session", category: "ui")
                    service.discard()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Colors.pink)
                        .padding(8)
                        .background(
                            Circle().fill(Theme.Colors.pink.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
