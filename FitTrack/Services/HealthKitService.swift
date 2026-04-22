import Foundation
import HealthKit

/// Thin wrapper around `HKHealthStore` for the Health tab.
///
/// Reads body metrics + Apple Watch fitness data the user already records
/// elsewhere (Apple Watch logs workouts, body weight comes from scales/manual
/// entry). The only write path is `writeInBodyScan` — used by the InBody PDF
/// import flow to push the HealthKit-supported subset of a scan back into
/// Apple Health so the iPhone Health app stays in sync.
@MainActor
final class HealthKitService: ObservableObject {
    static let shared = HealthKitService()

    private let store = HKHealthStore()

    /// True once `requestAuthorizationIfNeeded()` has resolved with at least
    /// the body-mass type granted. Drives the Health tab's auth-CTA state.
    @Published var isAuthorized: Bool = false

    /// HealthKit isn't available on Mac Catalyst / some simulators — the tab
    /// gracefully degrades to a "Not available" card when this is false.
    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Type sets

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.leanBodyMass),
            HKQuantityType(.bodyMassIndex),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.vo2Max),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.appleStandTime),
            HKObjectType.activitySummaryType(),
            HKWorkoutType.workoutType()
        ]
    }

    private var writeTypes: Set<HKSampleType> {
        [
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.leanBodyMass),
            HKQuantityType(.bodyMassIndex),
            HKQuantityType(.basalEnergyBurned)
        ]
    }

    // MARK: - Authorization

    /// Prompts once for read+write permissions across every type the app uses.
    /// HealthKit only shows the sheet on the first call per type set; later
    /// calls resolve immediately. Auth status is per-type and not directly
    /// observable for read access — we treat "no error from request" as
    /// authorized for the purpose of unblocking the dashboard.
    func requestAuthorizationIfNeeded() async {
        guard isHealthDataAvailable else {
            isAuthorized = false
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
    }

    // MARK: - Quantity reads

    /// Most recent body mass sample in pounds, or nil if none/no auth.
    func latestBodyMassLbs() async -> Double? {
        await mostRecentQuantity(.bodyMass, unit: .pound())
    }

    func latestBodyFatPct() async -> Double? {
        // bodyFatPercentage is stored as a unit fraction (0.0-1.0).
        if let v = await mostRecentQuantity(.bodyFatPercentage, unit: .percent()) {
            return v * 100
        }
        return nil
    }

    func latestRestingHRBpm() async -> Double? {
        await mostRecentQuantity(.restingHeartRate, unit: HKUnit(from: "count/min"))
    }

    func latestHRVms() async -> Double? {
        await mostRecentQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli))
    }

    // MARK: - Weekly aggregates

    func weeklyActiveEnergyKcal() async -> Double? {
        await sumLast7Days(.activeEnergyBurned, unit: .kilocalorie())
    }

    func weeklyExerciseMinutes() async -> Int? {
        guard let v = await sumLast7Days(.appleExerciseTime, unit: .minute()) else { return nil }
        return Int(v.rounded())
    }

    // MARK: - Activity rings

    /// Today's Move/Exercise/Stand summary (the data behind the iOS Fitness
    /// rings). Returns nil if HK is unavailable, the user denied access, or
    /// the day hasn't recorded any activity yet. Apple Watch syncs the summary
    /// to iPhone hourly, so a fresh-out-of-the-box morning may legitimately
    /// have no row for "today" until the watch checks in.
    func todaysActivitySummary() async -> HKActivitySummary? {
        guard isHealthDataAvailable else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: comps, end: comps)

        return await withCheckedContinuation { continuation in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, _ in
                continuation.resume(returning: summaries?.first)
            }
            store.execute(q)
        }
    }

    // MARK: - Workouts

    /// Returns the N most recent `HKWorkout` samples (sorted desc by start).
    /// Empty list if HK is unavailable or read auth is denied.
    func recentWorkouts(limit: Int = 10) async -> [HKWorkout] {
        guard isHealthDataAvailable else { return [] }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: nil,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Most recent `.highIntensityIntervalTraining` workout from start-of-today
    /// to now, or nil if the user hasn't done one yet today. Used by
    /// WorkoutView's "Today's training" home card to surface the matching
    /// Apple Watch HIIT session next to the day's logged FitTrack workout.
    func todaysHIITWorkout() async -> HKWorkout? {
        guard isHealthDataAvailable else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = Date()
        let datePred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let typePred = HKQuery.predicateForWorkouts(with: .highIntensityIntervalTraining)
        let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, typePred])

        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: combined,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let result = (samples as? [HKWorkout])?.first
                AppLogger.shared.log("todaysHIITWorkout → \(result.map { "duration=\(Int($0.duration))s" } ?? "nil")", category: "health")
                continuation.resume(returning: result)
            }
            store.execute(q)
        }
    }

    /// Returns the set of start-of-day dates that have at least one HIIT
    /// `HKWorkout` in the last `days` days. Used by the Progress tab's
    /// calendar to decide which day cells render a dot. Defaults to a 6-month
    /// window so the calendar feels populated without overscanning history.
    func hiitWorkoutDates(days: Int = 180) async -> Set<Date> {
        guard isHealthDataAvailable else { return [] }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -days, to: end) ?? end
        let datePred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let typePred = HKQuery.predicateForWorkouts(with: .highIntensityIntervalTraining)
        let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, typePred])

        return await withCheckedContinuation { continuation in
            let q = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: combined,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout]) ?? []
                let days = Set(workouts.map { cal.startOfDay(for: $0.startDate) })
                AppLogger.shared.log("hiitWorkoutDates → \(workouts.count) workouts, \(days.count) unique days", category: "health")
                continuation.resume(returning: days)
            }
            store.execute(q)
        }
    }

    /// First HIIT workout that started on the given calendar day, or nil.
    /// Used by Progress drill-downs to open the unified summary screen.
    func hiitWorkout(on date: Date) async -> HKWorkout? {
        guard isHealthDataAvailable else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        let datePred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let typePred = HKQuery.predicateForWorkouts(with: .highIntensityIntervalTraining)
        let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [datePred, typePred])

        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: combined,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout])?.first)
            }
            store.execute(q)
        }
    }

    /// Active calories, average HR, max HR for the workout's time window.
    /// Active kcal pulls the workout's own statistics (no HR aggregation
    /// available there); HR comes from a separate HR-sample query bracketed
    /// by the workout's start/end. Either HR field is nil if no samples
    /// were captured (e.g. user wore the watch loose).
    func watchStats(for workout: HKWorkout) async -> (activeKcal: Double, avgHR: Double?, maxHR: Double?) {
        let kcalType = HKQuantityType(.activeEnergyBurned)
        let kcal = workout.statistics(for: kcalType)?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie()) ?? 0

        guard isHealthDataAvailable else { return (kcal, nil, nil) }

        let hrType = HKQuantityType(.heartRate)
        let bpm = HKUnit(from: "count/min")
        let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])

        let stats: HKStatistics? = await withCheckedContinuation { continuation in
            let q = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: pred,
                options: [.discreteAverage, .discreteMax]
            ) { _, stats, _ in
                continuation.resume(returning: stats)
            }
            store.execute(q)
        }
        let avg = stats?.averageQuantity()?.doubleValue(for: bpm)
        let max = stats?.maximumQuantity()?.doubleValue(for: bpm)
        return (kcal, avg, max)
    }

    /// Time-series HR samples bracketed by a workout's start/end. Sorted
    /// ascending by date so the chart can render a left→right line. Returns
    /// an empty array when HK is unavailable, the user denied HR access, or
    /// the watch wasn't recording (e.g. dead battery).
    ///
    /// Rate-of-samples is typically one every ~5 seconds during a workout —
    /// fine to render as a single LineMark series without downsampling.
    func heartRateSamples(for workout: HKWorkout) async -> [(date: Date, bpm: Double)] {
        guard isHealthDataAvailable else { return [] }
        let hrType = HKQuantityType(.heartRate)
        let bpmUnit = HKUnit(from: "count/min")
        let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])

        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(
                sampleType: hrType,
                predicate: pred,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let mapped = (samples as? [HKQuantitySample] ?? []).map {
                    (date: $0.startDate, bpm: $0.quantity.doubleValue(for: bpmUnit))
                }
                AppLogger.shared.log("heartRateSamples → \(mapped.count) samples for workout \(Int(workout.duration))s", category: "health")
                continuation.resume(returning: mapped)
            }
            store.execute(q)
        }
    }

    // MARK: - InBody write

    /// Push the HealthKit-supported subset of a parsed InBody scan into Apple
    /// Health, dated at the scan's test date. Silently no-ops if a particular
    /// metric is 0 (= not parsed). Throws if HK rejects the save.
    func writeInBodyScan(_ scan: InBodyPDFParser.Scan) async throws {
        guard isHealthDataAvailable else { return }

        var samples: [HKQuantitySample] = []
        let date = scan.scanDate
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: true,
            "FitTrackSource": "InBody PDF Import"
        ]

        if scan.weightLbs > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .pound(), doubleValue: scan.weightLbs),
                start: date, end: date, metadata: metadata
            ))
        }
        if scan.bodyFatPercentage > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.bodyFatPercentage),
                quantity: HKQuantity(unit: .percent(), doubleValue: scan.bodyFatPercentage / 100.0),
                start: date, end: date, metadata: metadata
            ))
        }
        if scan.leanBodyMassLbs > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.leanBodyMass),
                quantity: HKQuantity(unit: .pound(), doubleValue: scan.leanBodyMassLbs),
                start: date, end: date, metadata: metadata
            ))
        }
        if scan.bmi > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.bodyMassIndex),
                quantity: HKQuantity(unit: .count(), doubleValue: scan.bmi),
                start: date, end: date, metadata: metadata
            ))
        }
        if scan.basalMetabolicRateKcal > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.basalEnergyBurned),
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: scan.basalMetabolicRateKcal),
                start: date, end: date, metadata: metadata
            ))
        }

        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    // MARK: - Helpers

    /// Most recent sample of a quantity type, mapped through `unit`. Returns
    /// nil when no samples exist or the query fails (which includes "read
    /// access denied" — HealthKit refuses to differentiate denial from "no
    /// data" for privacy reasons).
    private func mostRecentQuantity(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard isHealthDataAvailable else { return nil }
        let type = HKQuantityType(id)
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                if let s = samples?.first as? HKQuantitySample {
                    continuation.resume(returning: s.quantity.doubleValue(for: unit))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            store.execute(q)
        }
    }

    /// Sum of a cumulative quantity (e.g. activeEnergyBurned, exerciseTime)
    /// over the trailing 7 days. Nil if HK rejects the stats query.
    private func sumLast7Days(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard isHealthDataAvailable else { return nil }
        let type = HKQuantityType(id)
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        return await withCheckedContinuation { continuation in
            let q = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }
}
