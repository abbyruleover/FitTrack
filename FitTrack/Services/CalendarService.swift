import Foundation
import EventKit

/// Read-only Apple Calendar access for the Home welcome card. Modeled on
/// `HealthKitService`: `@MainActor` singleton, idempotent permission request,
/// `@Published var isAuthorized`. The only consumer right now is
/// `WorkoutView.welcomeCard`, which surfaces the next upcoming gym class event
/// from the user's calendar so they can see when to be at the gym
/// without bouncing into the Calendar app.
///
/// The search keyword is user-configurable via Settings ("Gym Class Keyword").
/// Default is empty, which matches any event. Setting it to e.g. "CrossFit"
/// or "Gym" narrows the match.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let store = EKEventStore()

    @Published var isAuthorized: Bool = false

    /// User-configurable keyword for matching calendar events. Stored in
    /// UserDefaults so it persists across launches. Empty string matches
    /// any event (returns the soonest one).
    static var titleKeyword: String {
        get {
            if let v = UserDefaults.standard.string(forKey: "calendar.eventKeyword") { return v }
            return "FNS"
        }
        set { UserDefaults.standard.set(newValue, forKey: "calendar.eventKeyword") }
    }

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

    /// Soonest event matching the user's keyword (case-insensitive) in the
    /// next 14 days across every calendar. If keyword is empty, returns the
    /// soonest event overall. Returns nil if permission is denied or no
    /// matching event exists.
    func nextClass() async -> EKEvent? {
        guard isAuthorized else {
            AppLogger.shared.log("CalendarService: nextClass aborted — not authorized", category: "calendar")
            return nil
        }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: Self.lookAheadDays, to: now) else {
            return nil
        }
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
        let needle = Self.titleKeyword.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            AppLogger.shared.log("CalendarService: no keyword set — skipping event search", category: "calendar")
            return nil
        }
        let matches = events.filter { ($0.title ?? "").lowercased().contains(needle) }
        let soonest = matches
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .first

        AppLogger.shared.log(
            "CalendarService: scanned \(events.count) events across \(calendars.count) calendars — \(matches.count) matched '\(needle)' → \(soonest?.title ?? "none")",
            category: "calendar"
        )
        return soonest
    }
}
