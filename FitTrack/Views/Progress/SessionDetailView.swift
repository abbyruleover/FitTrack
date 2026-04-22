import SwiftUI
import CoreData

/// Per-day session detail. Reached from a Progress chart-tap (a `ProgressPoint`'s
/// date) or any future calendar surface. Lists every `WorkoutSession` whose
/// `startedAt` falls within the chosen date, grouped by exercise name with
/// per-set weight × reps lines.
struct SessionDetailView: View {
    let date: Date

    @FetchRequest private var sessions: FetchedResults<WorkoutSession>

    init(date: Date) {
        self.date = date
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        _sessions = FetchRequest<WorkoutSession>(
            entity: WorkoutSession.entity(),
            sortDescriptors: [NSSortDescriptor(key: "startedAt", ascending: true)],
            predicate: NSPredicate(
                format: "startedAt >= %@ AND startedAt < %@",
                dayStart as NSDate, dayEnd as NSDate
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if sessions.isEmpty {
                    emptyState
                } else {
                    ForEach(sessions, id: \.objectID) { session in
                        SessionCard(session: session)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(dayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No sessions logged on this day")
                .font(Theme.Fonts.body(14))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
    }
}

// MARK: - Session card

private struct SessionCard: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text((session.workoutName ?? "Workout").uppercased())
                    .font(Theme.Fonts.header(18))
                    .foregroundStyle(Theme.Colors.accent)

                HStack(spacing: Theme.Spacing.sm) {
                    Text(timeWindow)
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if let elapsed = elapsedLabel {
                        Text("•")
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text(elapsed)
                            .font(Theme.Fonts.mono(12))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }

            Divider()
                .overlay(Theme.Colors.border)

            ForEach(exerciseGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(Theme.Fonts.header(14))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    ForEach(group.sets, id: \.objectID) { set in
                        Text(setLabel(for: set))
                            .font(Theme.Fonts.mono(13))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private var sortedSets: [LoggedSet] {
        let raw = (session.sets as? Set<LoggedSet>) ?? []
        return raw.sorted { lhs, rhs in
            let l = lhs.completedAt ?? lhs.session?.startedAt ?? Date.distantPast
            let r = rhs.completedAt ?? rhs.session?.startedAt ?? Date.distantPast
            if l != r { return l < r }
            return lhs.setIndex < rhs.setIndex
        }
    }

    private struct ExerciseGroup {
        let name: String
        let sets: [LoggedSet]
    }

    private var exerciseGroups: [ExerciseGroup] {
        var order: [String] = []
        var bucket: [String: [LoggedSet]] = [:]
        for set in sortedSets {
            let key = set.exerciseName ?? "Exercise"
            if bucket[key] == nil {
                order.append(key)
                bucket[key] = []
            }
            bucket[key]?.append(set)
        }
        return order.map { ExerciseGroup(name: $0, sets: bucket[$0] ?? []) }
    }

    private var timeWindow: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let start = session.startedAt.map { f.string(from: $0) } ?? "—"
        let end = session.finishedAt.map { f.string(from: $0) }
        if let end { return "\(start) → \(end)" }
        return "\(start) (in progress)"
    }

    private var elapsedLabel: String? {
        guard let start = session.startedAt else { return nil }
        let end = session.finishedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func setLabel(for set: LoggedSet) -> String {
        let weight = set.weightLbs
        let reps = Int(set.reps)
        let weightStr: String = {
            if weight == 0 { return "BW" }
            if weight.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", weight)
            }
            return String(weight)
        }()
        return "Set \(set.setIndex):  \(weightStr) × \(reps)"
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(date: Date())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
