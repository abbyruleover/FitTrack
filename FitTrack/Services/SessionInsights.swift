import Foundation
import CoreData
import HealthKit

/// Pure functions that turn a finished `WorkoutSession` into a list of
/// "what you crushed" callouts: weight PRs, rep PRs, volume delta vs the
/// previous same-named session, and streak milestones. Drives the colored
/// pill row at the top of `SessionSummaryView` (and reuses-able from the
/// unified view too).
///
/// All comparisons are computed against history that EXCLUDES the input
/// session — so a fresh PR from this very session reads as a strict
/// improvement, not a tie.
enum SessionInsights {

    struct WeightPR: Identifiable, Hashable {
        let id = UUID()
        let exerciseName: String
        let newBestLbs: Double
        let priorBestLbs: Double
        var deltaLbs: Double { newBestLbs - priorBestLbs }
    }

    struct RepPR: Identifiable, Hashable {
        let id = UUID()
        let exerciseName: String
        let weightLbs: Double
        let newBestReps: Int
        let priorBestReps: Int
    }

    struct VolumeDelta: Hashable {
        let workoutName: String
        let currentLbs: Double
        let previousLbs: Double
        /// Human-readable comparison label, e.g. "last Tue 6:15 AM class"
        /// when both sessions landed in the same slot, or "last Tuesday WOD"
        /// otherwise. Pre-formatted so the view doesn't re-derive it.
        let comparisonLabel: String
        var deltaLbs: Double { currentLbs - previousLbs }
        var deltaPct: Double {
            guard previousLbs > 0 else { return 0 }
            return (currentLbs - previousLbs) / previousLbs * 100
        }
    }

    /// Bundle of every callout for a single session. `isEmpty` lets the view
    /// skip the "What you crushed" section entirely on a quiet day.
    struct Bundle: Hashable {
        let weightPRs: [WeightPR]
        let repPRs: [RepPR]
        let volume: VolumeDelta?
        let streakMilestone: Int?
        var isEmpty: Bool {
            weightPRs.isEmpty && repPRs.isEmpty && volume == nil && streakMilestone == nil
        }
    }

    static let streakMilestones: [Int] = [3, 7, 14, 30, 60, 90, 180, 365]

    /// Compute every callout. Pulls all sets ever logged once and partitions
    /// into "this session" vs "prior" — single Core Data fetch keeps the
    /// summary screen snappy even with thousands of historical sets.
    static func compute(
        for session: WorkoutSession,
        in context: NSManagedObjectContext
    ) -> Bundle {
        let sessionSets: [LoggedSet] = (session.sets as? Set<LoggedSet>).map(Array.init) ?? []
        let completedThisSession = sessionSets.filter { $0.isCompleted && $0.weightLbs >= 0 }

        guard !completedThisSession.isEmpty else {
            return Bundle(weightPRs: [], repPRs: [], volume: nil, streakMilestone: nil)
        }

        let priorSets = fetchPriorSets(excluding: session, in: context)

        let weightPRs = computeWeightPRs(sessionSets: completedThisSession, priorSets: priorSets)
        let repPRs = computeRepPRs(sessionSets: completedThisSession, priorSets: priorSets)
        let volume = computeVolumeDelta(session: session, in: context)
        let streak = computeStreakMilestone(session: session, in: context)

        return Bundle(
            weightPRs: weightPRs,
            repPRs: repPRs,
            volume: volume,
            streakMilestone: streak
        )
    }

    // MARK: - Weight PRs

    private static func computeWeightPRs(
        sessionSets: [LoggedSet],
        priorSets: [LoggedSet]
    ) -> [WeightPR] {
        var priorBest: [String: Double] = [:]
        for set in priorSets {
            let name = key(set)
            guard !name.isEmpty else { continue }
            priorBest[name] = max(priorBest[name] ?? 0, set.weightLbs)
        }

        var sessionBest: [String: Double] = [:]
        for set in sessionSets {
            let name = key(set)
            guard !name.isEmpty, set.weightLbs > 0 else { continue }
            sessionBest[name] = max(sessionBest[name] ?? 0, set.weightLbs)
        }

        var prs: [WeightPR] = []
        for (name, current) in sessionBest {
            let prior = priorBest[name] ?? 0
            if current > prior {
                prs.append(WeightPR(
                    exerciseName: displayName(for: name, in: sessionSets),
                    newBestLbs: current,
                    priorBestLbs: prior
                ))
            }
        }
        return prs.sorted { $0.deltaLbs > $1.deltaLbs }
    }

    // MARK: - Rep PRs

    /// A rep PR fires when, at a given (exercise, weight), the user beat
    /// their prior max-reps for that exact weight. We only consider weights
    /// they've used before — pure new-weight territory is already covered
    /// by the weight PR pass.
    private static func computeRepPRs(
        sessionSets: [LoggedSet],
        priorSets: [LoggedSet]
    ) -> [RepPR] {
        var priorBest: [String: [Double: Int]] = [:]
        for set in priorSets {
            let name = key(set)
            guard !name.isEmpty else { continue }
            let weight = roundedWeight(set.weightLbs)
            let reps = Int(set.reps)
            let cur = priorBest[name]?[weight] ?? 0
            priorBest[name, default: [:]][weight] = max(cur, reps)
        }

        var sessionBest: [String: [Double: Int]] = [:]
        for set in sessionSets {
            let name = key(set)
            guard !name.isEmpty else { continue }
            let weight = roundedWeight(set.weightLbs)
            let reps = Int(set.reps)
            let cur = sessionBest[name]?[weight] ?? 0
            sessionBest[name, default: [:]][weight] = max(cur, reps)
        }

        var prs: [RepPR] = []
        for (name, weights) in sessionBest {
            for (weight, reps) in weights {
                guard reps > 0, weight > 0 else { continue }
                let prior = priorBest[name]?[weight] ?? 0
                guard prior > 0 else { continue }
                if reps > prior {
                    prs.append(RepPR(
                        exerciseName: displayName(for: name, in: sessionSets),
                        weightLbs: weight,
                        newBestReps: reps,
                        priorBestReps: prior
                    ))
                }
            }
        }
        return prs.sorted { ($0.newBestReps - $0.priorBestReps) > ($1.newBestReps - $1.priorBestReps) }
    }

    // MARK: - Volume delta

    private static func computeVolumeDelta(
        session: WorkoutSession,
        in context: NSManagedObjectContext
    ) -> VolumeDelta? {
        let name = (session.workoutName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let started = session.startedAt else { return nil }

        // Pull a small batch of prior same-name sessions so we can prefer the
        // one that matches this session's class slot. Falling back to plain
        // most-recent keeps the callout populated even when the user hops
        // between class slots week-to-week.
        let req = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "workoutName ==[c] %@", name),
            NSPredicate(format: "startedAt < %@", started as NSDate)
        ])
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = 12

        let candidates = (try? context.fetch(req)) ?? []
        guard !candidates.isEmpty else { return nil }

        let currentSlot = ClassSchedule.slot(for: started)
        let prev: WorkoutSession
        let label: String
        if let currentSlot,
           let match = candidates.first(where: {
               guard let s = $0.startedAt else { return false }
               return ClassSchedule.slot(for: s) == currentSlot
           }) {
            prev = match
            label = "last \(currentSlot.start.displayLabel) class"
        } else {
            prev = candidates[0]
            // Off-grid (Sunday or non-class-time) — name the workout to keep
            // the comparison meaningful.
            label = "last \(name)"
        }

        let currentVol = volume(of: session)
        let prevVol = volume(of: prev)
        guard currentVol > 0, prevVol > 0 else { return nil }
        return VolumeDelta(
            workoutName: name,
            currentLbs: currentVol,
            previousLbs: prevVol,
            comparisonLabel: label
        )
    }

    private static func volume(of session: WorkoutSession) -> Double {
        let sets = (session.sets as? Set<LoggedSet>) ?? []
        return sets.reduce(0) { acc, s in
            guard s.isCompleted else { return acc }
            return acc + s.weightLbs * Double(s.reps)
        }
    }

    // MARK: - Streak milestone

    /// Returns the milestone value when the session pushes the streak across
    /// it (3, 7, 14, 30, 60, 90, 180, 365). Nil otherwise.
    private static func computeStreakMilestone(
        session: WorkoutSession,
        in context: NSManagedObjectContext
    ) -> Int? {
        let req = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        req.predicate = NSPredicate(format: "startedAt != nil")
        let sessions = (try? context.fetch(req)) ?? []
        guard let started = session.startedAt else { return nil }
        let streak = ProgressAggregator.currentStreak(sessions: sessions, now: started)
        return streakMilestones.contains(streak) ? streak : nil
    }

    // MARK: - Helpers

    private static func fetchPriorSets(
        excluding session: WorkoutSession,
        in context: NSManagedObjectContext
    ) -> [LoggedSet] {
        let req = NSFetchRequest<LoggedSet>(entityName: "LoggedSet")
        if let id = session.id {
            req.predicate = NSPredicate(format: "isCompleted == YES AND (session.id == nil OR session.id != %@)", id as CVarArg)
        } else {
            req.predicate = NSPredicate(format: "isCompleted == YES AND session != %@", session)
        }
        return (try? context.fetch(req)) ?? []
    }

    private static func key(_ set: LoggedSet) -> String {
        (set.exerciseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Look up the original-cased name from the session's own sets so the
    /// callout displays "Bench Press" not "bench press".
    private static func displayName(for key: String, in sets: [LoggedSet]) -> String {
        for set in sets {
            let name = (set.exerciseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.lowercased() == key { return name }
        }
        return key
    }

    /// Bucket weights to the nearest 2.5 lbs so 135.0 and 135.00001 don't
    /// register as different "weights" when grouping rep PRs.
    private static func roundedWeight(_ lbs: Double) -> Double {
        (lbs / 2.5).rounded() * 2.5
    }

    // MARK: - Session-length history

    /// Mean duration of the last `limit` finished sessions, in seconds. Used
    /// by the live workout timer pill to compute its progress arc against a
    /// realistic personal baseline (so a 25-min user doesn't have to grind
    /// to a generic 60-min target before the arc fills). Falls back to
    /// `defaultSeconds` (3600 = 60 min) when the user has no finished
    /// sessions yet.
    static func avgSessionSeconds(
        in context: NSManagedObjectContext,
        limit: Int = 10,
        defaultSeconds: Double = 3600
    ) -> Double {
        let req = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        req.predicate = NSPredicate(format: "startedAt != nil AND finishedAt != nil")
        req.sortDescriptors = [NSSortDescriptor(key: "finishedAt", ascending: false)]
        req.fetchLimit = limit
        let sessions = (try? context.fetch(req)) ?? []
        let durations: [Double] = sessions.compactMap { s in
            guard let start = s.startedAt, let end = s.finishedAt else { return nil }
            let secs = end.timeIntervalSince(start)
            // Defend against junk rows: a finished-before-started session or a
            // multi-day-spanning ghost would otherwise drag the average to
            // useless territory.
            return (secs > 60 && secs < 6 * 3600) ? secs : nil
        }
        guard !durations.isEmpty else { return defaultSeconds }
        return durations.reduce(0, +) / Double(durations.count)
    }

    // MARK: - Multi-ring targets

    /// Bundle of "what counts as a full ring" for the unified session view.
    /// Targets are personal — computed from the user's own history rather
    /// than a generic 60-min / 500-kcal goal — so a 25-min HIIT regular
    /// doesn't have to grind extra to fill the duration ring.
    struct WorkoutTargets {
        let durationSecs: Double
        let kcal: Double
        let volumeLbs: Double
    }

    /// Computes the three ring targets for a unified session. Async because
    /// the kcal target needs a HealthKit query for each prior HIIT workout
    /// (mean active-kcal of the trailing 10 workouts).
    ///
    /// Defaults when the user has no history yet:
    ///  - duration: 3600s (60 min)
    ///  - kcal: 500
    ///  - volume: this session's own volume (so the ring reads ~100% on
    ///    first ever session — better than a 0% donut)
    @MainActor
    static func workoutTargets(
        for session: WorkoutSession,
        in context: NSManagedObjectContext,
        hkWorkout: HKWorkout? = nil
    ) async -> WorkoutTargets {
        let durationTarget = avgSessionSeconds(in: context, limit: 10, defaultSeconds: 3600)
        let volumeTarget = volumeTarget(for: session, in: context)
        let kcalTarget = await avgRecentKcal(excluding: hkWorkout)
        return WorkoutTargets(
            durationSecs: durationTarget,
            kcal: kcalTarget,
            volumeLbs: volumeTarget
        )
    }

    /// Mean of the **same-class** prior sessions' volumes; falls back to the
    /// user's best volume on the same workout name, falls back again to this
    /// session's own volume so the ring isn't perpetually empty.
    private static func volumeTarget(
        for session: WorkoutSession,
        in context: NSManagedObjectContext
    ) -> Double {
        let name = (session.workoutName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let started = session.startedAt
        let currentSlot = started.flatMap { ClassSchedule.slot(for: $0) }
        let myVolume = volume(of: session)

        guard !name.isEmpty else { return max(myVolume, 1) }

        let req = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        var predicates: [NSPredicate] = [NSPredicate(format: "workoutName ==[c] %@", name)]
        if let started {
            predicates.append(NSPredicate(format: "startedAt < %@", started as NSDate))
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = 20

        let priors = (try? context.fetch(req)) ?? []
        let slotPeers: [WorkoutSession]
        if let currentSlot {
            slotPeers = priors.filter {
                guard let s = $0.startedAt else { return false }
                return ClassSchedule.slot(for: s) == currentSlot
            }
        } else {
            slotPeers = []
        }

        if !slotPeers.isEmpty {
            let vols = slotPeers.map { volume(of: $0) }.filter { $0 > 0 }
            if !vols.isEmpty {
                return vols.reduce(0, +) / Double(vols.count)
            }
        }
        // Fallback: user's best volume on this workout name.
        let best = priors.map { volume(of: $0) }.max() ?? 0
        return max(best, myVolume, 1)
    }

    /// Average active-kcal across the trailing 10 HIIT workouts on Apple
    /// Watch (excluding the one we're rendering, so the ring isn't trivially
    /// 100%). Returns 500 as a sensible HIIT default when there's no
    /// history (matches Apple's default Move ring expectation).
    @MainActor
    private static func avgRecentKcal(excluding current: HKWorkout?) async -> Double {
        let recents = await HealthKitService.shared.recentWorkouts(limit: 20)
        let hiits = recents.filter { $0.workoutActivityType == .highIntensityIntervalTraining }
        let pool = hiits.filter { current == nil || $0.uuid != current?.uuid }.prefix(10)
        let kcals: [Double] = pool.compactMap { w in
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie())
            return (kcal ?? 0) > 0 ? kcal : nil
        }
        guard !kcals.isEmpty else { return 500 }
        return kcals.reduce(0, +) / Double(kcals.count)
    }
}
