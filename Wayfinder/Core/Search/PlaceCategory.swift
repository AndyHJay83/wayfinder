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

    static let food = PlaceCategory(
        id: "food", displayName: "Food", mapboxCategoryID: "restaurant",
        iconName: "fork.knife", usesMapKitFallback: false, mapKitQuery: nil, hasFuelPrices: false
    )
    /// Free-text flexible stop ("laundromat"). The query lives on the TripItem.
    static let search = PlaceCategory(
        id: "search", displayName: "Place", mapboxCategoryID: "",
        iconName: "magnifyingglass", usesMapKitFallback: false, mapKitQuery: nil, hasFuelPrices: false
    )

    /// The chip row, in display order.
    static let all: [PlaceCategory] = [.petrol, .cafe, .food, .carPark]

    static func with(id: String) -> PlaceCategory? { (all + [.search]).first { $0.id == id } }

    /// Cafes and food can be filtered by dietary requirements.
    var supportsDietary: Bool { id == PlaceCategory.cafe.id || id == PlaceCategory.food.id }
    var isParking: Bool { id == PlaceCategory.carPark.id }
    /// OSM `amenity` values used for dietary searches.
    var osmAmenities: [String] {
        switch id {
        case PlaceCategory.cafe.id: ["cafe"]
        case PlaceCategory.food.id: ["restaurant", "fast_food", "cafe"]
        default: []
        }
    }
}

/// Dietary requirements, mapped to OpenStreetMap `diet:*` tags.
enum DietaryFilter: String, CaseIterable, Identifiable, Codable {
    case vegan, vegetarian, glutenFree = "gluten_free", halal, kosher, dairyFree = "lactose_free"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vegan: "Vegan"
        case .vegetarian: "Vegetarian"
        case .glutenFree: "Gluten free"
        case .halal: "Halal"
        case .kosher: "Kosher"
        case .dairyFree: "Dairy free"
        }
    }
    /// Words added to a text search when OSM data isn't available.
    var searchWords: String {
        switch self {
        case .glutenFree: "gluten free"
        case .dairyFree: "dairy free"
        default: rawValue
        }
    }
}
