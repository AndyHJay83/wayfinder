import SwiftData
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var permission: LocationPermission
    @Query(sort: \SavedPlace.createdAt, order: .reverse) private var savedPlaces: [SavedPlace]
    @State private var map: MapController?

    /// The trip banner shows as soon as there's somewhere to go.
    private var showsBanner: Bool {
        !app.isSketching && (!app.trip.routableItems.isEmpty || app.isCalculating)
    }

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
                    if !showsBanner {
                        CategoryChipsView()
                            .transition(.opacity)
                    }
                    if let text = app.armedBannerText {
                        ArmedBanner(text: text) { app.disarmAll() }
                    }
                }
                StatusToast()
                Spacer()
                if !app.isSketching {
                    HStack(alignment: .bottom) {
                        if let map, !map.isFollowingUser {
                            RecenterButton { map.recenter() }
                        }
                        Spacer()
                        TripButton()
                    }
                    if showsBanner {
                        TripBanner()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
            .animation(Theme.Motion.banner, value: showsBanner)

            PressMenuOverlay(menu: app.pressMenu)
        }
        .sheet(item: $app.sheet) { sheet in
            SheetContent(sheet: sheet)
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
        case .naturalLanguage:
            NaturalLanguageView()
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
