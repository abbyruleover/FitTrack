import SwiftUI
import HealthKit

/// Hero Activity rings card used at the top of the Home tab. Three concentric
/// Move/Exercise/Stand rings on the left, ring legend on the right, the whole
/// surface tappable → opens the system Health app at Summary (which leads with
/// the Activity ring at the top). Apple's `HKActivityRingView` is UIKit-only
/// and awkward to embed in SwiftUI, so we redraw with `Canvas`.
///
/// This was lifted out of the deleted HealthView so Home — and any future
/// dashboard surface — can reuse the rings without dragging the rest of that
/// screen along.
struct ActivityRingsCard: View {
    let summary: HKActivitySummary?

    var body: some View {
        let move = summary?.activeEnergyBurned.doubleValue(for: .kilocalorie()) ?? 0
        let moveGoal = summary?.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()) ?? 0
        let exercise = summary?.appleExerciseTime.doubleValue(for: .minute()) ?? 0
        let exerciseGoal = summary?.exerciseTimeGoal?.doubleValue(for: .minute()) ?? summary?.appleExerciseTimeGoal.doubleValue(for: .minute()) ?? 0
        let stand = summary?.appleStandHours.doubleValue(for: .count()) ?? 0
        let standGoal = summary?.standHoursGoal?.doubleValue(for: .count()) ?? summary?.appleStandHoursGoal.doubleValue(for: .count()) ?? 0

        return Button {
            openFitness()
        } label: {
            HStack(spacing: Theme.Spacing.lg) {
                ActivityRings(
                    movePct: ringFraction(move, goal: moveGoal),
                    exercisePct: ringFraction(exercise, goal: exerciseGoal),
                    standPct: ringFraction(stand, goal: standGoal)
                )
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("FITNESS")
                            .font(Theme.Fonts.mono(9))
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    ringLegend(color: .red,
                               label: "Move",
                               value: "\(Int(move))",
                               unit: moveGoal > 0 ? "/\(Int(moveGoal)) cal" : "cal")
                    ringLegend(color: .green,
                               label: "Exercise",
                               value: "\(Int(exercise))",
                               unit: exerciseGoal > 0 ? "/\(Int(exerciseGoal)) min" : "min")
                    ringLegend(color: .cyan,
                               label: "Stand",
                               value: "\(Int(stand))",
                               unit: standGoal > 0 ? "/\(Int(standGoal)) hr" : "hr")
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tries the Apple Fitness URL scheme first (`x-apple-fitness://`), then
    /// the legacy `fitness://` host, and finally falls back to the Health app
    /// at the Summary tab (which leads with the Activity ring at the top).
    /// We deliberately avoid the App Store fallback — opening a "Get Fitness"
    /// landing page on a device that already has Fitness installed is worse
    /// UX than just opening Health, which always works since Health ships
    /// with iOS. `LSApplicationQueriesSchemes` in Info.plist must include
    /// each scheme we probe for `canOpenURL` to return true on iOS 17+.
    private func openFitness() {
        let candidates: [(scheme: String, url: String)] = [
            ("x-apple-fitness", "x-apple-fitness://"),
            ("fitness", "fitness://"),
            ("x-apple-health", "x-apple-health://")
        ]
        for c in candidates {
            guard let url = URL(string: c.url),
                  UIApplication.shared.canOpenURL(url) else { continue }
            UIApplication.shared.open(url)
            AppLogger.shared.log("opened \(c.scheme):// for activity rings", category: "ui")
            return
        }
        AppLogger.shared.log("no Fitness/Health scheme reachable — tap was a no-op", category: "ui")
    }

    private func ringFraction(_ value: Double, goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return value / goal
    }

    private func ringLegend(color: Color, label: String, value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text(label)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer(minLength: 4)
            Text(value)
                .font(Theme.Fonts.header(15))
                .foregroundStyle(color)
            Text(unit)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }
}

/// Three concentric Move/Exercise/Stand rings drawn with `Canvas`. Mirrors
/// Apple's Fitness app behavior:
///  - vibrant ring colors (red / green / cyan) on a dimmed track,
///  - lap-stacking when fraction > 1 (each completed lap stays nearly full
///    opacity; Apple barely fades stacked loops),
///  - a small chevron arrowhead + dark cap shadow at the leading edge of
///    any lapped ring, so the eye reads "this loop is sitting on top."
private struct ActivityRings: View {
    let movePct: Double
    let exercisePct: Double
    let standPct: Double

    var body: some View {
        Canvas { ctx, size in
            let lineWidth: CGFloat = 12
            let gap: CGFloat = 4
            let outer = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth/2, dy: lineWidth/2)
            let middle = outer.insetBy(dx: lineWidth + gap, dy: lineWidth + gap)
            let inner = middle.insetBy(dx: lineWidth + gap, dy: lineWidth + gap)

            ring(in: ctx, rect: outer, color: .red, fraction: movePct, lineWidth: lineWidth)
            ring(in: ctx, rect: middle, color: .green, fraction: exercisePct, lineWidth: lineWidth)
            ring(in: ctx, rect: inner, color: .cyan, fraction: standPct, lineWidth: lineWidth)
        }
    }

    private func ring(in ctx: GraphicsContext, rect: CGRect, color: Color, fraction: Double, lineWidth: CGFloat) {
        let track = Path(ellipseIn: rect)
        ctx.stroke(track, with: .color(color.opacity(0.2)),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        guard fraction > 0 else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let laps = Int(floor(fraction))
        let partial = fraction - Double(laps)

        // Full laps stack, only slightly dimmer per lap so 4-lap days still
        // feel vibrant — Apple's ring stays near-opaque even at 5+ laps.
        for lap in 0..<laps {
            var fullLap = Path()
            fullLap.addArc(center: center, radius: radius,
                           startAngle: .degrees(-90), endAngle: .degrees(270),
                           clockwise: false)
            let dim = max(0.55, 1.0 - 0.10 * Double(lap))
            ctx.stroke(fullLap, with: .color(color.opacity(dim)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }

        if partial > 0 {
            var arc = Path()
            arc.addArc(center: center, radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * partial),
                       clockwise: false)
            ctx.stroke(arc, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            let endAngleDeg = -90.0 + 360.0 * partial
            let r = endAngleDeg * .pi / 180.0
            let capX = center.x + radius * CGFloat(cos(r))
            let capY = center.y + radius * CGFloat(sin(r))

            if laps >= 1 {
                // Dark disc shadow under the cap so the leading edge looks
                // raised over the loop it's lapping.
                let shadowR = lineWidth * 0.55
                let shadow = Path(ellipseIn: CGRect(x: capX - shadowR,
                                                    y: capY - shadowR,
                                                    width: shadowR * 2,
                                                    height: shadowR * 2))
                ctx.fill(shadow, with: .color(.black.opacity(0.45)))

                // Chevron arrowhead pointing forward along the arc tangent.
                // Two short segments meeting at a tip just inside the cap.
                // tx,ty = forward tangent; nx,ny = outward radius normal.
                let tx = -sin(r), ty = cos(r)
                let nx = cos(r),  ny = sin(r)
                let armLen = lineWidth * 0.32
                let tipPush = lineWidth * 0.18
                let tip = CGPoint(x: capX + CGFloat(tx) * tipPush,
                                  y: capY + CGFloat(ty) * tipPush)
                let arm1 = CGPoint(x: tip.x - CGFloat(tx) * armLen + CGFloat(nx) * armLen * 0.6,
                                   y: tip.y - CGFloat(ty) * armLen + CGFloat(ny) * armLen * 0.6)
                let arm2 = CGPoint(x: tip.x - CGFloat(tx) * armLen - CGFloat(nx) * armLen * 0.6,
                                   y: tip.y - CGFloat(ty) * armLen - CGFloat(ny) * armLen * 0.6)
                var chev = Path()
                chev.move(to: arm1); chev.addLine(to: tip); chev.addLine(to: arm2)
                ctx.stroke(chev, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
