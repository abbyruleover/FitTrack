import SwiftUI

/// Shared empty-state used by Phase 1 tab placeholders.
struct PlaceholderContent: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Theme.Colors.accent)

                Text(title)
                    .font(Theme.Fonts.header(28))
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(subtitle)
                    .font(Theme.Fonts.body(15))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
        }
    }
}

#Preview {
    PlaceholderContent(
        icon: "house.fill",
        title: "Workout",
        subtitle: "Phase 1 placeholder."
    )
}
