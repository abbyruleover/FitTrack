import SwiftUI
import CoreData

/// Full vertical PR list, reached from the Progress tab's "Exercises >" header.
/// Renders one row per exercise with its all-time best weight + rep count, and
/// a search bar to narrow the list. Tapping a row pushes the same per-exercise
/// detail screen the carousel cards push to.
struct AllExercisesListView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        entity: LoggedSet.entity(),
        sortDescriptors: [NSSortDescriptor(key: "completedAt", ascending: false)]
    ) private var sets: FetchedResults<LoggedSet>

    @State private var searchQuery: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if filteredRecords.isEmpty {
                    emptyState
                } else {
                    if !filteredMainLifts.isEmpty {
                        mainLiftsSection
                    }
                    if !filteredOtherLifts.isEmpty {
                        otherLiftsSection
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("All Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
        .onAppear {
            AppLogger.shared.log("AllExercisesListView appeared (\(allRecords.count) exercises, \(filteredMainLifts.count) main lifts)", category: "ui")
        }
    }

    // MARK: - Sections

    /// Pinned box of station-1 / barbell main lifts. The user wants these
    /// surfaced separately so PR-tracking is glanceable — they're the only
    /// lifts where weight progression really matters week-to-week.
    private var mainLiftsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text("MAIN LIFTS")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.leading, 4)
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(filteredMainLifts) { record in
                    NavigationLink(value: record.exerciseName) {
                        ExercisePRRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var otherLiftsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if !filteredMainLifts.isEmpty {
                Text("EVERYTHING ELSE")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, Theme.Spacing.sm)
            }
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(filteredOtherLifts) { record in
                    NavigationLink(value: record.exerciseName) {
                        ExercisePRRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var allRecords: [ProgressAggregator.PersonalRecord] {
        ProgressAggregator.personalRecords(from: Array(sets))
    }

    private var filteredRecords: [ProgressAggregator.PersonalRecord] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allRecords }
        return allRecords.filter {
            $0.exerciseName.range(of: q, options: .caseInsensitive) != nil
        }
    }

    private var filteredMainLifts: [ProgressAggregator.PersonalRecord] {
        filteredRecords.filter { Self.isMainLift($0.exerciseName) }
    }

    private var filteredOtherLifts: [ProgressAggregator.PersonalRecord] {
        filteredRecords.filter { !Self.isMainLift($0.exerciseName) }
    }

    /// Match the lifts the user actually trains heavy at station 1: squat,
    /// deadlift, bench press, landmine, sled push. Substring + case-insensitive
    /// so variants like "Back Squat", "Trap Bar Deadlift", "Landmine Press"
    /// all qualify.
    private static func isMainLift(_ name: String) -> Bool {
        let n = name.lowercased()
        return mainLiftKeywords.contains { n.contains($0) }
    }

    private static let mainLiftKeywords: [String] = [
        "squat", "deadlift", "bench", "landmine", "sled"
    ]

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(searchQuery.isEmpty ? "No exercises yet" : "No matches")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(Theme.Spacing.lg)
    }
}

// MARK: - Row

/// Reusable PR row used in the All Exercises list. Mirrors the carousel card's
/// info but laid out horizontally to fit a vertical list.
struct ExercisePRRow: View {
    let record: ProgressAggregator.PersonalRecord

    var body: some View {
        let glyph = ExerciseIcon.glyph(for: record.exerciseName)
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(glyph.tint.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: glyph.systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(glyph.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.exerciseName)
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                Text("× \(record.bestReps) reps · last \(lastLabel)")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(weightLabel)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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

    private var weightLabel: String {
        let w = record.bestWeightLbs
        if w == 0 { return "BW" }
        if w.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", w)
        }
        return String(format: "%.1f", w)
    }

    private var lastLabel: String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: record.lastPerformed)
    }
}

#Preview {
    NavigationStack {
        AllExercisesListView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
    .preferredColorScheme(.dark)
}
