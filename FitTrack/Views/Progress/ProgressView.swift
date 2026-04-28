import SwiftUI
import HealthKit
import CoreData
import WidgetKit

/// Progress tab — top-level dashboard with two stacked sections:
///   • Exercises  — horizontal carousel of large PR cards
///   • Workouts   — month calendar with pink dots on session days
/// Section headers are tappable chevrons that push to full-list views.
struct ProgressView: View {
    @FetchRequest(
        entity: LoggedSet.entity(),
        sortDescriptors: [NSSortDescriptor(key: "completedAt", ascending: false)]
    ) private var sets: FetchedResults<LoggedSet>

    /// Loaded eagerly so the calendar tap can decide synchronously how many
    /// FitTrack sessions live on a given day, without a Core Data round-trip
    /// inside the gesture handler. Sorted oldest-first because we filter by
    /// date range, not order.
    @FetchRequest(
        entity: WorkoutSession.entity(),
        sortDescriptors: [NSSortDescriptor(key: "startedAt", ascending: true)]
    ) private var allSessions: FetchedResults<WorkoutSession>

    @State private var hiitDays: Set<Date> = []
    @State private var path = NavigationPath()

    // Live HK values for the "This Week" tiles. Loaded in .task; nil while
    // loading or if HealthKit is denied / unavailable.
    @State private var hrvMs: Double?
    @State private var weeklyKcal: Double?
    @State private var weeklyExerciseMin: Int?
    @State private var recentWorkouts: [HKWorkout] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    workoutsSection
                    thisWeekSection
                    exercisesSection
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle(AppStrings.Tabs.progress)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: String.self) { name in
                ExerciseProgressDetailView(exerciseName: name)
            }
            .navigationDestination(for: AllExercisesRoute.self) { _ in
                AllExercisesListView()
            }
            .navigationDestination(for: AllWorkoutsRoute.self) { _ in
                AllWorkoutsListView()
            }
            .navigationDestination(for: CalendarDayRoute.self) { route in
                SessionDayView(date: route.day)
            }
            .navigationDestination(for: ProgressUnifiedSessionRoute.self) { route in
                ProgressUnifiedSessionLoader(sessionID: route.sessionID)
            }
            .navigationDestination(for: HRChartRoute.self) { route in
                HRChartLoader(sessionID: route.sessionID)
            }
            .navigationDestination(for: WatchHIITOnlyRoute.self) { route in
                WatchHIITOnlyView(day: route.day)
            }
            .navigationDestination(for: WatchOnlyHRChartRoute.self) { route in
                WatchOnlyHRChartLoader(day: route.day)
            }
            .task {
                hiitDays = await HealthKitService.shared.hiitWorkoutDates(days: 365)
                // Cache for the home screen widget (can't use HealthKit from extensions)
                if let shared = UserDefaults(suiteName: PersistenceController.appGroupID) {
                    shared.set(hiitDays.map { $0.timeIntervalSince1970 }, forKey: "cachedHiitDays")
                }
                WidgetCenter.shared.reloadAllTimelines()
                async let h = HealthKitService.shared.latestHRVms()
                async let k = HealthKitService.shared.weeklyActiveEnergyKcal()
                async let m = HealthKitService.shared.weeklyExerciseMinutes()
                async let wk = HealthKitService.shared.recentWorkouts(limit: 20)
                let (hv, kv, mv, wkv) = await (h, k, m, wk)
                hrvMs = hv
                weeklyKcal = kv
                weeklyExerciseMin = mv
                recentWorkouts = wkv
                AppLogger.shared.log("ProgressView loaded — \(records.count) PRs, \(hiitDays.count) HIIT days, kcal=\(kv ?? -1)", category: "ui")
            }
        }
    }

    // MARK: - This Week section

    /// Four colored "This Week" tiles at the top of Progress: Active Energy
    /// (kcal, red), Exercise (min, green), Workouts (count, blue), HRV (ms,
    /// pink). Sourced from HealthKit so the values match what users see in
    /// Apple Fitness / Health. These moved from the deleted Health tab.
    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("This Week")
                .font(Theme.Fonts.header(20))
                .foregroundStyle(Theme.Colors.textPrimary)
            HStack(spacing: Theme.Spacing.sm) {
                bigStatCard(value: weeklyKcal.map { "\(Int($0))" } ?? "—",
                            unit: "CAL",
                            label: "Active Energy",
                            color: .red,
                            icon: "flame.fill")
                bigStatCard(value: weeklyExerciseMin.map { "\($0)" } ?? "—",
                            unit: "MIN",
                            label: "Exercise",
                            color: .green,
                            icon: "figure.run")
            }
            HStack(spacing: Theme.Spacing.sm) {
                bigStatCard(value: "\(weekWorkoutCount)",
                            unit: "WKT",
                            label: "Workouts",
                            color: .blue,
                            icon: "dumbbell.fill")
                bigStatCard(value: hrvMs.map { "\(Int($0))" } ?? "—",
                            unit: "MS",
                            label: "HRV",
                            color: .pink,
                            icon: "waveform.path.ecg")
            }
        }
    }

    private var weekWorkoutCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return recentWorkouts.filter { $0.startDate >= cutoff }.count
    }

    /// Bold-number / faint-label tile mirroring the Apple Fitness summary.
    private func bigStatCard(value: String, unit: String, label: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                Text(label.uppercased())
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(color.opacity(0.7))
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
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Exercises section

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader(label: "Exercises", route: AllExercisesRoute())
            if records.isEmpty {
                emptyExercises
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(records.prefix(12)) { record in
                            NavigationLink(value: record.exerciseName) {
                                ExercisePRCard(record: record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyExercises: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No PRs yet")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Finish a workout to see your top lifts here.")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
    }

    // MARK: - Workouts section

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader(label: "Workouts", route: AllWorkoutsRoute())
            workoutCountTiles
            WorkoutCalendarView(dayInfo: computedDayInfo) { day in
                AppLogger.shared.log("calendar day tapped → \(day)", category: "ui")
                routeCalendarTap(day)
            }
        }
    }

    private var computedDayInfo: [Date: WorkoutCalendarView.DaySource] {
        let cal = Calendar.current
        let fittrackDays: Set<Date> = Set(allSessions.compactMap {
            guard let d = $0.startedAt else { return nil }
            return cal.startOfDay(for: d)
        })
        var info: [Date: WorkoutCalendarView.DaySource] = [:]
        for d in hiitDays.union(fittrackDays) {
            let hasWatch = hiitDays.contains(d)
            let hasFT = fittrackDays.contains(d)
            info[d] = hasWatch && hasFT ? .both : (hasFT ? .fittrackOnly : .watchOnly)
        }
        return info
    }

    /// 1-click router for calendar taps. The old flow always pushed
    /// `SessionDayView` as an intermediate picker — even when there was only
    /// one session on the day, which made tapping a tile a needless two-step.
    /// Now we look at what the day actually has and jump straight to the
    /// right destination. Multi-session days still get the picker.
    private func routeCalendarTap(_ day: Date) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }

        let daySessions = allSessions.filter {
            guard let s = $0.startedAt else { return false }
            return s >= dayStart && s < dayEnd
        }
        let hasWatch = hiitDays.contains(dayStart)

        switch (daySessions.count, hasWatch) {
        case (1, _):
            path.append(ProgressUnifiedSessionRoute(sessionID: daySessions[0].objectID))
        case (0, true):
            path.append(WatchHIITOnlyRoute(day: dayStart))
        case (0, false):
            // Marker shouldn't have been visible — no-op rather than push an
            // empty picker.
            AppLogger.shared.log("calendar tap on \(dayStart) ignored — no sessions/HIIT", category: "ui")
        default:
            // 2+ FitTrack sessions on one day → keep the picker so the user
            // can choose which one to open.
            path.append(CalendarDayRoute(day: day))
        }
    }

    /// Two stat tiles above the calendar — count of HIIT days this calendar
    /// month and YTD. Sourced from `hiitDays` (Watch HIIT Set<Date>) since the
    /// user counts a workout as anything the Watch logged as HIIT, regardless
    /// of whether a FitTrack session was logged alongside it.
    private var workoutCountTiles: some View {
        HStack(spacing: Theme.Spacing.sm) {
            countTile(label: "THIS MONTH", value: "\(monthCount)")
            countTile(label: "YTD", value: "\(ytdCount)")
        }
    }

    private func countTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.accent)
                Text("workouts")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Section header

    private func sectionHeader<Route: Hashable>(label: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(Theme.Fonts.header(20))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    private var records: [ProgressAggregator.PersonalRecord] {
        ProgressAggregator.personalRecords(from: Array(sets))
    }

    /// Count of HIIT days landing in the current calendar month.
    private var monthCount: Int {
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        return hiitDays.filter { d in
            cal.component(.month, from: d) == month && cal.component(.year, from: d) == year
        }.count
    }

    /// Count of HIIT days landing in the current calendar year.
    private var ytdCount: Int {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        return hiitDays.filter { cal.component(.year, from: $0) == year }.count
    }
}

// MARK: - Routes

/// Sentinel route values for ProgressView's section-header pushes. Empty
/// structs because the destination is fully determined by type.
private struct AllExercisesRoute: Hashable {}
private struct AllWorkoutsRoute: Hashable {}

/// Carries the tapped calendar day into the SessionDayView push.
struct CalendarDayRoute: Hashable {
    let day: Date
}

// MARK: - Carousel card

/// Large PR card used in the Exercises horizontal carousel. ~280pt wide,
/// echoes Liftin's exercise card layout: icon + name on the left, big
/// rounded weight number on the right with the PR date below it.
private struct ExercisePRCard: View {
    let record: ProgressAggregator.PersonalRecord

    var body: some View {
        let glyph = ExerciseIcon.glyph(for: record.exerciseName)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(glyph.tint.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: glyph.systemName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(glyph.tint)
                }
                Spacer()
                Text("WEIGHT PR")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(weightLabel)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.accent)
                Text("lbs")
                    .font(Theme.Fonts.mono(13))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(record.exerciseName)
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                Spacer()
                Text(dateLabel)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 280, height: 180, alignment: .topLeading)
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

    private var weightLabel: String {
        let w = record.bestWeightLbs
        if w == 0 { return "BW" }
        if w.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", w)
        }
        return String(format: "%.1f", w)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: record.lastPerformed)
    }
}

// MARK: - Unified session loader

/// Wraps `UnifiedSessionView` so we can async-fetch the matching HKWorkout
/// before rendering. Without this wrapper we'd either block the navigation
/// push on a HealthKit query or render with `hkWorkout: nil` first then
/// have no way to swap it in (UnifiedSessionView's hkWorkout is `let`).
struct ProgressUnifiedSessionLoader: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var context
    @State private var session: WorkoutSession?
    @State private var hkWorkout: HKWorkout?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let session {
                UnifiedSessionView(session: session, hkWorkout: hkWorkout)
            } else {
                VStack {
                    SwiftUI.ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Colors.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.background.ignoresSafeArea())
            }
        }
        .task {
            session = (try? context.existingObject(with: sessionID)) as? WorkoutSession
            if let s = session, let date = s.startedAt {
                hkWorkout = await HealthKitService.shared.hiitWorkout(on: date)
            }
            loaded = true
            AppLogger.shared.log("ProgressUnifiedSessionLoader resolved — hk=\(hkWorkout != nil)", category: "ui")
        }
    }
}

#Preview {
    ProgressView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
