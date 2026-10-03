import CoreLocation
import Foundation
import SwiftData

// CloudKit-backed SwiftData rules followed by every model below:
//  - every stored property has a default value (or is optional)
//  - no @Attribute(.unique)
//  - every relationship is optional and has an inverse
//  - no .deny delete rules

/// Stage 6: a place the user saved.
@Model
final class SavedPlace {
    var uuid: UUID = UUID()
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var note: String = ""
    var icon: String = "star.fill"
    var colour: String = "yellow"
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \PlaceCollection.places)
    var collections: [PlaceCollection]? = []

    init(name: String, coordinate: CLLocationCoordinate2D, note: String = "", icon: String = "star.fill", colour: String = "yellow") {
        self.uuid = UUID()
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.note = note
        self.icon = icon
        self.colour = colour
        self.createdAt = Date()
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var asPlace: Place {
        Place(id: "saved-\(uuid)", name: name, subtitle: note.isEmpty ? nil : note, coordinate: coordinate,
              iconName: icon, source: .saved, savedPlaceID: uuid)
    }
}

/// Stage 6: a named group of saved places (Home, Favourites, ...).
@Model
final class PlaceCollection {
    var name: String = ""
    var createdAt: Date = Date()
    var places: [SavedPlace]? = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

/// Stage 10: a favourite petrol station (Fuel Finder station id).
@Model
final class FavouriteStation {
    var stationID: String = ""
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var addedAt: Date = Date()

    init(stationID: String, name: String, coordinate: CLLocationCoordinate2D) {
        self.stationID = stationID
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.addedAt = Date()
    }
}

/// Stage 11: ranked preferred car parks (rank 0 = most preferred).
@Model
final class PreferredCarPark {
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var rank: Int = 0

    init(name: String, coordinate: CLLocationCoordinate2D, rank: Int) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.rank = rank
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Stage 13: "I parked here" spots (trust level 1).
@Model
final class SavedParkingSpot {
    var uuid: UUID = UUID()
    var latitude: Double = 0
    var longitude: Double = 0
    var isFree: Bool = true
    var timeLimitNote: String = ""
    var maxStayMinutes: Int = 0          // 0 = unknown / none
    var pricePerHourPence: Int = -1      // -1 = unknown
    var note: String = ""
    var savedAt: Date = Date()
    /// Marked "Not valid" by the user. Hidden from results.
    var isHidden: Bool = false

    init(coordinate: CLLocationCoordinate2D, isFree: Bool, timeLimitNote: String = "", maxStayMinutes: Int = 0, pricePerHourPence: Int = -1) {
        self.uuid = UUID()
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.isFree = isFree
        self.timeLimitNote = timeLimitNote
        self.maxStayMinutes = maxStayMinutes
        self.pricePerHourPence = pricePerHourPence
        self.savedAt = Date()
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Stage 13: a car park entered by hand with its tariff (trust level 3).
@Model
final class ManualCarPark {
    var uuid: UUID = UUID()
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    /// Tariff bands as JSON-encoded `[TariffBand]` (kept as Data for CloudKit friendliness).
    var tariffData: Data = Data()
    var maxStayMinutes: Int = 0
    var openingHours: String = ""        // OSM opening_hours syntax, optional
    var note: String = ""

    init(name: String, coordinate: CLLocationCoordinate2D, tariff: [TariffBand] = [], maxStayMinutes: Int = 0) {
        self.uuid = UUID()
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.tariffData = (try? JSONEncoder().encode(tariff)) ?? Data()
        self.maxStayMinutes = maxStayMinutes
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var tariff: [TariffBand] {
        get { (try? JSONDecoder().decode([TariffBand].self, from: tariffData)) ?? [] }
        set { tariffData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// Stage 13: a saved chain shortcut such as "Coffee #1".
@Model
final class ChainShortcut {
    var name: String = ""
    var icon: String = "cup.and.saucer.fill"
    var createdAt: Date = Date()

    init(name: String, icon: String = "cup.and.saucer.fill") {
        self.name = name
        self.icon = icon
        self.createdAt = Date()
    }
}

enum Persistence {
    static let schema = Schema([
        SavedPlace.self, PlaceCollection.self, FavouriteStation.self, PreferredCarPark.self,
        SavedParkingSpot.self, ManualCarPark.self, ChainShortcut.self,
    ])

    /// Shared container so UIKit-presented screens (guidance) can use the same store.
    @MainActor static let shared: ModelContainer = makeContainer()

    /// CloudKit-synced store. Falls back to a local-only store if iCloud isn't set up yet,
    /// so the app still runs before the capability is switched on.
    static func makeContainer() -> ModelContainer {
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: local)
        }
    }
}
