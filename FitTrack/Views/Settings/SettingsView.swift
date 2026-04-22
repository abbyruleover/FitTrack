import SwiftUI
import CoreData

/// Settings screen pushed from the gear button on `WorkoutView`. Replaces the
/// previous `confirmationDialog` so we can group destructive actions, surface
/// per-session deletion, and link out to the debug log without burying it
/// behind a long sheet menu.
struct SettingsView: View {
    @Environment(\.managedObjectContext) private var context

    @State private var pendingClear: ClearAction?
    @State private var showDebugLog = false
    @State private var factoryConfirmStep: FactoryStep = .idle

    enum FactoryStep {
        case idle, first, second
    }

    /// Each row that fires a destructive Core Data write. Routed through a
    /// single `.alert(item:)` so the confirm UI is consistent.
    enum ClearAction: Identifiable {
        case thisWeek
        case allScheduled
        case allSessions
        case allInBody

        var id: Int {
            switch self {
            case .thisWeek: return 0
            case .allScheduled: return 1
            case .allSessions: return 2
            case .allInBody: return 3
            }
        }

        var title: String {
            switch self {
            case .thisWeek: return "Clear this week?"
            case .allScheduled: return "Clear all scheduled?"
            case .allSessions: return "Delete all sessions?"
            case .allInBody: return "Delete all InBody scans?"
            }
        }

        var message: String {
            switch self {
            case .thisWeek:
                return "Removes every workout scheduled for the active Mon–Sat window. Logged sessions are kept."
            case .allScheduled:
                return "Removes every scheduled workout in the app. Logged sessions are kept."
            case .allSessions:
                return "Permanently deletes every logged workout session and its sets. Scheduled days stay."
            case .allInBody:
                return "Removes every saved InBody scan. Apple Health entries are NOT touched."
            }
        }
    }

    var body: some View {
        Form {
            scheduleSection
            sessionsSection
            inBodySection
            catalogSection
            debugSection
            aboutSection
            resetSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert(item: $pendingClear) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text("Delete")) {
                    perform(action)
                },
                secondaryButton: .cancel {
                    AppLogger.shared.log("Settings: \(action) cancelled", category: "ui")
                }
            )
        }
        // Two independent alerts because a single-binding two-step alert
        // races itself: the dismiss callback fires after the button action and
        // resets state to .idle, swallowing the .second transition. Splitting
        // them lets each alert own its own bool binding, so the second alert
        // can present cleanly once the first dismisses.
        .alert("Factory reset?", isPresented: stepBinding(.first)) {
            Button("Cancel", role: .cancel) {
                AppLogger.shared.log("Settings: factory reset cancelled at step .first", category: "ui")
                factoryConfirmStep = .idle
            }
            Button("Continue", role: .destructive) {
                AppLogger.shared.log("Settings: factory reset advanced to second confirm", category: "ui")
                factoryConfirmStep = .second
            }
        } message: {
            Text("This deletes every scheduled workout, every logged session, every InBody scan, and the debug log. There is no undo.")
        }
        .alert("Last chance — really wipe everything?", isPresented: stepBinding(.second)) {
            Button("Cancel", role: .cancel) {
                AppLogger.shared.log("Settings: factory reset cancelled at step .second", category: "ui")
                factoryConfirmStep = .idle
            }
            Button("Wipe everything", role: .destructive) {
                AppLogger.shared.log("Settings: factory reset CONFIRMED — wiping", category: "ui")
                DataReset.factoryReset(context: context)
                factoryConfirmStep = .idle
            }
        } message: {
            Text("Sessions, sets, scheduled workouts, InBody scans, and the debug log will be deleted permanently.")
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogSheet()
        }
        .onAppear {
            AppLogger.shared.log("SettingsView appeared", category: "ui")
        }
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        Section("Schedule") {
            destructiveRow("Clear this week", systemImage: "calendar.badge.minus") {
                pendingClear = .thisWeek
            }
            destructiveRow("Clear all scheduled", systemImage: "trash") {
                pendingClear = .allScheduled
            }
        }
    }

    private var sessionsSection: some View {
        Section("Sessions") {
            NavigationLink {
                SessionListView()
            } label: {
                Label("Browse logged sessions", systemImage: "list.bullet.rectangle")
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            destructiveRow("Delete all sessions", systemImage: "trash") {
                pendingClear = .allSessions
            }
        }
    }

    private var inBodySection: some View {
        Section("InBody") {
            destructiveRow("Delete all InBody scans", systemImage: "trash") {
                pendingClear = .allInBody
            }
        }
    }

    private var catalogSection: some View {
        Section("Exercise Catalog") {
            NavigationLink {
                ExerciseCatalogManagerView()
            } label: {
                Label("Manage Exercises", systemImage: "books.vertical")
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            Button {
                AppLogger.shared.log("Settings → View debug log tapped", category: "ui")
                showDebugLog = true
            } label: {
                Label("View debug log", systemImage: "doc.text")
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            HStack {
                Label("Log file", systemImage: "folder")
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(AppLogger.shared.logFileURL.lastPathComponent)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Label("Version", systemImage: "app.badge")
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Text(Changelog.versionLabel)
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            NavigationLink {
                ChangelogView()
            } label: {
                Label("Changelog", systemImage: "list.bullet.clipboard")
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            HStack {
                Label("Created by", systemImage: "person.fill")
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                Text("Abhay Gulati")
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
    }

    private var resetSection: some View {
        Section {
            destructiveRow("Factory reset (everything)", systemImage: "exclamationmark.triangle.fill") {
                AppLogger.shared.log("Settings → Factory reset tapped (step 1)", category: "ui")
                factoryConfirmStep = .first
            }
        } header: {
            Text("Reset")
        } footer: {
            Text("Two-step confirmation. Wipes scheduled workouts, sessions, InBody scans, and the debug log.")
                .font(Theme.Fonts.body(11))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // MARK: - Helpers

    private func destructiveRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.red)
        }
    }

    private func perform(_ action: ClearAction) {
        switch action {
        case .thisWeek:
            AppLogger.shared.log("Settings: confirmed → clearActiveWeek", category: "data")
            WeekScheduler.clearActiveWeek(context: context)
        case .allScheduled:
            AppLogger.shared.log("Settings: confirmed → clearAllScheduled", category: "data")
            WeekScheduler.clearAllScheduled(context: context)
        case .allSessions:
            AppLogger.shared.log("Settings: confirmed → clearAllSessions", category: "data")
            DataReset.clearAllSessions(context: context)
        case .allInBody:
            AppLogger.shared.log("Settings: confirmed → clearAllInBody", category: "data")
            DataReset.clearAllInBody(context: context)
        }
    }

    private func stepBinding(_ step: FactoryStep) -> Binding<Bool> {
        Binding(
            get: { factoryConfirmStep == step },
            set: { presented in
                // Only react to dismiss-to-false. Never reset on a true→false
                // sequence we caused ourselves by transitioning to the next
                // step (the .second alert binding handles its own true).
                if !presented && factoryConfirmStep == step {
                    factoryConfirmStep = .idle
                }
            }
        )
    }
}

// MARK: - SessionListView

/// Browse + swipe-delete every `WorkoutSession`. Sorted newest-first.
struct SessionListView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutSession.startedAt, ascending: false)]
    ) private var sessions: FetchedResults<WorkoutSession>

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("No logged sessions yet.")
                    .font(Theme.Fonts.body(14))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .listRowBackground(Theme.Colors.surface)
            } else {
                ForEach(sessions, id: \.objectID) { session in
                    SessionRow(session: session)
                        .listRowBackground(Theme.Colors.surface)
                }
                .onDelete(perform: delete)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            AppLogger.shared.log("SessionListView appeared (\(sessions.count) sessions)", category: "ui")
        }
    }

    private func delete(at offsets: IndexSet) {
        var datesTouched: [Date] = []
        for idx in offsets {
            let s = sessions[idx]
            AppLogger.shared.log("swipe-delete session \(s.workoutName ?? "?") started=\(s.startedAt.map(ISO8601DateFormatter().string(from:)) ?? "nil")", category: "data")
            if let started = s.startedAt { datesTouched.append(started) }
            context.delete(s)
        }
        // After deletion, the WorkoutDay for the same calendar day might still
        // be flagged completed. Recompute now so the carousel reflects reality.
        for d in datesTouched {
            DataReset.recomputeDayCompletion(forDay: d, context: context)
        }
        do {
            try context.save()
            AppLogger.shared.log("session swipe-delete save OK", category: "data")
        } catch {
            AppLogger.shared.log("session swipe-delete save FAILED: \(error)", category: "data")
        }
    }
}

private struct SessionRow: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.workoutName ?? "Workout")
                    .font(Theme.Fonts.header(14))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                if let start = session.startedAt {
                    Text(dateLabel(start))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text(elapsedLabel)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("•")
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text("\(setCount) sets")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var setCount: Int {
        (session.sets as? Set<LoggedSet>)?.count ?? 0
    }

    private var elapsedLabel: String {
        guard let start = session.startedAt else { return "—" }
        let end = session.finishedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Debug log sheet (shared)

/// Lifted out of WorkoutView so SettingsView can present the same sheet.
/// File-private name to avoid collisions with the legacy copy in WorkoutView.
struct DebugLogSheet: View {
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if logger.lines.isEmpty {
                            Text("(no events yet — interact with the app to populate)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .padding()
                        } else {
                            ForEach(Array(logger.lines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .padding(Theme.Spacing.md)
                }
                .onAppear {
                    if let lastIdx = logger.lines.indices.last {
                        proxy.scrollTo(lastIdx, anchor: .bottom)
                    }
                }
            }
            .background(Theme.Colors.background.ignoresSafeArea())
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { logger.clear() }
                        .disabled(logger.lines.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ShareLink(item: logger.logFileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
