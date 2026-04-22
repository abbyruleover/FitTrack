import SwiftUI
import HealthKit
import CoreData

/// Lists everything that happened on a single calendar day. Reached from the
/// Progress tab's calendar dot tap.
///
/// Three states:
///  - **Both FitTrack + Watch HIIT** — list FitTrack rows; tapping each pushes
///    the unified Watch + FitTrack summary (loader resolves the HK workout).
///  - **FitTrack only** — same row layout, unified view will show no HK ring.
///  - **Watch HIIT only** — render a dedicated row that pushes
///    `WatchHIITOnlyView` (no Core Data session to attach to). Useful for
///    classes the user attended but didn't bother to log sets for.
///  - **Neither** — empty state.
struct SessionDayView: View {
    let date: Date

    @FetchRequest private var sessions: FetchedResults<WorkoutSession>
    @State private var hkWorkout: HKWorkout?
    @State private var hkLoaded = false

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
                if !sessions.isEmpty {
                    ForEach(sessions, id: \.objectID) { session in
                        NavigationLink(value: ProgressUnifiedSessionRoute(sessionID: session.objectID)) {
                            SessionDayRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                } else if hkLoaded, let hk = hkWorkout {
                    NavigationLink(value: WatchHIITOnlyRoute(day: Calendar.current.startOfDay(for: date))) {
                        WatchHIITOnlyRow(workout: hk)
                    }
                    .buttonStyle(.plain)
                } else if hkLoaded {
                    emptyState
                } else {
                    loadingPlaceholder
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
        .task {
            // Always probe HK regardless of FitTrack rows — even if FitTrack
            // sessions exist, we want to know whether to fall through to a
            // Watch-only row when none do. Idempotent.
            hkWorkout = await HealthKitService.shared.hiitWorkout(on: date)
            hkLoaded = true
            AppLogger.shared.log("SessionDayView appeared — \(dayLabel) sessions=\(sessions.count) hk=\(hkWorkout != nil)", category: "ui")
        }
    }

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    private var loadingPlaceholder: some View {
        HStack {
            Spacer()
            SwiftUI.ProgressView().tint(Theme.Colors.accent)
            Spacer()
        }
        .frame(minHeight: 80)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No sessions on this day")
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

// MARK: - Watch-only row

/// Row variant for days where only an Apple Watch HIIT workout exists
/// (no FitTrack session). Visually mirrors `SessionDayRow` so the calendar
/// drill-in feels consistent.
struct WatchHIITOnlyRow: View {
    let workout: HKWorkout

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.pink.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "applewatch")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.pink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Watch HIIT")
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text(metaLabel)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    if let chip = ClassSchedule.slotChip(for: workout.startDate) {
                        Text(chip)
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                Capsule().stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1)
                            )
                    }
                    Text("WATCH ONLY")
                        .font(Theme.Fonts.mono(9))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(
                            Capsule().stroke(Theme.Colors.border, lineWidth: 1)
                        )
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var metaLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let mins = Int(workout.duration) / 60
        return "\(f.string(from: workout.startDate)) · \(mins) min"
    }
}

// MARK: - Row

/// Compact session-row used in SessionDayView and AllWorkoutsListView.
/// Shows workout name, time, set count, and a chevron — UnifiedSessionView
/// has the full breakdown so we keep this row light.
struct SessionDayRow: View {
    let session: WorkoutSession

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.pink.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.pink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.workoutName ?? "Workout")
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(metaLabel)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    if let chip = classChip {
                        Text(chip)
                            .font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                Capsule().stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1)
                            )
                    }
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var metaLabel: String {
        let setCount = (session.sets as? Set<LoggedSet>)?.count ?? 0
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let time = session.startedAt.map { f.string(from: $0) } ?? "—"
        return "\(time) · \(setCount) sets"
    }

    /// Slot chip ("6:15 AM" / "8:30 AM") when the session lands in a known
    /// Equinox class slot. Nil on Sunday or off-grid times — the row falls
    /// back to plain time-of-day.
    private var classChip: String? {
        guard let started = session.startedAt else { return nil }
        return ClassSchedule.slotChip(for: started)
    }
}

// MARK: - Routes

/// Hashable navigation value used by ProgressView's stack to push the
/// unified Watch+FitTrack summary. The destination resolver fetches the
/// matching HKWorkout via `HealthKitService.hiitWorkout(on:)`.
struct ProgressUnifiedSessionRoute: Hashable {
    let sessionID: NSManagedObjectID
}

/// Pushed when the calendar day has only an Apple Watch HIIT workout
/// (no FitTrack session). The destination view re-fetches the workout via
/// `HealthKitService.hiitWorkout(on:)`. We carry just the `day` (Date) since
/// `HKWorkout` is not Hashable; one HIIT-per-day is the user's reality.
struct WatchHIITOnlyRoute: Hashable {
    let day: Date
}

#Preview {
    NavigationStack {
        SessionDayView(date: Date())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
