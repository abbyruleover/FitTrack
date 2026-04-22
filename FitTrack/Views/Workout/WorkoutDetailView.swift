import SwiftUI
import CoreData

/// Renders a `ParsedWorkout` as a vertical list of section cards.
/// Each section card uses the dark surface palette and the lime accent for
/// section titles, matching the Phase 1 / mockup look.
struct WorkoutDetailView: View {
    let workout: ParsedWorkout
    let workoutDay: WorkoutDay?

    @Environment(\.managedObjectContext) private var context
    @State private var showSessionDetail = false

    init(workout: ParsedWorkout, workoutDay: WorkoutDay? = nil) {
        self.workout = workout
        self.workoutDay = workoutDay
    }

    private var isCompleted: Bool { workoutDay?.isCompleted ?? false }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: Theme.Spacing.md) {
                ForEach(workout.sections) { section in
                    if section.kind.isLoggable {
                        SectionCard(section: section)
                    } else {
                        CollapsiblePrepCard(section: section)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            // Bottom inset accommodates the sticky Start Workout bar so the
            // last section card isn't hidden behind it on short workouts.
            .padding(.bottom, Theme.Spacing.xl + 56)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.xs) {
                if isCompleted {
                    Button {
                        AppLogger.shared.log("View Session tapped — workout=\(workout.name)", category: "ui")
                        showSessionDetail = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Completed — View Session")
                        }
                        .font(Theme.Fonts.header(16))
                        .foregroundStyle(Theme.Colors.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm + 4)
                        .background(
                            Capsule().fill(Theme.Colors.green)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        AppLogger.shared.log("Start a new session tapped — workout=\(workout.name)", category: "ui")
                        ActiveSessionService.shared.start(
                            workout: workout,
                            workoutDayID: workoutDay?.objectID,
                            context: context
                        )
                    } label: {
                        Text("Start a new session")
                            .font(Theme.Fonts.body(13))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Theme.Spacing.xs)
                } else {
                    Button {
                        AppLogger.shared.log("Start Workout tapped — workout=\(workout.name)", category: "ui")
                        ActiveSessionService.shared.start(
                            workout: workout,
                            workoutDayID: workoutDay?.objectID,
                            context: context
                        )
                    } label: {
                        Text("Start Workout")
                            .font(Theme.Fonts.header(16))
                            .foregroundStyle(Theme.Colors.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.sm + 4)
                            .background(
                                Capsule().fill(Theme.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)
            .background(
                Theme.Colors.background
                    .opacity(0.95)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .sheet(isPresented: $showSessionDetail) {
            if let date = workoutDay?.date {
                NavigationStack {
                    SessionDetailView(date: date)
                        .navigationTitle(workout.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSessionDetail = false }
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Collapsible prep card (warm-up / prep / finisher)
// Mirrors the in-session view so the pre-start preview matches what the user
// sees once they tap Start. Prep work is info-only: collapsed by default,
// expand for details. No SET/LBS/REPS table.

private struct CollapsiblePrepCard: View {
    let section: WorkoutSection
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(section.title.uppercased())
                        .font(Theme.Fonts.header(18))
                        .foregroundStyle(Theme.Colors.accent)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.header(15))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                if let scheme = section.scheme {
                    Text(scheme)
                        .font(Theme.Fonts.body(13))
                        .foregroundStyle(Theme.Colors.orange)
                }
                if let prefix = section.prefix {
                    Text(prefix)
                        .font(Theme.Fonts.body(13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .italic()
                }
                ForEach(Array(section.exercises.enumerated()), id: \.element.id) { idx, ex in
                    ExerciseRow(index: idx + 1, exercise: ex)
                }
                if let suffix = section.suffix {
                    Text(suffix)
                        .font(Theme.Fonts.body(13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .italic()
                        .padding(.top, Theme.Spacing.xs)
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
}

private struct SectionCard: View {
    let section: WorkoutSection

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header — lime accent so the eye finds section breaks fast.
            Text(section.title.uppercased())
                .font(Theme.Fonts.header(18))
                .foregroundStyle(Theme.Colors.accent)

            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            if let scheme = section.scheme {
                Text(scheme)
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.orange)
            }

            if let prefix = section.prefix {
                Text(prefix)
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .italic()
            }

            ForEach(Array(section.exercises.enumerated()), id: \.element.id) { idx, ex in
                ExerciseRow(index: idx + 1, exercise: ex)
            }

            if let suffix = section.suffix {
                Text(suffix)
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .italic()
                    .padding(.top, Theme.Spacing.xs)
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
}

private struct ExerciseRow: View {
    let index: Int
    let exercise: WorkoutExercise

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text("\(index).")
                .font(Theme.Fonts.mono(14))
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 24, alignment: .trailing)

            Text(exercise.name)
                .font(Theme.Fonts.body(15))
                .foregroundStyle(Theme.Colors.textPrimary)

            Spacer(minLength: Theme.Spacing.sm)

            if !exercise.reps.isEmpty {
                Text(exercise.reps)
                    .font(Theme.Fonts.mono(13))
                    .foregroundStyle(Theme.Colors.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        WorkoutDetailView(workout: .preview)
    }
    .preferredColorScheme(.dark)
}

extension ParsedWorkout {
    /// Compact fixture used by SwiftUI previews.
    static var preview: ParsedWorkout {
        ParsedWorkout(
            name: "Mon WOD",
            importedAt: Date(),
            sections: [
                WorkoutSection(
                    kind: .warmup, title: "Warm Up",
                    subtitle: nil, scheme: "3 Rounds", prefix: nil, suffix: nil,
                    exercises: [
                        WorkoutExercise(name: "Jumping Jacks", reps: "x 20"),
                        WorkoutExercise(name: "Air Squats", reps: "x 10")
                    ]
                ),
                WorkoutSection(
                    kind: .station1, title: "Station 1",
                    subtitle: "BB or DB Squats", scheme: "3 Rounds",
                    prefix: "Run 1 lap around the building then;",
                    suffix: nil,
                    exercises: [
                        WorkoutExercise(name: "Goblet Squat", reps: "x 8-10"),
                        WorkoutExercise(name: "Push Press", reps: "x 10")
                    ]
                )
            ]
        )
    }
}
