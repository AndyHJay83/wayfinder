import SwiftData
import SwiftUI

/// The round TRIP button. Tap: the trip's stops (or the menu when there's no trip yet).
/// Press and hold: saved destinations, plus "Create New Destination" for the place you
/// just searched. Slide to a row and lift to choose it.
struct TripButton: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var saved: [SavedPlace]

    @State private var frame: CGRect = .zero
    @State private var pressing = false
    @State private var openedByHold = false
    @State private var holdTask: Task<Void, Never>?
    @State private var naming: Place?
    @State private var newName = ""

    var body: some View {
        Text("TRIP")
            .font(Theme.Fonts.tripButton)
            .foregroundStyle(.white)
            .frame(width: Theme.Size.tripButton, height: Theme.Size.tripButton)
            .background(Circle().fill(Theme.Colors.tripButton))
            .overlay(alignment: .topTrailing) { badge }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .scaleEffect(pressing ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
            })
            .gesture(pressGesture)
            .accessibilityElement()
            .accessibilityLabel("Trip")
            .accessibilityHint("Touch and hold for saved destinations.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .accessibilityAction(named: "Saved destinations") { openMenu() }
            .alert("Name this destination", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("e.g. Sam's house", text: $newName)
                Button("Save") { saveNamed() }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                Text(naming?.subtitle ?? naming?.name ?? "")
            }
    }

    @ViewBuilder
    private var badge: some View {
        let stops = app.trip.items.count
        if stops > 1 {
            Text("\(stops)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Circle().fill(Theme.Colors.danger))
        }
    }

    /// One drag gesture handles tap, hold and slide, so the finger can go straight from
    /// the button onto a menu row without lifting.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !pressing {
                    pressing = true
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, pressing else { return }
                        openedByHold = true
                        Theme.Haptics.medium()
                        openMenu()
                    }
                } else if openedByHold {
                    app.pressMenu.track(value.location)
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                if openedByHold {
                    app.pressMenu.release(at: value.location)
                } else if hypot(value.translation.width, value.translation.height) < 24 {
                    tap()
                }
                pressing = false
                openedByHold = false
            }
    }

    private func tap() {
        if app.pressMenu.isPresented {
            app.pressMenu.dismiss()
        } else if app.trip.isEmpty {
            openMenu()
        } else {
            app.sheet = .tripBuilder
        }
    }

    private func openMenu() {
        let model = app
        var items: [PressMenuItem] = saved.prefix(8).map { place in
            let target = place.asPlace
            return PressMenuItem(
                id: "saved-\(place.uuid)",
                title: place.name,
                subtitle: app.trip.isEmpty ? nil : "Add on the way",
                icon: place.icon
            ) {
                model.useSavedDestination(target)
            }
        }
        if let searched = app.selectedPlace, searched.source != .saved {
            items.append(PressMenuItem(
                id: "create",
                title: "Create New Destination",
                subtitle: searched.name,
                icon: "plus.circle.fill",
                isProminent: true
            ) {
                newName = ""
                naming = searched
            })
        } else if saved.isEmpty {
            items.append(PressMenuItem(
                id: "hint", title: "No saved destinations yet",
                subtitle: "Search for a place, then hold TRIP", icon: "info.circle", isEnabled: false
            ) {})
        }
        if !app.trip.isEmpty {
            items.append(PressMenuItem(id: "stops", title: "Trip stops", icon: "list.bullet") {
                model.sheet = .tripBuilder
            })
        }
        app.pressMenu.present(
            title: saved.isEmpty ? nil : "Saved destinations",
            items: items,
            at: CGPoint(x: frame.midX, y: frame.minY),
            alignment: .trailing
        )
    }

    private func saveNamed() {
        guard let place = naming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        naming = nil
        guard !name.isEmpty else { return }
        context.insert(SavedPlace(name: name, coordinate: place.coordinate, note: place.subtitle ?? "", icon: "mappin"))
        app.statusMessage = "Saved \(name) to your destinations"
        Theme.Haptics.success()
    }
}
