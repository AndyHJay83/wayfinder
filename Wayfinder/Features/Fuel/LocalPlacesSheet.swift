import CoreLocation
import SwiftData
import SwiftUI

/// Places for a category. With a route on screen they're found along it (within the detour
/// set in Settings) and "Add" puts the stop in the right place on the way; otherwise they're
/// near you or the map centre. Petrol rows come from FuelService and always show price age.
/// Cafes and food can be filtered by dietary requirements.
struct LocalPlacesSheet: View {
    let category: PlaceCategory
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var context
    @Query private var favourites: [FavouriteStation]

    enum Sort: String, CaseIterable, Identifiable {
        case bestValue = "Best value", cheapest = "Cheapest", nearest = "Nearest"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .bestValue
    @State private var stations: [FuelStation] = []
    @State private var places: [Place] = []
    @State private var fromCache: Date?
    @State private var loading = true
    @State private var error: String?
    @State private var note: String?
    @State private var dietary: Set<DietaryFilter> = []

    /// Search along the planned route (not during guidance; that has its own screen).
    private var routeLine: [CLLocationCoordinate2D]? {
        guard !app.engine.isGuiding, let shape = app.previewRoutes?.mainRoute.route.shape?.coordinates, shape.count > 1 else { return nil }
        return shape
    }

    private var favouriteIDs: Set<String> { Set(favourites.map(\.stationID)) }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.Colors.warning) }
                if category.supportsDietary {
                    DietaryFilterRow(selection: $dietary)
                }
                if let note {
                    Label(note, systemImage: "info.circle").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                if let fromCache {
                    Label("Offline: showing prices saved \(Formatters.age(since: fromCache))", systemImage: "wifi.slash")
                        .font(Theme.Fonts.caption)
                }
                if category.hasFuelPrices {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(sortedStations) { station in
                        FuelStationRow(
                            station: station,
                            isFavourite: favouriteIDs.contains(station.id),
                            onFavourite: { toggleFavourite(station) },
                            onNavigate: { app.choose(destination: station.asPlace) },
                            onAdd: { add(station.asPlace) }
                        )
                    }
                } else {
                    ForEach(places) { place in
                        PlaceRow(place: place,
                                 onNavigate: { app.choose(destination: place) },
                                 onAdd: { add(place) })
                    }
                }
                if !loading && stations.isEmpty && places.isEmpty && error == nil {
                    Text(routeLine == nil ? "Nothing found nearby." : "Nothing found within \(Int(PlaceSearchService.maxDetourMinutes)) min of your route. You can allow a longer detour in Settings.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(routeLine == nil ? "\(category.displayName) nearby" : "\(category.displayName) on the way")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { app.sheet = nil; app.clearCategoryResults() } } }
            .task(id: dietary) { await load() }
            .onChange(of: sort) { _, _ in updatePins() }
        }
    }

    private var sortedStations: [FuelStation] {
        let settings = PlannerSettings.current
        let favs = favouriteIDs
        let sorted: [FuelStation] = switch sort {
        case .cheapest: stations.sorted { ($0.pricePence ?? 999) < ($1.pricePence ?? 999) }
        case .nearest: stations.sorted { ($0.distanceMetres ?? 0) < ($1.distanceMetres ?? 0) }
        case .bestValue: stations.sorted { valueScore($0, favs, settings) < valueScore($1, favs, settings) }
        }
        // Favourites pinned to the top.
        return sorted.filter { favs.contains($0.id) } + sorted.filter { !favs.contains($0.id) }
    }

    /// Stage 11 score for a there-and-back detour from here.
    private func valueScore(_ s: FuelStation, _ favs: Set<String>, _ settings: PlannerSettings) -> Double {
        guard let price = s.pricePence, !s.isStale() else { return .infinity }
        let km = (s.distanceMetres ?? 0) * 2 / 1000
        return PlannerScoring.fuelStopCost(driveMinutes: km / 0.6, pricePencePerLitre: price, detourKm: km,
                                           isFavourite: favs.contains(s.id), settings: settings)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        note = nil
        let line = routeLine
        guard let center = line == nil ? (app.map?.searchCenter ?? app.currentLocation?.coordinate) : line?.first else {
            error = RouteCalculationError.noOrigin.localizedDescription
            return
        }
        let search = PlaceSearchService.shared
        do {
            if category.hasFuelPrices {
                if let line {
                    stations = try await FuelService.shared.stationsAlong(route: line, corridor: PlaceSearchService.corridorMetres)
                    sort = .cheapest
                } else {
                    let result = try await FuelService.shared.stationsNear(center)
                    stations = result.stations
                    fromCache = result.source == .cache ? result.fetchedAt : nil
                }
            } else if !dietary.isEmpty {
                let result = try await search.dietarySearch(category: category, filters: Array(dietary), near: line == nil ? center : nil, alongRoute: line)
                places = result.places
                note = result.note
            } else if let line {
                places = try await search.search(category: category, alongRoute: line)
            } else {
                places = try await search.search(category: category, near: center)
            }
            updatePins()
        } catch {
            self.error = error.localizedDescription
            if category.hasFuelPrices {
                // No price data yet: still show stations from Mapbox.
                if let line {
                    places = (try? await search.search(category: category, alongRoute: line)) ?? []
                } else {
                    places = (try? await search.search(category: category, near: center)) ?? []
                }
                updatePins()
            }
        }
    }

    /// On a route: insert where it falls along the way. Otherwise: add to the trip.
    private func add(_ place: Place) {
        if routeLine != nil {
            app.insertAlongRoute(place)
            app.clearCategoryResults()
            app.sheet = nil
        } else {
            app.addToTrip(place)
        }
    }

    private func updatePins() {
        app.map?.showResults(category.hasFuelPrices && !stations.isEmpty ? sortedStations.map(\.asPlace) : places)
    }

    private func toggleFavourite(_ station: FuelStation) {
        if let existing = favourites.first(where: { $0.stationID == station.id }) {
            context.delete(existing)
        } else {
            context.insert(FavouriteStation(stationID: station.id, name: station.displayName, coordinate: station.coordinate))
        }
    }
}

/// Toggle chips for dietary requirements (OpenStreetMap diet tags).
struct DietaryFilterRow: View {
    @Binding var selection: Set<DietaryFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(DietaryFilter.allCases) { filter in
                    let on = selection.contains(filter)
                    Button {
                        if on { selection.remove(filter) } else { selection.insert(filter) }
                    } label: {
                        Label(filter.label, systemImage: on ? "checkmark" : "leaf")
                            .font(Theme.Fonts.caption.weight(.semibold))
                            .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 6)
                            .foregroundStyle(on ? Color.white : Theme.Colors.textPrimary)
                            .background(Capsule().fill(on ? AnyShapeStyle(Theme.Colors.chipArmed) : AnyShapeStyle(Theme.Colors.surface)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

struct FuelStationRow: View {
    let station: FuelStation
    let isFavourite: Bool
    let onFavourite: () -> Void
    let onNavigate: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Button(action: onFavourite) {
                    Image(systemName: isFavourite ? "star.fill" : "star").foregroundStyle(Theme.Colors.favourite)
                }
                .buttonStyle(.plain)
                Text(station.displayName).font(Theme.Fonts.body).lineLimit(1)
                Spacer()
                if let d = station.distanceMetres {
                    Text(Formatters.distance(d)).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            HStack {
                PriceLabel(station: station)
                if station.isMotorwayServices {
                    Text("Motorway services").font(.caption2).padding(3).background(Theme.Colors.warning.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button("Add to trip", action: onAdd).buttonStyle(.bordered).controlSize(.small)
                Button("Navigate", action: onNavigate).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}

/// "142.9p, 2h ago", flagged when older than 24 hours or missing.
struct PriceLabel: View {
    let station: FuelStation

    var body: some View {
        if station.pricePence == nil {
            Label("No price", systemImage: "questionmark.circle")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
        } else {
            HStack(spacing: 4) {
                Text(station.priceLabel()).font(Theme.Fonts.price)
                if station.isStale() {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Theme.Colors.warning)
                        .accessibilityLabel("Price is more than a day old")
                }
            }
            .foregroundStyle(station.isStale() ? Theme.Colors.warning : Theme.Colors.textPrimary)
        }
    }
}

struct PlaceRow: View {
    let place: Place
    let onNavigate: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(Theme.Fonts.body).lineLimit(1)
                HStack(spacing: 6) {
                    if let d = place.distance { Text(Formatters.distance(d)) }
                    if let open = place.isOpenNow {
                        Text(open ? "Open" : "Closed").foregroundStyle(open ? Theme.Colors.positive : Theme.Colors.danger)
                    }
                    if place.source == .mapKit { Text("Apple Maps") }
                }
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            Button("Add", action: onAdd).buttonStyle(.bordered).controlSize(.small)
            Button("Go", action: onNavigate).buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}
