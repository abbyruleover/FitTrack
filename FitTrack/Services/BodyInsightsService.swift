import Foundation
import CoreData
#if canImport(FoundationModels)
import FoundationModels
#endif

enum BodyInsightsService {

    private static let cacheTextKey = "body.insights.text"
    private static let cacheDateKey = "body.insights.lastScanDate"
    private static let iso = ISO8601DateFormatter()

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func generate(entries: [InBodyEntry]) async -> String? {
        let sorted = entries
            .filter { $0.date != nil }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        guard sorted.count >= 2 else { return nil }

        let latestDate = sorted.last?.date ?? Date()
        let cachedDateStr = UserDefaults.standard.string(forKey: cacheDateKey) ?? ""
        let currentDateStr = iso.string(from: latestDate)

        if cachedDateStr == currentDateStr,
           let cached = UserDefaults.standard.string(forKey: cacheTextKey),
           !cached.isEmpty {
            return cached
        }

        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else { return nil }

        let table = formatDataTable(sorted)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Analyze this InBody scan history and provide a brief insight.

        --- SCAN DATA ---
        \(table)
        --- END DATA ---
        """

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(text, forKey: cacheTextKey)
            UserDefaults.standard.set(currentDateStr, forKey: cacheDateKey)
            return text
        } catch {
            AppLogger.shared.log("BodyInsights LLM failed: \(error)", category: "insights")
            return nil
        }
    }

    @available(iOS 26.0, *)
    private static let instructions = """
    You are a body composition coach analyzing InBody 970 scan results. \
    Write exactly 2-3 sentences. Be specific with numbers from the data. \
    Cover:
    1. What's trending (body fat going down? muscle going up? plateau?)
    2. A projection or milestone (e.g. "at this rate you'll hit X% BF by month Y")
    3. One brief encouraging or actionable note

    Rules:
    - Only reference numbers that appear in the provided data table
    - Use lbs for weight/muscle, % for body fat
    - Keep it concise — no headers, no bullet points, just flowing sentences
    - Be encouraging but honest — if something plateaued, say so
    - Today's date is provided as the most recent scan date
    """
    #else
    static func generate(entries: [InBodyEntry]) async -> String? { nil }
    #endif

    static func invalidateCache() {
        UserDefaults.standard.removeObject(forKey: cacheTextKey)
        UserDefaults.standard.removeObject(forKey: cacheDateKey)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func formatDataTable(_ entries: [InBodyEntry]) -> String {
        var lines = ["Date | Weight(lbs) | BF% | SMM(lbs) | LBM(lbs) | Visceral"]
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        for e in entries {
            guard let d = e.date else { continue }
            let row = [
                df.string(from: d),
                e.weightLbs > 0 ? String(format: "%.1f", e.weightLbs) : "-",
                e.bodyFatPercentage > 0 ? String(format: "%.1f", e.bodyFatPercentage) : "-",
                e.skeletalMuscleMassLbs > 0 ? String(format: "%.1f", e.skeletalMuscleMassLbs) : "-",
                e.leanBodyMassLbs > 0 ? String(format: "%.1f", e.leanBodyMassLbs) : "-",
                e.visceralFatLevel > 0 ? "\(e.visceralFatLevel)" : "-"
            ].joined(separator: " | ")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
