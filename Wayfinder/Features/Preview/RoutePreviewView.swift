import MapboxDirections
import MapboxNavigationCore
import SwiftUI

/// Shown before guidance: ETA, distance, traffic-aware duration and up to two alternatives.
struct RoutePreviewView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var permission: LocationPermission

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    header
                    if let routes = app.previewRoutes {
                        RouteSummaryCard(route: routes.mainRoute.route, isSelected: true, label: "Fastest")
                        alternatives(routes)
                        if let walk = app.walkingDestination {
                            Label("Park, then walk to \(walk.name)", systemImage: "figure.walk")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        actions
                    } else if app.isCalculating {
                        ProgressView("Finding routes…").frame(maxWidth: .infinity).padding()
                    } else if let error = app.routeError {
                        Text(error).foregroundStyle(Theme.Colors.warning)
                        Button("Try again") { Task { await app.recalculate() } }
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { app.clearRoute(); app.sheet = nil }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.trip.routableItems.last?.name ?? "Route")
                .font(Theme.Fonts.title)
                .lineLimit(2)
            if let subtitle = app.selectedPlace?.subtitle {
                Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            if RoutePreferences.current.travelMode == .walking {
                Label("Walking. No live traffic for walking routes.", systemImage: "figure.walk")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func alternatives(_ routes: NavigationRoutes) -> some View {
        ForEach(Array(routes.alternativeRoutes.prefix(2).enumerated()), id: \.offset) { index, alternative in
            Button {
                Task { await app.selectAlternative(alternative) }
            } label: {
                RouteSummaryCard(route: alternative.route, isSelected: false, label: "Alternative \(index + 1)",
                                 delta: alternative.expectedTravelTimeDelta)
            }
            .buttonStyle(.plain)
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                permission.requestAlwaysIfNeeded()
                app.startGuidance()
            } label: {
                Label("Start", systemImage: "location.north.line.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                if let destination = app.selectedPlace {
                    Button {
                        app.sheet = .savePlace(destination)
                    } label: { Label("Save", systemImage: "star") }
                    Button {
                        app.sheet = .parkNearby(destination)
                    } label: { Label("Park nearby", systemImage: "parkingsign") }
                }
                Button {
                    app.sheet = .tripBuilder
                } label: { Label("Stops", systemImage: "list.bullet") }
            }
            .buttonStyle(.bordered)
            .font(Theme.Fonts.caption)
        }
    }
}

struct RouteSummaryCard: View {
    let route: Route
    let isSelected: Bool
    let label: String
    var delta: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(Formatters.duration(route.expectedTravelTime)).font(Theme.Fonts.eta)
                Text("· \(Formatters.distance(route.distance))").foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text("Arrive \(Formatters.arrival(after: route.expectedTravelTime))").font(Theme.Fonts.caption)
            }
            HStack {
                Text(label).font(Theme.Fonts.caption.weight(.semibold))
                if let delta {
                    Text(delta >= 0 ? "+\(Formatters.duration(delta))" : "−\(Formatters.duration(-delta))")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(delta > 0 ? Theme.Colors.warning : Theme.Colors.positive)
                }
                Spacer()
                trafficText
            }
            if let road = mainRoad {
                Text("Via \(road)").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.surface)
        )
    }

    /// Traffic-aware duration vs a typical day.
    @ViewBuilder
    private var trafficText: some View {
        if let typical = route.typicalTravelTime, typical > 0 {
            let extra = route.expectedTravelTime - typical
            if extra > 120 {
                Text("\(Formatters.duration(extra)) traffic delay").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
            } else {
                Text("Traffic normal").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.positive)
            }
        }
    }

    private var mainRoad: String? {
        route.legs.flatMap(\.steps).max { $0.distance < $1.distance }?.names?.first
    }
}
