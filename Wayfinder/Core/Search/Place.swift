import CoreLocation
import Foundation

/// A place from any source (Mapbox search, MapKit, saved place, long press, fuel station).
/// The common currency between search, map pins, route preview and the trip builder.
struct Place: Identifiable, Hashable {
    enum Source: String, Hashable { case mapbox, mapKit, saved, mapPress, fuel, osm, manual, chain }

    var id: String
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double
    var categoryIDs: [String] = []
    var iconName: String?
    var source: Source
    var savedPlaceID: UUID?
    /// Distance from the search origin, metres, when known.
    var distance: CLLocationDistance?
    var isOpenNow: Bool?

    init(
        id: String = UUID().uuidString,
        name: String,
        subtitle: String? = nil,
        coordinate: CLLocationCoordinate2D,
        categoryIDs: [String] = [],
        iconName: String? = nil,
        source: Source,
        savedPlaceID: UUID? = nil,
        distance: CLLocationDistance? = nil,
        isOpenNow: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.categoryIDs = categoryIDs
        self.iconName = iconName
        self.source = source
        self.savedPlaceID = savedPlaceID
        self.distance = distance
        self.isOpenNow = isOpenNow
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func asTripItem(kind: TripItem.Kind = .stop) -> TripItem {
        TripItem(kind: kind, name: name, coordinate: coordinate, savedPlaceID: savedPlaceID)
    }
}

enum Formatters {
    static let distance: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 1
        f.locale = Locale(identifier: "en_GB")
        return f
    }()

    static func distance(_ metres: CLLocationDistance) -> String {
        // UK roads: miles for distance, yards under a quarter mile.
        if metres < 400 {
            return "\(Int((metres * 1.09361 / 10).rounded() * 10)) yd"
        }
        let miles = metres / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func arrival(after seconds: TimeInterval, from date: Date = Date()) -> String {
        clock.string(from: date.addingTimeInterval(seconds))
    }

    static func pounds(_ value: Double) -> String {
        String(format: "£%.2f", value)
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
