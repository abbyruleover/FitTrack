import SwiftUI

/// Month grid for the Progress tab's "Workouts" section. Renders a 7-column
/// calendar of the visible month with a pink filled circle on any day that
/// `markedDays` contains. Days the user can act on are tappable; the others
/// just show a number. Month chevrons hop ±1 month at a time.
///
/// Pure layout — the parent owns the marked-days set and the tap callback.
struct WorkoutCalendarView: View {
    enum DaySource { case watchOnly, fittrackOnly, both }

    let dayInfo: [Date: DaySource]
    /// Fired when the user taps a day cell. Only marked days fire.
    let onSelectDay: (Date) -> Void

    @State private var visibleMonth: Date = Calendar.current.startOfMonth(for: Date())

    private let calendar = Calendar.current
    private let weekdaySymbols = Calendar.current.veryShortStandaloneWeekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            weekdayRow
            grid
            legend
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthLabel)
                .font(Theme.Fonts.header(16))
                .foregroundStyle(Theme.Colors.textPrimary)

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<weekdaySymbols.count, id: \.self) { i in
                Text(weekdaySymbols[i])
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let cells = monthCells
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(cells.indices, id: \.self) { i in
                cellView(for: cells[i])
            }
        }
    }

    @ViewBuilder
    private func cellView(for cell: DayCell) -> some View {
        switch cell {
        case .empty:
            Color.clear.frame(height: 38)
        case .day(let date):
            let day = calendar.startOfDay(for: date)
            let source = dayInfo[day]
            let marked = source != nil
            let isToday = calendar.isDateInToday(day)
            let dotColor = source.map { dotColor(for: $0) } ?? Theme.Colors.pink
            Button {
                guard marked else { return }
                onSelectDay(day)
            } label: {
                ZStack {
                    if marked && isToday {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 32, height: 32)
                        Circle()
                            .stroke(Theme.Colors.accent, lineWidth: 2)
                            .frame(width: 36, height: 36)
                    } else if marked {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 32, height: 32)
                    } else if isToday {
                        Circle()
                            .fill(Theme.Colors.accent.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Circle()
                            .stroke(Theme.Colors.accent, lineWidth: 1.5)
                            .frame(width: 32, height: 32)
                    }
                    Text("\(calendar.component(.day, from: date))")
                        .font(Theme.Fonts.mono(13))
                        .foregroundStyle(
                            marked
                            ? Theme.Colors.background
                            : (isToday ? Theme.Colors.accent : Theme.Colors.textSecondary)
                        )
                }
                .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.plain)
            .disabled(!marked)
        }
    }

    private func dotColor(for source: DaySource) -> Color {
        switch source {
        case .watchOnly:    return Theme.Colors.orange
        case .fittrackOnly: return Theme.Colors.accent
        case .both:         return Theme.Colors.pink
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Theme.Spacing.md) {
            legendDot(color: Theme.Colors.orange, label: "Watch")
            legendDot(color: Theme.Colors.accent, label: "FitTrack")
            legendDot(color: Theme.Colors.pink, label: "Both")
            Spacer()
        }
        .padding(.top, Theme.Spacing.xs)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // MARK: - Helpers

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: visibleMonth)
    }

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = calendar.startOfMonth(for: next)
        }
    }

    /// Builds the 6×7 cell layout for `visibleMonth`. Empty cells fill the
    /// leading/trailing weeks so day numbers line up under their weekday.
    private enum DayCell {
        case empty
        case day(Date)
    }

    private var monthCells: [DayCell] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth) else {
            return []
        }
        // First day of the month, expressed as 1-based weekday (1=Sun).
        let firstWeekday = calendar.component(.weekday, from: visibleMonth)
        // Calendar uses 1=Sunday by default; veryShortStandaloneWeekdaySymbols
        // also starts at index 0 = Sunday, so subtracting 1 lines them up.
        let leadingBlanks = firstWeekday - calendar.firstWeekday
        let normalizedLeading = leadingBlanks < 0 ? leadingBlanks + 7 : leadingBlanks

        var cells: [DayCell] = Array(repeating: .empty, count: normalizedLeading)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: visibleMonth) {
                cells.append(.day(d))
            }
        }
        // Pad to a multiple of 7 so the last row is full-width.
        while cells.count % 7 != 0 {
            cells.append(.empty)
        }
        return cells
    }
}

// MARK: - Calendar helper

extension Calendar {
    /// First instant of the month containing `date`, in this calendar's
    /// timezone. Used by the calendar grid to anchor the visible month.
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
