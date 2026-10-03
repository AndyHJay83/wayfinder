import CoreLocation
import Foundation
import MapboxSearch
import MapKit

/// All Mapbox Search calls go through here: autocomplete, category search (with a MapKit
/// fallback for car parks), reverse geocoding and chain/brand search.
@MainActor
final class PlaceSearchService {
    static let shared = PlaceSearchService()

    private lazy var autocomplete = PlaceAutocomplete()
    private lazy var categoryEngine = CategorySearchEngine(apiType: .searchBox)
    private lazy var searchEngine = SearchEngine(apiType: .searchBox)

    private var lastSuggestions: [String: PlaceAutocomplete.Suggestion] = [:]

    // MARK: Autocomplete (stage 3)

    struct Suggestion: Identifiable, Hashable {
        let id: String
        let name: String
        let subtitle: String?
        let distance: CLLocationDistance?
    }

    func suggestions(for query: String, near proximity: CLLocationCoordinate2D?) async throws -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        RequestCounter.shared.record(.search)
        let options = PlaceAutocomplete.Options(countries: [Country(countryCode: "gb")].compactMap { $0 })
        let results: [PlaceAutocomplete.Suggestion] = try await withCheckedThrowingContinuation { continuation in
            autocomplete.suggestions(for: trimmed, proximity: proximity, filterBy: options) { result in
                continuation.resume(with: result)
            }
        }
        lastSuggestions = [:]
        return results.map { suggestion in
            let id = suggestion.mapboxId ?? UUID().uuidString
            lastSuggestions[id] = suggestion
            return Suggestion(id: id, name: suggestion.name, subtitle: suggestion.description, distance: suggestion.distance)
        }
    }

    /// Resolves a suggestion to a full place with coordinates.
    func resolve(_ suggestion: Suggestion) async throws -> Place {
        guard let underlying = lastSuggestions[suggestion.id] else {
            throw SearchServiceError.staleSuggestion
        }
        let result: PlaceAutocomplete.Result = try await withCheckedThrowingContinuation { continuation in
            autocomplete.select(suggestion: underlying) { continuation.resume(with: $0) }
        }
        guard let coordinate = result.coordinate else { throw SearchServiceError.noCoordinate }
        return Place(
            id: result.mapboxId ?? suggestion.id,
            name: result.name,
            subtitle: result.address?.formattedAddress(style: .medium) ?? result.description,
            coordinate: coordinate,
            categoryIDs: result.categoryIds,
            iconName: result.iconName,
            source: .mapbox,
            distance: result.distance
        )
    }

    // MARK: Category search (stage 5)

    func search(category: PlaceCategory, near center: CLLocationCoordinate2D, limit: Int = 25) async throws -> [Place] {
        RequestCounter.shared.record(.search)
        let options = SearchOptions(countries: ["gb"], limit: limit, proximity: center, origin: center)
        let mapbox: [Place] = try await withCheckedThrowingContinuation { continuation in
            categoryEngine.search(categoryName: category.mapboxCategoryID, options: options) { result in
                continuation.resume(with: result.map { results in
                    results.map { Self.place(from: $0, category: category, origin: center) }
                }.mapError { $0 as Error })
            }
        }

        var places = mapbox
        // Mapbox POI coverage for car parks is patchy in the UK, so MapKit fills the gaps.
        if category.usesMapKitFallback, let query = category.mapKitQuery {
            let extra = (try? await mapKitSearch(query: query, near: center, category: category)) ?? []
            places += extra.filter { candidate in
                !places.contains { GeoMath.distance($0.coordinate, candidate.coordinate) < 40 }
            }
        }
        return places.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    /// Category search in a corridor along a route (used by the planner for long trips).
    func search(category: PlaceCategory, along routeOptions: MapboxSearch.RouteOptions, limit: Int = 25) async throws -> [Place] {
        RequestCounter.shared.record(.search)
        let options = SearchOptions(countries: ["gb"], limit: limit, routeOptions: routeOptions)
        return try await withCheckedThrowingContinuation { continuation in
            categoryEngine.search(categoryName: category.mapboxCategoryID, options: options) { result in
                continuation.resume(with: result.map { $0.map { Self.place(from: $0, category: category, origin: nil) } }.mapError { $0 as Error })
            }
        }
    }

    private func mapKitSearch(query: String, near center: CLLocationCoordinate2D, category: PlaceCategory) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: 4000, longitudinalMeters: 4000)
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking])
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let c = item.placemark.coordinate
            return Place(
                id: "mk-\(c.latitude),\(c.longitude)",
                name: item.name ?? category.displayName,
                subtitle: item.placemark.title,
                coordinate: c,
                categoryIDs: [category.id],
                iconName: category.iconName,
                source: .mapKit,
                distance: GeoMath.distance(center, c)
            )
        }
    }

    // MARK: Reverse geocoding (stage 8 sketch anchors)

    /// Nearest named place (place / locality / neighbourhood) to a coordinate.
    func nearestNamedPlace(to coordinate: CLLocationCoordinate2D) async throws -> Place? {
        try await namedPlaces(near: coordinate, limit: 1).first
    }

    func namedPlaces(near coordinate: CLLocationCoordinate2D, limit: Int = 5) async throws -> [Place] {
        RequestCounter.shared.record(.reverseGeocode)
        let options = ReverseGeocodingOptions(
            point: coordinate,
            limit: limit,
            filterQueryTypes: [.place, .locality, .neighborhood],
            countries: ["gb"]
        )
        return try await withCheckedThrowingContinuation { continuation in
            searchEngine.reverse(options: options) { result in
                continuation.resume(with: result.map { results in
                    results.map {
                        Place(
                            id: $0.id, name: $0.name, subtitle: $0.descriptionText,
                            coordinate: $0.coordinate, source: .mapbox,
                            distance: GeoMath.distance(coordinate, $0.coordinate)
                        )
                    }
                }.mapError { $0 as Error })
            }
        }
    }

    // MARK: Chain / brand search (stage 13)

    /// Nearest branches of a chain such as "Coffee #1", sorted by distance.
    func branches(of chain: String, near center: CLLocationCoordinate2D, limit: Int = 10) async throws -> [Place] {
        RequestCounter.shared.record(.search)
        let options = SearchOptions(
            countries: ["gb"], limit: limit, proximity: center, origin: center,
            filterQueryTypes: [.poi, .brand]
        )
        let results: [Place] = try await withCheckedThrowingContinuation { continuation in
            searchEngine.forward(query: chain, options: options) { result in
                continuation.resume(with: result.map { $0.map { Self.place(from: $0, category: nil, origin: center) } }.mapError { $0 as Error })
            }
        }
        let needle = chain.lowercased().filter { $0.isLetter || $0.isNumber }
        let matching = results.filter { $0.name.lowercased().filter { $0.isLetter || $0.isNumber }.contains(needle) }
        return (matching.isEmpty ? results : matching)
            .map { var p = $0; p.source = .chain; return p }
            .sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    // MARK: Mapping

    private static func place(from result: SearchResult, category: PlaceCategory?, origin: CLLocationCoordinate2D?) -> Place {
        Place(
            id: result.mapboxId ?? result.id,
            name: result.name,
            subtitle: result.address?.formattedAddress(style: .short) ?? result.descriptionText,
            coordinate: result.coordinate,
            categoryIDs: category.map { [$0.id] } ?? (result.categoryIds ?? []),
            iconName: category?.iconName,
            source: .mapbox,
            distance: origin.map { GeoMath.distance($0, result.coordinate) } ?? result.distance,
            isOpenNow: result.metadata?.openHours.flatMap { OpeningState.isOpen($0) }
        )
    }
}

enum SearchServiceError: LocalizedError {
    case staleSuggestion, noCoordinate
    var errorDescription: String? {
        switch self {
        case .staleSuggestion: "That suggestion has expired. Search again."
        case .noCoordinate: "That result has no location."
        }
    }
}

/// Opening state from Mapbox OpenHours.
enum OpeningState {
    static func isOpen(_ hours: OpenHours, at date: Date = Date(), calendar: Calendar = .current) -> Bool? {
        switch hours {
        case .alwaysOpened: return true
        case .temporarilyClosed, .permanentlyClosed: return false
        case .scheduled(let periods, _, _):
            let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return nil }
            let now = weekday * 1440 + hour * 60 + minute
            for period in periods {
                guard let sw = period.start.weekday, let ew = period.end.weekday else { continue }
                let start = sw * 1440 + (period.start.hour ?? 0) * 60 + (period.start.minute ?? 0)
                var end = ew * 1440 + (period.end.hour ?? 0) * 60 + (period.end.minute ?? 0)
                if end <= start { end += 7 * 1440 }
                if (start...end).contains(now) || (start...end).contains(now + 7 * 1440) { return true }
            }
            return false
        }
    }
}
