import SwiftUI
import WidgetKit

struct WeeklyHeatmapWidget: Widget {
    let kind = "WeeklyHeatmap"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HeatmapProvider()) { entry in
            HeatmapWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Weekly Activity")
        .description("See which days you worked out this week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct HeatmapEntry: TimelineEntry {
    let date: Date
    let weekDays: [DayStatus]
    let monthCount: Int
    let ytdCount: Int

    struct DayStatus: Identifiable {
        let id: Int
        let label: String
        let hasWorkout: Bool
    }
}

struct HeatmapProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeatmapEntry {
        HeatmapEntry(date: Date(), weekDays: placeholderDays, monthCount: 12, ytdCount: 48)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeatmapEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeatmapEntry>) -> Void) {
        let entry = makeEntry()
        let nextMidnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400 + 60)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func makeEntry() -> HeatmapEntry {
        let container = WidgetDataProvider.makeContainer()
        let ctx = container.viewContext
        let hiit = WidgetDataProvider.cachedHiitDays()
        let ft = WidgetDataProvider.fittrackSessionDays(context: ctx)
        let allDays = hiit.union(ft)

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1=Sun
        let symbols = cal.veryShortStandaloneWeekdaySymbols

        var days: [HeatmapEntry.DayStatus] = []
        for i in 0..<7 {
            // i=0 is Sunday. Offset from today to get each day of this week.
            let offset = i - (weekday - 1)
            let d = cal.date(byAdding: .day, value: offset, to: today)!
            let dayStart = cal.startOfDay(for: d)
            days.append(.init(id: i, label: symbols[i], hasWorkout: allDays.contains(dayStart)))
        }

        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        let monthCount = allDays.filter { cal.component(.month, from: $0) == month && cal.component(.year, from: $0) == year }.count
        let ytdCount = allDays.filter { cal.component(.year, from: $0) == year }.count

        return HeatmapEntry(date: Date(), weekDays: days, monthCount: monthCount, ytdCount: ytdCount)
    }

    private var placeholderDays: [HeatmapEntry.DayStatus] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return symbols.enumerated().map { .init(id: $0, label: $1, hasWorkout: [1,2,3,4,5].contains($0)) }
    }
}

// MARK: - Views

struct HeatmapWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: HeatmapEntry

    var body: some View {
        switch family {
        case .systemSmall: smallView
        case .systemMedium: mediumView
        default: smallView
        }
    }

    private var smallView: some View {
        VStack(spacing: 8) {
            Text("THIS WEEK")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.gray)

            HStack(spacing: 5) {
                ForEach(entry.weekDays) { day in
                    VStack(spacing: 2) {
                        Text(day.label)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.gray)
                        Circle()
                            .fill(day.hasWorkout ? Color(red: 0.78, green: 1.0, blue: 0.0) : Color.gray.opacity(0.25))
                            .frame(width: 12, height: 12)
                    }
                }
            }

            HStack(spacing: 16) {
                VStack(spacing: 1) {
                    Text("\(entry.monthCount)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.78, green: 1.0, blue: 0.0))
                    Text("this month")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.gray)
                }
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 1, height: 28)
                VStack(spacing: 1) {
                    Text("\(entry.ytdCount)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.78, green: 1.0, blue: 0.0))
                    Text("this year")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.gray)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(spacing: 10) {
                Text("THIS WEEK")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.gray)

                HStack(spacing: 8) {
                    ForEach(entry.weekDays) { day in
                        VStack(spacing: 3) {
                            Text(day.label)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.gray)
                            Circle()
                                .fill(day.hasWorkout ? Color(red: 0.78, green: 1.0, blue: 0.0) : Color.gray.opacity(0.25))
                                .frame(width: 18, height: 18)
                        }
                    }
                }
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            VStack(alignment: .leading, spacing: 8) {
                statBlock(label: "THIS MONTH", value: entry.monthCount)
                statBlock(label: "YTD", value: entry.ytdCount)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statBlock(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.gray)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.78, green: 1.0, blue: 0.0))
                Text("workouts")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
    }
}
