import SwiftUI
import CoreData

/// All historical InBody scans, sorted newest first. Tap a row to drill into
/// the full breakdown via `InBodyDetailView`.
struct InBodyHistoryView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        entity: InBodyEntry.entity(),
        sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
    ) private var entries: FetchedResults<InBodyEntry>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if entries.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: Theme.Spacing.sm) {
                        ForEach(entries, id: \.objectID) { entry in
                            NavigationLink {
                                InBodyDetailView(entry: entry)
                            } label: {
                                ScanRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("All Scans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No InBody scans yet")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
    }
}

private struct ScanRow: View {
    let entry: InBodyEntry

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateLabel)
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(secondaryLabel)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(weightLabel)
                    .font(Theme.Fonts.header(20))
                    .foregroundStyle(Theme.Colors.accent)
                Text("lbs")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var dateLabel: String {
        guard let d = entry.date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }

    private var secondaryLabel: String {
        let bf = entry.bodyFatPercentage
        let smm = entry.skeletalMuscleMassLbs
        return String(format: "%.1f%% BF · %.1f lbs SMM", bf, smm)
    }

    private var weightLabel: String {
        let w = entry.weightLbs
        if w == 0 { return "—" }
        return w.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", w)
            : String(format: "%.1f", w)
    }
}

#Preview {
    NavigationStack {
        InBodyHistoryView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
