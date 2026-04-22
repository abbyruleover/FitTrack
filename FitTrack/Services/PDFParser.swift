import Foundation
import PDFKit

/// Parses a WOD PDF (file URL) into a `ParsedWorkout`.
///
/// Format spec (confirmed across two weeks of sample PDFs — 4/13 and 4/20):
///   Sections appear in fixed order:
///     Warm Up, Athletic Prep, Station 1-4, Finishers
///   Each section:
///     - HEADER line (keyword-matched)
///     - optional SUBTITLE line (e.g. "BB or DB Squats")
///     - optional SCHEME line (e.g. "3 Rounds", "30 Seconds each", "8 Min AMRAP")
///     - optional PREFIX line (e.g. "Run 1 lap then;", "Buy in: …")
///     - numbered EXERCISES:  "1. <name> x <reps>"  / bullet `•` / asterisk `*`
///     - optional SUFFIX line (e.g. "Buy out: 1 Lap or 15 Burpees")
///
/// Detection is heuristic — we can't see PDF font weight reliably from
/// `PDFDocument.string`, so we rely on keyword matching for headers and
/// numeric/bullet prefixes for exercise lines.
///
/// Pre-processing handles three real-world PDFKit artifacts that the v1
/// parser couldn't: (a) wrapped exercise lines that lose half their reps,
/// (b) PDFs that emit `1. 2. 3. <name>` on one line with names following
/// unprefixed, (c) "Main Workout" / "Main Workout: 4 Stations" structural
/// labels bleeding into the previous section's suffix.
enum PDFParser {
    enum ParseError: Error, LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not open PDF."
            case .empty: return "PDF contained no extractable text."
            }
        }
    }

    /// Pre-processed text ready to feed to the on-device LLM. Drops PDFKit
    /// noise ("Main Workout" separators, blank lines), splits run-on number
    /// prefixes, and merges wrapped continuations — exactly what the regex
    /// parser already does. Hands the LLM a smaller, structurally-clean
    /// transcript, which is the difference between fitting and overflowing
    /// the on-device model's context window for long PDFs (Mon WODs).
    static func preprocessedText(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ParseError.unreadable }
        var raw = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let str = page.string {
                raw += str + "\n"
            }
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }
        return preprocess(raw).joined(separator: "\n")
    }

    /// Smart entry point: try the on-device LLM first, then fall back to the
    /// regex parser if it fails or isn't available. Use this for any UI-driven
    /// import — the model handles the cases regex can't disambiguate (e.g.
    /// "single lift with sub-numbered Warmup/Working set" vs. "three numbered
    /// movements"). Logs which path produced the result so we can audit later.
    static func smartParse(url: URL) async throws -> ParsedWorkout {
        do {
            if let llm = try await FoundationModelsParser.parse(url: url) {
                AppLogger.shared.log("smartParse: LLM path OK (\(llm.sections.count) sections)", category: "import")
                return llm
            } else {
                AppLogger.shared.log("smartParse: FoundationModels not compiled in — falling back to regex", category: "import")
            }
        } catch {
            AppLogger.shared.log("smartParse: LLM path FAILED (\(error.localizedDescription)) — falling back to regex", category: "import")
        }
        let parsed = try parse(url: url)
        AppLogger.shared.log("smartParse: regex path OK (\(parsed.sections.count) sections)", category: "import")
        return parsed
    }

    /// Top-level entry point — read the file at `url` and return the parsed model.
    static func parse(url: URL) throws -> ParsedWorkout {
        guard let doc = PDFDocument(url: url) else { throw ParseError.unreadable }
        var raw = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let str = page.string {
                raw += str + "\n"
            }
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }

        let lines = preprocess(raw)
        let sections = splitIntoSections(lines)
        let name = url.deletingPathExtension().lastPathComponent
        return ParsedWorkout(name: name, importedAt: Date(), sections: sections)
    }

    // MARK: - Preprocessing pipeline

    /// Trim, drop noise, drop "Main Workout" structural separators, then run
    /// the merge passes that recover from PDFKit line-wrap artifacts.
    private static func preprocess(_ raw: String) -> [String] {
        let trimmed = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !isMainWorkoutSeparator($0) }

        let withSplitRunOns = splitRunOnNumberPrefixes(trimmed)
        let merged = mergeWrappedContinuations(withSplitRunOns)
        return merged
    }

    /// "Main Workout", "Main Workout:", "Main Workout: 4 Stations (8 Min) Circuit"
    /// — these label the boundary between Athletic Prep and the stations but
    /// aren't a header we can route to. They were getting bucketed into the
    /// prep section's suffix, polluting the display. Drop them outright.
    private static func isMainWorkoutSeparator(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("main workout")
    }

    /// PDFKit sometimes renders three numbered items as `1. 2. 3. <name>`
    /// on one line, with the actual lifts following on unprefixed lines.
    /// Real example (Tues 4/20 S2):
    ///     "1. 2. 3. DB Bent over Row x 12"
    ///     "DB Suitcase squats to floor x 12"
    ///     "DB Hinge to curl x 12"
    /// We rewrite that into:
    ///     "1. DB Bent over Row x 12"
    ///     "2. DB Suitcase squats to floor x 12"
    ///     "3. DB Hinge to curl x 12"
    /// Strategy: detect the run-on prefix, peel off the leading numbers,
    /// emit "1. <body>" plus N-1 placeholders. The placeholders are
    /// invisible markers the merge pass uses to know how many follow-on
    /// unnumbered lines to claim.
    private static func splitRunOnNumberPrefixes(_ lines: [String]) -> [String] {
        var out: [String] = []
        let runOn = try! NSRegularExpression(pattern: #"^((?:\d+\.\s*){2,})(.*)$"#)
        var pendingClaims: Int = 0   // count of numbered slots still expected
        var nextIndex: Int = 2       // next number to assign to a continuation

        for raw in lines {
            // Resolve outstanding claims first: an unnumbered line right after
            // a run-on becomes the next numbered exercise.
            if pendingClaims > 0,
               raw.range(of: #"^\d+\."#, options: .regularExpression) == nil,
               !looksLikeNonExerciseText(raw) {
                out.append("\(nextIndex). \(raw)")
                nextIndex += 1
                pendingClaims -= 1
                continue
            }

            // Detect new run-on prefix.
            let ns = raw as NSString
            if let m = runOn.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let prefix = ns.substring(with: m.range(at: 1))
                let body   = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let count = prefix.split(whereSeparator: { $0 == "." }).count
                out.append("1. \(body)")
                pendingClaims = max(0, count - 1)
                nextIndex = 2
                continue
            }

            pendingClaims = 0
            out.append(raw)
        }
        return out
    }

    /// A line that looks like a header, scheme, prefix, or bullet shouldn't
    /// be eaten by run-on resolution — it's actually a new structural element.
    private static func looksLikeNonExerciseText(_ line: String) -> Bool {
        if detectHeader(line) != nil { return true }
        let l = line.lowercased()
        if l.hasPrefix("•") || l.hasPrefix("*") || l.hasPrefix("-") { return false } // these ARE exercises
        if l.hasPrefix("pacer") || l.hasPrefix("mover") { return true }
        if l.hasPrefix("buy in") || l.hasPrefix("buy out") { return true }
        return false
    }

    /// Merge lines that are obvious wrap-continuations of the previous line.
    /// Two cases (both seen in real PDFs):
    ///   (a) Previous line ends with " x" or ", and the current line starts
    ///       with reps-looking text (digits, "x ", "AMRAP", etc.). Glue.
    ///   (b) Previous line is a numbered/bulleted exercise and the current
    ///       line is plain prose (no number, no bullet, no header keyword,
    ///       short enough to be a wrap). Glue with a space.
    /// We deliberately do NOT merge across header boundaries.
    private static func mergeWrappedContinuations(_ lines: [String]) -> [String] {
        var out: [String] = []
        for raw in lines {
            guard let prev = out.last else { out.append(raw); continue }
            if shouldMerge(previous: prev, current: raw) {
                out.removeLast()
                out.append(prev + " " + raw)
            } else {
                out.append(raw)
            }
        }
        return out
    }

    private static func shouldMerge(previous: String, current: String) -> Bool {
        // Never absorb headers, scheme-shaped lines, or new bullets.
        if detectHeader(current) != nil { return false }
        if isNumberedOrBulleted(current) {
            // Special case: previous line ended with trailing " x" (reps got
            // line-wrapped onto a new numbered slot, e.g.
            //   "1. Sledgehammer Iso Lunge Chops"
            //   "2. x 10/10"
            // Treat the "2. x 10/10" as reps that belong to #1. Strip the
            // leading "<n>." and merge.
            if currentIsRepsContinuation(current), previousAcceptsRepsTail(previous) {
                return true
            }
            return false
        }
        // Plain wrap of an exercise.
        if isNumberedOrBulleted(previous) {
            // "Lateral shuffle to squat jump within your" + "zone x 10"
            // "Brick T-pose reverse fly (switch leg half" + "way)"
            // "Landmine SA reverse lunge to OH press x" + "10/10"
            return true
        }
        return false
    }

    private static func currentIsRepsContinuation(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: ".") else { return false }
        let body = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        let bl = body.lowercased()
        return bl.hasPrefix("x ") || bl.hasPrefix("amrap") || bl.range(of: #"^\d"#, options: .regularExpression) != nil
    }

    private static func previousAcceptsRepsTail(_ line: String) -> Bool {
        // Ends in trailing " x" with no reps captured, or has no reps at all.
        let l = line.lowercased()
        if l.hasSuffix(" x") { return true }
        // Numbered/bulleted line with no reps token at all.
        if isNumberedOrBulleted(line),
           line.range(of: #"\s+[xX]\s+"#, options: .regularExpression) == nil {
            return true
        }
        return false
    }

    private static func isNumberedOrBulleted(_ line: String) -> Bool {
        return line.range(of: #"^\s*(?:\d+\.|•|\*|-)\s*"#, options: .regularExpression) != nil
    }

    // MARK: - Section split

    /// Walk the line list, opening a new section whenever a header keyword hits,
    /// and bucketing intermediate lines into the current section.
    private static func splitIntoSections(_ lines: [String]) -> [WorkoutSection] {
        var built: [WorkoutSection] = []
        var current: SectionBuilder?

        for line in lines {
            if let kind = detectHeader(line) {
                if let c = current { built.append(c.finish()) }
                current = SectionBuilder(kind: kind, title: line)
                continue
            }
            current?.append(line)
        }
        if let c = current { built.append(c.finish()) }

        return built.sorted { $0.kind.sortIndex < $1.kind.sortIndex }
    }

    /// Header detection — case-insensitive keyword match. Order matters because
    /// "Station 1" must win over "Station" alone.
    fileprivate static func detectHeader(_ line: String) -> WorkoutSection.Kind? {
        let l = line.lowercased()
        // Skip if line is clearly an exercise (starts with "1.", "2.", etc.).
        if l.range(of: #"^\d+\."#, options: .regularExpression) != nil { return nil }

        if l.contains("station 1") { return .station1 }
        if l.contains("station 2") { return .station2 }
        if l.contains("station 3") { return .station3 }
        if l.contains("station 4") { return .station4 }
        if l.contains("warm up") || l.contains("warm-up") { return .warmup }
        if l.contains("athletic prep") || l.contains("prep") { return .prep }
        if l.contains("finisher") { return .finisher }
        return nil
    }
}

// MARK: - SectionBuilder

/// Mutable accumulator that figures out which incoming line is the
/// subtitle / scheme / prefix / exercises / suffix as it goes.
private final class SectionBuilder {
    let kind: WorkoutSection.Kind
    let title: String
    private var pending: [String] = []

    init(kind: WorkoutSection.Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    func append(_ line: String) { pending.append(line) }

    func finish() -> WorkoutSection {
        // Split the buffer into pre-list lines, exercise lines, post-list lines.
        var preList: [String] = []
        var exerciseLines: [String] = []
        var postList: [String] = []

        var phase: Phase = .pre
        for line in pending {
            let isExercise = isExerciseLine(line)
            switch phase {
            case .pre:
                if isExercise { phase = .list; exerciseLines.append(line) } else { preList.append(line) }
            case .list:
                if isExercise { exerciseLines.append(line) } else { phase = .post; postList.append(line) }
            case .post:
                postList.append(line)
            }
        }

        // Pre-list classification:
        //   first non-scheme line  → subtitle
        //   line that looks scheme → scheme
        //   anything trailing pre-list → prefix
        var subtitle: String?
        var scheme: String?
        var prefix: String?
        for line in preList {
            // "Buy in: 300m Row, 3-4 Rounds" — split into prefix + scheme.
            if scheme == nil,
               let (buyIn, rest) = splitBuyInScheme(line) {
                prefix = [prefix, buyIn].compactMap { $0 }.joined(separator: " ")
                scheme = rest
                continue
            }
            if scheme == nil, looksLikeScheme(line) {
                scheme = line
            } else if subtitle == nil, !looksLikeScheme(line), !looksLikePrefix(line) {
                subtitle = line
            } else {
                // Append into prefix (multiple prefix lines join with a space).
                prefix = [prefix, line].compactMap { $0 }.joined(separator: " ")
            }
        }

        let exercises = exerciseLines.compactMap(parseExercise)
        let suffix = postList.isEmpty ? nil : postList.joined(separator: " ")

        // Stations should never carry warmup wording — if the parser bucketed
        // a stray "Warm Up" line into a station (mis-detected header, prefix
        // bleed, etc.), drop it here so the live logger stays focused on the
        // station's actual lifts.
        if kind.isLoggable {
            return finishLoggable(subtitle: subtitle, scheme: scheme,
                                  prefix: prefix, suffix: suffix, exercises: exercises)
        }

        return WorkoutSection(
            kind: kind, title: title,
            subtitle: subtitle, scheme: scheme,
            prefix: prefix, suffix: suffix,
            exercises: exercises
        )
    }

    /// Stations carry the heuristic baggage: drop warmup-word exercises,
    /// collapse "subtitle is the lift, numbered list is set descriptors"
    /// into a single working-set card, and surface any non-descriptor lifts
    /// alongside.
    private func finishLoggable(subtitle: String?, scheme: String?, prefix: String?,
                                suffix: String?, exercises: [WorkoutExercise]) -> WorkoutSection {
        // Always strip "warm up" / "warmup" descriptor lines from a station's
        // numbered list — they're set-prep tells, not lifts the user logs.
        var workingSet = exercises.filter {
            !mentionsWarmup($0.name) && !isPureWarmupDescriptor($0.name)
        }

        // If the subtitle reads like an actual lift AND any of the surviving
        // lines are still set descriptors ("Working set"), promote the
        // subtitle to a real exercise and replace the descriptor with it
        // (carrying the descriptor's reps over). Anything that *isn't* a
        // descriptor stays — those are extra lifts (e.g. "Superband Twists").
        if let lift = subtitle, !workingSet.isEmpty {
            let descriptors = workingSet.filter { isSetDescriptor($0.name) }
            let extras      = workingSet.filter { !isSetDescriptor($0.name) }
            if !descriptors.isEmpty {
                let workingReps = descriptors.last?.reps ?? ""
                workingSet = [WorkoutExercise(name: lift, reps: workingReps)] + extras
                return WorkoutSection(
                    kind: kind, title: title,
                    subtitle: nil, scheme: scrubbed(scheme),
                    prefix: scrubbed(prefix), suffix: scrubbed(suffix),
                    exercises: workingSet
                )
            }
        }

        return WorkoutSection(
            kind: kind, title: title,
            subtitle: scrubbed(subtitle), scheme: scrubbed(scheme),
            prefix: scrubbed(prefix), suffix: scrubbed(suffix),
            exercises: workingSet
        )
    }

    private func mentionsWarmup(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("warm up") || l.contains("warm-up") || l.contains("warmup")
    }

    /// "Warm up x 10-12", "Warmup set x 12-15", etc. — distinct from
    /// `mentionsWarmup` because we want to drop these even when the lifts
    /// list also has legitimate non-warmup entries.
    private func isPureWarmupDescriptor(_ name: String) -> Bool {
        let l = name.lowercased().trimmingCharacters(in: .whitespaces)
        return l == "warm up" || l == "warmup" || l == "warm-up"
            || l.hasPrefix("warm up ") || l.hasPrefix("warmup ") || l.hasPrefix("warm-up ")
            || l.hasPrefix("warm ups ") || l == "warm ups"
            || l.hasPrefix("warm up set") || l.hasPrefix("warmup set")
    }

    private func scrubbed(_ text: String?) -> String? {
        guard let text else { return nil }
        return mentionsWarmup(text) ? nil : text
    }

    /// Set-descriptor labels that appear in the numbered list of a station
    /// when the actual lift is in the subtitle. If a numbered line is one
    /// of these, we treat it as a set count tell, not a lift name.
    private func isSetDescriptor(_ name: String) -> Bool {
        let l = name.lowercased().trimmingCharacters(in: .whitespaces)
        let descriptors = [
            "working set", "working sets", "work set", "work sets",
            "heavy single", "heavy", "heavy set",
            "max", "max effort", "max set",
            "build", "build up", "build to a heavy",
            "amrap", "drop set", "back off set", "back-off set",
            "top set", "top sets"
        ]
        return descriptors.contains { d in
            l == d || l.hasPrefix(d + " ") || l.hasSuffix(" " + d) || l.contains(" " + d + " ")
        }
    }

    private enum Phase { case pre, list, post }

    /// Numbered (1.), bulleted (•), asterisk (*), or dashed (-) lines all
    /// count as exercises. The asterisk case is intentionally narrow to
    /// avoid eating notes — only treat `*` as an exercise prefix when the
    /// rest of the line looks lift-shaped (has reps or known equipment).
    private func isExerciseLine(_ line: String) -> Bool {
        if line.range(of: #"^\d+\."#, options: .regularExpression) != nil { return true }
        if line.hasPrefix("•") { return true }
        if line.hasPrefix("-") { return true }
        // `*` is ambiguous (also used for notes like "*Run 1 lap then;").
        // Only count it when an "x <reps>" token follows.
        if line.hasPrefix("*"),
           line.range(of: #"\s+[xX]\s+"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Heuristic: scheme lines mention rounds/seconds/minutes/AMRAP/EMOM.
    private func looksLikeScheme(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("round") || l.contains("second") || l.contains("minute")
            || l.contains("amrap") || l.contains("emom") || l.contains(" each")
    }

    /// Heuristic: lines ending with ";" or starting with "Buy in"/"Run "/"Row "/"Pacer"/"Mover"
    /// are prefix/setup lines, not subtitles.
    private func looksLikePrefix(_ line: String) -> Bool {
        let l = line.lowercased()
        return line.hasSuffix(";")
            || l.hasPrefix("buy in") || l.hasPrefix("buy out")
            || l.hasPrefix("run ") || l.hasPrefix("row ")
            || l.hasPrefix("pacer") || l.hasPrefix("mover")
    }

    /// "Buy in: 300m Row, 3-4 Rounds" → ("Buy in: 300m Row", "3-4 Rounds").
    /// Returns nil if the line doesn't match the buy-in + comma + scheme shape.
    private func splitBuyInScheme(_ line: String) -> (String, String)? {
        let l = line.lowercased()
        guard l.hasPrefix("buy in"), let comma = line.firstIndex(of: ",") else { return nil }
        let left  = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
        let right = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        guard looksLikeScheme(right) else { return nil }
        return (left, right)
    }

    /// Split "1. Goblet Squat x 8-10" / "• Pacer: KB Swings x 15" into name + reps.
    /// Strips leading number / bullet / asterisk / dash. If no "x <reps>" suffix
    /// the entire body becomes the name and reps is "".
    private func parseExercise(_ line: String) -> WorkoutExercise? {
        var body: String

        if let dot = line.firstIndex(of: "."),
           line[..<dot].allSatisfy({ $0.isNumber || $0.isWhitespace }) {
            body = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("•") {
            body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("*") {
            body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("-") {
            body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        if body.isEmpty { return nil }

        // Try to split on " x " (case-insensitive) — that's the rep delimiter.
        if let xRange = body.range(of: #"\s+[xX]\s+"#, options: .regularExpression) {
            let name = String(body[..<xRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let reps = "x " + String(body[xRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return WorkoutExercise(name: name, reps: reps)
        }
        // Fallback: store the whole body as the name with empty reps.
        return WorkoutExercise(name: body, reps: "")
    }
}
