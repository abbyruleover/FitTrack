import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM path for parsing InBody 970 result sheets. Uses Apple's
/// Foundation Models framework (iOS 26+, Apple Intelligence-capable hardware).
/// The model sees OCR or PDFKit-extracted text plus a layout description and
/// emits a structured `LLMInBodyScan` via `@Generable` — no fragile regex or
/// spatial-bbox heuristics.
///
/// Callers go through `InBodyPDFParser.smartParse(...)` which falls back to
/// the regex/bbox parser when the model is unavailable, so older devices and
/// non-AI hardware still work.
enum FoundationModelsInBodyParser {

    enum FMError: Error, LocalizedError {
        case unavailable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "On-device model unavailable: \(why)"
            case .empty:                return "No text to parse."
            }
        }
    }

    /// Returns nil when Foundation Models isn't compiled in (Xcode SDK < 26).
    /// Throws when the SDK is present but the model is unavailable on this
    /// device. The caller should swallow the error and fall back.
    static func parse(text: String, filename: String, fallbackDate: Date) async throws -> InBodyPDFParser.Scan? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await parseV26(text: text, filename: filename, fallbackDate: fallbackDate)
        } else {
            throw FMError.unavailable("requires iOS 26+")
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func parseV26(text: String, filename: String, fallbackDate: Date) async throws -> InBodyPDFParser.Scan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FMError.empty }

        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FMError.unavailable(String(describing: reason))
        @unknown default:
            throw FMError.unavailable("unknown availability state")
        }

        let session = LanguageModelSession(instructions: Self.instructions)

        let prompt = """
        Extract all metrics from the following InBody 970 result sheet text. \
        Follow the rules in the instructions exactly.

        --- BEGIN INBODY TEXT ---
        \(trimmed)
        --- END INBODY TEXT ---
        """

        let response = try await session.respond(
            to: prompt,
            generating: LLMInBodyScan.self
        )

        return response.content.toScan(filename: filename, fallbackDate: fallbackDate)
    }

    @available(iOS 26.0, *)
    private static let instructions: String = """
    You extract numeric metrics from InBody 970 body composition result sheets. \
    The text is either from a digital PDF export (clean reading order) or from \
    Vision OCR on a photo/scan (may have scrambled column order).

    The InBody 970 result sheet has these sections:

    HEADER: Patient name, ID, height (ft/in), weight, age, test date/time.
      - Test Date / Time is formatted as "MM.dd.yyyy HH:mm" (e.g. "02.25.2026 11:07").
      - Height is in feet and inches (e.g. "5ft. 10.0in." = 70 inches).

    BODY COMPOSITION ANALYSIS: Weight (lbs), Skeletal Muscle Mass / SMM (lbs), \
    Body Fat Mass (lbs).

    MUSCLE-FAT ANALYSIS: Weight, SMM, Body Fat Mass again (same values).

    OBESITY ANALYSIS: BMI, Percent Body Fat / PBF (0-100 range).

    SEGMENTAL LEAN ANALYSIS: Five body regions, each with a lean mass in lbs \
    AND a percentage. Order is always:
      1. Right Arm — lbs, then %
      2. Left Arm — lbs, then %
      3. Trunk — lbs, then %
      4. Right Leg — lbs, then %
      5. Left Leg — lbs, then %
    CRITICAL: The lbs value comes FIRST, the percentage SECOND for each region. \
    Do NOT swap them. Lbs values are typically 4-80 range; percentages are \
    typically 80-120 range (percentage of ideal, not body fat %).

    BODY WATER: Intracellular Water / ICW (lbs), Extracellular Water / ECW (lbs), \
    Total Body Water / TBW (lbs), ECW/TBW Ratio (decimal 0.300-0.500 range).

    OTHER:
      - Lean Body Mass (lbs) — total lean, not segmental
      - Dry Lean Mass (lbs)
      - Visceral Fat Level — integer 1-20 (reported as "Level N")
      - Basal Metabolic Rate / BMR (kcal)

    IMPORTANT:
      - All weights are in POUNDS (lbs), not kg. The InBody at FNS reports imperial.
      - Ignore bar chart axis tick marks (55, 70, 85, 100, 115, etc.) — these are \
        scale labels, not metric values.
      - If a value cannot be found, use 0 (zero).
      - For scanDateString, reproduce the date exactly as "MM.dd.yyyy HH:mm". \
        If you cannot find a date, use an empty string.
      - ECW/TBW Ratio is a small decimal (e.g. 0.380), not a percentage.
    """

    // MARK: - Generable types

    @available(iOS 26.0, *)
    @Generable
    struct LLMInBodyScan {
        @Guide(description: "Scan date as 'MM.dd.yyyy HH:mm' or empty if not found")
        var scanDateString: String

        @Guide(description: "Height in total inches (e.g. 70.0 for 5ft 10in)")
        var heightInches: Double

        @Guide(description: "Age in years")
        var ageYears: Int

        @Guide(description: "Weight in lbs")
        var weightLbs: Double

        @Guide(description: "Body Mass Index")
        var bmi: Double

        @Guide(description: "Percent Body Fat 0-100")
        var bodyFatPercentage: Double

        @Guide(description: "Body Fat Mass in lbs")
        var bodyFatMassLbs: Double

        @Guide(description: "Lean Body Mass in lbs")
        var leanBodyMassLbs: Double

        @Guide(description: "Skeletal Muscle Mass in lbs")
        var skeletalMuscleMassLbs: Double

        @Guide(description: "Dry Lean Mass in lbs")
        var dryLeanMassLbs: Double

        @Guide(description: "Intracellular Water in lbs")
        var intracellularWaterLbs: Double

        @Guide(description: "Extracellular Water in lbs")
        var extracellularWaterLbs: Double

        @Guide(description: "Total Body Water in lbs")
        var totalBodyWaterLbs: Double

        @Guide(description: "ECW/TBW Ratio (decimal, e.g. 0.380)")
        var ecwTbwRatio: Double

        @Guide(description: "Visceral Fat Level integer 1-20")
        var visceralFatLevel: Int

        @Guide(description: "Basal Metabolic Rate in kcal")
        var basalMetabolicRateKcal: Double

        @Guide(description: "Right Arm lean mass in lbs")
        var rightArmLeanLbs: Double

        @Guide(description: "Right Arm lean percent of ideal")
        var rightArmLeanPct: Double

        @Guide(description: "Left Arm lean mass in lbs")
        var leftArmLeanLbs: Double

        @Guide(description: "Left Arm lean percent of ideal")
        var leftArmLeanPct: Double

        @Guide(description: "Trunk lean mass in lbs")
        var trunkLeanLbs: Double

        @Guide(description: "Trunk lean percent of ideal")
        var trunkLeanPct: Double

        @Guide(description: "Right Leg lean mass in lbs")
        var rightLegLeanLbs: Double

        @Guide(description: "Right Leg lean percent of ideal")
        var rightLegLeanPct: Double

        @Guide(description: "Left Leg lean mass in lbs")
        var leftLegLeanLbs: Double

        @Guide(description: "Left Leg lean percent of ideal")
        var leftLegLeanPct: Double

        func toScan(filename: String, fallbackDate: Date) -> InBodyPDFParser.Scan {
            var scan = InBodyPDFParser.Scan(scanDate: fallbackDate, pdfFilename: filename)

            if !scanDateString.isEmpty {
                scan.scanDate = parseDate(scanDateString) ?? fallbackDate
            }

            scan.heightInches = heightInches
            scan.ageYears = ageYears

            scan.weightLbs = weightLbs
            scan.bmi = bmi
            scan.bodyFatPercentage = bodyFatPercentage
            scan.bodyFatMassLbs = bodyFatMassLbs
            scan.leanBodyMassLbs = leanBodyMassLbs
            scan.skeletalMuscleMassLbs = skeletalMuscleMassLbs
            scan.dryLeanMassLbs = dryLeanMassLbs
            scan.intracellularWaterLbs = intracellularWaterLbs
            scan.extracellularWaterLbs = extracellularWaterLbs
            scan.totalBodyWaterLbs = totalBodyWaterLbs
            scan.ecwTbwRatio = ecwTbwRatio
            scan.visceralFatLevel = visceralFatLevel
            scan.basalMetabolicRateKcal = basalMetabolicRateKcal

            scan.rightArmLeanLbs = rightArmLeanLbs
            scan.rightArmLeanPct = rightArmLeanPct
            scan.leftArmLeanLbs = leftArmLeanLbs
            scan.leftArmLeanPct = leftArmLeanPct
            scan.trunkLeanLbs = trunkLeanLbs
            scan.trunkLeanPct = trunkLeanPct
            scan.rightLegLeanLbs = rightLegLeanLbs
            scan.rightLegLeanPct = rightLegLeanPct
            scan.leftLegLeanLbs = leftLegLeanLbs
            scan.leftLegLeanPct = leftLegLeanPct

            return scan
        }

        private func parseDate(_ str: String) -> Date? {
            let cleaned = str.replacingOccurrences(of: " ", with: "")
            let f = DateFormatter()
            f.dateFormat = "MM.dd.yyyy"
            let dateOnly = String(cleaned.prefix(10))
            let timeOnly = String(cleaned.suffix(5))
            guard let day = f.date(from: dateOnly) else { return nil }
            let comps = timeOnly.split(separator: ":").compactMap { Int($0) }
            guard comps.count == 2 else { return day }
            var cal = Calendar.current
            cal.timeZone = .current
            return cal.date(bySettingHour: comps[0], minute: comps[1], second: 0, of: day) ?? day
        }
    }
    #endif
}
