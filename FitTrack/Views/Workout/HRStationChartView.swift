import SwiftUI
import Charts
import HealthKit
import CoreData

/// HR-over-time chart for a single completed session, with horizontal bands
/// indicating which station (= exercise) the user was on. Pushed from
/// UnifiedSessionView when the user taps the AVG HR / MAX HR tile.
///
/// The X axis is wall-clock time (workout start → end); the Y axis is bpm.
/// One `LineMark` series for HR; one `RectangleMark` per station window so
/// the user can read "this spike happened during dumbbell snatches" at a
/// glance. Stations are derived from `LoggedSet.completedAt` — the earliest
/// and latest completedAt for a given exerciseName form the band.
struct HRStationChartView: View {
    let session: WorkoutSession
    let hkWorkout: HKWorkout

    @State private var samples: [HRPoint] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                headerCard
                chartCard
                if !stations.isEmpty {
                    legendSection
                }
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
            let raw = await HealthKitService.shared.heartRateSamples(for: hkWorkout)
            // Clamp samples to the workout window — HK can return strays that
            // bleed into the rest of the day, which warps the auto Y-domain.
            let window = hkWorkout.startDate...hkWorkout.endDate
            samples = raw
                .filter { window.contains($0.date) }
                .map { HRPoint(date: $0.date, bpm: $0.bpm) }
            loaded = true
            AppLogger.shared.log("HRStationChartView loaded — \(samples.count) HR samples in window, \(stations.count) stations", category: "ui")
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
            ForEach(stations) { st in
                RectangleMark(
                    xStart: .value("start", st.start),
                    xEnd: .value("end", st.end),
                    yStart: .value("y0", yDomain.lowerBound),
                    yEnd: .value("y1", yDomain.upperBound)
                )
                .foregroundStyle(st.tint.opacity(st.isPrimary ? 0.18 : 0.05))
            }
            ForEach(samples) { p in
                LineMark(
                    x: .value("time", p.date),
                    y: .value("bpm", p.bpm)
                )
                .foregroundStyle(Theme.Colors.accent)
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: hkWorkout.startDate...hkWorkout.endDate)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Theme.Colors.border.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour().minute(),
                               anchor: .top)
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

    // MARK: - Legend

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Stations")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
            ForEach(stations.filter { $0.isPrimary }) { st in
                stationRow(st)
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

    private func stationRow(_ st: Station) -> some View {
        let avg = avgBpm(in: st.start...st.end)
        let secs = Int(st.end.timeIntervalSince(st.start))
        let m = secs / 60, s = secs % 60
        return HStack(spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: 3)
                .fill(st.tint.opacity(0.85))
                .frame(width: 12, height: 12)
            Text(st.name)
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.sm)
            Text(String(format: "%d:%02d", m, s))
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(avg.map { "\(Int($0)) bpm" } ?? "—")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    // MARK: - Derived

    /// Class-structured station bands. Delegates to the shared
    /// `ClassSchedule.classStations(for:firstSetDate:)` so this drill-in chart
    /// and the inline `SessionHRTraceChart` on UnifiedSessionView never
    /// disagree on where a station starts. When the user has logged any sets,
    /// we anchor station 1 to the earliest checked set instead of guessing
    /// from the workout end.
    private var stations: [Station] {
        ClassSchedule.classStations(
            for: hkWorkout,
            firstSetDate: ClassSchedule.firstSetDate(in: session)
        )
    }

    /// Y-axis range padded ±10 bpm around the actual sample range so the line
    /// doesn't kiss the chart edges. Falls back to a sensible default if no
    /// samples (the empty-state takes over before we ever draw, but keeps
    /// the type non-optional).
    private var yDomain: ClosedRange<Double> {
        guard let mn = samples.map({ $0.bpm }).min(),
              let mx = samples.map({ $0.bpm }).max() else {
            return 60...180
        }
        let lo = floor((mn - 10) / 10) * 10
        let hi = ceil((mx + 10) / 10) * 10
        return max(40, lo)...min(220, hi)
    }

    private func avgBpm(in range: ClosedRange<Date>) -> Double? {
        let inRange = samples.filter { range.contains($0.date) }
        guard !inRange.isEmpty else { return nil }
        return inRange.map { $0.bpm }.reduce(0, +) / Double(inRange.count)
    }

    private var durationLabel: String {
        let total = Int(hkWorkout.duration)
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
