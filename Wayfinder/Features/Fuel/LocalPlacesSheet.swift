import SwiftData
import SwiftUI

/// Long press on a chip: local places for that category near you (or the map centre).
/// Petrol rows come from FuelService and always show price age.
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

    private var favouriteIDs: Set<String> { Set(favourites.map(\.stationID)) }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.Colors.warning) }
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
                            onAdd: { app.addToTrip(station.asPlace) }
                        )
                    }
                } else {
                    ForEach(places) { place in
                        PlaceRow(place: place,
                                 onNavigate: { app.choose(destination: place) },
                                 onAdd: { app.addToTrip(place) })
                    }
                }
                if !loading && stations.isEmpty && places.isEmpty && error == nil {
                    Text("Nothing found nearby.").foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("\(category.displayName) nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { app.sheet = nil; app.clearCategoryResults() } } }
            .task { await load() }
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
        guard let center = app.map?.searchCenter ?? app.currentLocation?.coordinate else {
            error = RouteCalculationError.noOrigin.localizedDescription
            return
        }
        do {
            if category.hasFuelPrices {
                let result = try await FuelService.shared.stationsNear(center)
                stations = result.stations
                fromCache = result.source == .cache ? result.fetchedAt : nil
            } else {
                places = try await PlaceSearchService.shared.search(category: category, near: center)
            }
            updatePins()
        } catch {
            self.error = error.localizedDescription
            if category.hasFuelPrices {
                // No price data yet: still show stations from Mapbox.
                places = (try? await PlaceSearchService.shared.search(category: category, near: center)) ?? []
                updatePins()
            }
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
