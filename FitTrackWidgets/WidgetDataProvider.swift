import Foundation
import CoreData

enum WidgetDataProvider {
    static let appGroupID = "group.com.abhaygulati.fittrack.ag2026"

    static func makeContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "FitTrack")
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let desc = container.persistentStoreDescriptions.first
            desc?.url = url.appendingPathComponent("FitTrack.sqlite")
            desc?.shouldMigrateStoreAutomatically = true
            desc?.shouldInferMappingModelAutomatically = true
            desc?.isReadOnly = true
        }
        container.loadPersistentStores { _, error in
            if let error { print("Widget Core Data error: \(error)") }
        }
        return container
    }

    static func cachedHiitDays() -> Set<Date> {
        let ud = UserDefaults(suiteName: appGroupID)
        let intervals = ud?.array(forKey: "cachedHiitDays") as? [TimeInterval] ?? []
        let cal = Calendar.current
        return Set(intervals.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0)) })
    }

    static func fittrackSessionDays(context: NSManagedObjectContext) -> Set<Date> {
        let req = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        let cal = Calendar.current
        guard let sessions = try? context.fetch(req) else { return [] }
        return Set(sessions.compactMap { s in
            guard let d = s.startedAt else { return nil }
            return cal.startOfDay(for: d)
        })
    }

    struct InBodyPoint: Identifiable {
        let id: UUID
        let date: Date
        let bodyFatPercentage: Double
        let weightLbs: Double
    }

    static func inBodyPoints(context: NSManagedObjectContext, days: Int = 90) -> [InBodyPoint] {
        let req = NSFetchRequest<InBodyEntry>(entityName: "InBodyEntry")
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        req.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        guard let entries = try? context.fetch(req) else { return [] }
        return entries.compactMap { e in
            guard let d = e.date, let id = e.id else { return nil }
            return InBodyPoint(id: id, date: d, bodyFatPercentage: e.bodyFatPercentage, weightLbs: e.weightLbs)
        }
    }
}
