import CoreLocation
import Foundation
import SwiftData

/// One way to park near a destination, from any source.
struct ParkingOption: Identifiable, Equatable {
    enum Kind: Equatable {
        case freeStreet, paidStreet, freeCarPark, paidCarPark, unknownStreet, unknownCarPark

        var label: String {
            switch self {
            case .freeStreet: "Free street"
            case .paidStreet: "Paid street"
            case .freeCarPark: "Free car park"
            case .paidCarPark: "Paid car park"
            case .unknownStreet: "Street parking"
            case .unknownCarPark: "Car park"
            }
        }

        var isFree: Bool { self == .freeStreet || self == .freeCarPark }
        var isPaid: Bool { self == .paidStreet || self == .paidCarPark }
        var isStreet: Bool { self == .freeStreet || self == .paidStreet || self == .unknownStreet }
    }

    /// Trust order: Verified by me > From map data > Unverified.
    enum Confidence: Int, Comparable {
        case verifiedByMe = 0, fromMapData = 1, unverified = 2
        static func < (l: Confidence, r: Confidence) -> Bool { l.rawValue < r.rawValue }

        var label: String {
            switch self {
            case .verifiedByMe: "Verified by me"
            case .fromMapData: "From map data"
            case .unverified: "Unverified"
            }
        }
    }

    enum Source: Equatable { case mine(UUID), osm(String), manual(UUID), mapSearch(String) }

    let id: String
    var kind: Kind
    var name: String?
    let coordinate: CLLocationCoordinate2D
    let source: Source
    var confidence: Confidence
    var walkDistance: CLLocationDistance
    var walkMinutes: Double
    var maxStayMinutes: Int?
    var validNow: Bool?
    var validUntil: Date?
    /// Cost for the planned stay in pence, nil = price unknown.
    var stayCostPence: Int?
    var tariffText: String?
    var isAtDestination: Bool
    var staySupported: Bool?

    var title: String { name.map { "\($0) (\(kind.label.lowercased()))" } ?? kind.label }

    var validityText: String? {
        guard let validNow else { return nil }
        let clock = validUntil.map { Formatters.clock.string(from: $0) }
        switch (validNow, kind.isFree, clock) {
        case (true, true, let c?): return "Free until \(c)"
        case (true, false, let c?): return "Paid until \(c)"
        case (false, _, let c?): return "Not allowed until \(c)"
        case (false, _, nil): return "Not allowed now"
        default: return nil
        }
    }

    var costText: String {
        if kind.isFree { return "Free" }
        guard let stayCostPence else { return "Price unknown" }
        return Formatters.pounds(Double(stayCostPence) / 100)
    }

    static func == (l: ParkingOption, r: ParkingOption) -> Bool { l.id == r.id }
}

/// Normalised OSM parking record returned by the `parking-osm` Edge Function.
struct OSMParkingSpot: Decodable {
    let id: String
    let kind: String            // "car_park" | "street"
    let name: String?
    let lat: Double
    let lng: Double
    let fee: String?
    let feeConditional: String?
    let maxstay: String?
    let maxstayConditional: String?
    let restriction: String?
    let restrictionConditional: String?
    let access: String?
    let openingHours: String?
    let charge: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, lat, lng, fee, maxstay, restriction, access, charge
        case feeConditional = "fee_conditional"
        case maxstayConditional = "maxstay_conditional"
        case restrictionConditional = "restriction_conditional"
        case openingHours = "opening_hours"
    }
}

/// All parking data goes through here so more sources (council feeds, national DTRO data)
/// can be added later without touching the UI.
@MainActor
final class ParkingService {
    static let shared = ParkingService()

    struct Settings {
        var stayMinutes: Int
        var maxWalkMetres: Double
        var priority: ParkingPriority

        static var current: Settings {
            let d = UserDefaults.standard
            return Settings(
                stayMinutes: Int(d.double(forKey: SettingsKeys.plannedStayMinutes)),
                maxWalkMetres: d.double(forKey: SettingsKeys.maxWalkMetres),
                priority: ParkingPriority(rawValue: d.string(forKey: SettingsKeys.parkingPriority) ?? "") ?? .freeFirst
            )
        }
    }

    private struct OSMRequest: Encodable {
        let lat: Double
        let lng: Double
        let radius_m: Double
    }

    /// Options near `destination` within `radius`, best first.
    func options(near destination: CLLocationCoordinate2D, radius: Double? = nil, arrival: Date = Date(), settings: Settings = .current) async -> (options: [ParkingOption], notes: [String]) {
        let radius = radius ?? settings.maxWalkMetres
        var notes: [String] = []
        var options: [ParkingOption] = []

        // 1. My own spots.
        let context = Persistence.shared.mainContext
        let mine = (try? context.fetch(FetchDescriptor<SavedParkingSpot>())) ?? []
        for spot in mine where !spot.isHidden {
            let walk = WalkingRouter.estimate(from: spot.coordinate, to: destination)
            guard walk.distance <= radius * 1.3 else { continue }
            let cost = spot.isFree ? 0 : (spot.pricePerHourPence >= 0 ? ParkingRules.cost(for: settings.stayMinutes, pencePerHour: spot.pricePerHourPence) : nil)
            options.append(ParkingOption(
                id: "mine-\(spot.uuid)", kind: spot.isFree ? .freeStreet : .paidStreet, name: spot.timeLimitNote.isEmpty ? "My spot" : "My spot, \(spot.timeLimitNote)",
                coordinate: spot.coordinate, source: .mine(spot.uuid), confidence: .verifiedByMe,
                walkDistance: walk.distance, walkMinutes: walk.minutes,
                maxStayMinutes: spot.maxStayMinutes > 0 ? spot.maxStayMinutes : nil, validNow: nil, validUntil: nil,
                stayCostPence: cost, tariffText: nil, isAtDestination: walk.distance < 60,
                staySupported: spot.maxStayMinutes > 0 ? settings.stayMinutes <= spot.maxStayMinutes : nil
            ))
        }

        // 2. OpenStreetMap via the Supabase cache.
        if let client = SupabaseClient.shared {
            do {
                let spots: [OSMParkingSpot] = try await client.invoke(
                    function: "parking-osm",
                    body: OSMRequest(lat: destination.latitude, lng: destination.longitude, radius_m: max(radius, 500))
                )
                let hidden = Set(mine.filter(\.isHidden).map { "\($0.latitude),\($0.longitude)" })
                for spot in spots {
                    let c = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lng)
                    if hidden.contains("\(spot.lat),\(spot.lng)") { continue }
                    let walk = WalkingRouter.estimate(from: c, to: destination)
                    guard walk.distance <= radius * 1.3 else { continue }
                    options.append(option(from: spot, coordinate: c, walk: walk, arrival: arrival, settings: settings))
                }
            } catch {
                notes.append("Map parking data unavailable: \(error.localizedDescription)")
            }
        } else {
            notes.append("Connect Supabase to see street parking from OpenStreetMap.")
        }

        // 3. My manual car parks.
        let manual = (try? context.fetch(FetchDescriptor<ManualCarPark>())) ?? []
        for park in manual {
            let walk = WalkingRouter.estimate(from: park.coordinate, to: destination)
            guard walk.distance <= max(radius, 800) * 1.3 else { continue }
            let tariff = park.tariff
            let cost = ParkingRules.cost(for: settings.stayMinutes, tariff: tariff)
            options.append(ParkingOption(
                id: "manual-\(park.uuid)", kind: tariff.isEmpty ? .unknownCarPark : (tariff.allSatisfy { $0.pricePence == 0 } ? .freeCarPark : .paidCarPark),
                name: park.name, coordinate: park.coordinate, source: .manual(park.uuid), confidence: .verifiedByMe,
                walkDistance: walk.distance, walkMinutes: walk.minutes,
                maxStayMinutes: park.maxStayMinutes > 0 ? park.maxStayMinutes : nil, validNow: nil, validUntil: nil,
                stayCostPence: cost, tariffText: tariff.map { "\($0.upToMinutes / 60)h \(Formatters.pounds(Double($0.pricePence) / 100))" }.joined(separator: " · "),
                isAtDestination: walk.distance < 60,
                staySupported: park.maxStayMinutes > 0 ? settings.stayMinutes <= park.maxStayMinutes : nil
            ))
        }

        return (sort(dedupe(options), priority: settings.priority), notes)
    }

    private func option(from spot: OSMParkingSpot, coordinate: CLLocationCoordinate2D, walk: (distance: CLLocationDistance, minutes: Double), arrival: Date, settings: Settings) -> ParkingOption {
        let evaluation = ParkingRules.evaluate(
            fee: spot.fee, feeConditional: spot.feeConditional,
            maxstay: spot.maxstay, maxstayConditional: spot.maxstayConditional,
            restriction: spot.restriction, restrictionConditional: spot.restrictionConditional,
            access: spot.access, arrival: arrival, stayMinutes: settings.stayMinutes
        )
        let isStreet = spot.kind == "street"
        let kind: ParkingOption.Kind = switch evaluation.status {
        case .free: isStreet ? .freeStreet : .freeCarPark
        case .paid: isStreet ? .paidStreet : .paidCarPark
        default: isStreet ? .unknownStreet : .unknownCarPark
        }
        let validNow: Bool? = switch evaluation.status {
        case .restricted: false
        case .unknown: nil
        default: true
        }
        // OSM `charge` is free text ("£1.50/hour"); only use it if we can parse a per-hour rate.
        let perHour = spot.charge.flatMap(Self.pencePerHour(from:))
        let cost = kind.isFree ? 0 : perHour.map { ParkingRules.cost(for: settings.stayMinutes, pencePerHour: $0) }
        let confident = evaluation.status != .unknown && (evaluation.maxStayMinutes != nil || spot.fee != nil)
        return ParkingOption(
            id: "osm-\(spot.id)", kind: kind, name: spot.name, coordinate: coordinate, source: .osm(spot.id),
            confidence: confident ? .fromMapData : .unverified,
            walkDistance: walk.distance, walkMinutes: walk.minutes,
            maxStayMinutes: evaluation.maxStayMinutes, validNow: validNow, validUntil: evaluation.until,
            stayCostPence: cost, tariffText: spot.charge, isAtDestination: walk.distance < 60,
            staySupported: evaluation.staySupported
        )
    }

    static func pencePerHour(from charge: String) -> Int? {
        let lower = charge.lowercased()
        guard lower.contains("hour") || lower.contains("/h") else { return nil }
        let pattern = #"(?:£|gbp\s?)(\d+(?:\.\d{1,2})?)"#
        guard let range = lower.range(of: pattern, options: .regularExpression) else { return nil }
        let number = lower[range].filter { $0.isNumber || $0 == "." }
        return Double(number).map { Int(($0 * 100).rounded()) }
    }

    private func dedupe(_ options: [ParkingOption]) -> [ParkingOption] {
        var result: [ParkingOption] = []
        for option in options.sorted(by: { $0.confidence < $1.confidence }) {
            if !result.contains(where: { GeoMath.distance($0.coordinate, option.coordinate) < 15 }) { result.append(option) }
        }
        return result
    }

    /// "At destination" first, then by walking distance, with free-first or cheapest-first.
    func sort(_ options: [ParkingOption], priority: ParkingPriority) -> [ParkingOption] {
        options.sorted { a, b in
            if a.isAtDestination != b.isAtDestination { return a.isAtDestination }
            if (a.validNow == false) != (b.validNow == false) { return b.validNow == false }
            return a.walkDistance < b.walkDistance
        }
    }

    /// The one-glance summary above the list, built only from real values.
    struct SummaryLine: Identifiable {
        var id: String { option.id }
        let text: String
        let option: ParkingOption
    }

    func summary(for options: [ParkingOption], stayMinutes: Int) -> [SummaryLine] {
        var lines: [SummaryLine] = []
        let atDestination = options.first(where: \.isAtDestination)
        if let here = atDestination {
            lines.append(SummaryLine(text: "Parking here: \(here.kind.isFree ? "free" : here.stayCostPence.map { "\(Formatters.pounds(Double($0) / 100)) for your stay" } ?? "price unknown").", option: here))
        }
        if let free = options.first(where: { $0.kind.isFree && $0.validNow != false && !$0.isAtDestination }) {
            var text = "\(free.kind.label) about \(Int(free.walkMinutes.rounded())) min walk away."
            if let here = atDestination, let cost = here.stayCostPence, cost > 0 {
                text += " Saves \(Formatters.pounds(Double(cost) / 100)), \(Int(free.walkMinutes.rounded())) min walk each way."
            }
            lines.append(SummaryLine(text: text, option: free))
        }
        if let paid = options.first(where: { $0.kind.isPaid && !$0.isAtDestination && $0.validNow != false }) {
            lines.append(SummaryLine(text: "Paid parking also available, \(Int(paid.walkMinutes.rounded())) min walk (\(paid.costText)).", option: paid))
        }
        return lines
    }

    // MARK: "No luck?" helpers

    static let widenSteps: [Double] = [150, 300, 500]

    func saveMySpot(at coordinate: CLLocationCoordinate2D, isFree: Bool, note: String, maxStayMinutes: Int) {
        let spot = SavedParkingSpot(coordinate: coordinate, isFree: isFree, timeLimitNote: note, maxStayMinutes: maxStayMinutes)
        Persistence.shared.mainContext.insert(spot)
    }

    func markNotValid(_ option: ParkingOption) {
        let context = Persistence.shared.mainContext
        if case .mine(let uuid) = option.source,
           let spot = try? context.fetch(FetchDescriptor<SavedParkingSpot>(predicate: #Predicate { $0.uuid == uuid })).first {
            spot.isHidden = true
        } else {
            let hidden = SavedParkingSpot(coordinate: option.coordinate, isFree: false, timeLimitNote: "Not valid")
            hidden.isHidden = true
            context.insert(hidden)
        }
    }
}
