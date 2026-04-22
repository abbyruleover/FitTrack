import SwiftUI
import CoreData
import Charts

/// Body tab — InBody-centric dashboard. Layout (top → bottom):
///   1. Latest scan hero card (big weight + body fat / SMM / lean tiles)
///   2. Three trend mini-charts: Weight, Body Fat %, Skeletal Muscle Mass
///   3. "All Metrics" link → InBodyProgressView for everything else (BMI,
///       BMR, ECW/TBW, Visceral, segmentals)
///   4. Import + View All Scans buttons
///
/// All InBody screens that previously hung off the Health tab are now reached
/// from here. The Health tab itself is gone — Activity rings moved to Home.
struct BodyView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        entity: InBodyEntry.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)]
    ) private var inBodyEntries: FetchedResults<InBodyEntry>

    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    bodyHeader
                    if let latest = inBodyEntries.last {
                        latestScanCard(latest)
                        if inBodyEntries.count >= 2 {
                            trendChartCard(metric: .weight, color: Theme.Colors.accent)
                            trendChartCard(metric: .bodyFat, color: Theme.Colors.orange)
                            trendChartCard(metric: .smm, color: Theme.Colors.purple)
                        }
                        allMetricsRow
                    } else {
                        emptyCard(icon: "figure.arms.open",
                                  text: "Import your first InBody PDF to start tracking body composition.")
                    }

                    actionButtons
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle(AppStrings.Tabs.body)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: InBodyTrendsRoute.self) { route in
                InBodyProgressView(initialMetric: route.metric)
                    .environment(\.managedObjectContext, context)
            }
            .sheet(isPresented: $showingImport) {
                InBodyImportSheet()
                    .environment(\.managedObjectContext, context)
                    .preferredColorScheme(.dark)
            }
            .onAppear {
                AppLogger.shared.log("BodyView appeared (\(inBodyEntries.count) scans)", category: "ui")
            }
        }
    }

    // MARK: - Header

    /// Big in-content title above the scan card. Nav-bar mode is set to
    /// `.inline` so we don't double-stack a giant "Body" both in the bar and
    /// inside the scroll. The subtitle hints at what the tab covers.
    private var bodyHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Body")
                .font(Theme.Fonts.header(28))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Composition + scan trends")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // MARK: - Latest scan hero

    /// Big rounded weight number on the left, scan date on the right, then a
    /// row of body-fat / skeletal-muscle / lean-mass tiles. Mirrors the old
    /// HealthView Body card so users have visual continuity after the tab
    /// restructure.
    private func latestScanCard(_ entry: InBodyEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                NavigationLink(value: InBodyTrendsRoute(metric: .weight)) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(format(entry.weightLbs))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text("lbs")
                            .font(Theme.Fonts.mono(13))
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if let d = entry.date {
                    Text(longDateLabel(d))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                bodyMetric(label: "Body Fat", value: format(entry.bodyFatPercentage), unit: "%", color: .orange)
                bodyMetric(label: "Skeletal Muscle", value: format(entry.skeletalMuscleMassLbs), unit: "lbs", color: .purple)
                bodyMetric(label: "Lean Mass", value: format(entry.leanBodyMassLbs), unit: "lbs", color: .teal)
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

    private func bodyMetric(label: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(color)
                Text(unit)
                    .font(Theme.Fonts.mono(9))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Trend mini-charts

    /// Tappable card with one InBody metric plotted over time. Tap → drills
    /// into `InBodyProgressView` with that metric pre-selected on the pill row.
    private func trendChartCard(metric: InBodyProgressView.InBodyMetric, color: Color) -> some View {
        let entries = Array(inBodyEntries)
        return NavigationLink(value: InBodyTrendsRoute(metric: metric)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(metric.displayName)
                        .font(Theme.Fonts.header(13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Trends")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(color)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                Chart(entries, id: \.objectID) { entry in
                    LineMark(
                        x: .value("Date", entry.date ?? Date()),
                        y: .value(metric.displayName, metric.value(from: entry))
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Date", entry.date ?? Date()),
                        y: .value(metric.displayName, metric.value(from: entry))
                    )
                    .foregroundStyle(color)
                    .symbolSize(40)
                }
                .chartYScale(domain: ChartDomain.padded(values: entries.compactMap {
                    let v = metric.value(from: $0)
                    return v > 0 ? v : nil
                }))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                .frame(height: 160)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - All metrics

    /// Catch-all row that drops into InBodyProgressView (no initialMetric →
    /// defaults to Weight). The pill picker inside lets the user reach BMI,
    /// BMR, ECW/TBW, Visceral, and segmental lean/fat — every metric not
    /// already on a hero chart.
    private var allMetricsRow: some View {
        NavigationLink {
            InBodyProgressView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Metrics")
                        .font(Theme.Fonts.header(15))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("BMI, BMR, ECW/TBW, Visceral, segmentals")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                AppLogger.shared.log("Body → Import InBody PDF tapped", category: "ui")
                showingImport = true
            } label: {
                Label("Import InBody PDF", systemImage: "doc.badge.plus")
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.accent)
                    )
            }
            .buttonStyle(.plain)

            if !inBodyEntries.isEmpty {
                NavigationLink {
                    InBodyHistoryView()
                        .environment(\.managedObjectContext, context)
                } label: {
                    Label("View All Scans", systemImage: "list.bullet")
                        .font(Theme.Fonts.body(14))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.Colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private func emptyCard(icon: String, text: String) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(text)
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
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

    // MARK: - Formatters

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }

    private func longDateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }
}

/// Pushes `InBodyProgressView` with a specific metric pre-selected. Used by
/// the body card's weight number and the trend mini-charts so users land
/// directly on the right pill instead of having to re-select.
struct InBodyTrendsRoute: Hashable {
    let metric: InBodyProgressView.InBodyMetric
}

#Preview {
    BodyView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
