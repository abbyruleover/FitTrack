import Foundation
import CoreData

/// Persists `ParsedWorkout` collections onto consecutive weekday `WorkoutDay`
/// rows and answers calendar-coverage questions used by the home banner,
/// the Sessions tab badge, and the local-notification reminder.
///
/// Week shape: Monday → Saturday (6 slots). Sunday is intentionally left
/// uncovered — that's the upload day.
enum WeekScheduler {
    /// Sunday-of-week → Saturday is index 5. We schedule Mon..Sat, so 6 slots.
    static let workoutDaysPerWeek = 6

    private static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday — matches the Mon..Sat scheduling window.
        return c
    }()

    // MARK: - Date helpers

    /// Snap any date to the Monday of that ISO/Gregorian week.
    static func mondayOfWeek(containing date: Date) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    /// Upcoming Monday: today if today is Monday, otherwise the next one.
    static func nextMonday(from date: Date = Date()) -> Date {
        let monday = mondayOfWeek(containing: date)
        let dayStart = calendar.startOfDay(for: date)
        if monday >= dayStart { return monday }
        return calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
    }

    /// "Active" Monday — the Monday whose Mon..Sat window the home dashboard
    /// should be focused on right now. On Sunday (the upload day) this rolls
    /// forward to next Monday so the carousel and banner reflect the week the
    /// user is actually planning, not the one that just ended.
    static func activeMonday(from date: Date = Date()) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        // weekday == 1 → Sunday in Gregorian. Roll forward to upcoming Monday.
        if weekday == 1 {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            return mondayOfWeek(containing: tomorrow)
        }
        return mondayOfWeek(containing: date)
    }

    static func mondayThroughSaturday(weekStarting monday: Date) -> [Date] {
        let start = calendar.startOfDay(for: monday)
        return (0..<workoutDaysPerWeek).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }

    // MARK: - Persistence

    /// Creates one `WorkoutDay` per parsed workout, stamped to consecutive
    /// dates Mon..Sat starting from the provided Monday. Excess workouts
    /// beyond 6 are dropped so we never spill into Sunday.
    @discardableResult
    static func assignToWeek(
        _ workouts: [ParsedWorkout],
        startingMonday monday: Date,
        context: NSManagedObjectContext
    ) -> [WorkoutDay] {
        let weekStart = mondayOfWeek(containing: monday)
        clearWeek(weekStart: weekStart, context: context)
        let dates = mondayThroughSaturday(weekStarting: weekStart)
        let weekNumber = calendar.component(.weekOfYear, from: weekStart)

        var created: [WorkoutDay] = []
        for (idx, parsed) in workouts.prefix(workoutDaysPerWeek).enumerated() {
            let day = WorkoutDay(context: context)
            day.id = UUID()
            day.name = parsed.name
            day.date = dates[idx]
            day.weekNumber = Int16(weekNumber)
            day.isCompleted = false

            // Flatten parsed sections into Exercise rows. We lose section
            // subtitle/scheme/prefix/suffix here — the carousel only needs
            // name + section count, and the live logger re-parses on Start.
            var orderIndex: Int16 = 0
            for section in parsed.sections {
                let stationNumber = stationCode(for: section.kind)
                for ex in section.exercises {
                    let row = Exercise(context: context)
                    row.id = UUID()
                    row.name = ex.name
                    row.equipment = ex.reps.isEmpty ? nil : ex.reps
                    row.orderIndex = orderIndex
                    row.station = stationNumber
                    row.workoutDay = day
                    let catalog = ExerciseCatalogService.shared.resolve(name: ex.name, context: context)
                    row.canonicalExerciseID = catalog.id
                    orderIndex += 1
                }
            }
            created.append(day)
        }

        do { try context.save() }
        catch {
            // Roll back anything half-saved so we don't leave orphans.
            context.rollback()
        }
        return created
    }

    /// Map section kinds onto the `Exercise.station` Int16 field.
    /// Stations 1-4 stay 1-4; warmup/prep/finisher use sentinel codes so the
    /// downstream UI can still distinguish them if needed.
    private static func stationCode(for kind: WorkoutSection.Kind) -> Int16 {
        switch kind {
        case .warmup:   return 0
        case .prep:     return 10
        case .station1: return 1
        case .station2: return 2
        case .station3: return 3
        case .station4: return 4
        case .finisher: return 9
        }
    }

    // MARK: - Filename-based auto-scheduling

    /// Map a PDF basename like "Mon WOD" / "Tues WOD" / "Thur WOD" to a
    /// 0-based offset from Monday. Returns nil if no day token is recognized.
    /// Match is case-insensitive and order-sensitive (longest prefix wins so
    /// "Thurs" beats "Thu" beats "Th").
    static func dayOffset(fromFilename filename: String) -> Int? {
        let lower = filename.lowercased()
        // Order matters: longer aliases first so "tues" matches before "tue".
        let table: [(String, Int)] = [
            ("monday", 0), ("mon", 0),
            ("tuesday", 1), ("tues", 1), ("tue", 1),
            ("wednesday", 2), ("weds", 2), ("wed", 2),
            ("thursday", 3), ("thurs", 3), ("thur", 3), ("thu", 3),
            ("friday", 4), ("fri", 4),
            ("saturday", 5), ("sat", 5)
        ]
        for (token, offset) in table {
            if lower.contains(token) { return offset }
        }
        return nil
    }

    /// Auto-assign a batch of imported PDFs to the right week based on the
    /// day token in each filename. The week is picked by looking at the
    /// earliest detected day: if that day is already in the past for the
    /// current week, we roll forward to next week. Pairs whose filename has
    /// no day token fall into the first unused Mon..Sat slot.
    @discardableResult
    static func assignByFilename(
        _ pairs: [(filename: String, workout: ParsedWorkout)],
        context: NSManagedObjectContext
    ) throws -> [WorkoutDay] {
        guard !pairs.isEmpty else { return [] }

        // Always target the active week. `activeMonday` already rolls forward
        // to next Monday when today is Sunday (the upload day). On any other
        // weekday — even Tue/Wed/etc. when Monday is already in the past —
        // the user clicked "Import this week's PDFs", so we honor that and
        // place WODs on this week's Mon..Sat (past days simply show as past).
        let targetMonday = activeMonday()
        AppLogger.shared.log("assignByFilename: \(pairs.count) pairs → week of \(ISO8601DateFormatter().string(from: targetMonday))", category: "scheduler")

        // Place each pair at its detected offset; unrecognized filenames spill
        // into the first empty slot. Collisions on the same day overwrite —
        // last-wins so the user can re-upload one day to fix it.
        var slots: [ParsedWorkout?] = Array(repeating: nil, count: workoutDaysPerWeek)
        var unassigned: [ParsedWorkout] = []
        for pair in pairs {
            if let offset = dayOffset(fromFilename: pair.filename),
               offset < workoutDaysPerWeek {
                AppLogger.shared.log("  '\(pair.filename)' → slot \(offset)", category: "scheduler")
                slots[offset] = pair.workout
            } else {
                AppLogger.shared.log("  '\(pair.filename)' → no day token, queueing for empty slot", category: "scheduler")
                unassigned.append(pair.workout)
            }
        }
        for wod in unassigned {
            if let firstEmpty = slots.firstIndex(where: { $0 == nil }) {
                slots[firstEmpty] = wod
                AppLogger.shared.log("  spillover → slot \(firstEmpty)", category: "scheduler")
            }
        }

        return try assignBySlot(slots, startingMonday: targetMonday, context: context)
    }

    /// Variant of `assignToWeek` that accepts a sparse slot array (Mon..Sat)
    /// and skips nil entries instead of compacting. Used by the
    /// filename-aware auto-scheduler to preserve day alignment.
    @discardableResult
    static func assignBySlot(
        _ slots: [ParsedWorkout?],
        startingMonday monday: Date,
        context: NSManagedObjectContext
    ) throws -> [WorkoutDay] {
        let weekStart = mondayOfWeek(containing: monday)
        clearWeek(weekStart: weekStart, context: context)
        let dates = mondayThroughSaturday(weekStarting: weekStart)
        let weekNumber = calendar.component(.weekOfYear, from: weekStart)

        var created: [WorkoutDay] = []
        for (idx, parsed) in slots.prefix(workoutDaysPerWeek).enumerated() {
            guard let parsed = parsed else { continue }

            let day = WorkoutDay(context: context)
            day.id = UUID()
            day.name = parsed.name
            day.date = dates[idx]
            day.weekNumber = Int16(weekNumber)
            day.isCompleted = false

            var orderIndex: Int16 = 0
            for section in parsed.sections {
                let stationNumber = stationCode(for: section.kind)
                for ex in section.exercises {
                    let row = Exercise(context: context)
                    row.id = UUID()
                    row.name = ex.name
                    row.equipment = ex.reps.isEmpty ? nil : ex.reps
                    row.orderIndex = orderIndex
                    row.station = stationNumber
                    row.workoutDay = day
                    let catalog = ExerciseCatalogService.shared.resolve(name: ex.name, context: context)
                    row.canonicalExerciseID = catalog.id
                    orderIndex += 1
                }
            }
            created.append(day)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return created
    }

    // MARK: - Coverage queries

    /// Dates Mon..Sat in the given week that have NO `WorkoutDay` row.
    static func missingDays(forWeekStarting monday: Date, context: NSManagedObjectContext) -> [Date] {
        let week = mondayThroughSaturday(weekStarting: mondayOfWeek(containing: monday))
        let scheduled = scheduledDays(in: week.first!, to: week.last!, context: context)
        let scheduledKeys = Set(scheduled.compactMap { $0.date.map { calendar.startOfDay(for: $0) } })
        return week.filter { !scheduledKeys.contains(calendar.startOfDay(for: $0)) }
    }

    /// True when the week AFTER the active week has zero `WorkoutDay` rows.
    /// On Sunday the "active" week is already next week, so this looks two
    /// weeks ahead — keeps the Sessions badge meaningful on upload day.
    static func nextWeekIsEmpty(context: NSManagedObjectContext) -> Bool {
        let active = activeMonday()
        let nextWeekMonday = calendar.date(byAdding: .day, value: 7, to: active) ?? active
        return missingDays(forWeekStarting: nextWeekMonday, context: context).count == workoutDaysPerWeek
    }

    /// True when the active week (Mon..Sat the dashboard is focused on) has
    /// any missing days. On Sunday this checks the upcoming week, so a fresh
    /// upload clears the banner immediately.
    static func currentWeekHasGaps(context: NSManagedObjectContext) -> Bool {
        return !missingDays(forWeekStarting: activeMonday(), context: context).isEmpty
    }

    // MARK: - On-demand clear

    /// Public wrapper around `clearWeek` for the gear-menu "Clear this week"
    /// action. Saves immediately so the carousel refetches an empty week.
    static func clearActiveWeek(context: NSManagedObjectContext) {
        let monday = activeMonday()
        AppLogger.shared.log("clearActiveWeek → week of \(ISO8601DateFormatter().string(from: monday))", category: "scheduler")
        clearWeek(weekStart: monday, context: context)
        do {
            try context.save()
            AppLogger.shared.log("clearActiveWeek save OK", category: "scheduler")
        } catch {
            AppLogger.shared.log("clearActiveWeek save FAILED: \(error)", category: "scheduler")
        }
    }

    /// Wipe every `WorkoutDay` in the store. Used by the gear-menu reset.
    /// Cascade delete on `WorkoutDay.exercises` removes child rows.
    static func clearAllScheduled(context: NSManagedObjectContext) {
        let request = NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay")
        let all = (try? context.fetch(request)) ?? []
        AppLogger.shared.log("clearAllScheduled → deleting \(all.count) WorkoutDays", category: "scheduler")
        for day in all { context.delete(day) }
        do {
            try context.save()
            AppLogger.shared.log("clearAllScheduled save OK", category: "scheduler")
        } catch {
            AppLogger.shared.log("clearAllScheduled save FAILED: \(error)", category: "scheduler")
        }
    }

    // MARK: - Internal

    /// Delete every `WorkoutDay` whose date falls in the Mon..Sat window of
    /// the given week. Re-imports rely on this so a fresh batch replaces the
    /// stale rows instead of stacking duplicate cards on the same date.
    /// Cascade delete on `WorkoutDay.exercises` removes the child rows.
    private static func clearWeek(weekStart: Date, context: NSManagedObjectContext) {
        let dayStart = calendar.startOfDay(for: weekStart)
        let weekEnd = calendar.date(byAdding: .day, value: workoutDaysPerWeek, to: dayStart) ?? dayStart
        let request = NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay")
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            dayStart as NSDate, weekEnd as NSDate
        )
        let existing = (try? context.fetch(request)) ?? []
        for day in existing { context.delete(day) }
    }

    private static func scheduledDays(
        in start: Date,
        to end: Date,
        context: NSManagedObjectContext
    ) -> [WorkoutDay] {
        let request = NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay")
        let dayStart = calendar.startOfDay(for: start)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@",
            dayStart as NSDate, dayAfterEnd as NSDate
        )
        return (try? context.fetch(request)) ?? []
    }
}
