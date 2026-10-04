import CoreLocation
import MapboxDirections
import MapboxNavigationCore
import SwiftUI

/// Live remaining time and distance for the ETA pill under the turn banner.
@MainActor
final class GuidanceStatusModel: ObservableObject {
    @Published var remainingSeconds: TimeInterval = 0
    @Published var remainingMetres: CLLocationDistance = 0
}

/// Small pill under the next-step banner during guidance: "14:32 · 18 min · 9.4 mi".
struct GuidanceETAPill: View {
    @ObservedObject var model: GuidanceStatusModel

    var body: some View {
        if model.remainingSeconds > 0 {
            HStack(spacing: 6) {
                Text(Formatters.arrival(after: model.remainingSeconds)).font(Theme.Fonts.eta)
                Text("· \(Formatters.duration(model.remainingSeconds)) · \(Formatters.distance(model.remainingMetres))")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Single tap on the map during guidance: the detailed screen. Add a stop on the way,
/// park near the destination, take an alternative route, reshape with sketch, or end.
struct JourneySheet: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var status: GuidanceStatusModel
    let onParking: () -> Void
    let onSketch: () -> Void
    let onEnd: () -> Void
    let onClose: () -> Void

    @State private var category: PlaceCategory?
    @State private var dietary: Set<DietaryFilter> = []
    @State private var results: [Place] = []
    @State private var stations: [FuelStation] = []
    @State private var loading = false
    @State private var message: String?

    private var navigation: MapboxNavigation { app.engine.mapboxNavigation }
    private var progress: RouteProgress? { navigation.navigation().currentRouteProgress?.routeProgress }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Formatters.duration(status.remainingSeconds)).font(Theme.Fonts.etaLarge)
                        Text("· \(Formatters.distance(status.remainingMetres))").foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        Text("Arrive \(Formatters.arrival(after: status.remainingSeconds))").font(Theme.Fonts.headline)
                    }
                    if let destination = app.destinationPlace {
                        Text(destination.name).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                }

                Section("Add a stop on the way") {
                    StopChipsRow { picked in
                        if picked.isParking { onParking() } else { category = picked }
                    }
                    if let category, category.supportsDietary {
                        DietaryFilterRow(selection: $dietary)
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if let message { Text(message).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary) }
                    ForEach(stations) { station in
                        resultRow(name: station.displayName, detail: station.priceLabel()) { add(station.asPlace) }
                    }
                    ForEach(results) { place in
                        resultRow(name: place.name, detail: place.subtitle) { add(place) }
                    }
                }

                if let progress, !progress.navigationRoutes.alternativeRoutes.isEmpty {
                    Section("Other routes") {
                        ForEach(Array(progress.navigationRoutes.alternativeRoutes.prefix(3).enumerated()), id: \.offset) { _, alternative in
                            Button {
                                navigation.navigation().selectAlternativeRoute(with: alternative.routeId)
                                onClose()
                            } label: {
                                RouteSummaryCard(route: alternative.route, isSelected: false, label: "Alternative",
                                                 delta: alternative.expectedTravelTimeDelta)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button { onSketch() } label: { Label("Reshape with sketch", systemImage: "scribble.variable") }
                    Button(role: .destructive) { onEnd() } label: { Label("End journey", systemImage: "xmark.octagon") }
                }
            }
            .navigationTitle("Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Back to map") { onClose() } } }
            .task(id: "\(category?.id ?? "")-\(dietary.map(\.rawValue).sorted())") { await search() }
        }
    }

    private func resultRow(name: String, detail: String?, onAdd: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if let detail { Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1) }
            }
            Spacer()
            Button("Add", action: onAdd).buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    /// The part of the route still ahead, starting from where you are.
    private var remainingLine: [CLLocationCoordinate2D] {
        guard let progress, let shape = progress.route.shape?.coordinates, shape.count > 1 else { return [] }
        var travelled = 0.0
        for i in 1..<shape.count {
            travelled += GeoMath.distance(shape[i - 1], shape[i])
            if travelled >= progress.distanceTraveled {
                return [app.currentLocation?.coordinate ?? shape[i - 1]] + shape[i...]
            }
        }
        return Array(shape.suffix(2))
    }

    private func search() async {
        results = []
        stations = []
        message = nil
        guard let category else { return }
        let line = remainingLine
        guard line.count > 1 else { return }
        loading = true
        defer { loading = false }
        do {
            if category.hasFuelPrices {
                do {
                    stations = try await FuelService.shared.stationsAlong(route: line, corridor: PlaceSearchService.corridorMetres)
                        .sorted { ($0.distanceAlongMetres ?? 0) < ($1.distanceAlongMetres ?? 0) }
                } catch {
                    results = try await PlaceSearchService.shared.search(category: category, alongRoute: line)
                }
            } else if !dietary.isEmpty {
                let found = try await PlaceSearchService.shared.dietarySearch(category: category, filters: Array(dietary), alongRoute: line)
                results = found.places
                message = found.note
            } else {
                results = try await PlaceSearchService.shared.search(category: category, alongRoute: line)
            }
            if results.isEmpty && stations.isEmpty {
                message = "Nothing within \(Int(PlaceSearchService.maxDetourMinutes)) min of your route."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func add(_ place: Place) {
        app.insertAlongRoute(place)
        onClose()
    }
}
