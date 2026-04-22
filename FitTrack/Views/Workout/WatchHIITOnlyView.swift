import SwiftUI
import HealthKit
import Charts

/// Day-summary screen for a calendar day where only an Apple Watch HIIT
/// workout exists — no FitTrack `WorkoutSession` was logged. Reached from
/// `SessionDayView`'s fall-through row, or directly from the Progress
/// calendar's 1-click router on Watch-only days.
///
/// Mirrors the post-Round-6 `UnifiedSessionView`: scrubbable HR trace at top,
/// then raw-unit TIME / KCAL / VOLUME row (VOLUME is "—" since there's no
/// logged sets), then watch stats. Footer explains why VOLUME is blank.
struct WatchHIITOnlyView: View {
    let day: Date

    @State private var hkWorkout: HKWorkout?
    @State private var loaded = false
    @State private var activeKcal: Double = 0
    @State private var avgHR: Double?
    @State private var maxHR: Double?
    @State private var hrSamples: [HRPoint] = []

    @Environment(\.managedObjectContext) private var context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !loaded {
                    placeholder
                } else if let w = hkWorkout {
                    Text(dateLabel(w))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    SessionHRTraceChart(
                        samples: hrSamples,
                        workoutWindow: w.startDate...w.endDate,
                        stations: ClassSchedule.classStations(for: w)
                    )
                    rawUnitsRow(w)
                    statsRow(w)
                    noFitTrackFooter
                } else {
                    missingWorkout
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            hkWorkout = await HealthKitService.shared.hiitWorkout(on: day)
            loaded = true
            if let w = hkWorkout {
                let stats = await HealthKitService.shared.watchStats(for: w)
                activeKcal = stats.activeKcal
                avgHR = stats.avgHR
                maxHR = stats.maxHR
                let raw = await HealthKitService.shared.heartRateSamples(for: w)
                let window = w.startDate...w.endDate
                hrSamples = raw
                    .filter { window.contains($0.date) }
                    .map { HRPoint(date: $0.date, bpm: $0.bpm) }
                AppLogger.shared.log("WatchHIITOnlyView loaded — kcal=\(Int(activeKcal)) hr=\(hrSamples.count)samples", category: "ui")
            } else {
                AppLogger.shared.log("WatchHIITOnlyView loaded — no HK workout for \(dayLabel)", category: "ui")
            }
        }
    }

    // MARK: - Raw-units row

    /// Same TIME / KCAL / VOLUME triple as UnifiedSessionView. VOLUME is "—"
    /// because we have no logged sets — the noFitTrackFooter explains that
    /// to the user.
    private func rawUnitsRow(_ w: HKWorkout) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            statTile(label: "TIME", value: durationLabel(w), suffix: nil)
            statTile(label: "KCAL", value: "\(Int(activeKcal))", suffix: "kcal")
            statTile(label: "VOLUME", value: "—", suffix: "lbs")
        }
    }

    // MARK: - Stats row

    private func statsRow(_ w: HKWorkout) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            hrTile(label: "AVG HR", value: avgHR.map { "\(Int($0))" } ?? "—", workout: w)
            hrTile(label: "MAX HR", value: maxHR.map { "\(Int($0))" } ?? "—", workout: w)
            statTile(label: "ELAPSED", value: durationLabel(w), suffix: nil)
        }
    }

    private func statTile(label: String, value: String, suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let suffix {
                    Text(suffix)
                        .font(Theme.Fonts.mono(9))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
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

    /// HR tile for the no-FitTrack case — pushes a HK-only HR chart route
    /// since we don't have a session ID to thread through `HRChartRoute`.
    private func hrTile(label: String, value: String, workout: HKWorkout) -> some View {
        NavigationLink(value: WatchOnlyHRChartRoute(day: Calendar.current.startOfDay(for: workout.startDate))) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(Theme.Fonts.mono(9))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Image(systemName: "chevron.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(Theme.Fonts.header(16))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("bpm")
                        .font(Theme.Fonts.mono(9))
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
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var noFitTrackFooter: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No FitTrack session was logged for this day, so the VOLUME ring and exercise breakdown aren't available.")
                .font(Theme.Fonts.body(12))
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    // MARK: - Empty / loading

    private var placeholder: some View {
        HStack {
            Spacer()
            SwiftUI.ProgressView().tint(Theme.Colors.accent)
            Spacer()
        }
        .frame(minHeight: 200)
    }

    private var missingWorkout: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No Apple Watch workout for this day")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Derived

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: day)
    }

    private func dateLabel(_ w: HKWorkout) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d • h:mm a"
        let base = f.string(from: w.startDate)
        if let slot = ClassSchedule.slot(for: w.startDate) {
            return "\(base) · \(slot.label) class"
        }
        return base
    }

    private func durationLabel(_ w: HKWorkout) -> String {
        let total = Int(w.duration)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Watch-only HR chart route

/// Route for pushing the per-station HR chart from a Watch-only day. Uses
/// `day` instead of a session ID since there's no `WorkoutSession` to anchor
/// the chart's station bands to — the chart will still show the HR line, just
/// without colored bands underneath.
struct WatchOnlyHRChartRoute: Hashable {
    let day: Date
}

/// Loader that resolves the HK workout for a given day, then renders the
/// HR chart with no station bands (no FitTrack session = no station data).
struct WatchOnlyHRChartLoader: View {
    let day: Date

    @State private var hkWorkout: HKWorkout?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let hk = hkWorkout {
                WatchOnlyHRChart(workout: hk)
            } else if loaded {
                missing
            } else {
                HStack { Spacer(); SwiftUI.ProgressView().tint(Theme.Colors.accent); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.background.ignoresSafeArea())
            }
        }
        .task {
            hkWorkout = await HealthKitService.shared.hiitWorkout(on: day)
            loaded = true
        }
    }

    private var missing: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No Apple Watch workout for this day")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Watch-only HR chart

/// HR-over-time chart for a Watch-only day. Mirrors `HRStationChartView`'s
/// stat tiles + line chart, but skips the per-station bands since there's no
/// FitTrack session (and therefore no `LoggedSet.completedAt`) to anchor
/// station windows to.
struct WatchOnlyHRChart: View {
    let workout: HKWorkout

    @State private var samples: [HRPoint] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                headerCard
                chartCard
            }
            .padding(Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            let raw = await HealthKitService.shared.heartRateSamples(for: workout)
            let window = workout.startDate...workout.endDate
            samples = raw
                .filter { window.contains($0.date) }
                .map { HRPoint(date: $0.date, bpm: $0.bpm) }
            loaded = true
            AppLogger.shared.log("WatchOnlyHRChart loaded — \(samples.count) HR samples in window", category: "ui")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        let avg = samples.isEmpty ? nil : samples.map { $0.bpm }.reduce(0, +) / Double(samples.count)
        let mx = samples.map { $0.bpm }.max()
        let mn = samples.map { $0.bpm }.min()
        return HStack(spacing: Theme.Spacing.sm) {
            statTile(label: "AVG", value: avg.map { "\(Int($0))" } ?? "—")
            statTile(label: "MAX", value: mx.map { "\(Int($0))" } ?? "—")
            statTile(label: "MIN", value: mn.map { "\(Int($0))" } ?? "—")
            statTile(label: "DURATION", value: durationLabel)
        }
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(value)
                .font(Theme.Fonts.header(16))
                .foregroundStyle(Theme.Colors.textPrimary)
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

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("HR over time")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)

            if !loaded {
                HStack {
                    Spacer()
                    SwiftUI.ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Colors.accent)
                    Spacer()
                }
                .frame(height: 240)
            } else if samples.isEmpty {
                emptyChart
            } else {
                chart
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { p in
                LineMark(
                    x: .value("time", p.date),
                    y: .value("bpm", p.bpm)
                )
                .foregroundStyle(Theme.Colors.accent)
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: workout.startDate...workout.endDate)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.Colors.border.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.Colors.border.opacity(0.3))
                AxisValueLabel().foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(height: 240)
    }

    private var emptyChart: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "heart.slash")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No HR samples")
                .font(Theme.Fonts.header(13))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Either the watch wasn't recording or HR access is denied.")
                .font(Theme.Fonts.body(12))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var yDomain: ClosedRange<Double> {
        guard let mn = samples.map({ $0.bpm }).min(),
              let mx = samples.map({ $0.bpm }).max() else {
            return 60...180
        }
        let lo = floor((mn - 10) / 10) * 10
        let hi = ceil((mx + 10) / 10) * 10
        return max(40, lo)...min(220, hi)
    }

    private var durationLabel: String {
        let total = Int(workout.duration)
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
