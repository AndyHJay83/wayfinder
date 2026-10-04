import CoreLocation
import Foundation

/// An ordered list of things to visit. The user's current location is always the implicit start.
/// Kept free of UI and SDK types so the planner (stage 11) and parking (stage 13) can reuse it.
struct Trip: Codable, Equatable {
    var items: [TripItem] = []

    var isEmpty: Bool { items.isEmpty }

    /// Items that have a real coordinate (flexible category items are resolved by the planner first).
    var routableItems: [TripItem] { items.filter { $0.coordinate != nil } }

    var hasUnresolvedCategoryItems: Bool {
        items.contains { if case .category = $0.kind, $0.coordinate == nil { return true } else { return false } }
    }

    mutating func append(_ item: TripItem) { items.append(item) }

    mutating func insert(_ item: TripItem, at index: Int) {
        items.insert(item, at: max(0, min(index, items.count)))
    }

    mutating func remove(id: TripItem.ID) { items.removeAll { $0.id == id } }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        // Same semantics as SwiftUI's Array.move(fromOffsets:toOffset:), without importing SwiftUI.
        let moving = fromOffsets.map { items[$0] }
        var remaining = items.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        let insertAt = toOffset - fromOffsets.filter { $0 < toOffset }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        items = remaining
    }

    mutating func toggleKind(id: TripItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].kind {
        case .stop: items[i].kind = .via
        case .via: items[i].kind = .stop
        case .category: break
        }
    }

    mutating func update(_ item: TripItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
    }

    /// Where a new stop at `coordinate` belongs: before the first item that is further along
    /// `shape` (the current route line), and never after the final destination.
    func insertionIndex(for coordinate: CLLocationCoordinate2D, along shape: [CLLocationCoordinate2D]) -> Int {
        guard !items.isEmpty else { return 0 }
        guard let touch = GeoMath.project(coordinate, onto: shape) else { return items.count - 1 }
        for (index, item) in items.enumerated() {
            guard let c = item.coordinate, let projected = GeoMath.project(c, onto: shape) else { continue }
            if projected.distanceAlong > touch.distanceAlong { return index }
        }
        return items.count - 1
    }
}

struct TripItem: Identifiable, Codable, Equatable {
    enum Kind: Codable, Equatable, Hashable {
        /// A real waypoint with its own leg, arrival announcement and ETA.
        case stop
        /// A silent point that bends the route without a stop or arrival announcement.
        case via
        /// A flexible stop resolved by the planner (stage 11). Holds a `PlaceCategory.id`.
        case category(String)

        var isSilent: Bool { self == .via }
    }

    /// Stage 11 ordering rules. `before`/`after` reference another item's id.
    enum OrderingRule: Codable, Equatable, Hashable {
        case before(UUID)
        case after(UUID)
        case last
    }

    var id = UUID()
    var kind: Kind
    var name: String
    var latitude: Double?
    var longitude: Double?
    var savedPlaceID: UUID?
    var orderingRule: OrderingRule?
    var arriveBy: Date?
    /// Snapping radius in metres for the Directions `radiuses` parameter (nil = SDK default).
    var snapRadius: Double?
    /// Flexible stops: free-text search (e.g. "laundromat") when the category is `search`.
    var query: String?
    /// Flexible food/cafe stops: dietary requirements (`DietaryFilter` raw values).
    var dietary: [String] = []
    /// Planned stay at this stop in minutes (parking cost); 10 = pick up / drop off.
    var stayMinutes: Int?
    /// Prefer stops/parking that are free to park at (e.g. "no change for parking").
    var freeParkingPreferred = false

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        coordinate: CLLocationCoordinate2D?,
        savedPlaceID: UUID? = nil,
        orderingRule: OrderingRule? = nil,
        arriveBy: Date? = nil,
        snapRadius: Double? = nil,
        query: String? = nil,
        dietary: [String] = [],
        stayMinutes: Int? = nil,
        freeParkingPreferred: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.savedPlaceID = savedPlaceID
        self.orderingRule = orderingRule
        self.arriveBy = arriveBy
        self.snapRadius = snapRadius
        self.query = query
        self.dietary = dietary
        self.stayMinutes = stayMinutes
        self.freeParkingPreferred = freeParkingPreferred
    }

    var coordinate: CLLocationCoordinate2D? {
        get {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        set {
            latitude = newValue?.latitude
            longitude = newValue?.longitude
        }
    }

    var categoryID: String? {
        if case .category(let id) = kind { return id }
        return nil
    }
}
