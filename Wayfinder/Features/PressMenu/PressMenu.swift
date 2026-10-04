import SwiftUI
import UIKit

/// One row in a press-and-slide menu.
struct PressMenuItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    var isEnabled = true
    var isProminent = false
    let action: @MainActor () -> Void
}

/// A small pop-up menu you open by pressing and holding, slide your finger to a row, and lift
/// to choose. If you lift without sliding, it stays open and rows can be tapped.
/// Used by the TRIP button and the map. Positions are in global (window) coordinates.
@MainActor
final class PressMenuModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var title: String?
    @Published private(set) var items: [PressMenuItem] = []
    @Published private(set) var origin: CGPoint = .zero
    @Published private(set) var highlightedID: String?
    /// Where the menu grows from, for the open animation.
    @Published private(set) var growAnchor: UnitPoint = .bottom

    /// Frame of the full-screen overlay, set by `PressMenuOverlay`.
    var container: CGRect = .zero

    enum Alignment { case leading, center, trailing }

    static let width: CGFloat = 260
    static let rowHeight: CGFloat = 48
    static let headerHeight: CGFloat = 32
    static let padding: CGFloat = 6

    private let selection = UISelectionFeedbackGenerator()

    var size: CGSize {
        CGSize(width: Self.width, height: (title == nil ? 0 : Self.headerHeight) + CGFloat(items.count) * Self.rowHeight + Self.padding * 2)
    }

    /// Shows the menu next to `anchor`, above it when there's room (thumbs cover what's below).
    func present(title: String?, items: [PressMenuItem], at anchor: CGPoint, alignment: Alignment = .center) {
        self.title = title
        self.items = items
        highlightedID = nil
        let bounds = container == .zero ? CGRect(x: 0, y: 0, width: 400, height: 900) : container
        let size = self.size
        var x: CGFloat
        switch alignment {
        case .trailing: x = anchor.x - size.width + 32
        case .leading: x = anchor.x - 32
        case .center: x = anchor.x - size.width / 2
        }
        x = min(max(x, bounds.minX + 12), bounds.maxX - size.width - 12)
        var y = anchor.y - size.height - 24
        growAnchor = .bottom
        if y < bounds.minY + 60 {
            y = anchor.y + 24
            growAnchor = .top
        }
        y = min(max(y, bounds.minY + 60), bounds.maxY - size.height - 12)
        origin = CGPoint(x: x, y: y)
        selection.prepare()
        isPresented = true
    }

    func updateTitle(_ title: String) {
        guard isPresented else { return }
        self.title = title
    }

    /// Frame of a row in global coordinates.
    func rowFrame(_ index: Int) -> CGRect {
        CGRect(
            x: origin.x,
            y: origin.y + Self.padding + (title == nil ? 0 : Self.headerHeight) + CGFloat(index) * Self.rowHeight,
            width: Self.width,
            height: Self.rowHeight
        )
    }

    /// Finger moved: highlight the row under it.
    func track(_ point: CGPoint) {
        guard isPresented else { return }
        let hit = items.indices.first { rowFrame($0).insetBy(dx: -24, dy: 0).contains(point) && items[$0].isEnabled }
        let id = hit.map { items[$0].id }
        if id != highlightedID {
            highlightedID = id
            if id != nil { selection.selectionChanged() }
        }
    }

    /// Finger lifted: choose the highlighted row, or stay open for a tap.
    func release(at point: CGPoint) {
        track(point)
        guard let id = highlightedID, let item = items.first(where: { $0.id == id }) else { return }
        choose(item)
    }

    func choose(_ item: PressMenuItem) {
        guard item.isEnabled else { return }
        dismiss()
        Theme.Haptics.light()
        item.action()
    }

    func dismiss() {
        isPresented = false
        highlightedID = nil
    }
}

/// Full-screen layer that draws the menu. Put it last in the root ZStack.
struct PressMenuOverlay: View {
    @ObservedObject var menu: PressMenuModel

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ZStack(alignment: .topLeading) {
                if menu.isPresented {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { menu.dismiss() }
                        .transition(.opacity)
                    card
                        .offset(x: menu.origin.x - frame.minX, y: menu.origin.y - frame.minY)
                        .transition(.scale(scale: 0.8, anchor: menu.growAnchor).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { menu.container = frame }
            .onChange(of: frame) { _, new in menu.container = new }
        }
        .ignoresSafeArea()
        .allowsHitTesting(menu.isPresented)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: menu.isPresented)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = menu.title {
                Text(title)
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(height: PressMenuModel.headerHeight, alignment: .leading)
            }
            ForEach(menu.items) { item in
                Button { menu.choose(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
            }
        }
        .padding(.vertical, PressMenuModel.padding)
        .frame(width: PressMenuModel.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.menu))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
    }

    private func row(_ item: PressMenuItem) -> some View {
        let highlighted = menu.highlightedID == item.id
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: item.icon)
                .frame(width: 24)
                .foregroundStyle(highlighted ? Color.white : (item.isProminent ? Theme.Colors.accent : Theme.Colors.textPrimary))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(Theme.Fonts.body.weight(item.isProminent ? .semibold : .regular)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption2).lineLimit(1)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Theme.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? Color.white : Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: PressMenuModel.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(highlighted ? Theme.Colors.accent : Color.clear)
                .padding(.horizontal, Theme.Spacing.xs)
        )
        .contentShape(Rectangle())
        .opacity(item.isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}
