import SwiftUI
import CoreData
import Charts

/// Per-metric progress drill-down for InBody scans. Mirrors the layout of
/// `ExerciseProgressDetailView` (range + metric pills above a Swift Charts
/// line, stats strip below) so the two surfaces feel identical.
///
/// Tapping a chart point opens the full `InBodyDetailView` for that scan
/// — the same drill-down the History view uses, so users land in a
/// consistent place regardless of how they got there.
struct InBodyProgressView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        entity: InBodyEntry.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)]
    ) private var entries: FetchedResults<InBodyEntry>

    @State private var metric: InBodyMetric
    @State private var range: ProgressAggregator.TimeRange = .sixMonth
    @State private var hoveredEntry: InBodyEntry?
    @State private var sheetEntry: InBodyEntry?

    init(initialMetric: InBodyMetric = .weight) {
        self._metric = State(initialValue: initialMetric)
    }

    /// Every metric the InBody import captures that's worth charting over
    /// time. Order matters — Weight is the default and most-used view.
    enum InBodyMetric: String, CaseIterable, Hashable {
        case weight, bodyFat, smm, lbm, bmi, bmr, ecwTbw, visceral

        var displayName: String {
            switch self {
            case .weight:   return "Weight"
            case .bodyFat:  return "Body Fat %"
            case .smm:      return "SMM"
            case .lbm:      return "Lean Mass"
            case .bmi:      return "BMI"
            case .bmr:      return "BMR"
            case .ecwTbw:   return "ECW/TBW"
            case .visceral: return "Visceral"
            }
        }

        var unitSuffix: String {
            switch self {
            case .weight, .smm, .lbm: return "lbs"
            case .bodyFat:            return "%"
            case .bmi, .ecwTbw, .visceral: return ""
            case .bmr:                return "kcal"
            }
        }

        func value(from entry: InBodyEntry) -> Double {
            switch self {
            case .weight:   return entry.weightLbs
            case .bodyFat:  return entry.bodyFatPercentage
            case .smm:      return entry.skeletalMuscleMassLbs
            case .lbm:      return entry.leanBodyMassLbs
            case .bmi:      return entry.bmi
            case .bmr:      return entry.basalMetabolicRateKcal
            case .ecwTbw:   return entry.ecwTbwRatio
            case .visceral: return Double(entry.visceralFatLevel)
            }
        }

        /// Whether a *lower* reading is the better outcome for this metric.
        /// Body fat %, ECW/TBW (inflammation marker), and visceral fat all
        /// invert the usual "max is best" assumption used by the stats strip.
        var lowerIsBetter: Bool {
            switch self {
            case .bodyFat, .ecwTbw, .visceral: return true
            default:                            return false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                rangePills
                metricPills
                chartCard
                statsStrip
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("InBody Trends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $sheetEntry) { entry in
            NavigationStack {
                InBodyDetailView(entry: entry)
                    .environment(\.managedObjectContext, context)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Pills

    private var rangePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ProgressAggregator.TimeRange.allCases, id: \.self) { r in
                    InBodyPill(label: r.displayLabel, isSelected: r == range) {
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
                ForEach(InBodyMetric.allCases, id: \.self) { m in
                    InBodyPill(label: m.displayName, isSelected: m == metric) {
                        metric = m
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Chart

    /// Filter to (a) entries inside the selected time range and (b) entries
    /// where the selected metric was actually populated. A scan with `BMR=0`
    /// shouldn't drag the line down — it just means that field wasn't
    /// extracted from the PDF.
    private var pointsInRange: [InBodyEntry] {
        let cutoff = range.cutoff(from: Date())
        return entries.filter { entry in
            guard let d = entry.date else { return false }
            return d >= cutoff && metric.value(from: entry) > 0
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(metric.displayName)
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if !pointsInRange.isEmpty {
                    Text("Drag to scrub")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                } else {
                    Text(range.displayLabel)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }

            if pointsInRange.isEmpty {
                emptyChart
            } else {
                chart
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
            Text("No \(metric.displayName.lowercased()) data in this range")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    /// Apple Fitness-style scrubbable chart. Drag horizontally to move a
    /// vertical rule + dot to the nearest scan; the tooltip card pinned at
    /// top-leading reads the metric value, date, and a "View scan" button.
    /// Tooltip pins after release — same behavior as `SessionHRTraceChart`.
    private var chart: some View {
        Chart {
            ForEach(pointsInRange, id: \.objectID) { entry in
                LineMark(
                    x: .value("Date", entry.date ?? Date()),
                    y: .value(metric.displayName, metric.value(from: entry))
                )
                .foregroundStyle(Theme.Colors.accent)
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Date", entry.date ?? Date()),
                    y: .value(metric.displayName, metric.value(from: entry))
                )
                .foregroundStyle(Theme.Colors.accent)
                .symbolSize(40)
            }
            if let h = hoveredEntry, let d = h.date {
                RuleMark(x: .value("scrub", d))
                    .foregroundStyle(Theme.Colors.textTertiary.opacity(0.7))
                PointMark(
                    x: .value("scrub", d),
                    y: .value(metric.displayName, metric.value(from: h))
                )
                .foregroundStyle(Theme.Colors.accent)
                .symbolSize(120)
            }
        }
        .chartYScale(domain: ChartDomain.padded(values: pointsInRange.map { metric.value(from: $0) }))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
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
                                hoveredEntry = nearestEntry(to: date)
                            }
                    )
            }
        }
        .chartOverlay { _ in
            VStack {
                HStack {
                    if let h = hoveredEntry {
                        tooltipCard(for: h)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 220)
    }

    private func tooltipCard(for entry: InBodyEntry) -> some View {
        let value = metric.value(from: entry)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(format(value))
                    .font(Theme.Fonts.header(18))
                    .foregroundStyle(Theme.Colors.accent)
                if !metric.unitSuffix.isEmpty {
                    Text(metric.unitSuffix)
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            if let d = entry.date {
                Text(dateLabel(d))
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Button {
                sheetEntry = entry
            } label: {
                HStack(spacing: 3) {
                    Text("View scan")
                    Image(systemName: "chevron.right")
                }
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
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

    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .month, .sixMonth: return .dateTime.month(.abbreviated).day()
        case .year, .threeYear: return .dateTime.month(.abbreviated).year(.twoDigits)
        case .fiveYear, .tenYear: return .dateTime.year()
        }
    }

    private func nearestEntry(to date: Date) -> InBodyEntry? {
        pointsInRange.min(by: {
            abs(($0.date ?? .distantPast).timeIntervalSince(date)) <
            abs(($1.date ?? .distantPast).timeIntervalSince(date))
        })
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        let inRange = pointsInRange
        let current = inRange.last.map { metric.value(from: $0) }
        let allValues = entries.map { metric.value(from: $0) }.filter { $0 > 0 }
        let allTimePR = (metric.lowerIsBetter ? allValues.min() : allValues.max()) ?? 0
        let lastDate = entries.compactMap { $0.date }.max()

        return HStack(spacing: Theme.Spacing.md) {
            statTile(label: "Current", value: current.map { format($0) } ?? "—", suffix: metric.unitSuffix)
            statTile(label: "All-time best", value: format(allTimePR), suffix: metric.unitSuffix)
            statTile(label: "Last scan", value: lastDate.map { dateLabel($0) } ?? "—", suffix: nil)
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
                if let suffix, !suffix.isEmpty {
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
}

private struct InBodyPill: View {
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

#Preview {
    NavigationStack {
        InBodyProgressView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
