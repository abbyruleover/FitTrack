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
    @State private var confirmingDiscard = false

    var body: some View {
        if let store = service.current, !service.isPresentingSession {
            PillContent(store: store, onResume: { service.resume() }, onTrash: { confirmingDiscard = true })
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .confirmationDialog(
                    "Discard this workout?",
                    isPresented: $confirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard Workout", role: .destructive) {
                        AppLogger.shared.log("Mini-pill trash confirmed → discarding session", category: "ui")
                        service.discard()
                    }
                    Button("Keep Recording", role: .cancel) { }
                } message: {
                    Text("Any sets you've already logged will be removed. This can't be undone.")
                }
        }
    }
}

/// Separated so SwiftUI directly observes the `SessionStore` and re-renders
/// every second when `elapsed` ticks — the parent only observes
/// `ActiveSessionService`, whose publishers don't fire on timer ticks.
private struct PillContent: View {
    @ObservedObject var store: SessionStore
    let onResume: () -> Void
    let onTrash: () -> Void

    var body: some View {
        Button {
            AppLogger.shared.log("Mini-pill tapped → resuming session", category: "ui")
            onResume()
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
                    HStack(spacing: 4) {
                        if let section = store.currentExerciseSection {
                            Text(section.uppercased())
                                .font(Theme.Fonts.mono(9))
                                .foregroundStyle(Theme.Colors.accent.opacity(0.85))
                            Text("·")
                                .font(Theme.Fonts.mono(9))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        Text(store.currentExerciseName)
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    AppLogger.shared.log("Mini-pill trash tapped → asking to confirm discard", category: "ui")
                    onTrash()
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
