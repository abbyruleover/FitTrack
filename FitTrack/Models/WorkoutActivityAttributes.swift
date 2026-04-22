import ActivityKit
import Foundation

/// Shape of the FitTrack Live Activity.
///
/// Lives in `Models/` so both the app target (which calls
/// `Activity<WorkoutActivityAttributes>.request(...)`) and the widget
/// extension (which renders the lock-screen + Dynamic Island views) can
/// import it. `project.yml` lists this single file as a source for both
/// targets.
///
/// Static attributes carry workout-name (set once at request time).
/// `ContentState` carries everything that ticks during a workout — we push
/// `update(...)` from `ActiveSessionService` whenever the user logs or
/// unchecks a set, or moves between exercises. The elapsed timer itself is
/// rendered with `Text(timerInterval:)` against `startedAt` so it ticks on
/// its own without us pushing per-second updates (would burn battery and
/// hit ActivityKit rate limits).
struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Wall-clock when the session started. Used by the widget to drive
        /// the auto-ticking timer label.
        var startedAt: Date
        /// Most recently touched exercise (last ✓), or the first exercise in
        /// the workout if nothing logged yet.
        var currentExerciseName: String
        /// 1-based index of the next not-yet-completed set for the current
        /// exercise. Falls back to `completedSetCount + 1` if all sets done.
        var currentSetIndex: Int
        /// Total drafts for the current exercise (so we can render "Set 2 of 4").
        var totalSetsForExercise: Int
        /// Pretty summary of the most recent completed set across the whole
        /// session, e.g. "135 × 8". Nil before the first ✓.
        var lastSetSummary: String?
        /// Total ✓-checked sets across the entire session — drives the
        /// "Set N" badge on the widget when no per-exercise total exists.
        var completedSetCount: Int
    }

    /// Display name from the parsed workout (e.g. "Mon WOD").
    var workoutName: String
}
