import SwiftUI
import CoreData

/// Post-Finish summary screen pushed onto the session navigation stack. Plays
/// a brief confetti burst, then renders a stats card (elapsed time, total
/// volume, set count) and an exercise breakdown. "Done" pops back two levels
/// so the user lands on `WorkoutDetailView` in its green Completed state.
struct SessionSummaryView: View {
    let sessionID: NSManagedObjectID

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var session: WorkoutSession?
    @State private var confettiTrigger = false
    @State private var insights: SessionInsights.Bundle = .init(
        weightPRs: [], repPRs: [], volume: nil, streakMilestone: nil
    )

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    headerCard
                    SessionInsightsCallouts(bundle: insights)
                    statsRow
                    if let session, !((session.sets as? Set<LoggedSet>)?.isEmpty ?? true) {
                        SessionExerciseBreakdown(session: session)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xl + 64)
            }

            // Confetti sits above content but below safeAreaInset.
            ConfettiOverlay(trigger: confettiTrigger)
                .allowsHitTesting(false)
        }
        .navigationTitle("Workout Complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Button {
                AppLogger.shared.log("SessionSummary Done tapped — popping to detail", category: "ui")
                dismiss()
            } label: {
                Text("Done")
                    .font(Theme.Fonts.header(16))
                    .foregroundStyle(Theme.Colors.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm + 4)
                    .background(Capsule().fill(Theme.Colors.accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)
            .background(Theme.Colors.background.opacity(0.95).ignoresSafeArea(edges: .bottom))
        }
        .onAppear {
            session = (try? context.existingObject(with: sessionID)) as? WorkoutSession
            if let session {
                insights = SessionInsights.compute(for: session, in: context)
            }
            AppLogger.shared.log("SessionSummary appeared — sets=\(loggedSets.count) volume=\(Int(totalVolume)) callouts=\(insights.weightPRs.count + insights.repPRs.count + (insights.volume != nil ? 1 : 0) + (insights.streakMilestone != nil ? 1 : 0))", category: "ui")
            // Tiny delay so the spring/confetti animation reads as deliberate
            // instead of fighting the navigation push.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                confettiTrigger = true
            }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Theme.Colors.green)
            Text(session?.workoutName ?? "Workout")
                .font(Theme.Fonts.header(22))
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(dateLabel)
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.green.opacity(0.4), lineWidth: 1)
        )
    }

    private var statsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            statTile(label: "Time", value: elapsedLabel, suffix: nil)
            statTile(label: "Volume", value: format(totalVolume), suffix: "lbs")
            statTile(label: "Sets", value: "\(loggedSets.count)", suffix: nil)
        }
    }

    private func statTile(label: String, value: String, suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.Fonts.header(18))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let suffix {
                    Text(suffix)
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.surface)
        )
    }

    // MARK: - Derived stats

    private var loggedSets: [LoggedSet] {
        guard let session, let raw = session.sets as? Set<LoggedSet> else { return [] }
        return raw.sorted { lhs, rhs in
            let l = lhs.completedAt ?? Date.distantPast
            let r = rhs.completedAt ?? Date.distantPast
            if l != r { return l < r }
            return lhs.setIndex < rhs.setIndex
        }
    }

    private var totalVolume: Double {
        loggedSets.reduce(0) { $0 + $1.weightLbs * Double($1.reps) }
    }

    private var elapsedLabel: String {
        guard let session, let start = session.startedAt else { return "—" }
        let end = session.finishedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d • h:mm a"
        return f.string(from: session?.finishedAt ?? session?.startedAt ?? Date())
    }

    private func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }
}

// MARK: - Confetti

/// Lightweight Canvas-driven confetti emitter. ~80 colored shapes fall from
/// the top with a small horizontal spread. Animates by mutating a published
/// `phase` over 2.5s; once finished, returns an empty view to free GPU work.
private struct ConfettiOverlay: View {
    let trigger: Bool

    private struct Particle: Identifiable {
        let id = UUID()
        let xFraction: CGFloat
        let xDrift: CGFloat
        let rotationStart: Double
        let rotationSpin: Double
        let color: Color
        let size: CGFloat
        let delay: Double
        let fallDuration: Double
    }

    @State private var particles: [Particle] = []
    @State private var startedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { timeline in
            Canvas { ctx, size in
                guard let startedAt else { return }
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                for p in particles {
                    let t = max(0, min(1, (elapsed - p.delay) / p.fallDuration))
                    if t <= 0 { continue }
                    let x = (p.xFraction * size.width) + (p.xDrift * size.width * CGFloat(t))
                    let y = -p.size + (size.height + p.size * 2) * CGFloat(t)
                    let opacity = t < 0.85 ? 1.0 : (1.0 - (t - 0.85) / 0.15)
                    let rotation = Angle(degrees: p.rotationStart + p.rotationSpin * t)
                    let rect = CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: rotation)
                    ctx.opacity = opacity
                    ctx.fill(Path(rect), with: .color(p.color))
                    ctx.opacity = 1
                    ctx.rotate(by: -rotation)
                    ctx.translateBy(x: -x, y: -y)
                }
            }
        }
        .onChange(of: trigger) { _, fire in
            if fire { launch() }
        }
    }

    private var isAnimating: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) < 3.0
    }

    private func launch() {
        let palette: [Color] = [
            Theme.Colors.accent,
            Theme.Colors.green,
            Theme.Colors.orange,
            Theme.Colors.blue,
            .pink,
            .purple,
            .yellow
        ]
        particles = (0..<80).map { _ in
            Particle(
                xFraction: CGFloat.random(in: 0.05...0.95),
                xDrift: CGFloat.random(in: -0.15...0.15),
                rotationStart: Double.random(in: 0...360),
                rotationSpin: Double.random(in: -540...540),
                color: palette.randomElement() ?? Theme.Colors.accent,
                size: CGFloat.random(in: 6...12),
                delay: Double.random(in: 0...0.4),
                fallDuration: Double.random(in: 1.6...2.4)
            )
        }
        startedAt = Date()
    }
}
