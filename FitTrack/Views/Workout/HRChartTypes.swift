import Foundation
import SwiftUI

/// Shared types for the HR chart family. Promoted to top-level so both the
/// inline `SessionHRTraceChart` (on UnifiedSessionView) and the push-screen
/// `HRStationChartView` consume the same `HRPoint`/`Station` model — there
/// used to be two separate definitions and they drifted.
enum HRChartTypes {}

/// One Y-value per timestamp. Identifiable for SwiftUI Charts identity stability.
struct HRPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

/// Class-structured time band laid behind the HR trace. `isPrimary` filters
/// what the legend lists (rests render as faint bands but don't get a row).
struct Station: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let start: Date
    let end: Date
    let tint: Color
    let isPrimary: Bool
}
