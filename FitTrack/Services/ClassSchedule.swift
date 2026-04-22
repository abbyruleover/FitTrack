import Foundation
import HealthKit
import SwiftUI

/// Maps a session's start time to the user's Equinox HIIT class slot.
///
/// Schedule (per the user, 2026 cadence):
///  - **Weekday** (Mon–Fri): 6:15, 7:30, 10:00, 12:00, 15:30, 17:00, 18:30
///  - **Saturday**: 7:00, 8:30, 10:00
///  - **Sunday**: no classes
///
/// `slot(for:)` returns the nearest scheduled slot within ±30 minutes of the
/// session's `startedAt`. Anything outside that window (e.g. an off-grid
/// open-gym session, a Sunday solo workout) returns nil so callers can fall
/// back to a plain time-of-day label.
///
/// Used for:
///  - `SessionInsights.computeVolumeDelta` — compare against the *same slot*
///    last time, not just the same workout name (so the 6:15am crowd doesn't
///    get compared to a tougher 5:30pm session).
///  - `SessionDayRow` and `UnifiedSessionView.dateLabel` — show "6:15 AM"
///    chip so the user can identify which class block the row belongs to.
enum ClassSchedule {
    struct TimeOfDay: Hashable {
        let hour: Int
        let minute: Int

        /// Minutes since midnight — handy for the ±30 min nearest-slot search.
        var minutesFromMidnight: Int { hour * 60 + minute }

        var displayLabel: String {
            let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
            let am = hour < 12 ? "AM" : "PM"
            return String(format: "%d:%02d %@", h12, minute, am)
        }
    }

    struct ClassSlot: Hashable {
        /// 1=Sun, 2=Mon, …, 7=Sat (matches `Calendar.current.component(.weekday, from:)`).
        let weekday: Int
        let start: TimeOfDay

        var label: String { start.displayLabel }

        /// Stable key for grouping/comparing — same slot on different
        /// calendar dates yields the same string.
        var canonicalKey: String { "wd\(weekday)-\(start.hour):\(start.minute)" }
    }

    static let weekdaySlots: [TimeOfDay] = [
        .init(hour: 6,  minute: 15),
        .init(hour: 7,  minute: 30),
        .init(hour: 10, minute: 0),
        .init(hour: 12, minute: 0),
        .init(hour: 15, minute: 30),
        .init(hour: 17, minute: 0),
        .init(hour: 18, minute: 30)
    ]

    static let saturdaySlots: [TimeOfDay] = [
        .init(hour: 7,  minute: 0),
        .init(hour: 8,  minute: 30),
        .init(hour: 10, minute: 0)
    ]

    /// Slots active on a given weekday (Calendar weekday: 1=Sun, 7=Sat).
    /// Sunday returns []; weekdays return `weekdaySlots`; Saturday returns
    /// `saturdaySlots`.
    static func slots(forWeekday weekday: Int) -> [TimeOfDay] {
        switch weekday {
        case 7: return saturdaySlots
        case 1: return []
        default: return weekdaySlots
        }
    }

    /// Nearest slot within ±30 min of `date`; nil if none (Sunday, or
    /// off-grid time on a class day).
    static func slot(for date: Date, calendar: Calendar = .current) -> ClassSlot? {
        let weekday = calendar.component(.weekday, from: date)
        let candidates = slots(forWeekday: weekday)
        guard !candidates.isEmpty else { return nil }

        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        let toleranceMin = 30
        var best: (slot: TimeOfDay, delta: Int)?
        for slot in candidates {
            let delta = abs(slot.minutesFromMidnight - mins)
            if delta <= toleranceMin && (best == nil || delta < best!.delta) {
                best = (slot, delta)
            }
        }
        guard let pick = best?.slot else { return nil }
        return ClassSlot(weekday: weekday, start: pick)
    }

    /// Display label honoring the slot when one matches, else falling back
    /// to plain time-of-day. With `includeWeekday: true` returns "Tue 6:15 AM"
    /// or "Tue 8:42 AM"; with false, just "6:15 AM" / "8:42 AM".
    static func label(for date: Date, includeWeekday: Bool = true, calendar: Calendar = .current) -> String {
        let slot = slot(for: date, calendar: calendar)
        let f = DateFormatter()
        f.dateFormat = includeWeekday ? "EEE h:mm a" : "h:mm a"

        if let slot {
            // Use slot's canonical time so 6:13 AM rounds to 6:15 AM display.
            var comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            comps.hour = slot.start.hour
            comps.minute = slot.start.minute
            if let normalized = calendar.date(from: comps) {
                return f.string(from: normalized)
            }
        }
        return f.string(from: date)
    }

    /// Short chip label for session rows: "6:15 AM" or "—" for off-grid.
    static func slotChip(for date: Date, calendar: Calendar = .current) -> String? {
        slot(for: date, calendar: calendar)?.label
    }
}

extension ClassSchedule {
    /// Class-structured station bands derived from an HKWorkout's start/end.
    /// The Equinox HIIT class is 60 minutes: warm-up + prep at the front,
    /// then four 8-minute strength stations with 90-second rests between
    /// them at the back.
    ///
    /// Two anchoring modes:
    ///  - **`firstSetDate` provided** (preferred): anchors station 1 to start
    ///    at `firstSetDate - 90s` (the user's first checked set marks the end
    ///    of the rest before station 1, give or take), then cascades forward
    ///    `8min + 90s + 8min + 90s + 8min + 90s + 8min`. This is exact when
    ///    the user logs sets — no schedule-shape guessing needed.
    ///  - **`firstSetDate == nil`** (Watch-only or unlogged FitTrack session):
    ///    falls back to the original "anchor to workout end" heuristic, since
    ///    classes always end on time and the back half is more reliable than
    ///    the front when we have nothing else to go on.
    ///
    /// Returns `[]` when the workout doesn't land in a recognised class
    /// slot (Sunday solo, off-grid open-gym) so callers can render the HR
    /// trace alone with no bands.
    ///
    /// Single source of truth for `SessionHRTraceChart`, `HRStationChartView`,
    /// and `WatchHIITOnlyView`.
    static func classStations(for workout: HKWorkout, firstSetDate: Date? = nil) -> [Station] {
        guard slot(for: workout.startDate) != nil else { return [] }

        let start = workout.startDate
        let end = workout.endDate
        let m: TimeInterval = 60

        let s1Start: Date
        if let anchor = firstSetDate, anchor > start.addingTimeInterval(-1) {
            // First-set anchor: station 1 begins 90s before the first checked
            // set lands. The 90s puts the user back at the rack as the
            // station opens, which matches how the class actually starts.
            s1Start = anchor.addingTimeInterval(-90)
        } else {
            // Back-anchored fallback: 36.5 min before workout end (4 stations
            // × 8 min + 3 rests × 1.5 min + 0.5 min trailing).
            s1Start = end.addingTimeInterval(-36.5 * m)
        }

        let s1End  = s1Start.addingTimeInterval(8 * m)
        let r1End  = s1End.addingTimeInterval(1.5 * m)
        let s2End  = r1End.addingTimeInterval(8 * m)
        let r2End  = s2End.addingTimeInterval(1.5 * m)
        let s3End  = r2End.addingTimeInterval(8 * m)
        let r3End  = s3End.addingTimeInterval(1.5 * m)
        let s4End  = r3End.addingTimeInterval(8 * m)

        var bands: [Station] = []
        if start < s1Start {
            bands.append(Station(name: "Warm-up & Prep",
                                 start: start, end: s1Start,
                                 tint: Theme.Colors.teal, isPrimary: true))
        }
        bands.append(contentsOf: [
            Station(name: "Station 1", start: s1Start, end: s1End,
                    tint: Theme.Colors.pink, isPrimary: true),
            Station(name: "Rest",      start: s1End,   end: r1End,
                    tint: Theme.Colors.textTertiary, isPrimary: false),
            Station(name: "Station 2", start: r1End,   end: s2End,
                    tint: Theme.Colors.orange, isPrimary: true),
            Station(name: "Rest",      start: s2End,   end: r2End,
                    tint: Theme.Colors.textTertiary, isPrimary: false),
            Station(name: "Station 3", start: r2End,   end: s3End,
                    tint: Theme.Colors.blue, isPrimary: true),
            Station(name: "Rest",      start: s3End,   end: r3End,
                    tint: Theme.Colors.textTertiary, isPrimary: false),
            Station(name: "Station 4", start: r3End,   end: s4End,
                    tint: Theme.Colors.accent, isPrimary: true)
        ])
        return bands
    }

    /// Earliest `LoggedSet.completedAt` in `session`. Returns nil when the
    /// session has no checked sets (typical for Watch-only days, or a logged
    /// session where the user finished without checking anything).
    static func firstSetDate(in session: WorkoutSession) -> Date? {
        guard let setsSet = session.value(forKey: "sets") as? NSSet else { return nil }
        return setsSet
            .compactMap { ($0 as? NSObject)?.value(forKey: "completedAt") as? Date }
            .min()
    }
}
