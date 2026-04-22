import Foundation
import CoreData

/// Pure data layer for the Progress tab. Transforms `LoggedSet` rows into PR
/// cards and per-exercise time-series points. No Core Data writes — views
/// drive `@FetchRequest` and hand the results in.
enum ProgressAggregator {

    // MARK: - Metric

    /// Y-axis metric the user can flip between on the chart.
    enum ProgressMetric: String, CaseIterable, Hashable {
        case weight, volume, oneRepMax, reps

        var displayName: String {
            switch self {
            case .weight:    return "Weight"
            case .volume:    return "Volume"
            case .oneRepMax: return "1RM"
            case .reps:      return "Reps"
            }
        }

        var unitSuffix: String {
            switch self {
            case .weight, .volume, .oneRepMax: return "lbs"
            case .reps:                        return "reps"
            }
        }
    }

    // MARK: - Time range

    /// X-axis window for the chart. `cutoff(from:)` returns the earliest date
    /// that should be included for the given "now".
    enum TimeRange: String, CaseIterable, Hashable {
        case month, sixMonth, year, threeYear, fiveYear, tenYear

        var displayLabel: String {
            switch self {
            case .month:     return "M"
            case .sixMonth:  return "6M"
            case .year:      return "Y"
            case .threeYear: return "3Y"
            case .fiveYear:  return "5Y"
            case .tenYear:   return "10Y"
            }
        }

        func cutoff(from now: Date = Date()) -> Date {
            let cal = Calendar.current
            let component: Calendar.Component
            let value: Int
            switch self {
            case .month:     component = .month; value = -1
            case .sixMonth:  component = .month; value = -6
            case .year:      component = .year;  value = -1
            case .threeYear: component = .year;  value = -3
            case .fiveYear:  component = .year;  value = -5
            case .tenYear:   component = .year;  value = -10
            }
            return cal.date(byAdding: component, value: value, to: now) ?? now
        }
    }

    // MARK: - Output models

    /// One row in the Progress tab's PR card list.
    struct PersonalRecord: Identifiable, Hashable {
        let id = UUID()
        let exerciseName: String
        let bestWeightLbs: Double
        let bestReps: Int
        let lastPerformed: Date
    }

    /// One point on the per-exercise chart. `sessionID` lets a chart-tap
    /// resolve back to the originating `WorkoutSession` (and therefore the
    /// session's date for `SessionDetailView(date:)`).
    struct ProgressPoint: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let value: Double
        let sessionID: NSManagedObjectID?
    }

    // MARK: - PR aggregation

    /// Build a list of PRs (one per exercise) from any `LoggedSet` slice.
    /// Best weight wins; ties on weight pick the rep count from the heaviest
    /// set; `lastPerformed` is the most recent `completedAt` for the exercise.
    /// Sorted by `lastPerformed` desc so the freshest activity floats up.
    static func personalRecords(from sets: [LoggedSet]) -> [PersonalRecord] {
        var bucket: [String: [LoggedSet]] = [:]
        for set in sets {
            let key = (set.exerciseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            bucket[key, default: []].append(set)
        }

        let records: [PersonalRecord] = bucket.compactMap { name, group in
            guard let heaviest = group.max(by: { $0.weightLbs < $1.weightLbs }) else {
                return nil
            }
            let bestReps = group
                .filter { $0.weightLbs == heaviest.weightLbs }
                .map { Int($0.reps) }
                .max() ?? Int(heaviest.reps)
            let lastPerformed = group
                .compactMap { $0.completedAt }
                .max() ?? Date.distantPast
            return PersonalRecord(
                exerciseName: name,
                bestWeightLbs: heaviest.weightLbs,
                bestReps: bestReps,
                lastPerformed: lastPerformed
            )
        }

        return records.sorted { $0.lastPerformed > $1.lastPerformed }
    }

    // MARK: - Time-series points

    /// Reduce a `LoggedSet` slice into one point per session for the chosen
    /// metric within the chosen window. Sessions with no usable value (e.g.
    /// volume of an empty group) are dropped.
    static func points(
        sets: [LoggedSet],
        metric: ProgressMetric,
        range: TimeRange,
        now: Date = Date()
    ) -> [ProgressPoint] {
        let cutoff = range.cutoff(from: now)
        let inRange = sets.filter { ($0.completedAt ?? .distantPast) >= cutoff }

        var grouped: [NSManagedObjectID: [LoggedSet]] = [:]
        var ungrouped: [LoggedSet] = []
        for set in inRange {
            if let sid = set.session?.objectID {
                grouped[sid, default: []].append(set)
            } else {
                ungrouped.append(set)
            }
        }

        var points: [ProgressPoint] = grouped.compactMap { sid, group in
            guard let value = reduce(group, metric: metric) else { return nil }
            let date = group.compactMap { $0.completedAt }.min() ?? Date.distantPast
            return ProgressPoint(date: date, value: value, sessionID: sid)
        }

        // Stragglers without a session — bucket them per-day so the chart
        // doesn't show a noisy point per orphan set.
        let cal = Calendar.current
        let perDay = Dictionary(grouping: ungrouped) { set -> Date in
            cal.startOfDay(for: set.completedAt ?? Date())
        }
        for (day, group) in perDay {
            guard let value = reduce(group, metric: metric) else { continue }
            points.append(ProgressPoint(date: day, value: value, sessionID: nil))
        }

        return points.sorted { $0.date < $1.date }
    }

    /// Per-metric reduction over a single session's sets.
    private static func reduce(_ group: [LoggedSet], metric: ProgressMetric) -> Double? {
        guard !group.isEmpty else { return nil }
        switch metric {
        case .weight:
            return group.map { $0.weightLbs }.max()
        case .volume:
            let total = group.reduce(0.0) { $0 + $1.weightLbs * Double($1.reps) }
            return total > 0 ? total : nil
        case .oneRepMax:
            return group.map { $0.weightLbs * (1.0 + Double($0.reps) / 30.0) }.max()
        case .reps:
            return group.map { Double($0.reps) }.max()
        }
    }

    // MARK: - Streak

    /// Consecutive-day workout streak counting back from `now` (default today).
    /// A day "counts" if it contains at least one `WorkoutSession.startedAt`.
    /// If `now` itself has no session, we still allow the streak to start at
    /// "yesterday" (so the user doesn't see their streak collapse mid-morning
    /// before they've worked out today).
    static func currentStreak(sessions: [WorkoutSession], now: Date = Date()) -> Int {
        let cal = Calendar.current
        let activeDays: Set<Date> = Set(
            sessions.compactMap { $0.startedAt.map { cal.startOfDay(for: $0) } }
        )
        guard !activeDays.isEmpty else { return 0 }

        var cursor = cal.startOfDay(for: now)
        if !activeDays.contains(cursor) {
            // Allow grace for "today not yet logged" — anchor at yesterday.
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while activeDays.contains(cursor) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    // MARK: - Recent PRs

    /// One PR delta — a set whose weight strictly exceeded the prior best for
    /// that exercise at the time it was logged. Used by the home dashboard's
    /// "Recent PRs" card.
    struct PRDelta: Identifiable, Hashable {
        let id = UUID()
        let exerciseName: String
        let newWeightLbs: Double
        let deltaLbs: Double
        let date: Date
    }

    /// Walks `sets` in chronological order tracking the running max weight per
    /// exercise. Each strict increase emits a `PRDelta`. Returns the most
    /// recent `limit` deltas (newest first).
    static func recentPRs(sets: [LoggedSet], limit: Int = 5) -> [PRDelta] {
        let chronological = sets.sorted {
            ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast)
        }
        var bestSoFar: [String: Double] = [:]
        var deltas: [PRDelta] = []
        for set in chronological {
            let name = (set.exerciseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let date = set.completedAt else { continue }
            let prior = bestSoFar[name] ?? 0
            if set.weightLbs > prior && set.weightLbs > 0 {
                deltas.append(PRDelta(
                    exerciseName: name,
                    newWeightLbs: set.weightLbs,
                    deltaLbs: set.weightLbs - prior,
                    date: date
                ))
                bestSoFar[name] = set.weightLbs
            } else if set.weightLbs > prior {
                bestSoFar[name] = set.weightLbs
            }
        }
        return Array(deltas.sorted { $0.date > $1.date }.prefix(limit))
    }
}
