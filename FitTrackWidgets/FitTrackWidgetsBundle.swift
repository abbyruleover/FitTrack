import SwiftUI
import WidgetKit

/// Entry point for the FitTrack widget extension. Currently just hosts the
/// workout Live Activity — home-screen widgets can be added here later.
@main
struct FitTrackWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        WeeklyHeatmapWidget()
        ProgressSparklineWidget()
    }
}
