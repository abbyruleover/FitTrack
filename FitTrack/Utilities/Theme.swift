import SwiftUI

/// Centralized colors, fonts, and spacing for FitTrack.
/// Source of truth for the visual design — never hardcode hex values in views.
enum Theme {
    enum Colors {
        // Surface palette — matches the FNS FitTrack mockup dark theme.
        static let background = Color(red: 0x0C / 255, green: 0x0C / 255, blue: 0x0E / 255)
        static let surface = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255)
        static let surfaceElevated = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x22 / 255)
        static let border = Color.white.opacity(0.08)

        // Text.
        static let textPrimary = Color(red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255)
        static let textSecondary = Color.white.opacity(0.65)
        static let textTertiary = Color.white.opacity(0.4)

        // Accents from the mockup.
        static let accent = Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)   // lime
        static let orange = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x35 / 255)
        static let blue = Color(red: 0x47 / 255, green: 0xB8 / 255, blue: 0xFF / 255)
        static let green = Color(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255)
        static let purple = Color.purple
        static let teal = Color.teal
        static let pink = Color(red: 0xFF / 255, green: 0x4D / 255, blue: 0x8D / 255)
    }

    enum Fonts {
        // Phase 1 uses system fonts. Custom fonts (Bebas Neue, DM Sans, DM Mono)
        // will be wired up in Phase 3 when we add charts/typography polish.
        static func header(_ size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .default)
        }
        static func body(_ size: CGFloat = 15) -> Font {
            .system(size: size, weight: .regular, design: .default)
        }
        static func mono(_ size: CGFloat = 15) -> Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }
}

/// Strings used in chrome (tab labels, nav titles). Keeps view code free of magic strings.
enum AppStrings {
    enum Tabs {
        static let home = "Home"
        static let progress = "Progress"
        static let body = "Body"
        static let settings = "Settings"
    }

    /// Pool the Home welcome card cycles through one-per-day. Picked
    /// deterministically by `dayOfYear % count` so the same line stays put
    /// from morning to night and rotates fresh tomorrow. Twelve entries means
    /// a tagline doesn't repeat within ~a week and a half.
    static let motivationalTaglines: [String] = [
        "Strong every day",
        "Earn your rest day",
        "Show up. Sets handle themselves.",
        "Today's reps, tomorrow's gains",
        "Nothing wasted by trying",
        "Form first, weight second",
        "You vs you",
        "Slow is smooth, smooth is heavy",
        "Quiet work, loud results",
        "One more set",
        "Discipline > motivation",
        "Move well, then move much"
    ]
}
