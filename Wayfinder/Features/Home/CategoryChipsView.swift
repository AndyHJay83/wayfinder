import SwiftUI

/// Chips from `PlaceCategory.all`. Tap arms the chip for the next trip; long press opens a
/// sheet of local places for that category.
struct CategoryChipsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(PlaceCategory.all) { category in
                    CategoryChip(category: category, isArmed: app.isArmed(category))
                        .onTapGesture { app.toggleArmed(category) }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            Theme.Haptics.light()
                            app.sheet = .localPlaces(category)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Tap to add to your next trip. Touch and hold to see places nearby.")
                }
            }
        }
    }
}

struct CategoryChip: View {
    let category: PlaceCategory
    let isArmed: Bool

    var body: some View {
        Label(category.displayName, systemImage: category.iconName)
            .font(Theme.Fonts.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .foregroundStyle(isArmed ? Color.white : Theme.Colors.textPrimary)
            .background(
                Capsule().fill(isArmed ? AnyShapeStyle(Theme.Colors.chipArmed) : AnyShapeStyle(.regularMaterial))
            )
            .overlay(Capsule().strokeBorder(isArmed ? Color.clear : Color.secondary.opacity(0.2)))
    }
}
