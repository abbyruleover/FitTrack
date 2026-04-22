import SwiftUI

/// Maps a parsed exercise name to a representative SF Symbol + tint. Used by
/// DayCard to render the station-1 lift on the home carousel and anywhere
/// else we want a quick visual cue (recent workouts, summary screens).
///
/// The mapping is keyword-based and case-insensitive — most CrossFit/HIIT
/// program names contain the canonical lift word ("Back Squat", "BB Bench
/// Press", "Trap-Bar Deadlift") so substring matching works without a giant
/// alias table.
enum ExerciseIcon {

    struct Glyph {
        let systemName: String
        let tint: Color
    }

    /// Best-guess glyph for a free-text exercise name. Falls back to a
    /// neutral dumbbell when nothing matches so the card never renders empty.
    static func glyph(for exerciseName: String) -> Glyph {
        let n = exerciseName.lowercased()

        // Order matters — check the more specific words first ("deadlift"
        // before "lift", "front squat" before "squat", etc.).
        if n.contains("deadlift") {
            return Glyph(systemName: "figure.strengthtraining.traditional", tint: .red)
        }
        if n.contains("snatch") || n.contains("clean") || n.contains("jerk") {
            return Glyph(systemName: "figure.strengthtraining.traditional", tint: .orange)
        }
        if n.contains("squat") || n.contains("lunge") || n.contains("step-up") || n.contains("step up") {
            return Glyph(systemName: "figure.strengthtraining.functional", tint: .purple)
        }
        if n.contains("bench") || n.contains("press") || n.contains("push-up") || n.contains("push up") || n.contains("dip") {
            return Glyph(systemName: "dumbbell.fill", tint: .blue)
        }
        if n.contains("row") {
            return Glyph(systemName: "figure.rower", tint: .teal)
        }
        if n.contains("pull-up") || n.contains("pull up") || n.contains("chin-up") || n.contains("chin up") || n.contains("pulldown") {
            return Glyph(systemName: "figure.pull.up", tint: .indigo)
        }
        if n.contains("curl") {
            return Glyph(systemName: "dumbbell.fill", tint: .pink)
        }
        if n.contains("run") || n.contains("sprint") || n.contains("jog") {
            return Glyph(systemName: "figure.run", tint: .green)
        }
        if n.contains("bike") || n.contains("cycle") || n.contains("cycling") || n.contains("assault") {
            return Glyph(systemName: "figure.outdoor.cycle", tint: .green)
        }
        if n.contains("ski") || n.contains("erg") {
            return Glyph(systemName: "figure.skiing.crosscountry", tint: .cyan)
        }
        if n.contains("plank") || n.contains("core") || n.contains("ab") || n.contains("crunch") || n.contains("sit-up") || n.contains("sit up") || n.contains("hollow") {
            return Glyph(systemName: "figure.core.training", tint: .yellow)
        }
        if n.contains("burpee") || n.contains("box jump") || n.contains("jumping") || n.contains("hiit") {
            return Glyph(systemName: "bolt.fill", tint: .orange)
        }
        if n.contains("yoga") || n.contains("stretch") || n.contains("mobility") {
            return Glyph(systemName: "figure.yoga", tint: .mint)
        }
        if n.contains("kettlebell") || n.contains("kb") || n.contains("swing") {
            return Glyph(systemName: "figure.strengthtraining.functional", tint: .orange)
        }
        if n.contains("carry") || n.contains("farmer") {
            return Glyph(systemName: "figure.walk", tint: .brown)
        }

        // Default — generic strength lift.
        return Glyph(systemName: "dumbbell.fill", tint: Theme.Colors.accent)
    }
}
