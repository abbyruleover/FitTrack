import SwiftUI

@main
struct FitTrackApp: App {
    private let persistence = PersistenceController.shared

    init() {
        // Install crash handlers FIRST so any subsequent crash gets a final
        // line in debug.log — including a crash inside ReminderService
        // authorization or HealthKit setup.
        AppLogger.shared.installCrashHandlers()
        AppLogger.shared.log("FitTrackApp launched (build=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"))", category: "lifecycle")
        // Ask for notification permission once on first launch. Idempotent —
        // the system caches the user's choice and never re-prompts.
        ReminderService.requestAuthorizationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
