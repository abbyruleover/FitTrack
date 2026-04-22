import SwiftUI
import CoreData

/// Per-exercise set list, grouped and sorted in the order the user logged
/// them. Shared by `SessionSummaryView` (post-finish) and
/// `UnifiedSessionView` (Progress drill-in) so both surfaces render
/// identically and never drift.
struct SessionExerciseBreakdown: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Exercises")
                .font(Theme.Fonts.header(14))
                .foregroundStyle(Theme.Colors.textSecondary)
            ForEach(groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.name)
                            .font(Theme.Fonts.header(14))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Spacer()
                        Text("\(group.sets.count) sets")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    ForEach(group.sets, id: \.objectID) { set in
                        Text(label(for: set))
                            .font(Theme.Fonts.mono(13))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                if group.name != groups.last?.name {
                    Divider().overlay(Theme.Colors.border)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private struct Group {
        let name: String
        let sets: [LoggedSet]
    }

    private var groups: [Group] {
        let sets = (session.sets as? Set<LoggedSet>) ?? []
        let sorted = sets.sorted { lhs, rhs in
            let l = lhs.completedAt ?? Date.distantPast
            let r = rhs.completedAt ?? Date.distantPast
            if l != r { return l < r }
            return lhs.setIndex < rhs.setIndex
        }
        var order: [String] = []
        var bucket: [String: [LoggedSet]] = [:]
        for s in sorted {
            let key = s.exerciseName ?? "Exercise"
            if bucket[key] == nil {
                order.append(key)
                bucket[key] = []
            }
            bucket[key]?.append(s)
        }
        return order.map { Group(name: $0, sets: bucket[$0] ?? []) }
    }

    private func label(for set: LoggedSet) -> String {
        let weight = set.weightLbs
        let weightStr = weight == 0
            ? "BW"
            : (weight.truncatingRemainder(dividingBy: 1) == 0
               ? String(format: "%.0f", weight)
               : String(weight))
        return "Set \(set.setIndex):  \(weightStr) × \(Int(set.reps))"
    }
}

/// Colored pill row for the "What you crushed" section. Renders nothing when
/// the bundle is empty so the parent can place it unconditionally.
struct SessionInsightsCallouts: View {
    let bundle: SessionInsights.Bundle

    var body: some View {
        if bundle.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("What you crushed")
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bundle.weightPRs) { pr in
                        calloutPill(
                            icon: "trophy.fill",
                            tint: Theme.Colors.accent,
                            text: weightPRText(pr)
                        )
                    }
                    ForEach(bundle.repPRs) { pr in
                        calloutPill(
                            icon: "figure.strengthtraining.traditional",
                            tint: Theme.Colors.pink,
                            text: repPRText(pr)
                        )
                    }
                    if let v = bundle.volume {
                        calloutPill(
                            icon: "chart.line.uptrend.xyaxis",
                            tint: Theme.Colors.teal,
                            text: volumeText(v)
                        )
                    }
                    if let streak = bundle.streakMilestone {
                        calloutPill(
                            icon: "flame.fill",
                            tint: Theme.Colors.orange,
                            text: "\(streak)-day streak!"
                        )
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
        }
    }

    private func calloutPill(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.15)))
            Text(text)
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func weightPRText(_ pr: SessionInsights.WeightPR) -> String {
        let weight = formatLbs(pr.newBestLbs)
        if pr.priorBestLbs > 0 {
            return "\(pr.exerciseName) PR — \(weight) lbs (+\(formatLbs(pr.deltaLbs)))"
        }
        return "\(pr.exerciseName) — first PR @ \(weight) lbs"
    }

    private func repPRText(_ pr: SessionInsights.RepPR) -> String {
        let weight = formatLbs(pr.weightLbs)
        return "\(pr.exerciseName): \(pr.newBestReps) reps @ \(weight) lbs (was \(pr.priorBestReps))"
    }

    private func volumeText(_ v: SessionInsights.VolumeDelta) -> String {
        let delta = v.deltaLbs
        let pct = abs(v.deltaPct)
        let arrow = delta >= 0 ? "+" : "−"
        let pctStr = pct >= 1 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
        return "\(arrow)\(formatLbs(abs(delta))) lbs vs \(v.comparisonLabel) (\(arrow)\(pctStr))"
    }

    private func formatLbs(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
    }
}
