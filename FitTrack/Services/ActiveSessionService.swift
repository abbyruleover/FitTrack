import Foundation
import CoreData
import SwiftUI
import ActivityKit
import Combine
import WidgetKit

/// App-wide owner of the currently-running `SessionStore`.
///
/// Why this exists: prior to v0.6.3 the store lived inside `WorkoutSessionView`
/// as `@StateObject`, so dismissing the view nuked the session. The user
/// wanted a Hevy-style minimize-to-mini-pill flow — leave the session
/// recording while you check Progress or Body, then resume — which requires
/// the store to outlive any one view. The service owns it; the session view
/// reads it as `@ObservedObject`. ContentView watches `isPresentingSession`
/// to drive the full-screen cover and renders the floating pill whenever a
/// session is active but not currently presented.
@MainActor
final class ActiveSessionService: ObservableObject {
    static let shared = ActiveSessionService()

    /// The live session if any. Set by `start(...)`; cleared by `finish()` or
    /// `discard()`.
    @Published private(set) var current: SessionStore?

    /// Drives the full-screen cover in `ContentView`. Set true on `start(...)`
    /// or when the user taps the mini-pill to resume; set false when the user
    /// taps minimize on the session view.
    @Published var isPresentingSession: Bool = false

    /// The lock-screen / Dynamic Island Live Activity tracking the current
    /// session. Created lazily in `start(...)` if ActivityKit is available
    /// and the user has enabled Live Activities for the app. Updates flow
    /// from the Combine subscription on `current.$drafts` (set toggles,
    /// new exercises). Ended on `discard()` / `didFinish()`.
    private var activity: Activity<WorkoutActivityAttributes>?

    /// Holds the subscription on `SessionStore.$drafts` so we can push
    /// `activity.update(...)` whenever the user logs or unchecks a set.
    /// Cleared when the session ends.
    private var draftsSubscription: AnyCancellable?

    private init() {}

    /// Begin a new session and immediately present it. No-op if a session is
    /// already in flight — the caller should resolve the conflict first
    /// (typically by routing the user back to the existing session).
    func start(workout: ParsedWorkout, workoutDayID: NSManagedObjectID?, context: NSManagedObjectContext) {
        guard current == nil else {
            AppLogger.shared.log("ActiveSessionService.start refused — already active (\(current?.workoutName ?? "?"))", category: "session")
            isPresentingSession = true
            return
        }
        let store = SessionStore(workout: workout, workoutDayID: workoutDayID, context: context)
        current = store
        isPresentingSession = true
        AppLogger.shared.log("ActiveSessionService → started \(workout.name)", category: "session")

        startLiveActivity(for: store)
        // Push an `update` whenever the user logs / unchecks a set so the
        // lock-screen pill reflects the latest state. Combine debouncing
        // would mask quick double-taps; ActivityKit handles its own
        // throttling, and we only push small payloads.
        draftsSubscription = store.$drafts
            .dropFirst() // skip the initial empty value
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.pushActivityUpdate(from: store)
            }
    }

    /// Called by `WorkoutSessionView` when the user taps Finish. The store
    /// already wrote `finishedAt` and saved; we just clear our reference so
    /// the pill disappears.
    func didFinish() {
        AppLogger.shared.log("ActiveSessionService → didFinish (clearing current)", category: "session")
        endLiveActivity(reason: .finished)
        current = nil
        isPresentingSession = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Trash button on the mini-pill. Wipes the session and cascades to any
    /// logged sets. Routed through `SessionStore.discardEntirely()` so the
    /// store can drop its timer cleanly.
    func discard() {
        guard let s = current else { return }
        s.discardEntirely()
        endLiveActivity(reason: .discarded)
        current = nil
        isPresentingSession = false
    }

    /// Mini-pill tap → re-present the cover. The store stays the same — only
    /// the cover visibility flips.
    func resume() {
        guard current != nil else { return }
        AppLogger.shared.log("ActiveSessionService → resume (mini-pill tapped)", category: "session")
        isPresentingSession = true
    }

    /// Minimize button on the session toolbar. Hides the cover but keeps the
    /// store alive so the pill takes over.
    func minimize() {
        AppLogger.shared.log("ActiveSessionService → minimize", category: "session")
        isPresentingSession = false
    }

    // MARK: - Live Activity

    private enum EndReason { case finished, discarded }

    /// Request a new Live Activity for the session. No-op if the user has
    /// disabled Live Activities for the app (Settings → Notifications →
    /// FitTrack → Live Activities). Also no-op if the request itself throws
    /// — typically because the entitlement / Info.plist key isn't wired up
    /// (handled separately in `Info.plist`).
    private func startLiveActivity(for store: SessionStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.shared.log("Live Activities disabled by user — skipping start", category: "session")
            return
        }
        do {
            let attrs = WorkoutActivityAttributes(workoutName: store.workoutName)
            let state = makeContentState(from: store)
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try Activity<WorkoutActivityAttributes>.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
            AppLogger.shared.log("Live Activity started — id=\(activity?.id ?? "?")", category: "session")
        } catch {
            AppLogger.shared.log("Live Activity start FAILED: \(error)", category: "session")
        }
    }

    /// Push a fresh ContentState to the running activity. Called whenever
    /// `SessionStore.drafts` changes (set logged / unchecked / new exercise).
    /// Cheap — ActivityKit handles its own throttling and the payload is a
    /// handful of strings + ints.
    private func pushActivityUpdate(from store: SessionStore) {
        guard let activity else { return }
        let state = makeContentState(from: store)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Tear down the activity. `.finished` keeps the card visible for 30s
    /// (so the user has time to glance at the final state from the lock
    /// screen), `.discarded` dismisses immediately since the session was
    /// just thrown away.
    private func endLiveActivity(reason: EndReason) {
        guard let activity else {
            draftsSubscription?.cancel()
            draftsSubscription = nil
            return
        }
        let finalState = activity.content.state
        Task { [activity] in
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            AppLogger.shared.log("Live Activity ended (reason=\(reason))", category: "session")
        }
        self.activity = nil
        draftsSubscription?.cancel()
        draftsSubscription = nil
    }

    /// Snapshot the store into the ActivityKit ContentState shape.
    ///
    /// Set-counter math:
    ///  - `currentSetIndex` is the 1-based index of the next ✓-able set for
    ///    the current exercise (or `totalSets` once everything is checked).
    ///  - `totalSetsForExercise` reflects the live draft count, never `1` as
    ///    a magic default — that produced "Set 1 of 1" while the workout was
    ///    sitting idle and made the Live Activity look broken.
    private func makeContentState(from store: SessionStore) -> WorkoutActivityAttributes.ContentState {
        let exName = store.currentExerciseName
        let exDrafts = store.drafts[exName] ?? []
        let totalSets = exDrafts.count
        let currentIdx: Int
        if let firstOpen = exDrafts.first(where: { !$0.isCompleted }) {
            currentIdx = firstOpen.setIndex
        } else if !exDrafts.isEmpty {
            currentIdx = totalSets // all drafts done
        } else {
            currentIdx = 1 // user hasn't opened the exercise yet
        }
        return WorkoutActivityAttributes.ContentState(
            startedAt: store.session.startedAt ?? Date(),
            currentExerciseName: exName,
            currentExerciseSection: store.currentExerciseSection,
            currentSetIndex: currentIdx,
            totalSetsForExercise: totalSets,
            lastSetSummary: store.lastCompletedSetSummary(),
            completedSetCount: store.totalCompletedSetCount
        )
    }
}
