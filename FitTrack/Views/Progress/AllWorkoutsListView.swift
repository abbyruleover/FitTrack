import SwiftUI
import CoreData

/// Chronological list of all FitTrack sessions whose date has a matching
/// Apple Watch HIIT workout. Reached from the Progress tab's "Workouts >"
/// header. Tap a row → unified Watch+FitTrack summary.
struct AllWorkoutsListView: View {
    @FetchRequest(
        entity: WorkoutSession.entity(),
        sortDescriptors: [NSSortDescriptor(key: "startedAt", ascending: false)]
    ) private var sessions: FetchedResults<WorkoutSession>

    @State private var hiitDays: Set<Date> = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if !loaded {
                    SwiftUI.ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Colors.accent)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if matchedSessions.isEmpty {
                    emptyState
                } else {
                    ForEach(matchedSessions, id: \.objectID) { session in
                        NavigationLink(value: ProgressUnifiedSessionRoute(sessionID: session.objectID)) {
                            SessionDayRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("All Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            hiitDays = await HealthKitService.shared.hiitWorkoutDates(days: 365)
            loaded = true
            AppLogger.shared.log("AllWorkoutsListView loaded — \(matchedSessions.count) HIIT-matched of \(sessions.count) total", category: "ui")
        }
    }

    /// Sessions whose `startedAt` falls on a day with at least one HIIT
    /// HKWorkout. The HKWorkout itself isn't fetched here — the row's
    /// destination resolver handles that — we just gate the list.
    private var matchedSessions: [WorkoutSession] {
        let cal = Calendar.current
        return sessions.filter { session in
            guard let started = session.startedAt else { return false }
            return hiitDays.contains(cal.startOfDay(for: started))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "applewatch")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No matched workouts")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Sessions show up here once Apple Watch logs a HIIT workout on the same day.")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
    }
}

#Preview {
    NavigationStack {
        AllWorkoutsListView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
