import Foundation
import PDFKit
import Vision
import CoreImage
import UIKit

/// Parses an InBody 970 result sheet (PDF) into an in-memory `Scan`.
///
/// Two ingest paths:
///   1. Digital export — `PDFDocument.string` returns text in semantic
///      reading order, so keyword + regex extraction is reliable.
///   2. Scanned printout / phone photo — no text layer, multi-column
///      layout. Vision OCR's flat string concatenates the left column
///      then the right column, which scrambles label/value adjacency
///      ("Extracellular Water 56.2" reads the ICW value because ECW
///      sits in another column). For this path we keep each recognized
///      observation's bounding box and extract values *spatially* —
///      find the label box, then look for the nearest non-tick decimal
///      on the same row (or directly below for vertical tables).
enum InBodyPDFParser {
    enum ParseError: Error, LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not open PDF."
            case .empty:      return "PDF contained no extractable text."
            }
        }
    }

    /// Snapshot of one InBody result sheet. Every numeric defaults to 0
    /// so the import flow can render every field — the user sees which
    /// ones were extracted vs. left blank before saving.
    struct Scan {
        var scanDate: Date
        var pdfFilename: String

        // Profile (PDF header)
        var heightInches: Double = 0
        var ageYears: Int = 0

        // Whole-body
        var weightLbs: Double = 0
        var bmi: Double = 0
        var bodyFatPercentage: Double = 0      // 0-100
        var bodyFatMassLbs: Double = 0
        var leanBodyMassLbs: Double = 0
        var skeletalMuscleMassLbs: Double = 0
        var dryLeanMassLbs: Double = 0
        var intracellularWaterLbs: Double = 0
        var extracellularWaterLbs: Double = 0
        var totalBodyWaterLbs: Double = 0
        var ecwTbwRatio: Double = 0
        var visceralFatLevel: Int = 0
        var basalMetabolicRateKcal: Double = 0

        // Segmental Lean
        var rightArmLeanLbs: Double = 0
        var rightArmLeanPct: Double = 0
        var leftArmLeanLbs: Double = 0
        var leftArmLeanPct: Double = 0
        var trunkLeanLbs: Double = 0
        var trunkLeanPct: Double = 0
        var rightLegLeanLbs: Double = 0
        var rightLegLeanPct: Double = 0
        var leftLegLeanLbs: Double = 0
        var leftLegLeanPct: Double = 0
    }

    /// One Vision text observation with its normalized bbox. Origin is
    /// bottom-left, both axes in [0,1]. For multi-page docs we offset Y
    /// by the page index so boxes from different pages never collide
    /// when filtered by Y range.
    private struct TextBox {
        let text: String
        let bbox: CGRect
        var midY: CGFloat { bbox.midY }
        var minX: CGFloat { bbox.minX }
        var maxX: CGFloat { bbox.maxX }
    }

    /// Top-level entry point — read the file at `url` and return the parsed `Scan`.
    /// Pass `onProgress` to receive `(fraction 0...1, status)` updates so the
    /// import sheet can drive a progress bar; OCR on phone-photo PDFs takes
    /// several seconds and would otherwise look hung.
    static func parse(url: URL, onProgress: (@Sendable (Double, String) -> Void)? = nil) throws -> Scan {
        onProgress?(0.05, "Opening PDF")
        guard let doc = PDFDocument(url: url) else { throw ParseError.unreadable }
        var raw = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let str = page.string {
                raw += str + "\n"
            }
        }

        var scan = Scan(scanDate: Date(), pdfFilename: url.lastPathComponent)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            // Digital export — PDFKit text is in correct reading order.
            onProgress?(0.5, "Extracting metrics")
            parseFromString(raw, into: &scan)
        } else {
            // Image-only PDF. OCR every page with bbox-aware extraction.
            let boxes = ocrAllPagesWithBoxes(of: doc, onProgress: onProgress)
            if !boxes.isEmpty {
                onProgress?(0.95, "Extracting metrics")
                parseFromBoxes(boxes, into: &scan)
            }
        }

        onProgress?(1.0, "Done")
        return scan
    }

    /// Image variant — OCRs the UIImage directly. We previously wrapped the
    /// image in a single-page PDF and reused `ocrAllPagesWithBoxes`, but that
    /// round-trip blew up memory for full-resolution iPhone photos (a 4032×3024
    /// camera grab became a ~12k-px PDF page render) and Vision would fail
    /// silently. The direct path also lets us pass the image's true orientation
    /// to Vision so text in portrait-shot photos is read right-side up.
    static func parse(image: UIImage, filename: String = "photo.jpg",
                       onProgress: (@Sendable (Double, String) -> Void)? = nil) throws -> Scan {
        onProgress?(0.05, "Preparing image")
        var scan = Scan(scanDate: Date(), pdfFilename: filename)
        let boxes = ocrImageWithBoxes(image, onProgress: onProgress)
        AppLogger.shared.log("InBody image OCR returned \(boxes.count) text boxes", category: "inbody")
        guard !boxes.isEmpty else { throw ParseError.empty }
        onProgress?(0.95, "Extracting metrics")
        parseFromBoxes(boxes, into: &scan)
        onProgress?(1.0, "Done")
        return scan
    }

    /// Run Vision text recognition on a UIImage. Returns each observation as
    /// a `TextBox` keyed by its normalized bbox so the same `parseFromBoxes`
    /// path that handles photo-PDFs can extract metrics spatially.
    private static func ocrImageWithBoxes(
        _ image: UIImage,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) -> [TextBox] {
        onProgress?(0.10, "Recognizing text")
        guard let cg = image.cgImage else {
            AppLogger.shared.log("InBody image has no cgImage backing", category: "inbody")
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.progressHandler = { _, p, _ in
            let frac = 0.10 + min(max(p, 0), 1) * 0.80
            onProgress?(frac, "Recognizing text")
        }

        let orientation = visionOrientation(from: image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLogger.shared.log("Vision perform failed: \(error)", category: "inbody")
            return []
        }

        var boxes: [TextBox] = []
        for obs in (request.results ?? []) {
            guard let cand = obs.topCandidates(1).first else { continue }
            boxes.append(TextBox(text: cand.string, bbox: obs.boundingBox))
        }
        return boxes
    }

    /// UIKit's image orientation enum doesn't line up 1:1 with Vision's. Map
    /// it explicitly so portrait phone photos OCR right-side up.
    private static func visionOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }

    // MARK: - String-based extraction (digital exports)

    /// Reads metrics from PDFKit's semantically-ordered text. Same code
    /// path the parser used end-to-end before bbox extraction landed.
    private static func parseFromString(_ raw: String, into scan: inout Scan) {
        let normalized = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let denoised = normalized.replacingOccurrences(
            of: #"(\d)\.\s+(\d)"#,
            with: "$1.$2",
            options: .regularExpression
        )
        let flat = denoised.replacingOccurrences(of: "\n", with: " ")

        scan.scanDate = parseDate(in: flat) ?? scan.scanDate
        scan.heightInches = parseHeight(in: flat) ?? 0
        scan.ageYears     = parseAge(in: flat) ?? 0

        scan.weightLbs                = firstDecimal(after: "Weight",                 in: flat) ?? 0
        scan.bmi                      = firstDecimal(after: "BMI",                    in: flat) ?? 0
        scan.bodyFatPercentage        = firstDecimal(after: "PBF",                    in: flat) ?? 0
        scan.bodyFatMassLbs           = firstDecimal(after: "Body Fat Mass",          in: flat) ?? 0
        scan.leanBodyMassLbs          = firstDecimal(after: "Lean Body Mass",         in: flat) ?? 0
        scan.skeletalMuscleMassLbs    = firstDecimal(after: "SMM",                    in: flat) ?? 0
        scan.dryLeanMassLbs           = firstDecimal(after: "Dry Lean Mass",          in: flat) ?? 0
        scan.intracellularWaterLbs    = firstDecimal(after: "Intracellular Water",    in: flat) ?? 0
        scan.extracellularWaterLbs    = firstDecimal(after: "Extracellular Water",    in: flat) ?? 0
        scan.totalBodyWaterLbs        = firstDecimal(after: "Total Body Water",       in: flat) ?? 0
        scan.ecwTbwRatio              = firstDecimal(after: "ECW/TBW",                in: flat) ?? 0
        scan.basalMetabolicRateKcal   = firstDecimal(after: "Basal Metabolic Rate",   in: flat)
                                     ?? firstDecimal(after: "BMR",                    in: flat) ?? 0
        scan.visceralFatLevel         = parseVisceralFat(in: flat) ?? 0

        if let leanSection = slice(after: "Segmental Lean Analysis", before: "ECW/TBW Analysis", in: denoised) {
            let pairs = parseSegmentalPairs(in: leanSection)
            (scan.rightArmLeanLbs, scan.rightArmLeanPct) = pairs[0]
            (scan.leftArmLeanLbs,  scan.leftArmLeanPct)  = pairs[1]
            (scan.trunkLeanLbs,    scan.trunkLeanPct)    = pairs[2]
            (scan.rightLegLeanLbs, scan.rightLegLeanPct) = pairs[3]
            (scan.leftLegLeanLbs,  scan.leftLegLeanPct)  = pairs[4]
        }
    }

    // MARK: - OCR + bbox extraction (image-only PDFs)

    /// Render each page at 3x and collect every Vision text observation
    /// with its bounding box. Pages are stacked along Y by index so we
    /// can freely filter on Y across the full document without collisions.
    private static func ocrAllPagesWithBoxes(
        of doc: PDFDocument,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) -> [TextBox] {
        var all: [TextBox] = []
        let total = max(doc.pageCount, 1)
        for i in 0..<doc.pageCount {
            // OCR is the bulk of the work — reserve 10% → 90% of the bar
            // for it so the import sheet shows continuous motion.
            let frac = 0.10 + (Double(i) / Double(total)) * 0.80
            onProgress?(frac, "OCR page \(i + 1) of \(total)")
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 3.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }

            guard let cg = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            // Vision fires `progressHandler` periodically during a long
            // recognition. Map the [0,1] within-page progress into our
            // page-aware band so the bar moves continuously instead of
            // sticking at the start-of-page tick.
            let pageIndex = i
            request.progressHandler = { _, p, _ in
                let clamped = min(max(p, 0), 1)
                let pageFrac = 0.10 + ((Double(pageIndex) + clamped) / Double(total)) * 0.80
                onProgress?(pageFrac, "OCR page \(pageIndex + 1) of \(total)")
            }

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])

            let pageOffset = CGFloat(i)
            for obs in (request.results ?? []) {
                guard let cand = obs.topCandidates(1).first else { continue }
                let bb = CGRect(
                    x: obs.boundingBox.minX,
                    y: obs.boundingBox.minY + pageOffset,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height
                )
                all.append(TextBox(text: cand.string, bbox: bb))
            }
        }
        return all
    }

    /// Extract metrics from spatially-positioned OCR boxes. For each
    /// label we find the matching observation, then walk right (same
    /// row) until we hit a non-tick decimal — falling back to the row
    /// immediately below for label/value pairs that wrap.
    private static func parseFromBoxes(_ boxes: [TextBox], into scan: inout Scan) {
        // Glued whole-document text for metadata (date/height/age) that
        // doesn't depend on label proximity.
        let combined = boxes
            .sorted { $0.midY > $1.midY }
            .map { $0.text }
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"(\d)\.\s+(\d)"#,
                with: "$1.$2",
                options: .regularExpression
            )
        scan.scanDate = parseDate(in: combined) ?? scan.scanDate
        scan.heightInches = parseHeight(in: combined) ?? 0
        scan.ageYears     = parseAge(in: combined) ?? 0

        scan.weightLbs              = valueNear("Weight",              in: boxes) ?? 0
        scan.bmi                    = valueNear("BMI",                 in: boxes) ?? 0
        scan.bodyFatPercentage      = valueNear("PBF",                 in: boxes) ?? 0
        scan.bodyFatMassLbs         = valueNear("Body Fat Mass",       in: boxes) ?? 0
        scan.leanBodyMassLbs        = valueNear("Lean Body Mass",      in: boxes) ?? 0
        scan.skeletalMuscleMassLbs  = valueNear("SMM",                 in: boxes) ?? 0
        scan.dryLeanMassLbs         = valueNear("Dry Lean Mass",       in: boxes) ?? 0
        scan.intracellularWaterLbs  = valueNear("Intracellular Water", in: boxes) ?? 0
        scan.extracellularWaterLbs  = valueNear("Extracellular Water", in: boxes) ?? 0
        scan.totalBodyWaterLbs      = valueNear("Total Body Water",    in: boxes) ?? 0
        scan.ecwTbwRatio            = valueNear("ECW/TBW",             in: boxes) ?? 0
        scan.basalMetabolicRateKcal = valueNear("Basal Metabolic Rate", in: boxes)
                                   ?? valueNear("BMR",                  in: boxes) ?? 0
        scan.visceralFatLevel       = visceralFatNear(in: boxes) ?? 0

        let leanPairs = segmentalPairsNear(headerKeyword: "Segmental Lean", in: boxes)
        (scan.rightArmLeanLbs, scan.rightArmLeanPct) = leanPairs[0]
        (scan.leftArmLeanLbs,  scan.leftArmLeanPct)  = leanPairs[1]
        (scan.trunkLeanLbs,    scan.trunkLeanPct)    = leanPairs[2]
        (scan.rightLegLeanLbs, scan.rightLegLeanPct) = leanPairs[3]
        (scan.leftLegLeanLbs,  scan.leftLegLeanPct)  = leanPairs[4]
    }

    /// Find the box containing `keyword`, then return the first non-tick
    /// decimal that lives either (a) in the same box after the keyword,
    /// (b) on the same row to the right, or (c) on the row directly
    /// below near the same X. Tolerances are tuned for InBody's tight
    /// row spacing (~1-1.5% of page height).
    private static func valueNear(_ keyword: String, in boxes: [TextBox]) -> Double? {
        guard let label = boxes.first(where: { $0.text.range(of: keyword, options: .caseInsensitive) != nil }) else {
            return nil
        }
        // (a) same box, after the keyword
        if let r = label.text.range(of: keyword, options: .caseInsensitive) {
            let tail = String(label.text[r.upperBound...])
            for d in decimals(in: tail) where !isChartTick(d) { return d }
        }
        let yTol: CGFloat = 0.012
        // (b) same row, to the right of label
        let sameRow = boxes
            .filter { abs($0.midY - label.midY) < yTol && $0.minX > label.maxX - 0.005 && $0.text != label.text }
            .sorted { $0.minX < $1.minX }
        for b in sameRow {
            for d in decimals(in: b.text) where !isChartTick(d) { return d }
        }
        // (c) directly below, near the same X (handles 2-line label/value layouts)
        let belowBand = (label.midY - yTol * 4)..<(label.midY - yTol)
        let below = boxes
            .filter { belowBand.contains($0.midY) && abs($0.minX - label.minX) < 0.08 }
            .sorted { abs($0.minX - label.minX) < abs($1.minX - label.minX) }
        for b in below {
            for d in decimals(in: b.text) where !isChartTick(d) { return d }
        }
        return nil
    }

    /// Visceral fat is reported as "Level 7" (an int after the literal
    /// word "Level"). We prefer matches inside a box on the same row as
    /// the "Visceral Fat" label.
    private static func visceralFatNear(in boxes: [TextBox]) -> Int? {
        guard let label = boxes.first(where: { $0.text.range(of: "Visceral Fat", options: .caseInsensitive) != nil }) else {
            return nil
        }
        let yTol: CGFloat = 0.02
        let row = boxes.filter { abs($0.midY - label.midY) < yTol }
        for b in row {
            if let m = b.text.range(of: #"Level\s+(\d+)"#, options: .regularExpression) {
                let chunk = String(b.text[m])
                if let n = chunk.matches(of: #/\d+/#).first { return Int(n.0) }
            }
        }
        // Fallback: any "Level <n>" anywhere below the label, biased to nearest.
        let below = boxes
            .filter { $0.midY < label.midY }
            .sorted { abs($0.midY - label.midY) < abs($1.midY - label.midY) }
        for b in below.prefix(8) {
            if let m = b.text.range(of: #"Level\s+(\d+)"#, options: .regularExpression) {
                let chunk = String(b.text[m])
                if let n = chunk.matches(of: #/\d+/#).first { return Int(n.0) }
            }
        }
        return nil
    }

    /// Five (lbs, %) pairs in canonical order: Right Arm, Left Arm,
    /// Trunk, Right Leg, Left Leg. We anchor to the section header,
    /// find each region label inside the section, and read the two
    /// non-tick decimals on that row.
    private static func segmentalPairsNear(headerKeyword: String, in boxes: [TextBox]) -> [(Double, Double)] {
        var pairs: [(Double, Double)] = Array(repeating: (0, 0), count: 5)
        guard let header = boxes.first(where: { $0.text.range(of: headerKeyword, options: .caseInsensitive) != nil }) else {
            return pairs
        }
        // Section content is below the header (lower Y in bottom-left
        // coords), bounded above by the next section header on the same
        // page. We accept anything in the band [header - 0.4, header).
        let band = (header.midY - 0.4)..<header.midY
        let section = boxes.filter { band.contains($0.midY) }

        let regions = ["Right Arm", "Left Arm", "Trunk", "Right Leg", "Left Leg"]
        for (i, region) in regions.enumerated() {
            guard let rb = section.first(where: { $0.text.range(of: region, options: .caseInsensitive) != nil }) else {
                continue
            }
            let yTol: CGFloat = 0.015
            let row = section.filter { abs($0.midY - rb.midY) < yTol && $0.minX >= rb.minX - 0.005 }
            let nums = row
                .sorted { $0.minX < $1.minX }
                .flatMap { decimals(in: $0.text) }
                .filter { !isChartTick($0) }
            if nums.count >= 1 { pairs[i].0 = nums[0] }
            if nums.count >= 2 { pairs[i].1 = nums[1] }
        }
        return pairs
    }

    /// All decimal numbers in `text`, in order. Used by every spatial
    /// search to harvest candidates from a box's recognized string.
    private static func decimals(in text: String) -> [Double] {
        text.matches(of: #/-?\d+(\.\d+)?/#).compactMap { Double($0.0) }
    }

    // MARK: - Field extractors (string path)

    /// Grab the first "real" decimal number that appears after a keyword.
    /// Skips InBody chart axis tick marks (55, 70, 85, 100, 115, ...) so
    /// keyword extraction lands on the actual metric value rather than the
    /// bar chart's scale labels.
    private static func firstDecimal(after keyword: String, in text: String) -> Double? {
        guard let r = text.range(of: keyword, options: [.caseInsensitive]) else { return nil }
        let tail = String(text[r.upperBound...])
        let matches = tail.matches(of: #/-?\d+(\.\d+)?/#)
        for match in matches {
            guard let v = Double(match.0) else { continue }
            if !isChartTick(v) { return v }
        }
        return nil
    }

    /// Whole-number ticks the InBody bar charts use. A value matching one
    /// of these is almost always a chart axis label, not a metric.
    private static func isChartTick(_ v: Double) -> Bool {
        let ticks: Set<Double> = [
            // Lean / weight bars (lbs)
            40, 55, 60, 70, 80, 85, 90, 100, 110, 115, 120, 130, 140, 145,
            150, 160, 170, 175, 190, 205,
            // Body fat mass bar (lbs)
            220, 280, 340, 400, 460, 520,
            // BMI bar
            10.0, 15.0, 18.5, 22.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 55.0,
            // PBF bar
            0.0, 5.0,
            // ECW/TBW bar
            0.320, 0.340, 0.360, 0.380, 0.390, 0.400, 0.410, 0.420, 0.430, 0.440, 0.450
        ]
        return ticks.contains(v)
    }

    /// "Test Date / Time  02.25.2026 11:07" → Date.
    private static func parseDate(in text: String) -> Date? {
        let pattern = #"(\d{2})\.\s*(\d{2})\.\s*(\d{4})\s*(\d{2}):(\d{2})"#
        guard let m = text.range(of: pattern, options: .regularExpression) else { return nil }
        let s = String(text[m])
        let f = DateFormatter()
        let cleaned = s.replacingOccurrences(of: " ", with: "")
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

    /// "5ft. 10.0in." → 70.0 inches. Tolerates "ft", "ft.", "Ft", missing
    /// space before "in", etc.
    private static func parseHeight(in text: String) -> Double? {
        let pattern = #"(\d+)\s*ft\.?\s*(\d+(\.\d+)?)\s*in"#
        guard let m = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let s = text[m]
        let nums = s.matches(of: #/\d+(\.\d+)?/#).compactMap { Double($0.0) }
        guard nums.count >= 2 else { return nil }
        return nums[0] * 12 + nums[1]
    }

    /// "Age 35" — first integer after the "Age" label.
    private static func parseAge(in text: String) -> Int? {
        guard let r = text.range(of: "Age", options: [.caseInsensitive]) else { return nil }
        let tail = String(text[r.upperBound...])
        guard let m = tail.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(tail[m])
    }

    /// "Visceral Fat Level ... Level 7" — int after the literal word "Level".
    private static func parseVisceralFat(in text: String) -> Int? {
        guard let header = text.range(of: "Visceral Fat", options: [.caseInsensitive]) else { return nil }
        let tail = String(text[header.upperBound...])
        if let m = tail.range(of: #"Level\s+(\d+)"#, options: .regularExpression) {
            let chunk = String(tail[m])
            if let n = chunk.matches(of: #/\d+/#).first { return Int(n.0) }
        }
        return nil
    }

    // MARK: - Segmental helpers (string path)

    /// Carve out the slice of text between two section headings. Returns
    /// nil if either anchor isn't found, so callers can fall through
    /// gracefully.
    private static func slice(after start: String, before end: String, in text: String) -> String? {
        guard let s = text.range(of: start, options: [.caseInsensitive]) else { return nil }
        let after = String(text[s.upperBound...])
        if let e = after.range(of: end, options: [.caseInsensitive]) {
            return String(after[..<e.lowerBound])
        }
        return after
    }

    /// Pull all decimal numbers out of a segmental section in document
    /// order and pair them as (lbs, percent) for each of the five
    /// regions. Returns exactly 5 pairs; missing numbers come back as
    /// 0/0 so callers can destructure with confidence.
    private static func parseSegmentalPairs(in text: String) -> [(Double, Double)] {
        let nums = text.matches(of: #/-?\d+(\.\d+)?/#).compactMap { Double($0.0) }
        let ticks: Set<Double> = [55, 70, 85, 100, 115, 130, 145, 160, 175, 190, 205,
                                   80, 90, 110, 120, 140, 150, 170,
                                   40, 60, 220, 280, 340, 400, 460, 520]
        let real = nums.filter { !ticks.contains($0) }
        var pairs: [(Double, Double)] = Array(repeating: (0, 0), count: 5)
        for i in 0..<5 {
            let lbsIdx = i * 2
            let pctIdx = i * 2 + 1
            if lbsIdx < real.count { pairs[i].0 = real[lbsIdx] }
            if pctIdx < real.count { pairs[i].1 = real[pctIdx] }
        }
        return pairs
    }
}
