import Foundation

/// Computes a tight, padded Y-axis domain for trend charts so the line
/// shape is readable. Swift Charts' default behavior anchors the domain at
/// 0, which flattens body-weight / SMM / BMI trends — a 1.5 lb week-over-
/// week change looks like a flat line when the axis spans 0-200.
///
/// Usage: `.chartYScale(domain: ChartDomain.padded(values: dataPoints))`
enum ChartDomain {
    /// Pads ±10% of the data span around min/max, with a floor on the span
    /// so a single point or near-flat data doesn't collapse the y-axis to
    /// a zero-height range. Negative values are allowed — for body metrics
    /// the data is always positive but the helper doesn't enforce that
    /// (BMR / weight / BF% never realistically dip below 0 in practice).
    static func padded(values: [Double], minSpan: Double = 1.0) -> ClosedRange<Double> {
        guard let mn = values.min(), let mx = values.max() else {
            return 0...1
        }
        let rawSpan = mx - mn
        let span = max(rawSpan, minSpan)
        let pad = span * 0.15
        let lo = mn - pad
        let hi = mx + pad
        guard lo < hi else { return (lo - 1)...(hi + 1) }
        return lo...hi
    }
}
