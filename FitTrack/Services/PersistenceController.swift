import CoreData
import Foundation

/// Singleton owner of the Core Data stack for FitTrack.
/// Use `PersistenceController.shared` in production and `PersistenceController.preview`
/// inside SwiftUI previews so they don't pollute the on-disk store.
struct PersistenceController {
    static let shared = PersistenceController()

    /// In-memory store for SwiftUI previews — never written to disk.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext
        // Seed a single sample WorkoutDay so previews render with realistic data.
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
                // Routes the store to /dev/null so nothing persists between launches.
                desc.url = URL(fileURLWithPath: "/dev/null")
            }
            // Lightweight migration: when the .xcdatamodeld picks up a new
            // attribute or entity, Core Data infers the mapping and migrates the
            // user's existing on-disk store in place instead of refusing to
            // load it. Without this, an app update that touches the schema
            // would either crash on launch or silently lose every workout the
            // user logged. Adding optional attributes / new entities is safe;
            // renames or required-non-default fields still need a versioned
            // model + manual mapping (see Apple's lightweight-migration rules).
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores { desc, error in
            if let error = error as NSError? {
                // Crash early in development if the store fails to load — silent failures here
                // would hide schema/migration bugs that matter.
                fatalError("Core Data store failed to load: \(error), \(error.userInfo)")
            }
            // Log the on-disk path once so the user can confirm where their
            // workout history actually lives (App Group container, app
            // sandbox, etc.) when investigating "did my data move?" worries
            // after an update.
            if !inMemory, let url = desc.url {
                AppLogger.shared.log("CoreData store loaded — \(url.path)", category: "data")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Idempotent — skips entries whose canonicalName already exists.
        if !inMemory {
            ExerciseCatalogService.shared.seedIfNeeded(context: container.viewContext)
        }
    }
}
