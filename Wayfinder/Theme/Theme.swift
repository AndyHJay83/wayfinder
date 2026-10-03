import SwiftUI
import UIKit

/// All colours, fonts, spacing and radii live here so a new design can be dropped in
/// without touching view logic.
enum Theme {
    enum Colors {
        static let accent = Color.accentColor
        static let background = Color(.systemBackground)
        static let surface = Color(.secondarySystemBackground)
        static let surfaceElevated = Color(.tertiarySystemBackground)
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let positive = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let chipArmed = Color.accentColor
        static let chipIdle = Color(.secondarySystemBackground)
        static let favourite = Color.yellow

        static let stopPin = UIColor.systemRed
        static let viaPin = UIColor.systemPurple
        static let savedPin = UIColor.systemYellow
        static let resultPin = UIColor.systemBlue

        /// Temporary sketch line while drawing.
        static let sketchStroke = UIColor.systemPink.withAlphaComponent(0.85)
        /// Rubber-band preview while dragging the route.
        static let dragPreview = UIColor.systemPurple.withAlphaComponent(0.7)
        static let walkingLeg = UIColor.systemTeal
    }

    enum Fonts {
        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let price = Font.system(.headline, design: .rounded).monospacedDigit()
        static let eta = Font.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 16
        static let card: CGFloat = 14
        static let button: CGFloat = 12
    }

    enum Line {
        static let sketchWidth: CGFloat = 5
        static let dragPreviewWidth: Double = 4
        static let walkingWidth: Double = 4
    }

    enum Haptics {
        static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

extension View {
    /// Standard floating card look used across overlays.
    func cardStyle() -> some View {
        self
            .padding(Theme.Spacing.m)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
