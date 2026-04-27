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
                .withMinimizedSessionPill(service: sessionService)
                .tag(AppTab.home)
                .tabItem {
                    Label(AppStrings.Tabs.home, systemImage: "house.fill")
                }

            ProgressView()
                .withMinimizedSessionPill(service: sessionService)
                .tag(AppTab.progress)
                .tabItem {
                    Label(AppStrings.Tabs.progress, systemImage: "chart.line.uptrend.xyaxis")
                }

            BodyView()
                .withMinimizedSessionPill(service: sessionService)
                .tag(AppTab.body)
                .tabItem {
                    Label(AppStrings.Tabs.body, systemImage: "figure.arms.open")
                }

            NavigationStack {
                SettingsView()
            }
            .withMinimizedSessionPill(service: sessionService)
            .tag(AppTab.settings)
            .tabItem {
                Label(AppStrings.Tabs.settings, systemImage: "gearshape.fill")
            }
        }
        .tint(Theme.Colors.accent)
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

/// Inserts the `MinimizedSessionPill` into the tab's own safe area so it
/// sits *above* the tab bar instead of being painted on top of it.
///
/// Why per-tab instead of once on the TabView:
/// `safeAreaInset(.bottom)` on a TabView in iOS 17 places its inset content
/// inside the tab-bar zone — the inset visually overlaps the tab labels (we
/// shipped that bug in v0.6.5). Applying the inset to each tab's content
/// view instead anchors the pill above the tab bar, mirroring how Apple
/// Music/Podcasts position the now-playing bar.
private struct MinimizedSessionPillModifier: ViewModifier {
    @ObservedObject var service: ActiveSessionService

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            MinimizedSessionPill(service: service)
                .animation(.easeInOut(duration: 0.2), value: service.current != nil)
                .animation(.easeInOut(duration: 0.2), value: service.isPresentingSession)
        }
    }
}

extension View {
    fileprivate func withMinimizedSessionPill(service: ActiveSessionService) -> some View {
        modifier(MinimizedSessionPillModifier(service: service))
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
