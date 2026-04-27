import Foundation
import EventKit

/// Read-only Apple Calendar access for the Home welcome card. Modeled on
/// `HealthKitService`: `@MainActor` singleton, idempotent permission request,
/// `@Published var isAuthorized`. The only consumer right now is
/// `WorkoutView.welcomeCard`, which surfaces the next "FNS Gym Class" event
/// from the user's default calendar so they can see when to be at the gym
/// without bouncing into the Calendar app.
///
/// Title match is case-insensitive equality on `"FNS Gym Class"` — narrow on
/// purpose so an unrelated meeting doesn't hijack the slot. If the event is
/// renamed by the gym, this is a one-line follow-up.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let store = EKEventStore()

    /// True once the user has granted full or write-only access to events.
    /// Drives whether the welcome card even attempts to fetch — the greeting
    /// + tagline still render without it.
    @Published var isAuthorized: Bool = false

    /// Substring match (case-insensitive) on the calendar event title. We
    /// search for "fns" rather than the full "FNS Gym Class" because real
    /// calendar entries vary — "FNS 6:15 AM Class", "Gym Class — FNS Cupertino",
    /// "FNS Strength" all match. The brand string is unique enough that we
    /// won't catch unrelated events.
    private static let titleNeedle = "fns"

    /// How far ahead to look for the next class. 14 days handles a
    /// once-a-week schedule plus a buffer if the user opens the app during a
    /// holiday week.
    private static let lookAheadDays = 14

    // MARK: - Authorization

    /// Idempotent — safe to call on every Home appear. EventKit only shows
    /// the system sheet once per app install; later invocations resolve
    /// against the cached decision. iOS 17 split read-access into the new
    /// `requestFullAccessToEvents`; pre-17 falls back to the old API.
    func requestAuthorizationIfNeeded() async {
        if #available(iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .writeOnly:
                AppLogger.shared.log("CalendarService: already authorized (status=\(status.rawValue))", category: "calendar")
                isAuthorized = true
                return
            case .denied, .restricted:
                AppLogger.shared.log("CalendarService: denied/restricted (status=\(status.rawValue)) — fix in Settings → Privacy → Calendars → FitTrack", category: "calendar")
                isAuthorized = false
                return
            case .authorized:
                AppLogger.shared.log("CalendarService: legacy .authorized status — treating as granted", category: "calendar")
                isAuthorized = true
                return
            case .notDetermined:
                AppLogger.shared.log("CalendarService: status notDetermined — requesting full access", category: "calendar")
            @unknown default:
                AppLogger.shared.log("CalendarService: unknown status \(status.rawValue) — requesting", category: "calendar")
            }
            do {
                let granted = try await store.requestFullAccessToEvents()
                AppLogger.shared.log("CalendarService: requestFullAccessToEvents → \(granted)", category: "calendar")
                isAuthorized = granted
            } catch {
                AppLogger.shared.log("CalendarService: requestFullAccessToEvents FAILED: \(error)", category: "calendar")
                isAuthorized = false
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .authorized {
                isAuthorized = true
                return
            }
            if status == .denied || status == .restricted {
                isAuthorized = false
                return
            }
            do {
                let granted = try await store.requestAccess(to: .event)
                isAuthorized = granted
            } catch {
                isAuthorized = false
            }
        }
    }

    // MARK: - Queries

    /// Soonest event whose title contains "fns" (case-insensitive) in the
    /// next 14 days across every calendar the user has. Returns nil if
    /// permission is denied or no matching event exists in the window.
    /// We search every calendar — the gym class might live on a shared
    /// calendar the user subscribed to, not the default one.
    func nextFNSClass() async -> EKEvent? {
        guard isAuthorized else {
            AppLogger.shared.log("CalendarService: nextFNSClass aborted — not authorized", category: "calendar")
            return nil
        }
        let now = Date()
        guard let weekOut = Calendar.current.date(byAdding: .day, value: Self.lookAheadDays, to: now) else {
            return nil
        }
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: now, end: weekOut, calendars: calendars)
        let events = store.events(matching: predicate)
        let matches = events.filter { ($0.title ?? "").lowercased().contains(Self.titleNeedle) }
        let soonest = matches
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .first

        AppLogger.shared.log(
            "CalendarService: scanned \(events.count) events across \(calendars.count) calendars over \(Self.lookAheadDays)d — \(matches.count) matched '\(Self.titleNeedle)' → \(soonest?.title ?? "none")",
            category: "calendar"
        )
        return soonest
    }
}
