import SwiftUI
import CoreData
import QuickLook

/// Breakdown of a single InBody scan. Defaults to read-only; toggling Edit
/// flips the rows into TextFields backed directly by the Core Data entry. A
/// "Source" toolbar button opens the original PDF/photo via QuickLook so the
/// user can sanity-check a parsed number against the raw scan side-by-side.
struct InBodyDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var entry: InBodyEntry

    @State private var isEditing = false
    @State private var sourcePreviewURL: URL?
    @State private var saveError: String?
    @FocusState private var anyFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                if let mime = entry.rawSourceMimeType, entry.rawSourceData != nil {
                    rawSourceCard(mime: mime)
                }

                group(title: "Whole-body", rows: wholeBodyRows)
                group(title: "Segmental Lean", rows: segmentalLeanRows)
                group(title: "Profile", rows: profileRows)

                if let saveError {
                    Text(saveError)
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.orange)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(headerDate)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing { commit() }
                    isEditing.toggle()
                }
                .foregroundStyle(Theme.Colors.accent)
            }
            // Numeric keyboards have no Return — surface a Done so the user
            // can dismiss without rotating to a different row.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { anyFieldFocused = false }
            }
        }
        .quickLookPreview($sourcePreviewURL)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                stat(value: format(entry.weightLbs), unit: "lbs")
                stat(value: format(entry.bodyFatPercentage), unit: "% BF")
                stat(value: format(entry.skeletalMuscleMassLbs), unit: "lbs SMM")
            }
            if let f = entry.pdfFilename {
                Text(f)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func stat(value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(Theme.Fonts.header(20))
                .foregroundStyle(Theme.Colors.accent)
            Text(unit)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // MARK: - Raw source

    /// CTA card surfacing the original PDF/photo. Tapping writes the bytes to
    /// a temp file and pushes QuickLook so the user can hold the parsed values
    /// next to what they were taken from.
    private func rawSourceCard(mime: String) -> some View {
        Button {
            openSource()
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: mime.hasPrefix("image/") ? "photo.fill" : "doc.richtext.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("View original scan")
                        .font(Theme.Fonts.header(14))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(mime.hasPrefix("image/") ? "Photo · saved on import" : "PDF · saved on import")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openSource() {
        guard let data = entry.rawSourceData else { return }
        let ext = (entry.rawSourceMimeType ?? "").hasPrefix("image/") ? "jpg" : "pdf"
        let name = "InBody-\(entry.id?.uuidString ?? UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            sourcePreviewURL = url
            AppLogger.shared.log("InBody source opened — \(data.count) bytes \(ext)", category: "inbody")
        } catch {
            AppLogger.shared.log("InBody source write FAILED: \(error)", category: "inbody")
            saveError = "Couldn't open scan: \(error.localizedDescription)"
        }
    }

    // MARK: - Row groups

    private struct EditableRow: Identifiable {
        let id = UUID()
        let label: String
        let unit: String
        let binding: Binding<Double>
    }

    private var wholeBodyRows: [EditableRow] {
        [
            EditableRow(label: "Weight", unit: "lbs", binding: doubleBinding(\.weightLbs)),
            EditableRow(label: "BMI", unit: "", binding: doubleBinding(\.bmi)),
            EditableRow(label: "Body Fat %", unit: "%", binding: doubleBinding(\.bodyFatPercentage)),
            EditableRow(label: "Body Fat Mass", unit: "lbs", binding: doubleBinding(\.bodyFatMassLbs)),
            EditableRow(label: "Lean Body Mass", unit: "lbs", binding: doubleBinding(\.leanBodyMassLbs)),
            EditableRow(label: "Skeletal Muscle Mass", unit: "lbs", binding: doubleBinding(\.skeletalMuscleMassLbs)),
            EditableRow(label: "Dry Lean Mass", unit: "lbs", binding: doubleBinding(\.dryLeanMassLbs)),
            EditableRow(label: "Intracellular Water", unit: "lbs", binding: doubleBinding(\.intracellularWaterLbs)),
            EditableRow(label: "Extracellular Water", unit: "lbs", binding: doubleBinding(\.extracellularWaterLbs)),
            EditableRow(label: "Total Body Water", unit: "lbs", binding: doubleBinding(\.totalBodyWaterLbs)),
            EditableRow(label: "ECW/TBW", unit: "", binding: doubleBinding(\.ecwTbwRatio)),
            EditableRow(label: "Visceral Fat Level", unit: "", binding: int16Binding(\.visceralFatLevel)),
            EditableRow(label: "Basal Metabolic Rate", unit: "kcal", binding: doubleBinding(\.basalMetabolicRateKcal))
        ]
    }

    private var segmentalLeanRows: [EditableRow] {
        [
            EditableRow(label: "Right Arm", unit: "lbs", binding: doubleBinding(\.rightArmLeanLbs)),
            EditableRow(label: "Left Arm",  unit: "lbs", binding: doubleBinding(\.leftArmLeanLbs)),
            EditableRow(label: "Trunk",     unit: "lbs", binding: doubleBinding(\.trunkLeanLbs)),
            EditableRow(label: "Right Leg", unit: "lbs", binding: doubleBinding(\.rightLegLeanLbs)),
            EditableRow(label: "Left Leg",  unit: "lbs", binding: doubleBinding(\.leftLegLeanLbs))
        ]
    }

    private var profileRows: [EditableRow] {
        [
            EditableRow(label: "Height (in)", unit: "in", binding: doubleBinding(\.heightInches)),
            EditableRow(label: "Age", unit: "yr", binding: int16Binding(\.ageYears))
        ]
    }

    private func group(title: String, rows: [EditableRow]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.header(14))
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    rowView(row)
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

    @ViewBuilder
    private func rowView(_ row: EditableRow) -> some View {
        HStack {
            Text(row.label)
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
            if isEditing {
                TextField("0", value: row.binding, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(row.binding.wrappedValue == 0 ? Theme.Colors.textTertiary : Theme.Colors.accent)
                    .frame(maxWidth: 70)
                    .focused($anyFieldFocused)
                Button {
                    row.binding.wrappedValue = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(row.binding.wrappedValue == 0 ? Theme.Colors.textTertiary.opacity(0.4) : Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(row.binding.wrappedValue == 0)
                if !row.unit.isEmpty {
                    Text(row.unit)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            } else {
                Text(displayValue(row))
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(row.binding.wrappedValue == 0 ? Theme.Colors.textTertiary : Theme.Colors.accent)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func displayValue(_ row: EditableRow) -> String {
        let v = row.binding.wrappedValue
        if v == 0 { return "—" }
        let n = v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
        return row.unit.isEmpty ? n : "\(n) \(row.unit)"
    }

    // MARK: - Editing

    /// Bridge a Double Core Data attribute as a SwiftUI Binding<Double>.
    private func doubleBinding(_ keyPath: ReferenceWritableKeyPath<InBodyEntry, Double>) -> Binding<Double> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { entry[keyPath: keyPath] = $0 }
        )
    }

    /// Same idea for Int16 attributes — round on commit so the user can type
    /// fractional values into the keypad without weird truncation jumps.
    private func int16Binding(_ keyPath: ReferenceWritableKeyPath<InBodyEntry, Int16>) -> Binding<Double> {
        Binding(
            get: { Double(entry[keyPath: keyPath]) },
            set: { entry[keyPath: keyPath] = Int16(clamping: Int($0.rounded())) }
        )
    }

    private func commit() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            saveError = nil
            AppLogger.shared.log("InBodyDetail edits saved", category: "inbody")
        } catch {
            saveError = "Couldn't save edits: \(error.localizedDescription)"
            AppLogger.shared.log("InBodyDetail save FAILED: \(error)", category: "inbody")
        }
    }

    // MARK: - Formatters

    private var headerDate: String {
        guard let d = entry.date else { return "Scan" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }

    private func format(_ v: Double) -> String {
        if v == 0 { return "—" }
        return v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
    }
}
