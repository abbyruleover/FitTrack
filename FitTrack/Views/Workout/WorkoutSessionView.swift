import SwiftUI
import CoreData

/// Live workout-logging screen. Presented as a full-screen cover from
/// `ContentView` whenever `ActiveSessionService.shared.isPresentingSession` is
/// true. The store lives on the service (not as a local @StateObject) so the
/// session survives the user tapping minimize and switching tabs.
///
/// Sets are persisted to Core Data (`LoggedSet` rows) the moment the user taps
/// the ✓ — no separate "save" step. Tapping Finish stamps `finishedAt`, fires
/// the summary push, and the service clears its reference.
struct WorkoutSessionView: View {
    let workout: ParsedWorkout

    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var service = ActiveSessionService.shared
    @State private var showSummary = false
    @State private var finishedSessionID: NSManagedObjectID?

    var body: some View {
        NavigationStack {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store = service.current {
            sessionScroll(store: store)
        } else {
            // Defensive: cover is up but the service has no store. Show a
            // dismiss-only stub so the user isn't trapped.
            Color.clear
                .onAppear { service.minimize() }
        }
    }

    private func sessionScroll(store: SessionStore) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: Theme.Spacing.md) {
                ForEach(workout.sections) { section in
                    if section.kind.isLoggable {
                        SessionSectionCard(section: section, store: store)
                    } else {
                        CollapsibleInfoCard(section: section)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            // Minimize: dismiss the cover but keep the store alive — the
            // floating mini-pill in ContentView takes over from here.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    AppLogger.shared.log("Minimize tapped — workout=\(workout.name)", category: "ui")
                    service.minimize()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Theme.Colors.surface)
                        )
                        .overlay(
                            Capsule().stroke(Theme.Colors.border, lineWidth: 1)
                        )
                }
            }
            ToolbarItem(placement: .principal) {
                LiveTimerPill(
                    elapsedLabel: store.elapsedLabel,
                    fraction: store.elapsedFraction
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppLogger.shared.log("Finish button tapped in WorkoutSessionView", category: "ui")
                    store.finish()
                    finishedSessionID = store.session.objectID
                    showSummary = true
                } label: {
                    Text("Finish")
                        .font(Theme.Fonts.header(15))
                        .foregroundStyle(Theme.Colors.background)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            Capsule().fill(Theme.Colors.accent)
                        )
                }
            }
        }
        .navigationDestination(isPresented: $showSummary) {
            if let oid = finishedSessionID {
                SessionSummaryView(sessionID: oid)
            }
        }
        .onChange(of: showSummary) { wasShown, isShown in
            // User popped the summary (Done or back-swipe) → release the
            // session and dismiss the cover so they land back where they
            // started.
            if wasShown && !isShown {
                AppLogger.shared.log("summary popped — releasing active session", category: "ui")
                service.didFinish()
            }
        }
        .onAppear {
            AppLogger.shared.log("WorkoutSessionView appeared — workout=\(workout.name)", category: "ui")
        }
    }
}

// MARK: - Collapsible info card (warm-up / prep / finisher)

private struct CollapsibleInfoCard: View {
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
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(idx + 1).")
                            .font(Theme.Fonts.mono(13))
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(width: 24, alignment: .trailing)
                        Text(ex.name)
                            .font(Theme.Fonts.body(14))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Spacer(minLength: Theme.Spacing.sm)
                        if !ex.reps.isEmpty {
                            Text(ex.reps)
                                .font(Theme.Fonts.mono(12))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
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

// MARK: - Section card

private struct SessionSectionCard: View {
    let section: WorkoutSection
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
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

            ForEach(section.exercises) { ex in
                ExerciseLogCard(exercise: ex, store: store)
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

// MARK: - Per-exercise log card

private struct ExerciseLogCard: View {
    let exercise: WorkoutExercise
    @ObservedObject var store: SessionStore

    private var isSkipped: Bool { store.isSkipped(exerciseName: exercise.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.name)
                    .font(Theme.Fonts.header(15))
                    .foregroundStyle(isSkipped ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                    .strikethrough(isSkipped)
                Spacer()
                if !exercise.reps.isEmpty {
                    Text(exercise.reps)
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Button {
                    store.toggleSkip(exerciseName: exercise.name)
                } label: {
                    Text(isSkipped ? "Unskip" : "Skip")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(isSkipped ? Theme.Colors.accent : Theme.Colors.textTertiary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule()
                                .stroke(isSkipped ? Theme.Colors.accent : Theme.Colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if isSkipped {
                Text("Skipped — won't be logged")
                    .font(Theme.Fonts.body(12))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .italic()
                    .padding(.top, 2)
            } else {
                // Column headers — Hevy-style pill row.
                HStack(spacing: Theme.Spacing.sm) {
                    Text("SET").frame(width: 36, alignment: .center)
                    Text("PREVIOUS").frame(maxWidth: .infinity, alignment: .center)
                    Text("LBS").frame(width: 56, alignment: .center)
                    Text("REPS").frame(width: 56, alignment: .center)
                    Image(systemName: "checkmark").frame(width: 28, alignment: .center)
                }
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textTertiary)

                ForEach(store.drafts(for: exercise.name)) { draft in
                    SetRow(
                        draft: draft,
                        isPR: store.prDraftIDs.contains(draft.id),
                        previous: store.previous(for: exercise.name),
                        onWeight: { store.updateWeight(for: exercise.name, draftID: draft.id, value: $0) },
                        onReps: { store.updateReps(for: exercise.name, draftID: draft.id, value: $0) },
                        onCheck: { store.toggleComplete(for: exercise.name, draftID: draft.id) }
                    )
                }

                Button { store.addSet(for: exercise.name) } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Set")
                    }
                    .font(Theme.Fonts.body(13))
                    .foregroundStyle(Theme.Colors.accent)
                }
                .padding(.top, 2)
            }
        }
        .padding(Theme.Spacing.sm)
        .opacity(isSkipped ? 0.55 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.surfaceElevated)
        )
    }
}

// MARK: - One set row

private struct SetRow: View {
    let draft: SessionStore.SetDraft
    let isPR: Bool
    let previous: String?
    let onWeight: (Double) -> Void
    let onReps: (Int) -> Void
    let onCheck: () -> Void

    // Local string state so the user can clear and retype freely; we push
    // numeric values up only when the field actually parses.
    @State private var weightText: String = ""
    @State private var repsText: String = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("\(draft.setIndex)")
                .font(Theme.Fonts.mono(14))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 36, alignment: .center)

            Text(previous ?? "—")
                .font(Theme.Fonts.mono(13))
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("0", text: $weightText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(Theme.Fonts.mono(14))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 56)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Colors.background.opacity(0.5))
                )
                .onChange(of: weightText) { _, new in
                    if let v = Double(new) { onWeight(v) }
                }

            TextField("0", text: $repsText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.Fonts.mono(14))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 56)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Colors.background.opacity(0.5))
                )
                .onChange(of: repsText) { _, new in
                    if let v = Int(new) { onReps(v) }
                }

            Button(action: onCheck) {
                Image(systemName: draft.isCompleted
                      ? (isPR ? "trophy.fill" : "checkmark.square.fill")
                      : "square")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(draft.isCompleted
                                     ? (isPR ? Theme.Colors.accent : Theme.Colors.green)
                                     : Theme.Colors.textTertiary)
            }
            .frame(width: 28, alignment: .center)
        }
        .padding(.vertical, 2)
        .background(
            draft.isCompleted
                ? (isPR ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.green.opacity(0.10))
                : Color.clear
        )
        .onAppear {
            // Hydrate text fields with whatever the store already has, so a
            // re-render after Add Set keeps the user's typed values visible.
            if draft.weightLbs > 0 {
                weightText = draft.weightLbs.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", draft.weightLbs)
                    : String(draft.weightLbs)
            }
            if draft.reps > 0 { repsText = String(draft.reps) }
        }
    }
}

// MARK: - Section.Kind helpers
// `isLoggable` lives on `WorkoutSection.Kind` in ParsedWorkout.swift.

#Preview {
    WorkoutSessionView(workout: .preview)
        .preferredColorScheme(.dark)
}
