import SwiftUI
import UniformTypeIdentifiers
import CoreData
import HealthKit

/// Phase 5 home dashboard. Activity rings card at the top (taps into the
/// Health app), then a "This Week" horizontal carousel of scheduled
/// `WorkoutDay` rows (lime border on today, dim on past), then today's
/// matched HIIT activity if both Watch + FitTrack halves exist. Body metrics
/// and InBody charts moved to the Body tab; this screen focuses on training.
struct WorkoutView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutDay.date, ascending: true)]
    ) private var allWorkoutDays: FetchedResults<WorkoutDay>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutSession.startedAt, ascending: false)]
    ) private var sessions: FetchedResults<WorkoutSession>

    @State private var isImporting = false
    @State private var importError: String?
    @State private var importProgress: ImportProgress?
    @State private var bannerDismissed = false
    @State private var todaysHIIT: HKWorkout?
    @ObservedObject private var logger = AppLogger.shared

    /// Live state for the import overlay. The on-device LLM takes ~10s per
    /// PDF; for a six-file bulk import the user otherwise just stares at a
    /// frozen screen. We surface a deterministic "X of N" plus the current
    /// filename and which path is doing the work (LLM vs. regex fallback).
    struct ImportProgress: Equatable {
        var current: Int          // 1-based index of the file being parsed
        var total: Int
        var filename: String
        var phase: Phase

        enum Phase: String { case parsing, saving }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    headerRow

                    if shouldShowBanner { reminderBanner }

                    thisWeekSection

                    if let day = todaysWorkoutDay {
                        todaysHighlightsCard(day: day, session: todaysSession, hiit: todaysHIIT)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .background(Theme.Colors.background.ignoresSafeArea())
            .overlay {
                if let p = importProgress {
                    importOverlay(p)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WorkoutDay.self) { day in
                WorkoutDetailView(workout: ParsedWorkout(from: day), workoutDay: day)
                    .onAppear {
                        let label = day.date.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                        AppLogger.shared.log("nav → WorkoutDetailView for day=\(label) completed=\(day.isCompleted)", category: "ui")
                    }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert("Import failed", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .navigationDestination(for: SettingsRoute.self) { _ in
                SettingsView()
            }
            .navigationDestination(for: UnifiedSessionRoute.self) { route in
                if let session = try? context.existingObject(with: route.sessionID) as? WorkoutSession {
                    UnifiedSessionView(session: session, hkWorkout: todaysHIIT)
                        .onAppear {
                            AppLogger.shared.log("nav → UnifiedSessionView session=\(session.workoutName ?? "?")", category: "ui")
                        }
                }
            }
            .navigationDestination(for: HRChartRoute.self) { route in
                HRChartLoader(sessionID: route.sessionID)
                    .environment(\.managedObjectContext, context)
            }
            .onAppear {
                AppLogger.shared.log("WorkoutView appeared (\(allWorkoutDays.count) total scheduled days)", category: "ui")
                ReminderService.scheduleNextWeekReminderIfNeeded(context: context)
                Task {
                    await HealthKitService.shared.requestAuthorizationIfNeeded()
                    todaysHIIT = await HealthKitService.shared.todaysHIITWorkout()
                }
            }
        }
    }

    /// Sentinel value used purely to drive the `.navigationDestination` for
    /// the gear → Settings push. Keeps the destination registration alongside
    /// the `WorkoutDay` one instead of inlining a `NavigationLink { … }`.
    private struct SettingsRoute: Hashable {}

    /// Route value for the unified Watch+FitTrack session screen. Carries the
    /// session's `NSManagedObjectID` so the destination resolver can refault
    /// it from Core Data, plus the optional Watch HKWorkout (passed through
    /// the parent's state since `HKWorkout` isn't directly Hashable).
    struct UnifiedSessionRoute: Hashable {
        let sessionID: NSManagedObjectID
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppStrings.Tabs.home)
                .font(Theme.Fonts.header(34))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
            NavigationLink(value: SettingsRoute()) {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(importProgress != nil)
            .opacity(importProgress != nil ? 0.4 : 1.0)
            .simultaneousGesture(TapGesture().onEnded {
                AppLogger.shared.log("gear button tapped → pushing SettingsView", category: "ui")
            })
        }
    }

    // MARK: - Banner

    private var shouldShowBanner: Bool {
        guard !bannerDismissed else { return false }
        return WeekScheduler.currentWeekHasGaps(context: context)
    }

    private var reminderBanner: some View {
        Button {
            AppLogger.shared.log("reminder banner tapped → opening file importer", category: "ui")
            isImporting = true
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Colors.background)

                VStack(alignment: .leading, spacing: 2) {
                    Text("This week has gaps")
                        .font(Theme.Fonts.header(13))
                        .foregroundStyle(Theme.Colors.background)
                    Text("Tap to upload Monday–Saturday WODs.")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.background.opacity(0.85))
                }

                Spacer(minLength: 0)

                // Inner button — `.plain` style so the parent Button doesn't
                // hijack the tap; this gives the user a way to dismiss
                // without launching the importer.
                Button {
                    AppLogger.shared.log("reminder banner dismissed", category: "ui")
                    bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.background)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.accent)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - This Week section

    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if thisWeekDays.isEmpty {
                emptyWeekCard
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.md) {
                        ForEach(thisWeekDays, id: \.objectID) { day in
                            NavigationLink(value: day) {
                                DayCard(day: day, isToday: isToday(day), isPast: isPast(day))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var emptyWeekCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("No workouts scheduled for this week")
                .font(Theme.Fonts.body(14))
                .foregroundStyle(Theme.Colors.textSecondary)
            Button {
                AppLogger.shared.log("emptyWeekCard → Import this week's PDFs tapped", category: "ui")
                isImporting = true
            } label: {
                Text("Import this week's PDFs")
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.background)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Capsule().fill(Theme.Colors.accent))
            }
            .buttonStyle(.plain)
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

    // MARK: - Derived state

    private var thisWeekDays: [WorkoutDay] {
        let monday = WeekScheduler.activeMonday()
        let week = WeekScheduler.mondayThroughSaturday(weekStarting: monday)
        guard let first = week.first, let last = week.last else { return [] }
        let cal = Calendar(identifier: .gregorian)
        let lo = cal.startOfDay(for: first)
        let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last
        return allWorkoutDays.filter {
            guard let d = $0.date else { return false }
            return d >= lo && d < hi
        }
    }

    private func isToday(_ day: WorkoutDay) -> Bool {
        guard let d = day.date else { return false }
        return Calendar.current.isDate(d, inSameDayAs: Date())
    }

    private func isPast(_ day: WorkoutDay) -> Bool {
        guard let d = day.date else { return false }
        let cal = Calendar.current
        return cal.startOfDay(for: d) < cal.startOfDay(for: Date())
    }

    // MARK: - Import overlay

    /// Full-screen scrim with a card showing "Importing X of Y" plus the
    /// current filename and a determinate progress bar. The on-device LLM is
    /// our slow leg (~10s per file) and there's nothing to interact with
    /// during the wait, so we block input.
    @ViewBuilder
    private func importOverlay(_ p: ImportProgress) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .allowsHitTesting(true)

            VStack(spacing: Theme.Spacing.md) {
                SwiftUI.ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)

                Text(p.phase == .saving ? "Saving…" : "Parsing with Apple Intelligence")
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)

                if p.phase == .parsing, p.total > 0 {
                    Text("\(p.current) of \(p.total) — \(p.filename)")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    SwiftUI.ProgressView(value: Double(p.current - 1) + 0.5, total: Double(p.total))
                        .tint(Theme.Colors.accent)
                        .frame(width: 220)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 320)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: p)
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        AppLogger.shared.log("fileImporter completed", category: "import")
        switch result {
        case .success(let urls):
            AppLogger.shared.log("URLs received: count=\(urls.count)", category: "import")
            guard !urls.isEmpty else {
                AppLogger.shared.log("urls empty — aborting", category: "import")
                return
            }
            // Capture security-scoped access for the duration of the async
            // work. We can't rely on a `defer` inside a sync function because
            // the parse hop runs on another task — so claim and release
            // explicitly inside the Task.
            let scoped: [(URL, Bool)] = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            let total = scoped.count
            importProgress = ImportProgress(current: 0, total: total, filename: "", phase: .parsing)
            Task {
                defer {
                    for (u, ok) in scoped where ok { u.stopAccessingSecurityScopedResource() }
                }
                var pairs: [(filename: String, workout: ParsedWorkout)] = []
                for (idx, entry) in scoped.enumerated() {
                    let (url, ok) = entry
                    let basename = url.deletingPathExtension().lastPathComponent
                    AppLogger.shared.log("processing \(url.lastPathComponent) scoped=\(ok)", category: "import")
                    await MainActor.run {
                        importProgress = ImportProgress(current: idx + 1, total: total, filename: basename, phase: .parsing)
                    }
                    do {
                        let parsed = try await PDFParser.smartParse(url: url)
                        let exCount = parsed.sections.reduce(0) { $0 + $1.exercises.count }
                        AppLogger.shared.log("  parsed OK: \(parsed.sections.count) sections, \(exCount) exercises", category: "import")
                        pairs.append((filename: basename, workout: parsed))
                    } catch {
                        AppLogger.shared.log("  parse FAILED: \(error)", category: "import")
                        await MainActor.run {
                            importError = error.localizedDescription
                            importProgress = nil
                        }
                        return
                    }
                }
                AppLogger.shared.log("calling assignByFilename with \(pairs.count) pairs", category: "import")
                await MainActor.run {
                    importProgress = ImportProgress(current: total, total: total, filename: "", phase: .saving)
                    do {
                        let created = try WeekScheduler.assignByFilename(pairs, context: context)
                        AppLogger.shared.log("save OK: created \(created.count) WorkoutDays", category: "import")
                    } catch {
                        AppLogger.shared.log("save FAILED: \(error)", category: "import")
                        importError = "Couldn't save workouts: \(error.localizedDescription)"
                        importProgress = nil
                        return
                    }
                    bannerDismissed = false
                    ReminderService.scheduleNextWeekReminderIfNeeded(context: context)
                    importProgress = nil
                }
            }

        case .failure(let err):
            AppLogger.shared.log("fileImporter failure: \(err)", category: "import")
            importError = err.localizedDescription
        }
    }

    // MARK: - Today's training (HIIT-matched)

    private var todaysSession: WorkoutSession? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        return sessions.first { s in
            guard let started = s.startedAt else { return false }
            return cal.isDate(started, inSameDayAs: day)
        }
    }

    /// Today's scheduled `WorkoutDay`, if one exists. Drives the visual
    /// highlights card so the home screen can preview today's planned lifts
    /// before any are logged.
    private var todaysWorkoutDay: WorkoutDay? {
        let cal = Calendar.current
        return allWorkoutDays.first { d in
            guard let date = d.date else { return false }
            return cal.isDate(date, inSameDayAs: Date())
        }
    }

    /// Visual preview of today's planned workout. Replaces the old text-heavy
    /// "FITTRACK | APPLE WATCH HIIT" stat card. Shows a big station-1 glyph,
    /// the main lift name, mini rows for stations 2-4, and a footer that
    /// flips between "Plan your day" (no session yet) and live training stats
    /// (kcal / sets / bpm) when a logged session + Watch HIIT exist.
    @ViewBuilder
    private func todaysHighlightsCard(day: WorkoutDay, session: WorkoutSession?, hiit: HKWorkout?) -> some View {
        if let session {
            NavigationLink(value: UnifiedSessionRoute(sessionID: session.objectID)) {
                highlightsCardBody(day: day, session: session, hiit: hiit)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                AppLogger.shared.log("home highlights → unified session", category: "ui")
            })
        } else {
            NavigationLink(value: day) {
                highlightsCardBody(day: day, session: nil, hiit: hiit)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                AppLogger.shared.log("home highlights → planned workout detail", category: "ui")
            })
        }
    }

    private func highlightsCardBody(day: WorkoutDay, session: WorkoutSession?, hiit: HKWorkout?) -> some View {
        let stations = stationExercises(for: day)
        let main = stations.first
        let mainGlyph = ExerciseIcon.glyph(for: main?.name ?? "")
        let dayName = dayOfWeekLabel(for: day.date ?? Date())
        let setCount = (session?.sets as? Set<LoggedSet>)?.filter { $0.isCompleted }.count ?? 0
        let kcal = hiit?.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY · \(dayName.uppercased())")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.accent)
                    Text(main?.name ?? "Rest day")
                        .font(Theme.Fonts.header(20))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                }
                Spacer()
                glyphHalo(glyph: mainGlyph, size: 56)
            }

            if stations.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(stations.dropFirst().enumerated()), id: \.element.objectID) { offset, ex in
                        stationRow(stationIndex: offset + 2, exercise: ex)
                    }
                }
            }

            Divider().overlay(Theme.Colors.border)

            highlightsFooter(session: session, setCount: setCount, kcal: kcal)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func stationRow(stationIndex: Int, exercise: Exercise) -> some View {
        let glyph = ExerciseIcon.glyph(for: exercise.name ?? "")
        return HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(glyph.tint.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: glyph.systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(glyph.tint)
            }
            Text("STN \(stationIndex)")
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 42, alignment: .leading)
            Text(exercise.name ?? "—")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func highlightsFooter(session: WorkoutSession?, setCount: Int, kcal: Double?) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if session != nil {
                footerStat(icon: "checkmark.circle.fill", text: "\(setCount) sets", tint: Theme.Colors.green)
                if let kcal {
                    footerStat(icon: "flame.fill", text: "\(Int(kcal)) kcal", tint: Theme.Colors.pink)
                }
            } else {
                footerStat(icon: "play.circle.fill", text: "Tap to start", tint: Theme.Colors.accent)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
        }
    }

    private func footerStat(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func glyphHalo(glyph: ExerciseIcon.Glyph, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(glyph.tint.opacity(0.18))
                .frame(width: size, height: size)
            Circle()
                .stroke(glyph.tint.opacity(0.35), lineWidth: 1)
                .frame(width: size, height: size)
            Image(systemName: glyph.systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(glyph.tint)
        }
    }

    private func stationExercises(for day: WorkoutDay) -> [Exercise] {
        guard let set = day.exercises as? Set<Exercise> else { return [] }
        return set
            .filter { (1...4).contains($0.station) }
            .sorted { lhs, rhs in
                if lhs.station != rhs.station { return lhs.station < rhs.station }
                return lhs.orderIndex < rhs.orderIndex
            }
    }

    private func dayOfWeekLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }
}

// MARK: - Day card

/// Horizontally-scrolling card for a scheduled `WorkoutDay`. Lime border on
/// today, dimmed opacity for past days, normal styling for upcoming days.
private struct DayCard: View {
    let day: WorkoutDay
    let isToday: Bool
    let isPast: Bool

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // Top header — day + date on the left, completion check on the
            // right. Stays anchored to the top edge.
            HStack(spacing: Theme.Spacing.xs) {
                Text(dayLabel.uppercased())
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.accent)
                Text(dateLabel)
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer(minLength: 0)
                if day.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Colors.green)
                }
            }

            Spacer(minLength: 0)

            // Vertically-centered glyph — visual anchor of the card.
            glyphHalo

            Spacer(minLength: 0)

            // Bottom title + exercise count, centered under the glyph so the
            // card reads as three balanced zones (header / glyph / label).
            VStack(spacing: 4) {
                Text(mainExerciseName ?? "Workout")
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(exerciseCount) exercises")
                        .font(Theme.Fonts.body(10))
                }
                .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Theme.Spacing.md)
        .frame(width: 175, height: 210)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .opacity(isPast && !day.isCompleted ? 0.5 : 1.0)
    }

    /// Big tinted circle with the lift's SF Symbol — the visual anchor of the
    /// card. Glyph + tint come from `ExerciseIcon` based on the station-1 lift.
    private var glyphHalo: some View {
        let glyph = ExerciseIcon.glyph(for: mainExerciseName ?? "")
        return ZStack {
            Circle()
                .fill(glyph.tint.opacity(0.18))
                .frame(width: 78, height: 78)
            Circle()
                .stroke(glyph.tint.opacity(0.35), lineWidth: 1)
                .frame(width: 78, height: 78)
            Image(systemName: glyph.systemName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(glyph.tint)
        }
    }

    private var borderColor: Color {
        if day.isCompleted { return Theme.Colors.green }
        if isToday { return Theme.Colors.accent }
        return Theme.Colors.border
    }

    private var borderWidth: CGFloat {
        (day.isCompleted || isToday) ? 2 : 1
    }

    private var dayLabel: String {
        guard let d = day.date else { return "" }
        return Self.dayLabelFormatter.string(from: d)
    }

    private var dateLabel: String {
        guard let d = day.date else { return "" }
        return Self.dateLabelFormatter.string(from: d)
    }

    private var exerciseCount: Int {
        guard let set = day.exercises as? Set<Exercise> else { return 0 }
        return set.filter { (1...4).contains($0.station) }.count
    }

    /// First exercise of station 1 — the "main lift" that drives the card's
    /// glyph + tint. Falls back to nil if the day has no main-station
    /// exercises (the body then renders a generic dumbbell with the accent
    /// tint). Warmup/prep/finisher rows are excluded so the title shows the
    /// actual lift, not "Laying Knee Hugs".
    private var mainExerciseName: String? {
        guard let set = day.exercises as? Set<Exercise> else { return nil }
        return set
            .filter { (1...4).contains($0.station) }
            .sorted { lhs, rhs in
                if lhs.station != rhs.station { return lhs.station < rhs.station }
                return lhs.orderIndex < rhs.orderIndex
            }
            .first?
            .name
    }
}

#Preview {
    WorkoutView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
