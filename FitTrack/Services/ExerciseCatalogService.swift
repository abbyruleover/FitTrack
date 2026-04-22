import Foundation
import CoreData

final class ExerciseCatalogService {
    static let shared = ExerciseCatalogService()

    private static let matchThreshold: Double = 0.88

    private struct SeedEntry: Decodable {
        let canonicalName: String
        let aliases: [String]
        let movementPattern: String
        let equipment: String
        let primaryMuscle: String?
    }

    func seedIfNeeded(context: NSManagedObjectContext) {
        guard let url = Bundle.main.url(forResource: "exercise_catalog_seed", withExtension: "json") else {
            AppLogger.shared.log("seed JSON not found in bundle", category: "catalog")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([SeedEntry].self, from: data) else {
            AppLogger.shared.log("seed JSON failed to decode", category: "catalog")
            return
        }

        let existing = fetchAllNames(context: context)
        var inserted = 0
        for e in entries {
            if existing.contains(e.canonicalName.lowercased()) { continue }
            let row = ExerciseCatalog(context: context)
            row.id = UUID()
            row.canonicalName = e.canonicalName
            row.aliases = e.aliases.joined(separator: ", ")
            row.movementPattern = e.movementPattern
            row.equipment = e.equipment
            row.primaryMuscle = e.primaryMuscle
            row.isUserCreated = false
            row.isUnreviewed = false
            row.createdAt = Date()
            inserted += 1
        }
        if inserted > 0 {
            do {
                try context.save()
                AppLogger.shared.log("seedIfNeeded inserted \(inserted) catalog entries", category: "catalog")
            } catch {
                AppLogger.shared.log("seedIfNeeded save FAILED: \(error)", category: "catalog")
                context.rollback()
            }
        } else {
            AppLogger.shared.log("seedIfNeeded — catalog already populated", category: "catalog")
        }
    }

    func resolve(name: String, context: NSManagedObjectContext) -> ExerciseCatalog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = fetchAll(context: context)

        var bestScore: Double = 0
        var best: ExerciseCatalog?
        for entry in all {
            let candidates = [entry.canonicalName ?? ""] + aliasList(for: entry)
            for cand in candidates where !cand.isEmpty {
                let score = ExerciseNormalizer.similarity(trimmed, cand)
                if score > bestScore {
                    bestScore = score
                    best = entry
                }
            }
        }

        if let best, bestScore >= Self.matchThreshold {
            AppLogger.shared.log("resolve('\(trimmed)') → '\(best.canonicalName ?? "?")' score=\(String(format: "%.3f", bestScore))", category: "catalog")
            return best
        }

        let row = ExerciseCatalog(context: context)
        row.id = UUID()
        row.canonicalName = trimmed
        row.aliases = ""
        row.movementPattern = MovementPattern.conditioning.rawValue
        row.equipment = Equipment.body.rawValue
        row.primaryMuscle = nil
        row.isUserCreated = true
        row.isUnreviewed = true
        row.createdAt = Date()
        AppLogger.shared.log("resolve('\(trimmed)') → CREATED unreviewed (best score \(String(format: "%.3f", bestScore)))", category: "catalog")
        return row
    }

    func merge(source: UUID, into target: UUID, context: NSManagedObjectContext) throws {
        guard source != target else { return }
        guard let sourceEntry = fetch(id: source, context: context),
              let targetEntry = fetch(id: target, context: context) else {
            AppLogger.shared.log("merge FAILED — source or target not found", category: "catalog")
            return
        }

        // Rewrite Exercise references.
        let exReq = NSFetchRequest<Exercise>(entityName: "Exercise")
        exReq.predicate = NSPredicate(format: "canonicalExerciseID == %@", source as CVarArg)
        let exRows = (try? context.fetch(exReq)) ?? []
        for row in exRows { row.canonicalExerciseID = target }

        // Rewrite LoggedSet references.
        let setReq = NSFetchRequest<LoggedSet>(entityName: "LoggedSet")
        setReq.predicate = NSPredicate(format: "canonicalExerciseID == %@", source as CVarArg)
        let setRows = (try? context.fetch(setReq)) ?? []
        for row in setRows { row.canonicalExerciseID = target }

        // Carry the source's canonicalName into the target's alias list (so
        // future imports of the source spelling still match).
        let sourceName = sourceEntry.canonicalName ?? ""
        if !sourceName.isEmpty {
            let existing = aliasList(for: targetEntry).map { $0.lowercased() }
            if !existing.contains(sourceName.lowercased())
                && (targetEntry.canonicalName ?? "").lowercased() != sourceName.lowercased() {
                let merged = (aliasList(for: targetEntry) + [sourceName]).joined(separator: ", ")
                targetEntry.aliases = merged
            }
        }

        context.delete(sourceEntry)
        try context.save()
        AppLogger.shared.log("merge \(sourceName) → \(targetEntry.canonicalName ?? "?") rewrote \(exRows.count) Exercise + \(setRows.count) LoggedSet", category: "catalog")
    }

    // MARK: - Helpers

    func aliasList(for entry: ExerciseCatalog) -> [String] {
        (entry.aliases ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func fetchAll(context: NSManagedObjectContext) -> [ExerciseCatalog] {
        let req = NSFetchRequest<ExerciseCatalog>(entityName: "ExerciseCatalog")
        return (try? context.fetch(req)) ?? []
    }

    private func fetchAllNames(context: NSManagedObjectContext) -> Set<String> {
        Set(fetchAll(context: context).compactMap { $0.canonicalName?.lowercased() })
    }

    private func fetch(id: UUID, context: NSManagedObjectContext) -> ExerciseCatalog? {
        let req = NSFetchRequest<ExerciseCatalog>(entityName: "ExerciseCatalog")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return try? context.fetch(req).first
    }
}
