import SwiftUI
import HealthKit
import CoreData

/// Combined Watch + FitTrack post-session view. Top of the screen is now a
/// scrubbable HR trace (Apple Fitness-style), then a 3-tile row showing TIME
/// / KCAL / VOLUME in raw units (the multi-ring used to live here, but it
/// hid the raw numbers behind percentages and didn't let you read intensity
/// over time). Below that: trimmed Watch stats, the "What you crushed"
/// callouts, and the per-exercise breakdown.
struct UnifiedSessionView: View {
    let session: WorkoutSession
    let hkWorkout: HKWorkout?

    @Environment(\.managedObjectContext) private var context

    @State private var activeKcal: Double = 0
    @State private var avgHR: Double?
    @State private var maxHR: Double?
    @State private var insights: SessionInsights.Bundle = .init(
        weightPRs: [], repPRs: [], volume: nil, streakMilestone: nil
    )
    @State private var hrSamples: [HRPoint] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(dateLabel)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
                SessionHRTraceChart(
                    samples: hrSamples,
                    workoutWindow: hkWorkout.map { $0.startDate...$0.endDate },
                    stations: hkWorkout.flatMap {
                        ClassSchedule.classStations(
                            for: $0,
                            firstSetDate: ClassSchedule.firstSetDate(in: session)
                        )
                    } ?? []
                )
                rawUnitsRow
                if hkWorkout != nil {
                    watchStatsRow
                }
                SessionInsightsCallouts(bundle: insights)
                SessionExerciseBreakdown(session: session)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            insights = SessionInsights.compute(for: session, in: context)
            if let w = hkWorkout {
                let stats = await HealthKitService.shared.watchStats(for: w)
                activeKcal = stats.activeKcal
                avgHR = stats.avgHR
                maxHR = stats.maxHR
                let raw = await HealthKitService.shared.heartRateSamples(for: w)
                // Clamp to the workout window so a stray AM sample doesn't
                // bleed into the chart's auto-domain.
                let window = w.startDate...w.endDate
                hrSamples = raw
                    .filter { window.contains($0.date) }
                    .map { HRPoint(date: $0.date, bpm: $0.bpm) }
                AppLogger.shared.log("UnifiedSession watchStats kcal=\(Int(activeKcal)) avgHR=\(avgHR.map { Int($0) } ?? -1) hrSamples=\(hrSamples.count)", category: "ui")
            }
        }
    }

    // MARK: - Raw-units row (replaces the multi-ring legend)

    /// TIME / KCAL / VOLUME in their actual units instead of percentages.
    /// The user explicitly wanted raw numbers — "I can do percent math in my
    /// head, what I can't do is reconstruct kcal from a 73% ring."
    private var rawUnitsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            statTile(label: "TIME", value: durationLabel, suffix: nil)
            statTile(label: "KCAL", value: "\(Int(activeKcal))", suffix: "kcal")
            statTile(label: "VOLUME", value: volumeLabel, suffix: "lbs")
        }
    }

    // MARK: - Watch stats (trimmed)

    /// AVG HR / MAX HR / ELAPSED. We dropped the ACTIVE kcal tile that used
    /// to live here — it's now in `rawUnitsRow` so we don't show the same
    /// number twice.
    private var watchStatsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            hrTile(label: "AVG HR", value: avgHR.map { "\(Int($0))" } ?? "—")
            hrTile(label: "MAX HR", value: maxHR.map { "\(Int($0))" } ?? "—")
            statTile(label: "ELAPSED", value: durationLabel, suffix: nil)
        }
    }

    /// HR tile that pushes into the per-station HR chart. Only navigates when
    /// we have an HK workout (otherwise there's nothing to chart). Reads the
    /// same value/suffix as `statTile` so the visual matches the elapsed
    /// neighbor exactly — the only difference is the `chevron.up.right` glyph
    /// telegraphing it's tappable.
    @ViewBuilder
    private func hrTile(label: String, value: String) -> some View {
        if hkWorkout != nil {
            NavigationLink(value: HRChartRoute(sessionID: session.objectID)) {
                hrTileContent(label: label, value: value, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            hrTileContent(label: label, value: value, tappable: false)
        }
    }

    private func hrTileContent(label: String, value: String, tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Theme.Fonts.mono(9))
                    .foregroundStyle(Theme.Colors.textTertiary)
                if tappable {
                    Image(systemName: "chevron.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("bpm")
                    .font(Theme.Fonts.mono(9))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func statTile(label: String, value: String, suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(9))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let suffix {
                    Text(suffix)
                        .font(Theme.Fonts.mono(9))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Derived

    private var currentDurationSecs: Double {
        if let w = hkWorkout { return w.duration }
        if let start = session.startedAt {
            return (session.finishedAt ?? Date()).timeIntervalSince(start)
        }
        return 0
    }

    private var currentVolumeLbs: Double {
        let sets = (session.sets as? Set<LoggedSet>) ?? []
        return sets.reduce(0) { acc, s in
            guard s.isCompleted else { return acc }
            return acc + s.weightLbs * Double(s.reps)
        }
    }

    private var durationLabel: String {
        let total = Int(currentDurationSecs)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Thousands-grouped lbs string, e.g. "12,450". Zero collapses to "0".
    private var volumeLabel: String {
        let v = Int(currentVolumeLbs)
        guard v > 0 else { return "0" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d • h:mm a"
        let date = hkWorkout?.startDate ?? session.finishedAt ?? session.startedAt ?? Date()
        let base = f.string(from: date)
        if let slot = ClassSchedule.slot(for: date) {
            return "\(base) · \(slot.label) class"
        }
        return base
    }
}

// MARK: - HR chart route

/// Pushed onto the parent NavigationStack when the user taps an HR tile.
/// Carries only the session's `NSManagedObjectID` because `HKWorkout` isn't
/// `Hashable`. The destination resolver in WorkoutView/ProgressView re-fetches
/// the matching HKWorkout via `HealthKitService.hiitWorkout(on:)`.
struct HRChartRoute: Hashable {
    let sessionID: NSManagedObjectID
}

/// Loader that resolves a session + its HKWorkout, then renders
/// `HRStationChartView`. Mirrors the `ProgressUnifiedSessionLoader` pattern
/// so the view tree stays simple even though the inputs are async.
struct HRChartLoader: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var context
    @State private var session: WorkoutSession?
    @State private var hkWorkout: HKWorkout?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let session, let hkWorkout {
                HRStationChartView(session: session, hkWorkout: hkWorkout)
            } else if loaded {
                // Resolved but no HKWorkout — show a friendly empty state
                // rather than crash. Happens if the user shows up here from a
                // FitTrack-only session (Watch wasn't worn).
                noWorkoutState
            } else {
                VStack {
                    SwiftUI.ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.Colors.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.background.ignoresSafeArea())
            }
        }
        .task {
            session = (try? context.existingObject(with: sessionID)) as? WorkoutSession
            if let s = session, let date = s.startedAt {
                hkWorkout = await HealthKitService.shared.hiitWorkout(on: date)
            }
            loaded = true
            AppLogger.shared.log("HRChartLoader resolved — hk=\(hkWorkout != nil)", category: "ui")
        }
    }

    private var noWorkoutState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("No Apple Watch workout for this day")
                .font(Theme.Fonts.header(15))
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("HR samples come from a HIIT workout recorded on the Watch.")
                .font(Theme.Fonts.body(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}
