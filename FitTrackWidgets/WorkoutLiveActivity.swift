import SwiftUI
import WidgetKit
import ActivityKit

/// Live Activity that surfaces while a workout is recording.
///
/// Two render paths are configured here:
///
/// 1. **Lock screen / banner** — full-card layout patterned after Hevy's
///    Live Activity: header row (workout name + auto-ticking elapsed timer),
///    middle row (current exercise + "Set X of Y"), footer row (last
///    completed set summary).
/// 2. **Dynamic Island** — compact (icon + timer), minimal (icon only),
///    expanded (full layout in two columns + bottom row).
///
/// Per ActivityKit best practices we never push per-second updates — the
/// elapsed label uses `Text(timerInterval:countsDown:)` with the session's
/// `startedAt`, and ticks on its own. We only call `update(...)` on
/// meaningful state changes (set logged/unchecked, exercise switched).
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .padding(14)
                .activityBackgroundTint(Color(red: 0x0C / 255, green: 0x0C / 255, blue: 0x0E / 255))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        IconBadge(size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.workoutName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("FitTrack")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture,
                         pauseTime: nil,
                         countsDown: false,
                         showsHours: false)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(context.state.currentExerciseName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text(setOfLabel(state: context.state))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if let last = context.state.lastSetSummary {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(accent)
                                Text("Last: \(last)")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }
            } compactLeading: {
                IconBadge(size: 18)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture,
                     pauseTime: nil,
                     countsDown: false,
                     showsHours: false)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                IconBadge(size: 16)
            }
            .keylineTint(accent)
        }
    }

    private var accent: Color {
        Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)
    }

    private func setOfLabel(state: WorkoutActivityAttributes.ContentState) -> String {
        // Once at least one set has been opened, render "Set X of Y".
        // Before then (no drafts), show the session's overall ✓ count so the
        // pill stays informative without lying about a per-exercise total.
        if state.totalSetsForExercise > 0 {
            let total = max(state.totalSetsForExercise, state.currentSetIndex)
            return "Set \(state.currentSetIndex) of \(total)"
        }
        return "\(state.completedSetCount) ✓ this session"
    }
}

/// Lock-screen card. Three rows top-to-bottom:
///   • Header — workout name + elapsed timer
///   • Body   — exercise + "Set X of Y"
///   • Footer — last logged set
private struct LockScreenView: View {
    let state: WorkoutActivityAttributes.ContentState
    let attributes: WorkoutActivityAttributes

    private let accent = Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)

    /// Render-side mirror of `WorkoutLiveActivity.setOfLabel(state:)`. The
    /// widget can't reach the parent struct's helper from inside this view.
    private var setLabel: String {
        if state.totalSetsForExercise > 0 {
            let total = max(state.totalSetsForExercise, state.currentSetIndex)
            return "Set \(state.currentSetIndex) of \(total)"
        }
        return "\(state.completedSetCount) ✓ this session"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center) {
                IconBadge(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Workout")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(attributes.workoutName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
                Text(timerInterval: state.startedAt...Date.distantFuture,
                     pauseTime: nil,
                     countsDown: false,
                     showsHours: true)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 130)
            }

            Divider().background(Color.white.opacity(0.1))

            // Body — current exercise
            HStack(alignment: .top, spacing: 10) {
                ExerciseGlyph()
                VStack(alignment: .leading, spacing: 2) {
                    if let section = state.currentExerciseSection {
                        Text(section.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent.opacity(0.8))
                            .tracking(0.5)
                    }
                    Text(state.currentExerciseName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(setLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            // Footer — last logged set summary
            if let summary = state.lastSetSummary {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(summary)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("\(state.completedSetCount) ✓")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Tap ✓ on a set to log it")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Lime-on-black dumbbell badge used in the Dynamic Island compact and the
/// lock-screen header.
private struct IconBadge: View {
    let size: CGFloat
    private let accent = Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(accent.opacity(0.18))
            Image(systemName: "dumbbell.fill")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: size, height: size)
    }
}

/// Larger glyph used next to the current exercise label on the lock screen.
private struct ExerciseGlyph: View {
    private let accent = Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)
    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.15))
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 36, height: 36)
    }
}
