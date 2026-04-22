import Foundation
import UserNotifications
import CoreData

/// Thin wrapper over `UNUserNotificationCenter` for the "upload next week's
/// WODs" Sunday-9am nudge. Idempotent: scheduling twice is a no-op.
enum ReminderService {
    private static let nextWeekReminderId = "fittrack.reminder.next-week-empty"

    /// Ask for notification permission once. Safe to call on every app launch
    /// — the system caches the user's choice and never re-prompts.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            AppLogger.shared.log("notification authorizationStatus=\(settings.authorizationStatus.rawValue)", category: "notif")
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    AppLogger.shared.log("notif requestAuthorization → granted=\(granted) err=\(error?.localizedDescription ?? "nil")", category: "notif")
                }
            default:
                break
            }
        }
    }

    /// If next week (Mon..Sat) is empty, queue a one-shot local notification
    /// for the upcoming Sunday at 9:00 local time. If a request with the
    /// same id is already pending, we replace it so the date stays accurate.
    static func scheduleNextWeekReminderIfNeeded(context: NSManagedObjectContext) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                AppLogger.shared.log("scheduleNextWeekReminder skipped — auth=\(settings.authorizationStatus.rawValue)", category: "notif")
                return
            }
            guard WeekScheduler.nextWeekIsEmpty(context: context) else {
                AppLogger.shared.log("scheduleNextWeekReminder → next week populated, removing pending reminder", category: "notif")
                center.removePendingNotificationRequests(withIdentifiers: [nextWeekReminderId])
                return
            }
            AppLogger.shared.log("scheduleNextWeekReminder → next week empty, scheduling Sunday 9am reminder", category: "notif")
            scheduleSundayReminder(center: center)
        }
    }

    private static func scheduleSundayReminder(center: UNUserNotificationCenter) {
        guard let trigger = nextSunday9amTrigger() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Upload next week's WODs"
        content.body = "Tap to import Monday–Saturday workouts for the coming week."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: nextWeekReminderId,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [nextWeekReminderId])
        center.add(request, withCompletionHandler: nil)
    }

    /// Calendar trigger that fires the next time the wall clock reads
    /// Sunday 09:00 local. Returns nil only on calendar arithmetic failure.
    private static func nextSunday9amTrigger() -> UNCalendarNotificationTrigger? {
        var comps = DateComponents()
        comps.weekday = 1 // Sunday in Gregorian
        comps.hour = 9
        comps.minute = 0
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }
}
