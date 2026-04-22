import SwiftUI
import CoreData
import Charts

/// Per-exercise drill-down: time-range + metric pills above a Swift Charts
/// line, stats strip below. Tapping a chart point pins that day's logged sets
/// for THIS exercise into an inline card under the stats strip — keeps the
/// user on the same screen instead of pushing a sheet.
struct ExerciseProgressDetailView: View {
    let exerciseName: String

    @Environment(\.managedObjectContext) private var context

    @FetchRequest private var sets: FetchedResults<LoggedSet>

    @State private var metric: ProgressAggregator.ProgressMetric = .weight
    @State private var range: ProgressAggregator.TimeRange = .month
    @State private var selectedDate: Date?
    @State private var pinnedDate: Date?

    init(exerciseName: String) {
        self.exerciseName = exerciseName
        _sets = FetchRequest<LoggedSet>(
            entity: LoggedSet.entity(),
            sortDescriptors: [NSSortDescriptor(key: "completedAt", ascending: true)],
            predicate: NSPredicate(format: "exerciseName ==[c] %@", exerciseName)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                rangePills
                metricPills
                chartCard
                statsStrip
                if pinnedDate != nil {
                    selectedSessionCard
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            AppLogger.shared.log("ExerciseProgressDetailView appeared — \(exerciseName) (\(sets.count) total sets)", category: "ui")
        }
    }

    // MARK: - Pills

    private var rangePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ProgressAggregator.TimeRange.allCases, id: \.self) { r in
                    Pill(label: r.displayLabel, isSelected: r == range) {
                        range = r
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var metricPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ProgressAggregator.ProgressMetric.allCases, id: \.self) { m in
                    Pill(label: m.displayName, isSelected: m == metric) {
                        metric = m
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Chart

    private var points: [ProgressAggregator.ProgressPoint] {
        ProgressAggregator.points(sets: Array(sets), metric: metric, range: range)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(metric.displayName)
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(range.displayLabel)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            if points.isEmpty {
                emptyChart
            } else {
                Chart(points) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value(metric.displayName, p.value)
                    )
                    .foregroundStyle(Theme.Colors.accent)
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Date", p.date),
                        y: .value(metric.displayName, p.value)
                    )
                    .foregroundStyle(Theme.Colors.accent)
                    .symbolSize(40)
                }
                .chartYScale(domain: ChartDomain.padded(values: points.map(\.value)))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(format: xAxisFormat)
                            .foregroundStyle(Theme.Colors.textTertiary)
                        AxisGridLine().foregroundStyle(Theme.Colors.border)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().foregroundStyle(Theme.Colors.textTertiary)
                        AxisGridLine().foregroundStyle(Theme.Colors.border)
                    }
                }
                .chartXSelection(value: $selectedDate)
                .frame(height: 220)
                .onChange(of: selectedDate) { _, newValue in
                    guard let newValue else { return }
                    // Snap to the nearest available data point so the inline
                    // card always corresponds to a real session, even if the
                    // user dragged between two points.
                    let snapped = nearestPointDate(to: newValue) ?? Calendar.current.startOfDay(for: newValue)
                    pinnedDate = snapped
                    AppLogger.shared.log("chart point selected → \(ISO8601DateFormatter().string(from: snapped))", category: "ui")
                }
            }
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

    private var emptyChart: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No data in this range")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .month, .sixMonth: return .dateTime.month(.abbreviated).day()
        case .year, .threeYear: return .dateTime.month(.abbreviated).year(.twoDigits)
        case .fiveYear, .tenYear: return .dateTime.year()
        }
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        let inRange = points
        let current = inRange.last?.value
        let allTimePR = Array(sets).map { allTimeValue(for: $0) }.max() ?? 0
        let lastDate = sets.compactMap { $0.completedAt }.max()

        return HStack(spacing: Theme.Spacing.md) {
            statTile(label: "Current", value: current.map { format($0) } ?? "—", suffix: metric.unitSuffix)
            statTile(label: "All-time PR", value: format(allTimePR), suffix: metric.unitSuffix)
            statTile(label: "Last", value: lastDate.map { dateLabel($0) } ?? "—", suffix: nil)
        }
    }

    private func statTile(label: String, value: String, suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let suffix {
                    Text(suffix)
                        .font(Theme.Fonts.mono(10))
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
    }

    /// All-time per-set value used by the right-most stat tile. Mirrors the
    /// reduction in `ProgressAggregator.reduce` but per-set, since the stat
    /// tile measures the heaviest single set rather than per-session totals.
    private func allTimeValue(for set: LoggedSet) -> Double {
        switch metric {
        case .weight:    return set.weightLbs
        case .volume:    return set.weightLbs * Double(set.reps)
        case .oneRepMax: return set.weightLbs * (1.0 + Double(set.reps) / 30.0)
        case .reps:      return Double(set.reps)
        }
    }

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f.string(from: d)
    }

    // MARK: - Inline session card

    /// Returns the chart-point date closest to a raw selection. Without this
    /// the user would frequently land on a day with no logged set for this
    /// exercise (chart x-axis is continuous; logged data is sparse).
    private func nearestPointDate(to raw: Date) -> Date? {
        let pts = points
        guard !pts.isEmpty else { return nil }
        return pts.min(by: {
            abs($0.date.timeIntervalSince(raw)) < abs($1.date.timeIntervalSince(raw))
        })?.date
    }

    /// Sets logged for THIS exercise on the pinned day, ordered by setIndex.
    private var setsOnPinnedDate: [LoggedSet] {
        guard let pinnedDate else { return [] }
        let cal = Calendar.current
        let day = cal.startOfDay(for: pinnedDate)
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return [] }
        return Array(sets)
            .filter { ($0.completedAt.map { day <= $0 && $0 < next }) ?? false }
            .sorted { $0.setIndex < $1.setIndex }
    }

    private var selectedSessionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(pinnedDate.map { sessionHeaderLabel($0) } ?? "")
                        .font(Theme.Fonts.header(15))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                Spacer()
                Button {
                    AppLogger.shared.log("inline session card dismissed", category: "ui")
                    pinnedDate = nil
                    selectedDate = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(Theme.Colors.border)

            if setsOnPinnedDate.isEmpty {
                Text("No \(exerciseName) sets logged on this day.")
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.vertical, Theme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(setsOnPinnedDate, id: \.objectID) { set in
                        HStack {
                            Text("Set \(set.setIndex)")
                                .font(Theme.Fonts.mono(12))
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .frame(width: 56, alignment: .leading)
                            Text(setLabel(for: set))
                                .font(Theme.Fonts.mono(13))
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                            Text("\(Int(set.weightLbs * Double(set.reps))) lbs vol")
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                }
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
                .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
        )
    }

    private func sessionHeaderLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy"
        return f.string(from: d)
    }

    private func setLabel(for set: LoggedSet) -> String {
        let w = set.weightLbs
        let weightStr = w == 0
            ? "BW"
            : (w.truncatingRemainder(dividingBy: 1) == 0
               ? String(format: "%.0f", w)
               : String(w))
        return "\(weightStr) lbs × \(set.reps)"
    }
}

// MARK: - Pill

private struct Pill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(isSelected ? Theme.Colors.background : Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Theme.Colors.accent : Color.clear)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Theme.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ExerciseProgressDetailView(exerciseName: "Bench Press")
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
