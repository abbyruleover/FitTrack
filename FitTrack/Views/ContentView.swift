import SwiftUI

/// One typed identifier per tab. Hoisted to the root so child views can flip
/// the tab from a button (e.g., a card on Home that conceptually belongs to
/// the Body tab).
enum AppTab: Hashable {
    case home
    case progress
    case body
    case settings

    /// Short label shown on the trailing edge of a section header to hint
    /// the destination tab when the section is tappable.
    var shortLabel: String {
        switch self {
        case .home:     return AppStrings.Tabs.home
        case .progress: return AppStrings.Tabs.progress
        case .body:     return AppStrings.Tabs.body
        case .settings: return AppStrings.Tabs.settings
        }
    }
}

/// Root tab container. Four tabs after the Phase 5 restructure:
/// Home (rings + this-week schedule + today's training), Progress (this-week
/// HK tiles + counts + calendar + exercises), Body (InBody trends + import),
/// Settings.
///
/// Also owns the cross-tab session affordances:
///  - the floating `MinimizedSessionPill` shown above the tab bar whenever a
///    workout is recording but minimized,
///  - the full-screen cover that re-presents `WorkoutSessionView` either on
///    fresh start or on mini-pill tap-to-resume.
struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var selection: AppTab = .home
    @ObservedObject private var sessionService = ActiveSessionService.shared

    var body: some View {
        TabView(selection: $selection) {
            WorkoutView()
                .tag(AppTab.home)
                .tabItem {
                    Label(AppStrings.Tabs.home, systemImage: "house.fill")
                }

            ProgressView()
                .tag(AppTab.progress)
                .tabItem {
                    Label(AppStrings.Tabs.progress, systemImage: "chart.line.uptrend.xyaxis")
                }

            BodyView()
                .tag(AppTab.body)
                .tabItem {
                    Label(AppStrings.Tabs.body, systemImage: "figure.arms.open")
                }

            NavigationStack {
                SettingsView()
            }
            .tag(AppTab.settings)
            .tabItem {
                Label(AppStrings.Tabs.settings, systemImage: "gearshape.fill")
            }
        }
        .tint(Theme.Colors.accent)
        .safeAreaInset(edge: .bottom) {
            // Sits above the tab bar when minimized; collapses entirely
            // when no session is active or the cover is up.
            MinimizedSessionPill(service: sessionService)
                .animation(.easeInOut(duration: 0.2), value: sessionService.current != nil)
                .animation(.easeInOut(duration: 0.2), value: sessionService.isPresentingSession)
        }
        .fullScreenCover(isPresented: $sessionService.isPresentingSession) {
            // Pull the workout shape from the live session — the store holds
            // the parsed sections so the view can re-render after minimize.
            if let store = sessionService.current {
                WorkoutSessionView(workout: store.parsedWorkout)
                    .environment(\.managedObjectContext, context)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
