import SwiftUI

/// Read-only "what changed" log, pushed from Settings → About → Changelog.
/// Renders one card per release with date, version pill, and bullet list.
/// Newest release sits at top with a "CURRENT" tag so the user can confirm
/// the build they're running matches what the changelog says shipped.
struct ChangelogView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Array(Changelog.entries.enumerated()), id: \.element.id) { idx, entry in
                    entryCard(entry, isCurrent: idx == 0)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Changelog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            AppLogger.shared.log("ChangelogView appeared — \(Changelog.entries.count) entries", category: "ui")
        }
    }

    private func entryCard(_ entry: Changelog.Entry, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("v\(entry.version)")
                    .font(Theme.Fonts.header(20))
                    .foregroundStyle(Theme.Colors.accent)
                if isCurrent {
                    Text("CURRENT")
                        .font(Theme.Fonts.mono(9))
                        .foregroundStyle(Theme.Colors.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Colors.accent))
                }
                Spacer()
                Text(dateLabel(entry.date))
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            ForEach(Array(entry.highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text("•")
                        .font(Theme.Fonts.mono(13))
                        .foregroundStyle(Theme.Colors.accent)
                    Text(line)
                        .font(Theme.Fonts.body(13))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                .stroke(isCurrent ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.border, lineWidth: 1)
        )
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }
}

#Preview {
    NavigationStack {
        ChangelogView()
    }
    .preferredColorScheme(.dark)
}
