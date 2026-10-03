import SwiftData
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var permission: LocationPermission
    @Query(sort: \SavedPlace.createdAt, order: .reverse) private var savedPlaces: [SavedPlace]
    @State private var map: MapController?

    var body: some View {
        ZStack {
            if let map {
                MapViewRepresentable(controller: map)
                    .ignoresSafeArea()
            } else {
                Theme.Colors.surface.ignoresSafeArea()
            }

            if app.isSketching, let map {
                SketchOverlay(map: map)
            }

            VStack(spacing: Theme.Spacing.s) {
                if !app.isSketching {
                    SearchBarButton { app.sheet = .search }
                    CategoryChipsView()
                    if let text = app.armedBannerText {
                        ArmedBanner(text: text) { app.disarmAll() }
                    }
                }
                StatusToast()
                Spacer()
                if !app.isSketching {
                    HStack(alignment: .bottom) {
                        if app.previewRoutes != nil, app.sheet == nil {
                            Button {
                                app.sheet = app.trip.items.count > 1 ? .tripBuilder : .routePreview
                            } label: {
                                Label("Route ready", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                        if let map, !map.isFollowingUser {
                            RecenterButton { map.recenter() }
                        }
                    }
                    HomeToolbar()
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
        }
        .sheet(item: $app.sheet) { sheet in
            SheetContent(sheet: sheet)
        }
        .confirmationDialog(
            app.pendingMapPress?.name ?? "Dropped pin",
            isPresented: Binding(get: { app.pendingMapPress != nil }, set: { if !$0 { app.pendingMapPress = nil } }),
            titleVisibility: .visible,
            presenting: app.pendingMapPress
        ) { place in
            Button("Navigate here") { app.choose(destination: place) }
            Button("Add as stop") { app.addToTrip(place, kind: .stop) }
            Button("Add as via point") { app.addToTrip(place, kind: .via) }
            Button("Save place") { app.sheet = .savePlace(place) }
        }
        .onAppear {
            if map == nil { map = MapController(appModel: app) }
            NavigationEngine.shared.startFreeDrive()
            map?.showSavedPlaces(savedPlaces)
        }
        .onChange(of: savedPlaces) { _, places in
            map?.showSavedPlaces(places)
        }
    }
}

/// Routes each sheet case to its view.
struct SheetContent: View {
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .search:
            SearchView()
        case .routePreview:
            RoutePreviewView()
                .presentationDetents([.height(320), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(320)))
        case .savedPlaces:
            SavedPlacesView()
        case .settings:
            SettingsView()
        case .tripBuilder:
            TripBuilderView()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .savePlace(let place):
            SavePlaceView(place: place)
        case .localPlaces(let category):
            LocalPlacesSheet(category: category)
                .presentationDetents([.fraction(0.35), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
        case .parkNearby(let destination):
            ParkNearbySheet(destination: destination)
                .presentationDetents([.medium, .large])
        case .chainBranches(let chain):
            ChainBranchesView(chain: chain)
                .presentationDetents([.medium, .large])
        case .plannerResult:
            PlannerResultView()
                .presentationDetents([.medium, .large])
        }
    }
}

struct SearchBarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "magnifyingglass")
                Text("Where to?")
                Spacer()
            }
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(Theme.Spacing.m)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Spacing.s)
    }
}

struct RecenterButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Recenter on my location")
    }
}

struct ArmedBanner: View {
    let text: String
    let onCancel: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.chipArmed)
            Text(text).font(Theme.Fonts.caption.weight(.semibold))
            Spacer()
            Button("Cancel", action: onCancel).font(Theme.Fonts.caption)
        }
        .cardStyle()
    }
}

/// Errors and short confirmations, auto-hiding.
struct StatusToast: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if let error = app.routeError {
                toast(error, icon: "exclamationmark.triangle.fill", colour: Theme.Colors.warning) { app.routeError = nil }
            } else if let message = app.statusMessage {
                toast(message, icon: "info.circle.fill", colour: Theme.Colors.accent) { app.statusMessage = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if app.statusMessage == message { app.statusMessage = nil }
                    }
            }
        }
        .animation(.default, value: app.routeError)
        .animation(.default, value: app.statusMessage)
    }

    private func toast(_ text: String, icon: String, colour: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(colour)
            Text(text).font(Theme.Fonts.caption)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.font(Theme.Fonts.caption)
        }
        .cardStyle()
    }
}

struct HomeToolbar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack {
            item("Saved", "star.fill") { app.sheet = .savedPlaces }
            item("Trip", "list.bullet") { app.sheet = .tripBuilder }
            item("Sketch", "scribble.variable") { app.sheet = nil; app.isSketching = true }
            item("Settings", "gearshape.fill") { app.sheet = .settings }
        }
        .padding(.vertical, Theme.Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func item(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
