import CoreLocation
import Foundation

enum FuelType: String, CaseIterable, Identifiable, Codable {
    case e10 = "E10"
    case e5 = "E5"
    case diesel = "B7"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .e10: "Unleaded (E10)"
        case .e5: "Super unleaded (E5)"
        case .diesel: "Diesel (B7)"
        }
    }

    static var current: FuelType {
        FuelType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.fuelType) ?? "") ?? .e10
    }
}

/// One station with its price for the selected fuel. Prices always travel with their age.
struct FuelStation: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let brand: String?
    let latitude: Double
    let longitude: Double
    let isMotorwayServices: Bool
    let pricePence: Double?
    let reportedAt: Date?
    /// Metres from the search point (stations_near) or along the route (stations_along).
    let distanceMetres: Double?
    let distanceAlongMetres: Double?

    enum CodingKeys: String, CodingKey {
        case id = "station_id"
        case name, brand, latitude, longitude
        case isMotorwayServices = "is_motorway_services"
        case pricePence = "price_pence"
        case reportedAt = "reported_at"
        case distanceMetres = "distance_m"
        case distanceAlongMetres = "distance_along_m"
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    static let staleAfter: TimeInterval = 24 * 3600

    func priceAge(now: Date = Date()) -> TimeInterval? { reportedAt.map { now.timeIntervalSince($0) } }

    func isStale(now: Date = Date()) -> Bool { (priceAge(now: now) ?? .infinity) > Self.staleAfter }

    /// "142.9p, 2h ago". Never a price without its age.
    func priceLabel(now: Date = Date()) -> String {
        guard let pricePence, let reportedAt else { return "No price" }
        return String(format: "%.1fp, ", pricePence) + Formatters.age(since: reportedAt, now: now)
    }

    var displayName: String {
        if let brand, !brand.isEmpty, !name.localizedCaseInsensitiveContains(brand) { return "\(brand), \(name)" }
        return name
    }

    var asPlace: Place {
        Place(id: "fuel-\(id)", name: displayName, subtitle: priceLabel(), coordinate: coordinate,
              categoryIDs: [PlaceCategory.petrol.id], iconName: PlaceCategory.petrol.iconName, source: .fuel,
              distance: distanceMetres)
    }
}

/// Reads cached Fuel Finder prices from Supabase (stage 10). Caches the last result on device
/// and serves it when offline.
actor FuelService {
    static let shared = FuelService()

    struct Cached: Codable {
        let fetchedAt: Date
        let latitude: Double
        let longitude: Double
        let fuelType: String
        let stations: [FuelStation]
    }

    enum Source { case live, cache }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("fuel-near.json")
    }

    private struct NearParams: Encodable {
        let lat: Double
        let lng: Double
        let radius_m: Double
        let fuel_type: String
    }

    private struct AlongParams: Encodable {
        let route: [[Double]] // [[lng, lat], ...]
        let corridor_m: Double
        let fuel_type: String
    }

    func stationsNear(_ coordinate: CLLocationCoordinate2D, radius: Double = 8000, fuel: FuelType = .current) async throws -> (stations: [FuelStation], source: Source, fetchedAt: Date) {
        do {
            guard let client = SupabaseClient.shared else { throw SupabaseClient.ClientError.notConfigured }
            let stations: [FuelStation] = try await client.rpc(
                "stations_near",
                params: NearParams(lat: coordinate.latitude, lng: coordinate.longitude, radius_m: radius, fuel_type: fuel.rawValue)
            )
            let cached = Cached(fetchedAt: Date(), latitude: coordinate.latitude, longitude: coordinate.longitude, fuelType: fuel.rawValue, stations: stations)
            try? JSONEncoder().encode(cached).write(to: cacheURL, options: .atomic)
            return (stations, .live, cached.fetchedAt)
        } catch {
            // Offline: fall back to the last result, re-measuring distances from here.
            guard let data = try? Data(contentsOf: cacheURL),
                  let cached = try? JSONDecoder().decode(Cached.self, from: data),
                  cached.fuelType == fuel.rawValue else { throw error }
            let stations = cached.stations.map { s in
                FuelStation(id: s.id, name: s.name, brand: s.brand, latitude: s.latitude, longitude: s.longitude,
                            isMotorwayServices: s.isMotorwayServices, pricePence: s.pricePence, reportedAt: s.reportedAt,
                            distanceMetres: GeoMath.distance(coordinate, s.coordinate), distanceAlongMetres: nil)
            }
            .filter { ($0.distanceMetres ?? 0) <= radius }
            .sorted { ($0.distanceMetres ?? 0) < ($1.distanceMetres ?? 0) }
            return (stations, .cache, cached.fetchedAt)
        }
    }

    /// Stations within `corridor` metres of a route, with distance along it.
    func stationsAlong(route: [CLLocationCoordinate2D], corridor: Double = 2000, fuel: FuelType = .current) async throws -> [FuelStation] {
        guard let client = SupabaseClient.shared else { throw SupabaseClient.ClientError.notConfigured }
        // Keep the payload small: ~1 point per km is plenty for a 2 km corridor.
        let sampled = GeoMath.resample(route, count: min(500, max(2, Int(GeoMath.length(of: route) / 1000))))
        return try await client.rpc(
            "stations_along",
            params: AlongParams(route: sampled.map { [$0.longitude, $0.latitude] }, corridor_m: corridor, fuel_type: fuel.rawValue)
        )
    }
}
