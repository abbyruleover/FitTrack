import CoreData
import Foundation

/// Singleton owner of the Core Data stack for FitTrack.
/// Use `PersistenceController.shared` in production and `PersistenceController.preview`
/// inside SwiftUI previews so they don't pollute the on-disk store.
struct PersistenceController {
    static let shared = PersistenceController()
    static let appGroupID = "group.com.abhaygulati.fittrack.ag2026"

    /// In-memory store for SwiftUI previews — never written to disk.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext
        let sample = WorkoutDay(context: ctx)
        sample.id = UUID()
        sample.name = "Tuesday WOD"
        sample.weekNumber = 1
        sample.date = Date()
        sample.isCompleted = false
        try? ctx.save()
        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "FitTrack")
        if let desc = container.persistentStoreDescriptions.first {
            if inMemory {
                desc.url = URL(fileURLWithPath: "/dev/null")
            } else if let sharedURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupID
            ) {
                Self.migrateStoreIfNeeded(to: sharedURL)
                desc.url = sharedURL.appendingPathComponent("FitTrack.sqlite")
            }
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores { desc, error in
            if let error = error as NSError? {
                fatalError("Core Data store failed to load: \(error), \(error.userInfo)")
            }
            if !inMemory, let url = desc.url {
                AppLogger.shared.log("CoreData store loaded — \(url.path)", category: "data")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        if !inMemory {
            ExerciseCatalogService.shared.seedIfNeeded(context: container.viewContext)
        }
    }

    /// Copy the SQLite files from the old app-sandbox location to the shared
    /// App Group container on first launch after the migration. Uses copy (not
    /// move) so the original stays intact as a safety net.
    private static func migrateStoreIfNeeded(to sharedDir: URL) {
        let fm = FileManager.default
        let oldDir = NSPersistentContainer.defaultDirectoryURL()
        let newStore = sharedDir.appendingPathComponent("FitTrack.sqlite")
        let oldStore = oldDir.appendingPathComponent("FitTrack.sqlite")
        guard fm.fileExists(atPath: oldStore.path), !fm.fileExists(atPath: newStore.path) else { return }
        for ext in ["", "-wal", "-shm"] {
            let src = oldDir.appendingPathComponent("FitTrack.sqlite\(ext)")
            let dst = sharedDir.appendingPathComponent("FitTrack.sqlite\(ext)")
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                AppLogger.shared.log("Store migration copy failed for \(ext): \(error)", category: "data")
            }
        }
        AppLogger.shared.log("Core Data migrated to shared container", category: "data")
    }
}
