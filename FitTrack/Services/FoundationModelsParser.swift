import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM path for parsing WOD PDFs. Uses Apple's Foundation Models
/// framework (iOS 26+, Apple Intelligence-capable hardware). The model sees
/// the raw extracted text plus a clear taxonomy and emits a structured
/// `LLMParsedWorkout` via the `@Generable` macro — no fragile regex.
///
/// This file is deliberately additive: callers go through
/// `PDFParser.smartParse(url:)` which falls back to the regex parser when the
/// model is unavailable, so the deployment target stays at iOS 17 and older
/// devices still work.
enum FoundationModelsParser {

    enum FMError: Error, LocalizedError {
        case unavailable(String)
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "On-device model unavailable: \(why)"
            case .empty:                return "PDF contained no extractable text."
            case .unreadable:           return "Could not open PDF."
            }
        }
    }

    /// Returns nil when Foundation Models isn't compiled in (Xcode SDK < 26).
    /// Throws when the SDK is present but the model is unavailable on this
    /// device (older iOS, no Apple Intelligence, downloading, etc.) — the
    /// caller should swallow that and fall back.
    static func parse(url: URL) async throws -> ParsedWorkout? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await parseV26(url: url)
        } else {
            throw FMError.unavailable("requires iOS 26+")
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func parseV26(url: URL) async throws -> ParsedWorkout {
        // 1. Pull pre-processed text from the regex parser. This drops PDFKit
        //    noise (blank lines, "Main Workout" separators), splits run-on
        //    number prefixes, and merges wrap-split continuations — leaving
        //    the LLM a clean, compact transcript. Critical for long PDFs
        //    (Mon WODs) that otherwise overflow the on-device context window.
        let cleaned = try PDFParser.preprocessedText(url: url)

        // 2. Verify the on-device model is actually usable. The framework can
        //    return `unavailable` for several reasons — surface the reason so
        //    the debug log tells us why the fallback fired.
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FMError.unavailable(String(describing: reason))
        @unknown default:
            throw FMError.unavailable("unknown availability state")
        }

        // 3. Set up a session with explicit instructions about the WOD format.
        //    The instructions encode the same taxonomy the regex parser tries
        //    to recover heuristically — but the model can use prose context
        //    instead of regex to disambiguate.
        let session = LanguageModelSession(instructions: Self.instructions)

        let prompt = """
        Parse the following workout PDF text into structured sections. Follow
        the rules in the instructions exactly.

        --- BEGIN PDF TEXT ---
        \(cleaned)
        --- END PDF TEXT ---
        """

        let response = try await session.respond(
            to: prompt,
            generating: LLMParsedWorkout.self
        )

        let llm = response.content
        let basename = url.deletingPathExtension().lastPathComponent
        return llm.toParsedWorkout(name: basename)
    }

    @available(iOS 26.0, *)
    private static let instructions: String = """
    You parse CrossFit-style WOD (Workout of the Day) PDFs. Each PDF has \
    sections in this fixed order:

      • Warm Up
      • Athletic Prep
      • Station 1, Station 2, Station 3, Station 4 (these are the working sets)
      • Finisher

    For every section emit:
      - kind: one of warmup, prep, station1, station2, station3, station4, finisher
      - title: the original section header text from the PDF
      - subtitle: an optional bold subheader, if any (often just a lift name)
      - scheme: round/time scheme like "4-6 Rounds", "12 Min EMOM", "30 Seconds each"
      - prefix: setup work that runs once before the list (e.g. "Buy in: 300m Row")
      - suffix: cooldown work that runs once after the list (e.g. "Buy out: 1 Lap")
      - exercises: the list of MAIN movements

    CRITICAL exercise rules:

    1) When a station has a single named lift followed by sub-numbered descriptors
       like "1. Warmup x 12-15" / "2. Working set x 8-10", the MAIN exercise is
       the lift named on the subtitle line. Drop ALL warm-up AND working-set
       descriptor rows entirely. Use the working-set descriptor's reps as the
       lift's reps. Example:

         Station 1
         BB or DB Deadlift
            1. Warmup x 12-15 each
            2. Working set x 8-10 each

       ✓ RIGHT: ONE exercise → name="BB or DB Deadlift", reps="x 8-10 each"
       ✗ WRONG: TWO exercises with name="Warmup" and name="Working set"
       ✗ WRONG: name="BB or DB Deadlift x 8-10 each", reps=""

       The words "Warmup", "Warm up", "Warm ups", "Working set", "Working sets",
       "Heavy single", "Heavy", "Heavy set", "Build to a heavy", "AMRAP",
       "Drop set", "Back-off set", "Top set" are NEVER exercise names — they
       are descriptors that must be dropped.

    2) When a station lists multiple distinct numbered movements, EACH ONE is a
       main exercise. Example:

         Station 3
         3-4 Rounds
            1. KB Front Squat to SL knee drive x 12
            2. KB high pulls x 12
            3. Bike x 10 cal

       → THREE exercises, scheme="3-4 Rounds".

    3) Heuristic for telling them apart: if the subtitle is a single LIFT NAME
       and every sub-item is "Warmup" / "Working set" / "Heavy single" / \
       "Build to a heavy" / "AMRAP" / "Drop set" / "Top set" — apply rule (1).
       Otherwise apply rule (2).

    4) Pacer / Mover labels (e.g. "Pacer:", "Mover: Bike") describe pairing, \
       NOT extra exercises. Strip the label from any exercise NAME and put it \
       in prefix or suffix instead.

    5) Never include warm-up descriptor lines as exercises in stations.

    6) `reps` is the raw rep/scheme text (e.g. "x 12", "x 8-10 each", \
       "500-300-200M"). Empty string if none. NEVER bake reps into the \
       `name` field — the rep text after " x " must always go in `reps`.

    7) Alternate-exercise tails such as "x 12 Or *Progression Row 250m" — the \
       asterisk marks an alternative movement, not part of the rep scheme. \
       Keep only the primary movement's reps; drop everything from " Or *" \
       onward. Example:
         "Pull ups x 12 Or *Progression Row 250m" \
         → name="Pull ups", reps="x 12"

    Skip "Main Workout" / "Main Workout: 4 Stations" header lines — they're \
    structural separators, not section headers.
    """

    // MARK: - Post-processing helpers (defense-in-depth for LLM slips)

    @available(iOS 26.0, *)
    private static let descriptorNames: Set<String> = [
        "warmup", "warm up", "warm-up", "warm ups", "warm-ups",
        "working set", "working sets", "work set", "work sets",
        "heavy single", "heavy", "heavy set",
        "max", "max effort", "max set",
        "build", "build up", "build to a heavy", "build to heavy",
        "amrap", "drop set", "back off set", "back-off set",
        "top set", "top sets"
    ]

    /// True when the exercise name (with any trailing " x ..." stripped) is
    /// a pure set-descriptor like "Working set" or "Heavy single" — these are
    /// never exercises on their own and must be dropped.
    @available(iOS 26.0, *)
    private static func isDescriptorOnly(_ name: String) -> Bool {
        let trimmed = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let head: String
        if let r = trimmed.range(of: #"\s+[xX]\s+"#, options: .regularExpression) {
            head = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            head = trimmed
        }
        return descriptorNames.contains(head)
    }

    /// If reps is empty and the name ends in " x ...", split the trailing
    /// rep text out into the reps field. Handles LLM slips where the model
    /// glued the rep scheme into the exercise name. Also runs when reps is
    /// already populated (the LLM frequently duplicates) — in that case the
    /// existing reps win and the name just gets cleaned up.
    ///
    /// Refuses the split when it would leave an unbalanced "(" in the head,
    /// so e.g. "Sled Push (Speedbump and back) x 2" doesn't land as
    /// name="Sled Push (Speedbump and back" / reps="x 2)".
    @available(iOS 26.0, *)
    private static func splitTrailingReps(name: String, reps: String) -> (String, String) {
        guard let r = name.range(of: #"\s+[xX]\s+\S.*$"#, options: .regularExpression) else {
            return (name, reps)
        }
        let head = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var tail = String(name[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        if tail.first == "X" { tail = "x" + tail.dropFirst() }
        let opens = head.filter { $0 == "(" }.count
        let closes = head.filter { $0 == ")" }.count
        if opens > closes { return (name, reps) }
        let finalReps = reps.trimmingCharacters(in: .whitespaces).isEmpty ? tail : reps
        return (head, finalReps)
    }

    /// Blank out reps when its body (after the leading "x ") is contained in
    /// the name. Catches cases like name="Row 400m + 40 Pushups" /
    /// reps="x 400m + 40 Pushups" where the LLM duplicated the work into
    /// both fields.
    @available(iOS 26.0, *)
    private static func dedupeRepsAgainstName(name: String, reps: String) -> String {
        let r = reps.trimmingCharacters(in: .whitespaces)
        guard r.lowercased().hasPrefix("x ") else { return reps }
        let body = String(r.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard body.count >= 3 else { return reps }
        if name.lowercased().contains(body.lowercased()) { return "" }
        return reps
    }

    /// Strip alternate-exercise tails like " Or *Progression Row 250m" from
    /// the reps field — the asterisk variant is a substitution suggestion,
    /// not part of the actual rep scheme.
    @available(iOS 26.0, *)
    private static func stripAlternateTail(_ reps: String) -> String {
        if let r = reps.range(of: #"\s+[Oo]r\s+\*.*$"#, options: .regularExpression) {
            return String(reps[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return reps
    }

    /// Gym-specific abbreviations that must stay all-caps regardless of how
    /// the LLM cased them in the source. Standard title-case would otherwise
    /// produce "Bb Bench" / "Db Row" / "Trx Row" — unprofessional.
    @available(iOS 26.0, *)
    private static let preserveTokens: Set<String> = [
        "BB", "DB", "KB", "MB", "SB", "TRX", "BOSU",
        "AFAP", "AMRAP", "EMOM", "RFT", "RFE", "BSS",
        "RDL", "SLDL", "OHP", "GHD", "HSPU", "T2B", "TTB", "C2B", "DU",
        "ROM", "ATG", "PR", "WOD", "SL", "DL", "BP", "FS", "BS",
        "S360", "S180"
    ]

    /// Title-case every word (including small connectors like "to", "or",
    /// "and") while preserving gym abbreviations. Hyphenated words get
    /// each segment cased independently so "bent-over" becomes "Bent-Over".
    @available(iOS 26.0, *)
    private static func titleCased(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let s = String(word)
            if s.isEmpty { return s }
            if preserveTokens.contains(s.uppercased()) { return s.uppercased() }
            return s.split(separator: "-", omittingEmptySubsequences: false)
                .map { titleCaseSegment(String($0)) }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    @available(iOS 26.0, *)
    private static func titleCaseSegment(_ s: String) -> String {
        if s.isEmpty { return s }
        if preserveTokens.contains(s.uppercased()) { return s.uppercased() }
        return s.prefix(1).uppercased() + s.dropFirst().lowercased()
    }

    // MARK: - Generable mirror types

    @available(iOS 26.0, *)
    @Generable
    struct LLMParsedWorkout {
        @Guide(description: "Sections in canonical order: warmup, prep, station1-4, finisher")
        var sections: [LLMSection]

        func toParsedWorkout(name: String) -> ParsedWorkout {
            let mapped = sections.compactMap { $0.toSection() }
            let sorted = mapped.sorted { $0.kind.sortIndex < $1.kind.sortIndex }
            return ParsedWorkout(name: name, importedAt: Date(), sections: sorted)
        }
    }

    @available(iOS 26.0, *)
    @Generable
    struct LLMSection {
        @Guide(description: "Section kind: one of warmup, prep, station1, station2, station3, station4, finisher")
        var kind: String

        @Guide(description: "Original section header text from the PDF")
        var title: String

        @Guide(description: "Optional bold subheader (often a lift name) — null if none")
        var subtitle: String?

        @Guide(description: "Round/time scheme like '4-6 Rounds', '12 Min EMOM', '30 Seconds each' — null if none")
        var scheme: String?

        @Guide(description: "One-time setup line e.g. 'Buy in: 300m Row' — null if none")
        var prefix: String?

        @Guide(description: "One-time cooldown line e.g. 'Buy out: 1 Lap' — null if none")
        var suffix: String?

        @Guide(description: "Main exercises — collapse warm-up/working-set descriptors into the lift named in subtitle (rule 1 in instructions)")
        var exercises: [LLMExercise]

        func toSection() -> WorkoutSection? {
            guard let k = WorkoutSection.Kind(rawValue: kind.lowercased()) else { return nil }

            // 1. Normalize each exercise: split trailing reps from name,
            //    blank duplicated reps, strip alternate-exercise tails,
            //    title-case the name.
            let normalized: [WorkoutExercise] = exercises.map { ex in
                let (n1, r1) = FoundationModelsParser.splitTrailingReps(name: ex.name, reps: ex.reps)
                let r2 = FoundationModelsParser.dedupeRepsAgainstName(name: n1, reps: r1)
                let r3 = FoundationModelsParser.stripAlternateTail(r2)
                let n2 = FoundationModelsParser.titleCased(n1)
                return WorkoutExercise(name: n2, reps: r3)
            }

            // 2. Drop pure descriptor rows ("Working set x 8-10", "Warmup x 12").
            let nonDescriptor = normalized.filter { !FoundationModelsParser.isDescriptorOnly($0.name) }

            // 3. Dedupe by lowercased name. The LLM frequently substitutes the
            //    lift's subtitle into both the warmup and working-set rows,
            //    leaving "BB Bench Press" twice. Walk in reverse so the LAST
            //    occurrence wins (working-set reps), then re-reverse.
            var seen = Set<String>()
            var deduped: [WorkoutExercise] = []
            for ex in nonDescriptor.reversed() {
                let key = ex.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if seen.insert(key).inserted { deduped.append(ex) }
            }
            deduped.reverse()

            // 4. If the LLM kept descriptors but no real exercises AND we have
            //    a subtitle (the lift name), promote the subtitle to be the
            //    single exercise — using the LAST descriptor's reps (typically
            //    the working-set reps).
            let finalExercises: [WorkoutExercise]
            let finalSubtitle: String?
            if deduped.isEmpty, !normalized.isEmpty, let lift = subtitle?.nilIfEmpty {
                let workingReps = normalized.last?.reps ?? ""
                finalExercises = [WorkoutExercise(name: FoundationModelsParser.titleCased(lift), reps: workingReps)]
                finalSubtitle = nil
            } else {
                finalExercises = deduped
                finalSubtitle = subtitle?.nilIfEmpty.map { FoundationModelsParser.titleCased($0) }
            }

            return WorkoutSection(
                kind: k,
                title: title,
                subtitle: finalSubtitle,
                scheme: scheme?.nilIfEmpty,
                prefix: prefix?.nilIfEmpty,
                suffix: suffix?.nilIfEmpty,
                exercises: finalExercises
            )
        }
    }

    @available(iOS 26.0, *)
    @Generable
    struct LLMExercise {
        @Guide(description: "Exercise name (e.g. 'BB Deadlift', 'KB high pulls')")
        var name: String

        @Guide(description: "Raw reps/scheme text (e.g. 'x 12', 'x 8-10 each', '500-300-200M'). Empty string if none.")
        var reps: String

        func toExercise() -> WorkoutExercise {
            WorkoutExercise(name: name, reps: reps)
        }
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
