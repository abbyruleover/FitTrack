import Foundation
import CoreData
import Combine

/// Live state for an active workout session.
///
/// Owns:
///  - the underlying Core Data `WorkoutSession` row,
///  - an in-memory list of `SetDraft` rows per exercise (so the UI can edit
///    weight/reps before tapping ✓),
///  - a 1Hz timer that drives the elapsed-time label in the header,
///  - PREVIOUS-set lookup (last completed set for an exercise name from a
///    different session, so users see what they hit last time).
///
/// The store is created when the user taps "Start Workout" and lives for the
/// duration of the session. Tapping ✓ on a row promotes the in-memory draft
/// into a persisted `LoggedSet`. Tapping Finish stamps `finishedAt` and saves.
@MainActor
final class SessionStore: ObservableObject {
    /// In-memory representation of one row in the SET table.
    /// `loggedID` is non-nil once the row has been persisted (✓ tapped).
    struct SetDraft: Identifiable {
        let id = UUID()
        var setIndex: Int
        var weightLbs: Double
        var reps: Int
        var isCompleted: Bool
        var loggedID: NSManagedObjectID?
    }

    /// The Core Data session row (created on init, finalized on `finish()`).
    let session: WorkoutSession
    let workoutName: String

    /// The full parsed workout shape (sections + exercises). Held so the
    /// session view can be re-rendered by `ContentView` after the user
    /// minimizes — the WorkoutDay relationship isn't on the session row, so
    /// we keep the original `ParsedWorkout` here.
    let parsedWorkout: ParsedWorkout

    /// Per-exercise drafts keyed by exercise name. Order doesn't matter — the
    /// view drives display order off the parsed workout sections.
    @Published var drafts: [String: [SetDraft]] = [:]

    /// Exercise names the user has marked Skip in this session. In-memory
    /// only; the next session for the same workout starts with skip cleared.
    @Published var skippedExercises: Set<String> = []

    /// Updated every second so the header label refreshes.
    @Published var elapsed: TimeInterval = 0

    /// Set to true once `finish()` is called; the view uses this to dismiss.
    @Published var isFinished = false

    private let context: NSManagedObjectContext
    private let workoutDayID: NSManagedObjectID?
    private var timer: AnyCancellable?

    /// Cached at init from `SessionInsights.avgSessionSeconds(in:)` so the
    /// timer pill's progress arc reflects the user's own session-length
    /// baseline. Cached (vs. re-fetched per tick) because Core Data fetches
    /// don't belong on a 1Hz UI update path.
    private let avgSessionSeconds: Double

    init(workout: ParsedWorkout, workoutDayID: NSManagedObjectID? = nil, context: NSManagedObjectContext) {
        self.context = context
        self.workoutName = workout.name
        self.parsedWorkout = workout
        self.workoutDayID = workoutDayID
        self.avgSessionSeconds = SessionInsights.avgSessionSeconds(in: context)

        // Create the session row up front so any saved sets have something to
        // attach to. Don't save yet — wait until at least one set lands.
        let s = WorkoutSession(context: context)
        s.id = UUID()
        s.workoutName = workout.name
        s.startedAt = Date()
        self.session = s

        AppLogger.shared.log("SessionStore created — workout=\(workout.name) hasDayID=\(workoutDayID != nil)", category: "session")

        // Drive the elapsed label. Common.run keeps the timer firing while
        // the user is dragging the scroll view (default mode would pause it).
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(s.startedAt ?? Date())
            }
    }

    deinit { timer?.cancel() }

    // MARK: - Draft management

    /// Returns the current draft list for an exercise, seeding a single empty
    /// set if the user hasn't touched it yet (matches Hevy's behavior — every
    /// exercise card opens with one blank set ready to fill in).
    func drafts(for exerciseName: String) -> [SetDraft] {
        if let existing = drafts[exerciseName] { return existing }
        let seed = [SetDraft(setIndex: 1, weightLbs: 0, reps: 0, isCompleted: false, loggedID: nil)]
        drafts[exerciseName] = seed
        return seed
    }

    func addSet(for exerciseName: String) {
        var rows = drafts(for: exerciseName)
        let nextIdx = (rows.last?.setIndex ?? 0) + 1
        // Carry the previous row's weight/reps so the user only types the diff.
        let last = rows.last
        rows.append(SetDraft(
            setIndex: nextIdx,
            weightLbs: last?.weightLbs ?? 0,
            reps: last?.reps ?? 0,
            isCompleted: false,
            loggedID: nil
        ))
        drafts[exerciseName] = rows
        AppLogger.shared.log("addSet → \(exerciseName) now has \(rows.count) rows (set \(nextIdx))", category: "session")
    }

    func updateWeight(for exerciseName: String, draftID: UUID, value: Double) {
        guard var rows = drafts[exerciseName],
              let i = rows.firstIndex(where: { $0.id == draftID }) else { return }
        rows[i].weightLbs = value
        drafts[exerciseName] = rows
    }

    func updateReps(for exerciseName: String, draftID: UUID, value: Int) {
        guard var rows = drafts[exerciseName],
              let i = rows.firstIndex(where: { $0.id == draftID }) else { return }
        rows[i].reps = value
        drafts[exerciseName] = rows
    }

    /// Toggle a set's ✓. When checking, persist as a `LoggedSet`. When
    /// unchecking, delete the persisted row so PREVIOUS lookups stay honest.
    func toggleComplete(for exerciseName: String, draftID: UUID) {
        guard var rows = drafts[exerciseName],
              let i = rows.firstIndex(where: { $0.id == draftID }) else { return }
        rows[i].isCompleted.toggle()

        if rows[i].isCompleted {
            let logged = LoggedSet(context: context)
            logged.id = UUID()
            logged.exerciseName = exerciseName
            logged.setIndex = Int16(rows[i].setIndex)
            logged.weightLbs = rows[i].weightLbs
            logged.reps = Int16(rows[i].reps)
            logged.isCompleted = true
            logged.completedAt = Date()
            logged.session = session
            logged.canonicalExerciseID = canonicalID(for: exerciseName)
            rows[i].loggedID = logged.objectID
            do {
                try context.save()
                AppLogger.shared.log("✓ logged set \(rows[i].setIndex) of \(exerciseName) — \(rows[i].weightLbs) lbs × \(rows[i].reps)", category: "session")
            } catch {
                AppLogger.shared.log("✗ FAILED to save set \(rows[i].setIndex) of \(exerciseName): \(error)", category: "session")
            }
        } else if let oid = rows[i].loggedID,
                  let obj = try? context.existingObject(with: oid) {
            context.delete(obj)
            rows[i].loggedID = nil
            do {
                try context.save()
                AppLogger.shared.log("uncheck → deleted set \(rows[i].setIndex) of \(exerciseName)", category: "session")
            } catch {
                AppLogger.shared.log("✗ FAILED to delete set \(rows[i].setIndex) of \(exerciseName): \(error)", category: "session")
            }
        }

        drafts[exerciseName] = rows
    }

    /// Look up the canonical ID for an exercise within this session's parent
    /// `WorkoutDay`. Falls back to a fresh resolve if the day has no matching
    /// row (shouldn't happen — the importer always binds — but keeps the
    /// LoggedSet consistent in case of edge cases).
    private func canonicalID(for exerciseName: String) -> UUID? {
        if let oid = workoutDayID,
           let day = try? context.existingObject(with: oid) as? WorkoutDay,
           let exercises = day.exercises as? Set<Exercise>,
           let match = exercises.first(where: { $0.name == exerciseName }),
           let id = match.canonicalExerciseID {
            return id
        }
        return ExerciseCatalogService.shared.resolve(name: exerciseName, context: context).id
    }

    // MARK: - PREVIOUS lookup

    /// Returns the most recent completed set of the same exercise from a prior
    /// session, formatted as "45 × 7". Nil if the exercise has no history.
    func previous(for exerciseName: String) -> String? {
        let req = NSFetchRequest<LoggedSet>(entityName: "LoggedSet")
        req.predicate = NSPredicate(
            format: "exerciseName == %@ AND isCompleted == YES AND session != %@",
            exerciseName, session
        )
        req.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
        req.fetchLimit = 1
        guard let last = try? context.fetch(req).first else { return nil }
        let w = last.weightLbs
        let weightStr = w.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", w) : String(format: "%.1f", w)
        return "\(weightStr) × \(last.reps)"
    }

    // MARK: - Skip

    /// Toggle skip for an exercise. Skipped exercises render dimmed in the
    /// session view with their log table hidden. Pure UX cleanup — no Core
    /// Data writes; nothing persists past this session.
    func toggleSkip(exerciseName: String) {
        if skippedExercises.contains(exerciseName) {
            skippedExercises.remove(exerciseName)
            AppLogger.shared.log("unskipped \(exerciseName)", category: "session")
        } else {
            skippedExercises.insert(exerciseName)
            AppLogger.shared.log("skipped \(exerciseName)", category: "session")
        }
    }

    func isSkipped(exerciseName: String) -> Bool {
        skippedExercises.contains(exerciseName)
    }

    // MARK: - Finish

    func finish() {
        let totalSets = drafts.values.flatMap { $0 }.filter { $0.isCompleted }.count
        AppLogger.shared.log("Finish tapped — workout=\(workoutName) totalLoggedSets=\(totalSets) elapsed=\(elapsedLabel)", category: "session")
        session.finishedAt = Date()
        // Mark the parent WorkoutDay completed so the carousel and detail
        // view can switch out of "Start Workout" state. User explicitly
        // tapped Finish, so this counts even if no sets were logged (some
        // workouts are pure cardio that the user just doesn't want to track).
        if let oid = workoutDayID,
           let day = try? context.existingObject(with: oid) as? WorkoutDay {
            day.isCompleted = true
            AppLogger.shared.log("marked WorkoutDay isCompleted=true", category: "session")
        }
        do {
            try context.save()
            AppLogger.shared.log("session save OK", category: "session")
        } catch {
            AppLogger.shared.log("session save FAILED: \(error)", category: "session")
        }
        timer?.cancel()
        isFinished = true
    }

    /// Called when the user backs out without tapping Finish. Drops the
    /// session if nothing was logged so the history stays clean. Skipped if
    /// the user actually finished — an empty-but-finished session is still a
    /// valid completion record.
    func discardIfEmpty() {
        guard !isFinished else {
            AppLogger.shared.log("discardIfEmpty skipped — session was finished", category: "session")
            return
        }
        let hasAnyCompleted = drafts.values.flatMap { $0 }.contains(where: { $0.isCompleted })
        if !hasAnyCompleted {
            context.delete(session)
            try? context.save()
            AppLogger.shared.log("discardIfEmpty → deleted empty session", category: "session")
        } else {
            AppLogger.shared.log("discardIfEmpty kept session — has logged sets", category: "session")
        }
    }

    /// Hard discard — invoked when the user taps the trash button on the
    /// minimized pill. Deletes the session AND any logged sets, regardless of
    /// progress. The cascade rule on `WorkoutSession.sets` removes the
    /// `LoggedSet` rows automatically.
    func discardEntirely() {
        AppLogger.shared.log("discardEntirely → deleting session (had \(drafts.values.flatMap { $0 }.filter { $0.isCompleted }.count) logged sets)", category: "session")
        context.delete(session)
        try? context.save()
        timer?.cancel()
        isFinished = true
    }

    /// Most recently touched exercise — drives the mini-pill subtitle and the
    /// Live Activity body while the session is minimized. Resolution order:
    ///   1. The exercise of the most recently completed set (real progress).
    ///   2. The first loggable station's first exercise (sensible default
    ///      before the user has tapped ✓ on anything).
    ///   3. The workout name as a last resort.
    /// Returning the workout name as a default produced a useless
    /// "Thur WOD / Thur WOD" Live Activity card.
    var currentExerciseName: String {
        let allSets = drafts.flatMap { (name, rows) in
            rows.compactMap { row -> (String, NSManagedObjectID)? in
                guard row.isCompleted, let oid = row.loggedID else { return nil }
                return (name, oid)
            }
        }
        let resolved: [(String, Date)] = allSets.compactMap { name, oid in
            guard let obj = try? context.existingObject(with: oid) as? LoggedSet,
                  let d = obj.completedAt else { return nil }
            return (name, d)
        }
        if let latest = resolved.max(by: { $0.1 < $1.1 })?.0 { return latest }
        if let firstStationExercise = parsedWorkout.sections
            .first(where: { $0.kind.isLoggable })?
            .exercises.first?.name { return firstStationExercise }
        return workoutName
    }

    /// Section title for the current exercise (e.g. "Station 1"). Used as the
    /// Live Activity subtitle so the user can tell where in the class the
    /// current exercise sits without opening the app.
    var currentExerciseSection: String? {
        let name = currentExerciseName
        return parsedWorkout.sections
            .first(where: { $0.exercises.contains(where: { $0.name == name }) })?.title
    }

    /// Pretty summary of the most recently logged set across the whole
    /// session, e.g. `"135 × 8 reps"`. Drives the lock-screen Live Activity's
    /// footer ("Last: …"). Returns nil before the user taps ✓ on anything.
    func lastCompletedSetSummary() -> String? {
        let candidates: [(Date, Double, Int)] = drafts.flatMap { _, rows in
            rows.compactMap { row -> (Date, Double, Int)? in
                guard row.isCompleted, let oid = row.loggedID,
                      let obj = try? context.existingObject(with: oid) as? LoggedSet,
                      let d = obj.completedAt else { return nil }
                return (d, row.weightLbs, row.reps)
            }
        }
        guard let latest = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        let w = latest.1
        let weightStr = w.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", w) : String(format: "%.1f", w)
        return "\(weightStr) × \(latest.2) reps"
    }

    /// Total ✓-checked sets across every exercise in this session. Drives the
    /// "N ✓" badge on the Live Activity footer.
    var totalCompletedSetCount: Int {
        drafts.values.flatMap { $0 }.filter { $0.isCompleted }.count
    }

    /// Formats the running timer label as "MM:SS" (or "H:MM:SS" past an hour).
    var elapsedLabel: String {
        let total = Int(elapsed)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Progress arc fraction for the live timer pill. 0 → just started, 1 →
    /// at the user's average session length, capped at 2 so a runaway "forgot
    /// to hit Finish" session doesn't make the overflow ring spin forever.
    var elapsedFraction: Double {
        guard avgSessionSeconds > 0 else { return 0 }
        return min(elapsed / avgSessionSeconds, 2.0)
    }
}
