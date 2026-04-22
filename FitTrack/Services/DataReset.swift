import Foundation
import CoreData

/// Bulk delete helpers for the Settings → Reset section. Each method logs its
/// before/after counts so the debug log captures exactly what was wiped.
enum DataReset {
    /// Delete every `WorkoutSession` (and via cascade, every `LoggedSet`).
    /// `WorkoutDay` rows are kept — the user's calendar of scheduled workouts
    /// is independent of logged sessions — but their `isCompleted` flag is
    /// reset, since "Completed" only makes sense when there's a session
    /// backing the day. Without this the carousel kept showing green days.
    static func clearAllSessions(context: NSManagedObjectContext) {
        let request = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        let all = (try? context.fetch(request)) ?? []
        AppLogger.shared.log("clearAllSessions → deleting \(all.count) WorkoutSessions", category: "data")
        for s in all { context.delete(s) }

        // No sessions left → no day can legitimately be "completed".
        let dayReq = NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay")
        let days = (try? context.fetch(dayReq)) ?? []
        var resetCount = 0
        for d in days where d.isCompleted {
            d.isCompleted = false
            resetCount += 1
        }
        AppLogger.shared.log("clearAllSessions → reset isCompleted on \(resetCount) WorkoutDays", category: "data")
        save(context: context, label: "clearAllSessions")
    }

    /// Delete every `InBodyEntry`. The corresponding HealthKit samples we
    /// wrote at import time stay in Apple Health — that's the user's
    /// authoritative store and we don't want to surprise-delete from it.
    static func clearAllInBody(context: NSManagedObjectContext) {
        let request = NSFetchRequest<InBodyEntry>(entityName: "InBodyEntry")
        let all = (try? context.fetch(request)) ?? []
        AppLogger.shared.log("clearAllInBody → deleting \(all.count) InBodyEntries", category: "data")
        for e in all { context.delete(e) }
        save(context: context, label: "clearAllInBody")
    }

    /// Wipe everything: scheduled days, sessions, sets, InBody entries, and
    /// the on-disk debug log. Two-step confirmation belongs at the call site.
    /// After deletes, `refreshAllObjects()` invalidates any held faults so
    /// existing @FetchRequests re-evaluate immediately rather than continuing
    /// to display stale objects.
    static func factoryReset(context: NSManagedObjectContext) {
        AppLogger.shared.log("factoryReset → starting full wipe", category: "data")
        WeekScheduler.clearAllScheduled(context: context)
        clearAllSessions(context: context)
        clearAllInBody(context: context)
        AppLogger.shared.log("factoryReset → clearing debug log", category: "data")
        AppLogger.shared.clear()

        context.refreshAllObjects()
        let postSessions = (try? context.count(for: NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession"))) ?? -1
        let postDays = (try? context.count(for: NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay"))) ?? -1
        let postInBody = (try? context.count(for: NSFetchRequest<InBodyEntry>(entityName: "InBodyEntry"))) ?? -1
        AppLogger.shared.log("factoryReset → done. remaining counts: WorkoutSession=\(postSessions) WorkoutDay=\(postDays) InBodyEntry=\(postInBody)", category: "data")
    }

    /// Re-derive the `isCompleted` flag for the WorkoutDay matching `day`.
    /// Call after deleting one or more sessions: if no sessions remain on
    /// the same calendar day, the day flips back to incomplete. Caller is
    /// responsible for `context.save()`.
    static func recomputeDayCompletion(forDay day: Date, context: NSManagedObjectContext) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }

        let sReq = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        sReq.predicate = NSPredicate(format: "startedAt >= %@ AND startedAt < %@",
                                     dayStart as NSDate, dayEnd as NSDate)
        let remaining = (try? context.fetch(sReq)) ?? []
        guard remaining.isEmpty else {
            AppLogger.shared.log("recomputeDayCompletion: \(remaining.count) sessions still on \(dayStart) — leaving day completed", category: "data")
            return
        }

        let dReq = NSFetchRequest<WorkoutDay>(entityName: "WorkoutDay")
        dReq.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                     dayStart as NSDate, dayEnd as NSDate)
        let days = (try? context.fetch(dReq)) ?? []
        for d in days where d.isCompleted {
            d.isCompleted = false
            AppLogger.shared.log("recomputeDayCompletion → reset WorkoutDay \(dayStart) to incomplete", category: "data")
        }
    }

    private static func save(context: NSManagedObjectContext, label: String) {
        do {
            try context.save()
            AppLogger.shared.log("\(label) save OK", category: "data")
        } catch {
            AppLogger.shared.log("\(label) save FAILED: \(error)", category: "data")
        }
    }
}
