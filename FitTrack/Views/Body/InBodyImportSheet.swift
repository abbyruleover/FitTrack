import SwiftUI
import CoreData
import UniformTypeIdentifiers
import PhotosUI
import UIKit

/// Modal for importing an InBody PDF.
///
/// Flow: tap "Choose PDF" → `.fileImporter` → `InBodyPDFParser.parse` →
/// preview every parsed metric (grouped Whole-body / Segmental Lean) →
/// toggle "Also write to Apple Health" → Save persists the `InBodyEntry`
/// and (if toggled) pushes the HealthKit-supported subset via
/// `HealthKitService.writeInBodyScan`.
/// Tracks parse progress so the sheet can update a determinate progress
/// bar from a background task. Lives at MainActor so the View can read its
/// fields directly without bridging.
@MainActor
final class InBodyParseProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var status: String = "Reading PDF"

    func reset() {
        fraction = 0
        status = "Reading PDF"
    }
}

struct InBodyImportSheet: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pickerOpen = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var scan: InBodyPDFParser.Scan?
    @State private var pickedURL: URL?
    /// Raw bytes of the imported PDF or photo, persisted alongside the parsed
    /// values so the user can re-open the source from the detail view if a
    /// number ever looks suspect. PDF → "application/pdf"; camera/photo →
    /// "image/jpeg" (we re-encode at 0.9 to keep DB rows manageable).
    @State private var rawSourceData: Data?
    @State private var rawSourceMimeType: String?
    @State private var writeToHealth = true
    @State private var errorText: String?
    @State private var isSaving = false
    @State private var isParsing = false
    @StateObject private var parseProgress = InBodyParseProgress()

    /// Decimal-pad keyboards have no Return key, so we drive field-to-field
    /// navigation manually via a keyboard toolbar with ← / → / Done. Field
    /// indices are global across both preview groups: Whole-body 0–12,
    /// Segmental Lean 13–17 (totalFieldCount = 18).
    @FocusState private var focusedFieldIndex: Int?
    private let totalFieldCount = 18

    /// Selected metric whose explanation is shown in a glossary alert.
    /// Driven by the small `info.circle` button next to each row label.
    @State private var glossaryEntry: InBodyMetricGlossary.Info?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if isParsing {
                        parsingCard
                    } else if let scanBinding = Binding($scan) {
                        scanPreview(scanBinding)
                    } else {
                        introCard
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.Fonts.body(13))
                            .foregroundStyle(Theme.Colors.orange)
                            .padding(.horizontal, Theme.Spacing.md)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Import InBody")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AppLogger.shared.log("InBody Save tapped (hasScan=\(scan != nil))", category: "inbody")
                        Task { await save() }
                    }
                        .foregroundStyle(scan == nil ? Theme.Colors.textTertiary : Theme.Colors.accent)
                        .disabled(scan == nil || isSaving || isParsing)
                }
                // Keyboard toolbar: ← / → step between numeric fields,
                // Done dismisses the keyboard. Only shown while a field has
                // focus (SwiftUI auto-hides .keyboard placement otherwise).
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        let cur = focusedFieldIndex ?? 0
                        focusedFieldIndex = max(0, cur - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled((focusedFieldIndex ?? 0) <= 0)

                    Button {
                        let cur = focusedFieldIndex ?? -1
                        focusedFieldIndex = min(totalFieldCount - 1, cur + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled((focusedFieldIndex ?? -1) >= totalFieldCount - 1)

                    Spacer()
                    Button("Done") { focusedFieldIndex = nil }
                }
            }
            .fileImporter(
                isPresented: $pickerOpen,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                handlePick(result)
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                AppLogger.shared.log("PhotosPicker item selected", category: "inbody")
                Task { await handlePhotoItem(newItem) }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image {
                        AppLogger.shared.log("camera capture returned image \(Int(image.size.width))x\(Int(image.size.height))", category: "inbody")
                        Task { await handleImage(image, source: "camera.jpg") }
                    } else {
                        AppLogger.shared.log("camera capture cancelled", category: "inbody")
                    }
                }
            }
            .alert(item: $glossaryEntry) { entry in
                Alert(title: Text(entry.title),
                      message: Text(entry.body),
                      dismissButton: .default(Text("Got it")))
            }
        }
    }

    // MARK: - Parsing progress

    private var parsingCard: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.accent)
            Text("Reading InBody PDF…")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
            SwiftUI.ProgressView(value: parseProgress.fraction, total: 1.0)
                .progressViewStyle(.linear)
                .tint(Theme.Colors.accent)
            HStack {
                Text(parseProgress.status)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text("\(Int(parseProgress.fraction * 100))%")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Text("Photo PDFs run on-device OCR — usually a few seconds per page.")
                .font(Theme.Fonts.body(12))
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("Import an InBody result")
                .font(Theme.Fonts.header(16))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("FitTrack reads every metric the InBody 970 reports — whole-body composition, segmental lean, BMR, and visceral fat level.")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                AppLogger.shared.log("intro → Choose PDF tapped", category: "inbody")
                pickerOpen = true
            } label: {
                Label("Choose PDF", systemImage: "folder")
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.accent)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: Theme.Spacing.sm) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    Label("Photo", systemImage: "photo.on.rectangle")
                        .font(Theme.Fonts.header(14))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.Colors.accent, lineWidth: 1)
                        )
                }
                Button {
                    AppLogger.shared.log("intro → Camera tapped", category: "inbody")
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .font(Theme.Fonts.header(14))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.Colors.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }

            Text("PDFs parse instantly. Photos run on-device OCR — usually a few seconds.")
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Preview

    @ViewBuilder
    private func scanPreview(_ scanBinding: Binding<InBodyPDFParser.Scan>) -> some View {
        let scan = scanBinding.wrappedValue
        // Visceral fat is stored as Int on the Scan; expose it as a Double
        // binding for the editor so it can share the same TextField path as
        // every other numeric row. Round on write to keep the integer
        // contract intact.
        let visceralBinding = Binding<Double>(
            get: { Double(scanBinding.wrappedValue.visceralFatLevel) },
            set: { scanBinding.wrappedValue.visceralFatLevel = Int($0.rounded()) }
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.pdfFilename)
                        .font(Theme.Fonts.body(13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                    DatePicker("", selection: scanBinding.scanDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                }
                Spacer()
                Button("Replace") { pickerOpen = true }
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }

        Text("Tap any value to edit, the × to clear, or use ← → to step through fields.")
            .font(Theme.Fonts.mono(11))
            .foregroundStyle(Theme.Colors.textTertiary)

        previewGroup(title: "Whole-body", startIndex: 0, rows: [
            ("Weight", scanBinding.weightLbs, "lbs"),
            ("BMI", scanBinding.bmi, ""),
            ("Body Fat %", scanBinding.bodyFatPercentage, "%"),
            ("Body Fat Mass", scanBinding.bodyFatMassLbs, "lbs"),
            ("Lean Body Mass", scanBinding.leanBodyMassLbs, "lbs"),
            ("Skeletal Muscle Mass", scanBinding.skeletalMuscleMassLbs, "lbs"),
            ("Dry Lean Mass", scanBinding.dryLeanMassLbs, "lbs"),
            ("Intracellular Water", scanBinding.intracellularWaterLbs, "lbs"),
            ("Extracellular Water", scanBinding.extracellularWaterLbs, "lbs"),
            ("Total Body Water", scanBinding.totalBodyWaterLbs, "lbs"),
            ("ECW/TBW", scanBinding.ecwTbwRatio, ""),
            ("Visceral Fat Level", visceralBinding, ""),
            ("Basal Metabolic Rate", scanBinding.basalMetabolicRateKcal, "kcal")
        ])

        previewGroup(title: "Segmental Lean", startIndex: 13, rows: [
            ("Right Arm", scanBinding.rightArmLeanLbs, "lbs"),
            ("Left Arm",  scanBinding.leftArmLeanLbs,  "lbs"),
            ("Trunk",     scanBinding.trunkLeanLbs,    "lbs"),
            ("Right Leg", scanBinding.rightLegLeanLbs, "lbs"),
            ("Left Leg",  scanBinding.leftLegLeanLbs,  "lbs")
        ])

        Toggle(isOn: $writeToHealth) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also write to Apple Health")
                    .font(Theme.Fonts.body(14))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Pushes weight, body fat %, lean mass, BMI, and BMR.")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .tint(Theme.Colors.accent)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
    }

    private func previewGroup(title: String, startIndex: Int, rows: [(String, Binding<Double>, String)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.header(14))
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack {
                        Text(row.0)
                            .font(Theme.Fonts.body(13))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Button {
                            glossaryEntry = InBodyMetricGlossary.info(for: row.0)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About \(row.0)")
                        Spacer()
                        TextField("0", value: row.1, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(Theme.Fonts.mono(12))
                            .foregroundStyle(row.1.wrappedValue == 0 ? Theme.Colors.textTertiary : Theme.Colors.accent)
                            .frame(maxWidth: 70)
                            .focused($focusedFieldIndex, equals: startIndex + idx)
                        Button {
                            row.1.wrappedValue = 0
                            focusedFieldIndex = startIndex + idx
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(row.1.wrappedValue == 0 ? Theme.Colors.textTertiary.opacity(0.4) : Theme.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(row.1.wrappedValue == 0)
                        .accessibilityLabel("Clear \(row.0)")
                        if !row.2.isEmpty {
                            Text(row.2)
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                    if idx < rows.count - 1 {
                        Divider().background(Theme.Colors.border)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func handlePick(_ result: Result<[URL], Error>) {
        errorText = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            AppLogger.shared.log("PDF picked: \(url.lastPathComponent)", category: "inbody")
            isParsing = true
            scan = nil
            parseProgress.reset()
            let progress = parseProgress

            Task {
                do {
                    let parsed = try await Task.detached(priority: .userInitiated) {
                        // Security-scoped resource needed for files chosen via Files.app.
                        // Acquire/release inside the detached task so the URL stays
                        // accessible for the entire parse.
                        let needsScope = url.startAccessingSecurityScopedResource()
                        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                        return try await InBodyPDFParser.smartParse(url: url) { frac, msg in
                            Task { @MainActor in
                                progress.fraction = frac
                                progress.status = msg
                            }
                        }
                    }.value
                    self.pickedURL = url
                    self.scan = parsed
                    // Snapshot the PDF bytes so the user can pull the source
                    // back up from the detail view. Read inside a fresh
                    // security scope so it works even after the parse task ended.
                    if let data = readURLData(url) {
                        self.rawSourceData = data
                        self.rawSourceMimeType = "application/pdf"
                        AppLogger.shared.log("captured raw PDF \(data.count) bytes", category: "inbody")
                    } else {
                        AppLogger.shared.log("WARN: could not snapshot raw PDF bytes", category: "inbody")
                    }
                    AppLogger.shared.log("PDF parse OK: weight=\(parsed.weightLbs) bodyFat%=\(parsed.bodyFatPercentage)", category: "inbody")
                } catch {
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    AppLogger.shared.log("PDF parse FAILED: \(error)", category: "inbody")
                }
                self.isParsing = false
            }
        case .failure(let error):
            errorText = error.localizedDescription
            AppLogger.shared.log("fileImporter failure: \(error)", category: "inbody")
        }
    }

    /// Drain a `PhotosPickerItem` into a `UIImage` then route through the
    /// shared image-parse path. Errors land in `errorText` for the user.
    private func handlePhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                AppLogger.shared.log("PhotosPicker → no image data", category: "inbody")
                errorText = "Couldn't read image."
                return
            }
            AppLogger.shared.log("PhotosPicker → got image \(Int(image.size.width))x\(Int(image.size.height))", category: "inbody")
            await handleImage(image, source: "library.jpg")
        } catch {
            AppLogger.shared.log("PhotosPicker load FAILED: \(error)", category: "inbody")
            errorText = error.localizedDescription
        }
    }

    /// Run the InBody image-OCR path on a UIImage and populate `scan` on
    /// success. Mirrors `handlePick`'s state lifecycle.
    private func handleImage(_ image: UIImage, source: String) async {
        errorText = nil
        scan = nil
        parseProgress.reset()
        isParsing = true
        let progress = parseProgress
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                try await InBodyPDFParser.smartParse(image: image, filename: source) { frac, msg in
                    Task { @MainActor in
                        progress.fraction = frac
                        progress.status = msg
                    }
                }
            }.value
            self.scan = parsed
            // Re-encode the photo as JPEG @0.9 — keeps the file small enough
            // for external-binary-storage Core Data without losing legibility
            // for the user re-checking the original number against the parse.
            if let data = image.jpegData(compressionQuality: 0.9) {
                self.rawSourceData = data
                self.rawSourceMimeType = "image/jpeg"
                AppLogger.shared.log("captured raw JPEG \(data.count) bytes", category: "inbody")
            } else {
                AppLogger.shared.log("WARN: could not encode JPEG for raw source", category: "inbody")
            }
            AppLogger.shared.log("image parse OK: weight=\(parsed.weightLbs) bodyFat%=\(parsed.bodyFatPercentage)", category: "inbody")
        } catch {
            self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLogger.shared.log("image parse FAILED: \(error)", category: "inbody")
        }
        self.isParsing = false
    }

    @MainActor
    private func save() async {
        guard let scan else { return }
        AppLogger.shared.log("InBody save() begin — weight=\(scan.weightLbs) writeToHealth=\(writeToHealth)", category: "inbody")
        isSaving = true
        defer { isSaving = false }

        AppLogger.shared.log("InBody raw ints: ageYears=\(scan.ageYears) visceralFat=\(scan.visceralFatLevel)", category: "inbody")
        let entry = InBodyEntry(context: context)
        entry.id = UUID()
        entry.date = scan.scanDate
        entry.pdfFilename = scan.pdfFilename
        entry.rawSourceData = rawSourceData
        entry.rawSourceMimeType = rawSourceMimeType
        entry.heightInches = scan.heightInches
        entry.ageYears = Int16(clamping: scan.ageYears)

        entry.weightLbs = scan.weightLbs
        entry.bmi = scan.bmi
        entry.bodyFatPercentage = scan.bodyFatPercentage
        entry.bodyFatMassLbs = scan.bodyFatMassLbs
        entry.leanBodyMassLbs = scan.leanBodyMassLbs
        entry.skeletalMuscleMassLbs = scan.skeletalMuscleMassLbs
        entry.dryLeanMassLbs = scan.dryLeanMassLbs
        entry.intracellularWaterLbs = scan.intracellularWaterLbs
        entry.extracellularWaterLbs = scan.extracellularWaterLbs
        entry.totalBodyWaterLbs = scan.totalBodyWaterLbs
        entry.ecwTbwRatio = scan.ecwTbwRatio
        entry.visceralFatLevel = Int16(clamping: scan.visceralFatLevel)
        entry.basalMetabolicRateKcal = scan.basalMetabolicRateKcal

        entry.rightArmLeanLbs = scan.rightArmLeanLbs
        entry.rightArmLeanPct = scan.rightArmLeanPct
        entry.leftArmLeanLbs = scan.leftArmLeanLbs
        entry.leftArmLeanPct = scan.leftArmLeanPct
        entry.trunkLeanLbs = scan.trunkLeanLbs
        entry.trunkLeanPct = scan.trunkLeanPct
        entry.rightLegLeanLbs = scan.rightLegLeanLbs
        entry.rightLegLeanPct = scan.rightLegLeanPct
        entry.leftLegLeanLbs = scan.leftLegLeanLbs
        entry.leftLegLeanPct = scan.leftLegLeanPct

        do {
            try context.save()
            AppLogger.shared.log("InBody Core Data save OK", category: "inbody")
        } catch {
            AppLogger.shared.log("InBody Core Data save FAILED: \(error)", category: "inbody")
            errorText = "Could not save: \(error.localizedDescription)"
            return
        }

        if writeToHealth {
            do {
                try await HealthKitService.shared.writeInBodyScan(scan)
                AppLogger.shared.log("HealthKit write OK", category: "inbody")
            } catch {
                AppLogger.shared.log("HealthKit write FAILED: \(error)", category: "inbody")
                // Save the entry but warn — the user can re-toggle later if
                // HK auth changes. Don't block dismissal on a HK write failure.
                errorText = "Saved locally. Apple Health write failed: \(error.localizedDescription)"
                return
            }
        }
        AppLogger.shared.log("InBody save complete — dismissing", category: "inbody")
        dismiss()
    }

    // MARK: - Formatters

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }

    private func percent(_ v: Double) -> String {
        v == 0 ? "—" : String(format: "%.1f%%", v)
    }

    private func longDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f.string(from: d)
    }

    /// Slurp a security-scoped file URL into Data. Used to snapshot the
    /// imported PDF for `rawSourceData` so we don't depend on the user
    /// keeping the original around in Files.app.
    private func readURLData(_ url: URL) -> Data? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}

#Preview {
    InBodyImportSheet()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}

// MARK: - CameraPicker

/// Thin UIKit bridge for `UIImagePickerController` in `.camera` mode.
/// `PhotosPicker` covers the library, but only UIImagePickerController can
/// open the live camera on-device. `onPick(nil)` indicates the user cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onPick(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
