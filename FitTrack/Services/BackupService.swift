import Foundation
import CoreData

enum BackupService {

    struct BackupPayload: Codable {
        var exportedAt: String
        var version: String = "1.0"
        var sessions: [[String: Any]]
        var loggedSets: [[String: Any]]
        var inBodyEntries: [[String: Any]]

        enum CodingKeys: String, CodingKey {
            case exportedAt, version, sessions, loggedSets, inBodyEntries
        }

        // Manual Codable because [String: Any] isn't Codable
        init(exportedAt: String, sessions: [[String: Any]], loggedSets: [[String: Any]], inBodyEntries: [[String: Any]]) {
            self.exportedAt = exportedAt
            self.sessions = sessions
            self.loggedSets = loggedSets
            self.inBodyEntries = inBodyEntries
        }

        init(from decoder: Decoder) throws { fatalError("Use fromJSON instead") }
        func encode(to encoder: Encoder) throws { fatalError("Use toJSON instead") }
    }

    private static let iso = ISO8601DateFormatter()

    // MARK: - Export

    static func exportJSON(context: NSManagedObjectContext) throws -> Data {
        let sessions = try context.fetch(NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession"))
        let sets = try context.fetch(NSFetchRequest<LoggedSet>(entityName: "LoggedSet"))
        let inBody = try context.fetch(NSFetchRequest<InBodyEntry>(entityName: "InBodyEntry"))

        let payload: [String: Any] = [
            "exportedAt": iso.string(from: Date()),
            "version": "1.0",
            "sessions": sessions.map { encodeSession($0) },
            "loggedSets": sets.map { encodeLoggedSet($0) },
            "inBodyEntries": inBody.map { encodeInBody($0) }
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func encodeSession(_ s: WorkoutSession) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = s.id?.uuidString ?? UUID().uuidString
        d["workoutName"] = s.workoutName ?? ""
        if let t = s.startedAt { d["startedAt"] = iso.string(from: t) }
        if let t = s.finishedAt { d["finishedAt"] = iso.string(from: t) }
        return d
    }

    private static func encodeLoggedSet(_ s: LoggedSet) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = s.id?.uuidString ?? UUID().uuidString
        d["exerciseName"] = s.exerciseName ?? ""
        d["setIndex"] = Int(s.setIndex)
        d["weightLbs"] = s.weightLbs
        d["reps"] = Int(s.reps)
        d["isCompleted"] = s.isCompleted
        if let t = s.completedAt { d["completedAt"] = iso.string(from: t) }
        if let cid = s.canonicalExerciseID { d["canonicalExerciseID"] = cid.uuidString }
        if let sid = s.session?.id { d["sessionID"] = sid.uuidString }
        return d
    }

    private static func encodeInBody(_ e: InBodyEntry) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = e.id?.uuidString ?? UUID().uuidString
        if let t = e.date { d["date"] = iso.string(from: t) }
        d["pdfFilename"] = e.pdfFilename ?? ""
        if let raw = e.rawSourceData {
            d["rawSourceData"] = raw.base64EncodedString()
        }
        d["rawSourceMimeType"] = e.rawSourceMimeType ?? ""
        d["heightInches"] = e.heightInches
        d["ageYears"] = Int(e.ageYears)
        d["weightLbs"] = e.weightLbs
        d["bmi"] = e.bmi
        d["bodyFatPercentage"] = e.bodyFatPercentage
        d["bodyFatMassLbs"] = e.bodyFatMassLbs
        d["leanBodyMassLbs"] = e.leanBodyMassLbs
        d["skeletalMuscleMassLbs"] = e.skeletalMuscleMassLbs
        d["dryLeanMassLbs"] = e.dryLeanMassLbs
        d["intracellularWaterLbs"] = e.intracellularWaterLbs
        d["extracellularWaterLbs"] = e.extracellularWaterLbs
        d["totalBodyWaterLbs"] = e.totalBodyWaterLbs
        d["ecwTbwRatio"] = e.ecwTbwRatio
        d["visceralFatLevel"] = Int(e.visceralFatLevel)
        d["basalMetabolicRateKcal"] = e.basalMetabolicRateKcal
        d["rightArmLeanLbs"] = e.rightArmLeanLbs
        d["rightArmLeanPct"] = e.rightArmLeanPct
        d["leftArmLeanLbs"] = e.leftArmLeanLbs
        d["leftArmLeanPct"] = e.leftArmLeanPct
        d["trunkLeanLbs"] = e.trunkLeanLbs
        d["trunkLeanPct"] = e.trunkLeanPct
        d["rightLegLeanLbs"] = e.rightLegLeanLbs
        d["rightLegLeanPct"] = e.rightLegLeanPct
        d["leftLegLeanLbs"] = e.leftLegLeanLbs
        d["leftLegLeanPct"] = e.leftLegLeanPct
        return d
    }

    // MARK: - Import

    static func importJSON(data: Data, context: NSManagedObjectContext) throws -> (sessions: Int, sets: Int, inBody: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BackupService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure"])
        }

        var sessionCount = 0
        var setCount = 0
        var inBodyCount = 0

        // Build session ID → object map for linking sets
        var sessionMap: [String: WorkoutSession] = [:]

        // Import sessions
        if let arr = root["sessions"] as? [[String: Any]] {
            for item in arr {
                guard let idStr = item["id"] as? String,
                      let uid = UUID(uuidString: idStr) else { continue }
                if existsInStore(entity: "WorkoutSession", id: uid, context: context) {
                    if let existing = fetchByID(entity: "WorkoutSession", id: uid, context: context) as? WorkoutSession {
                        sessionMap[idStr] = existing
                    }
                    continue
                }
                let s = WorkoutSession(context: context)
                s.id = uid
                s.workoutName = item["workoutName"] as? String
                s.startedAt = (item["startedAt"] as? String).flatMap { iso.date(from: $0) }
                s.finishedAt = (item["finishedAt"] as? String).flatMap { iso.date(from: $0) }
                sessionMap[idStr] = s
                sessionCount += 1
            }
        }

        // Import logged sets
        if let arr = root["loggedSets"] as? [[String: Any]] {
            for item in arr {
                guard let idStr = item["id"] as? String,
                      let uid = UUID(uuidString: idStr) else { continue }
                if existsInStore(entity: "LoggedSet", id: uid, context: context) { continue }
                let ls = LoggedSet(context: context)
                ls.id = uid
                ls.exerciseName = item["exerciseName"] as? String
                ls.setIndex = Int16(item["setIndex"] as? Int ?? 0)
                ls.weightLbs = item["weightLbs"] as? Double ?? 0
                ls.reps = Int16(item["reps"] as? Int ?? 0)
                ls.isCompleted = item["isCompleted"] as? Bool ?? false
                ls.completedAt = (item["completedAt"] as? String).flatMap { iso.date(from: $0) }
                if let cidStr = item["canonicalExerciseID"] as? String {
                    ls.canonicalExerciseID = UUID(uuidString: cidStr)
                }
                if let sidStr = item["sessionID"] as? String {
                    ls.session = sessionMap[sidStr]
                }
                setCount += 1
            }
        }

        // Import InBody entries
        if let arr = root["inBodyEntries"] as? [[String: Any]] {
            for item in arr {
                guard let idStr = item["id"] as? String,
                      let uid = UUID(uuidString: idStr) else { continue }
                if existsInStore(entity: "InBodyEntry", id: uid, context: context) { continue }
                let e = InBodyEntry(context: context)
                e.id = uid
                e.date = (item["date"] as? String).flatMap { iso.date(from: $0) }
                e.pdfFilename = item["pdfFilename"] as? String
                if let b64 = item["rawSourceData"] as? String {
                    e.rawSourceData = Data(base64Encoded: b64)
                }
                e.rawSourceMimeType = item["rawSourceMimeType"] as? String
                e.heightInches = item["heightInches"] as? Double ?? 0
                e.ageYears = Int16(item["ageYears"] as? Int ?? 0)
                e.weightLbs = item["weightLbs"] as? Double ?? 0
                e.bmi = item["bmi"] as? Double ?? 0
                e.bodyFatPercentage = item["bodyFatPercentage"] as? Double ?? 0
                e.bodyFatMassLbs = item["bodyFatMassLbs"] as? Double ?? 0
                e.leanBodyMassLbs = item["leanBodyMassLbs"] as? Double ?? 0
                e.skeletalMuscleMassLbs = item["skeletalMuscleMassLbs"] as? Double ?? 0
                e.dryLeanMassLbs = item["dryLeanMassLbs"] as? Double ?? 0
                e.intracellularWaterLbs = item["intracellularWaterLbs"] as? Double ?? 0
                e.extracellularWaterLbs = item["extracellularWaterLbs"] as? Double ?? 0
                e.totalBodyWaterLbs = item["totalBodyWaterLbs"] as? Double ?? 0
                e.ecwTbwRatio = item["ecwTbwRatio"] as? Double ?? 0
                e.visceralFatLevel = Int16(item["visceralFatLevel"] as? Int ?? 0)
                e.basalMetabolicRateKcal = item["basalMetabolicRateKcal"] as? Double ?? 0
                e.rightArmLeanLbs = item["rightArmLeanLbs"] as? Double ?? 0
                e.rightArmLeanPct = item["rightArmLeanPct"] as? Double ?? 0
                e.leftArmLeanLbs = item["leftArmLeanLbs"] as? Double ?? 0
                e.leftArmLeanPct = item["leftArmLeanPct"] as? Double ?? 0
                e.trunkLeanLbs = item["trunkLeanLbs"] as? Double ?? 0
                e.trunkLeanPct = item["trunkLeanPct"] as? Double ?? 0
                e.rightLegLeanLbs = item["rightLegLeanLbs"] as? Double ?? 0
                e.rightLegLeanPct = item["rightLegLeanPct"] as? Double ?? 0
                e.leftLegLeanLbs = item["leftLegLeanLbs"] as? Double ?? 0
                e.leftLegLeanPct = item["leftLegLeanPct"] as? Double ?? 0
                inBodyCount += 1
            }
        }

        try context.save()
        AppLogger.shared.log("Backup import OK — \(sessionCount) sessions, \(setCount) sets, \(inBodyCount) InBody", category: "backup")
        return (sessionCount, setCount, inBodyCount)
    }

    // MARK: - Helpers

    private static func existsInStore(entity: String, id: UUID, context: NSManagedObjectContext) -> Bool {
        let req = NSFetchRequest<NSManagedObject>(entityName: entity)
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.count(for: req)) ?? 0 > 0
    }

    private static func fetchByID(entity: String, id: UUID, context: NSManagedObjectContext) -> NSManagedObject? {
        let req = NSFetchRequest<NSManagedObject>(entityName: entity)
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return try? context.fetch(req).first
    }
}
