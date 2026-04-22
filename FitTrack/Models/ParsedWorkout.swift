import Foundation
import CoreData

/// In-memory representation of a parsed WOD PDF.
/// Independent of Core Data so the parser stays pure and easy to test.
/// Persistence to `WorkoutDay`/`Exercise` happens in a separate step once the
/// user is happy with what they see on screen.
struct ParsedWorkout: Identifiable, Hashable {
    let id = UUID()
    let name: String          // e.g. "Mon WOD"
    let importedAt: Date
    var sections: [WorkoutSection]
}

extension ParsedWorkout {
    /// Reconstruct a `ParsedWorkout` from a scheduled `WorkoutDay` so the home
    /// carousel can route into the same `WorkoutDetailView` that single-PDF
    /// imports use (collapsible prep cards + sticky Start Workout button).
    /// Inverse of `WeekScheduler.stationCode(for:)`. Subtitle/scheme/prefix/
    /// suffix are lost at scheduling time — the live logger never reads them.
    init(from day: WorkoutDay) {
        let rows = (day.exercises as? Set<Exercise>)?
            .sorted(by: { $0.orderIndex < $1.orderIndex }) ?? []
        let buckets = Dictionary(grouping: rows, by: { $0.station })

        // Canonical order: Warm Up → Athletic Prep → Stations 1-4 → Finisher.
        let order: [(code: Int16, kind: WorkoutSection.Kind, title: String)] = [
            (0,  .warmup,   "Warm Up"),
            (10, .prep,     "Athletic Prep"),
            (1,  .station1, "Station 1"),
            (2,  .station2, "Station 2"),
            (3,  .station3, "Station 3"),
            (4,  .station4, "Station 4"),
            (9,  .finisher, "Finisher")
        ]

        let sections: [WorkoutSection] = order.compactMap { entry in
            guard let exs = buckets[entry.code], !exs.isEmpty else { return nil }
            var mapped = exs.map {
                WorkoutExercise(name: $0.name ?? "Exercise",
                                reps: $0.equipment ?? "")
            }
            // Stations don't carry warmup work — drop any rows whose name
            // mentions warm up so a previously mis-bucketed PDF doesn't
            // surface warmup exercises in the live logger.
            if entry.kind.isLoggable {
                mapped = mapped.filter { ex in
                    let n = ex.name.lowercased()
                    return !n.contains("warm up") && !n.contains("warm-up") && !n.contains("warmup")
                }
            }
            guard !mapped.isEmpty else { return nil }
            return WorkoutSection(
                kind: entry.kind,
                title: entry.title,
                subtitle: nil,
                scheme: nil,
                prefix: nil,
                suffix: nil,
                exercises: mapped
            )
        }

        self.name = day.name ?? "Workout"
        self.importedAt = day.date ?? Date()
        self.sections = sections
    }
}

/// A single block within a WOD — fixed-order: Warm Up, Athletic Prep,
/// Stations 1-4, Finishers. Keeps `subtitle`, `prefix`, `suffix` optional
/// because real PDFs only set them sometimes.
struct WorkoutSection: Identifiable, Hashable {
    let id = UUID()
    let kind: Kind
    let title: String         // raw header from PDF, e.g. "Station 1"
    let subtitle: String?     // optional bold subheader, e.g. "BB or DB Squats"
    let scheme: String?       // raw scheme line, e.g. "3 Rounds"
    let prefix: String?       // optional pre-list line ("Run 1 lap then;")
    let suffix: String?       // optional post-list line ("Buy out: 1 Lap...")
    var exercises: [WorkoutExercise]

    enum Kind: String, CaseIterable, Hashable {
        case warmup, prep, station1, station2, station3, station4, finisher

        /// Stable ordering used when assembling sections off the parser.
        var sortIndex: Int {
            switch self {
            case .warmup:   return 0
            case .prep:     return 1
            case .station1: return 2
            case .station2: return 3
            case .station3: return 4
            case .station4: return 5
            case .finisher: return 6
            }
        }

        /// Stations are the only sections users actively log sets for. Warm-up,
        /// athletic prep, and finishers render as collapsed info-only cards.
        var isLoggable: Bool {
            switch self {
            case .station1, .station2, .station3, .station4: return true
            case .warmup, .prep, .finisher:                  return false
            }
        }
    }
}

/// One numbered line in a station list. `reps` is kept as the raw substring
/// from the PDF ("x 8-10", "500-300-200M", "") — display fidelity for v1.
struct WorkoutExercise: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let reps: String
}
