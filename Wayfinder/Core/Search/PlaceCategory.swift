import Foundation

/// Category chips are data. Add a row here to get a new chip on the home map.
/// `mapboxCategoryID` is a Mapbox Search Box canonical category id
/// (see https://docs.mapbox.com/api/search/search-box/#list-categories).
struct PlaceCategory: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let mapboxCategoryID: String
    let iconName: String          // SF Symbol
    /// Use MapKit's MKLocalSearch in addition to Mapbox (car parks are patchy in Mapbox POI data).
    let usesMapKitFallback: Bool
    /// Text for MKLocalSearch when the fallback is used.
    let mapKitQuery: String?
    /// Whether this category has prices from FuelService (stage 10).
    let hasFuelPrices: Bool

    static let petrol = PlaceCategory(
        id: "petrol", displayName: "Petrol", mapboxCategoryID: "gas_station",
        iconName: "fuelpump.fill", usesMapKitFallback: false, mapKitQuery: nil, hasFuelPrices: true
    )
    static let cafe = PlaceCategory(
        id: "cafe", displayName: "Cafes", mapboxCategoryID: "cafe",
        iconName: "cup.and.saucer.fill", usesMapKitFallback: false, mapKitQuery: nil, hasFuelPrices: false
    )
    static let carPark = PlaceCategory(
        id: "carPark", displayName: "Car parks", mapboxCategoryID: "parking_lot",
        iconName: "parkingsign.circle.fill", usesMapKitFallback: true, mapKitQuery: "car park", hasFuelPrices: false
    )

    /// The chip row, in display order.
    static let all: [PlaceCategory] = [.petrol, .cafe, .carPark]

    static func with(id: String) -> PlaceCategory? { all.first { $0.id == id } }
}
