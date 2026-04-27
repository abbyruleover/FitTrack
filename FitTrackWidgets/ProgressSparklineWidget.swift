import SwiftUI
import WidgetKit
import Charts

struct ProgressSparklineWidget: Widget {
    let kind = "ProgressSparkline"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SparklineProvider()) { entry in
            SparklineWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Body Trends")
        .description("Track your body fat or weight over time.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct SparklineEntry: TimelineEntry {
    let date: Date
    let points: [DataPoint]
    let currentValue: Double
    let delta: Double
    let metricName: String
    let unitSuffix: String

    struct DataPoint: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
    }
}

struct SparklineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SparklineEntry {
        SparklineEntry(
            date: Date(), points: [], currentValue: 21.1,
            delta: -1.8, metricName: "Body Fat %", unitSuffix: "%"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SparklineEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SparklineEntry>) -> Void) {
        let entry = makeEntry()
        let refresh = Date().addingTimeInterval(4 * 3600)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func makeEntry() -> SparklineEntry {
        let container = WidgetDataProvider.makeContainer()
        let ctx = container.viewContext
        let raw = WidgetDataProvider.inBodyPoints(context: ctx, days: 90)

        let bfPoints = raw.filter { $0.bodyFatPercentage > 0 }

        if bfPoints.count >= 2 {
            let points = bfPoints.map {
                SparklineEntry.DataPoint(id: $0.id, date: $0.date, value: $0.bodyFatPercentage)
            }
            let current = points.last?.value ?? 0
            let oldest = points.first?.value ?? current
            return SparklineEntry(
                date: Date(), points: points, currentValue: current,
                delta: current - oldest, metricName: "Body Fat %", unitSuffix: "%"
            )
        }

        let wtPoints = raw.filter { $0.weightLbs > 0 }
        if wtPoints.count >= 2 {
            let points = wtPoints.map {
                SparklineEntry.DataPoint(id: $0.id, date: $0.date, value: $0.weightLbs)
            }
            let current = points.last?.value ?? 0
            let oldest = points.first?.value ?? current
            return SparklineEntry(
                date: Date(), points: points, currentValue: current,
                delta: current - oldest, metricName: "Weight", unitSuffix: "lbs"
            )
        }

        return SparklineEntry(
            date: Date(), points: [], currentValue: 0,
            delta: 0, metricName: "Body Fat %", unitSuffix: "%"
        )
    }
}

// MARK: - Views

struct SparklineWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: SparklineEntry

    private let lime = Color(red: 0.78, green: 1.0, blue: 0.0)

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.metricName)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.gray)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(formatValue(entry.currentValue))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(lime)
                Text(entry.unitSuffix)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
            }

            if entry.delta != 0 {
                Text(deltaLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entry.delta < 0 ? .green : .orange)
            }

            if entry.points.count >= 2 {
                sparkChart
                    .frame(maxHeight: 40)
            } else {
                Spacer()
                Text("Not enough data")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.metricName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.gray)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(formatValue(entry.currentValue))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(lime)
                    Text(entry.unitSuffix)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.gray)
                }

                if entry.delta != 0 {
                    Text(deltaLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(entry.delta < 0 ? .green : .orange)
                }

                Text("vs 90 days ago")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray.opacity(0.7))

                Spacer(minLength: 0)
            }

            if entry.points.count >= 2 {
                sparkChart
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sparkChart: some View {
        Chart(entry.points) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Value", p.value)
            )
            .foregroundStyle(lime)
            .interpolationMethod(.monotone)

            AreaMark(
                x: .value("Date", p.date),
                y: .value("Value", p.value)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [lime.opacity(0.3), lime.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private var deltaLabel: String {
        let sign = entry.delta > 0 ? "+" : ""
        return "\(sign)\(formatValue(entry.delta)) \(entry.unitSuffix)"
    }

    private func formatValue(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
    }
}
