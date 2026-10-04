import MapboxDirections
import MapboxNavigationCore
import SwiftUI

/// Slides up from the bottom once a destination is chosen: ETA, distance, alternatives,
/// quick "add a stop on the way" buttons, and GO.
struct TripBanner: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var permission: LocationPermission

    private var route: Route? { app.previewRoutes?.mainRoute.route }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            if let routes = app.previewRoutes, !routes.alternativeRoutes.isEmpty {
                alternatives(routes)
            }
            StopChipsRow { category in add(category) }
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    app.sheet = .tripBuilder
                } label: {
                    Label(stopsTitle, systemImage: "list.bullet")
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .padding(.horizontal, Theme.Spacing.m)
                        .frame(height: 44)
                        .background(Capsule().fill(Theme.Colors.surface))
                }
                .buttonStyle(.plain)
                Spacer()
                goButton
            }
        }
        .padding(Theme.Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.banner))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.destinationPlace?.name ?? "Route")
                    .font(Theme.Fonts.headline)
                    .lineLimit(1)
                if let route {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Formatters.duration(route.expectedTravelTime)).font(Theme.Fonts.etaLarge)
                        Text("· \(Formatters.distance(route.distance))")
                        Text("· arrive \(Formatters.arrival(after: route.expectedTravelTime))")
                    }
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: route.expectedTravelTime)
                } else if app.isCalculating {
                    HStack { ProgressView(); Text("Finding routes…") }.font(Theme.Fonts.caption)
                } else if let error = app.routeError {
                    Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning).lineLimit(2)
                }
                if let walk = app.walkingDestination {
                    Label("Park, then walk to \(walk.name)", systemImage: "figure.walk")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                } else if RoutePreferences.current.travelMode == .walking {
                    Label("Walking", systemImage: "figure.walk")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            Button {
                app.clearRoute()
                app.selectedPlace = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.Colors.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel route")
        }
    }

    private func alternatives(_ routes: NavigationRoutes) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                Text("Fastest")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Colors.accent.opacity(0.18)))
                ForEach(Array(routes.alternativeRoutes.prefix(2).enumerated()), id: \.offset) { _, alternative in
                    Button {
                        Task { await app.selectAlternative(alternative) }
                    } label: {
                        Text(alternativeLabel(alternative))
                            .font(Theme.Fonts.caption)
                            .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 6)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func alternativeLabel(_ alternative: AlternativeRoute) -> String {
        let delta = alternative.expectedTravelTimeDelta
        let time = delta >= 0 ? "+\(Formatters.duration(delta))" : "−\(Formatters.duration(-delta))"
        let road = alternative.route.legs.flatMap(\.steps).max { $0.distance < $1.distance }?.names?.first
        return road.map { "\(time) via \($0)" } ?? time
    }

    private var goButton: some View {
        Button {
            permission.requestAlwaysIfNeeded()
            app.startGuidance()
        } label: {
            Text("GO")
                .font(Theme.Fonts.goButton)
                .foregroundStyle(.white)
                .frame(width: 110, height: 52)
                .background(Capsule().fill(Theme.Colors.go))
        }
        .buttonStyle(.plain)
        .disabled(app.previewRoutes == nil || app.isCalculating)
        .opacity(app.previewRoutes == nil ? 0.5 : 1)
        .accessibilityLabel("Go. Start navigation")
    }

    private var stopsTitle: String {
        let stops = app.trip.items.count
        return stops > 1 ? "\(stops) stops" : "Stops"
    }

    private func add(_ category: PlaceCategory) {
        if category.isParking {
            if let destination = app.destinationPlace { app.sheet = .parkNearby(destination) }
        } else {
            app.sheet = .localPlaces(category)
        }
    }
}

/// Petrol / Cafes / Food / Car parks as small buttons for adding a stop on the way.
struct StopChipsRow: View {
    let onTap: (PlaceCategory) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(PlaceCategory.all) { category in
                    Button { onTap(category) } label: {
                        Label(category.isParking ? "Parking" : category.displayName, systemImage: category.iconName)
                            .font(Theme.Fonts.caption.weight(.semibold))
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.s)
                            .background(Capsule().fill(Theme.Colors.surface))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(category.isParking ? "Parking near your destination" : "Find \(category.displayName.lowercased()) on your route")
                }
            }
        }
    }
}
