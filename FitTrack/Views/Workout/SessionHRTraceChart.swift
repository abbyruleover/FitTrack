import SwiftUI
import Charts

/// Apple Fitness-style scrubbable HR trace shown at the top of
/// `UnifiedSessionView`. Drag horizontally across the chart to move a
/// vertical rule + colored dot to the nearest sample; the tooltip card
/// pinned at top-leading reads bpm + time.
///
/// Visually mirrors `HRStationChartView`: same RectangleMark station bands +
/// LineMark trace. Bands come from `ClassSchedule.classStations(for:)` so
/// both charts share one source of truth for class-slot-anchored windows.
/// When `stations` is empty (Sunday solo, off-grid time) we just draw the
/// trace.
struct SessionHRTraceChart: View {
    let samples: [HRPoint]
    let workoutWindow: ClosedRange<Date>?
    let stations: [Station]

    @State private var hoveredSample: HRPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Heart rate")
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                if !samples.isEmpty {
                    Text("Drag to scrub")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }

            if samples.isEmpty {
                emptyState
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

    // MARK: - Chart

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
            if let h = hoveredSample {
                RuleMark(x: .value("scrub", h.date))
                    .foregroundStyle(Theme.Colors.textTertiary.opacity(0.7))
                PointMark(
                    x: .value("scrub", h.date),
                    y: .value("bpm", h.bpm)
                )
                .foregroundStyle(Theme.Colors.accent)
                .symbolSize(120)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let originX = geo[plotFrame].origin.x
                                let width = geo[plotFrame].size.width
                                let x = v.location.x - originX
                                guard x >= 0, x <= width else { return }
                                guard let date: Date = proxy.value(atX: x) else { return }
                                hoveredSample = samples.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                })
                            }
                            // Keep the tooltip pinned after release — Apple
                            // Fitness behaves the same way; lifting your
                            // finger doesn't erase the value you scrubbed to.
                    )
            }
        }
        .chartOverlay { _ in
            // Separate overlay for the tooltip card so it doesn't intercept
            // gestures from the scrub layer above. Aligned to the chart's
            // top-leading corner regardless of where the user is dragging.
            VStack {
                HStack {
                    if let h = hoveredSample {
                        tooltipCard(for: h)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 220)
    }

    private func tooltipCard(for sample: HRPoint) -> some View {
        let station = stationName(at: sample.date)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(sample.bpm))")
                    .font(Theme.Fonts.header(18))
                    .foregroundStyle(Theme.Colors.accent)
                Text("bpm")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            if let station {
                Text(station.uppercased())
                    .font(Theme.Fonts.mono(9))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            Text(timeLabel(sample.date))
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.background.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    /// Returns the station whose window contains `date`, if any. Empty
    /// `stations` (Watch-only days, off-grid times) yields nil — the tooltip
    /// then just shows bpm + time.
    private func stationName(at date: Date) -> String? {
        stations.first { st in
            date >= st.start && date <= st.end
        }?.name
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No HR samples")
                .font(Theme.Fonts.header(13))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Watch wasn't worn or HR access denied.")
                .font(Theme.Fonts.body(12))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Domains + formatters

    /// Falls back to the sample range when no workout window is supplied —
    /// covers the Watch-only / non-class case where caller passes nil.
    private var xDomain: ClosedRange<Date> {
        if let w = workoutWindow { return w }
        let dates = samples.map(\.date)
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else {
            let now = Date()
            return now...now.addingTimeInterval(60)
        }
        return lo...hi
    }

    /// Pad ±10 bpm around the sample range so the line doesn't kiss the
    /// chart edges. Bounded into [40, 220] so a stray outlier doesn't blow
    /// out the scale.
    private var yDomain: ClosedRange<Double> {
        guard let mn = samples.map(\.bpm).min(),
              let mx = samples.map(\.bpm).max() else {
            return 60...180
        }
        let lo = floor((mn - 10) / 10) * 10
        let hi = ceil((mx + 10) / 10) * 10
        return max(40, lo)...min(220, hi)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: d)
    }
}
