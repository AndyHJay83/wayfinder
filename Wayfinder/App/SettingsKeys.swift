import Foundation

/// Every @AppStorage key in one place, with its default.
enum SettingsKeys {
    // Stage 4: route preferences
    static let avoidMotorways = "avoidMotorways"
    static let avoidTolls = "avoidTolls"
    static let avoidFerries = "avoidFerries"
    static let travelMode = "travelMode"

    // Stage 9: faster-route checker
    static let fasterRouteThresholdSeconds = "fasterRouteThresholdSeconds"   // default 60
    static let fasterRouteAutoAccept = "fasterRouteAutoAccept"               // default false
    static let fasterRouteAutoAcceptSeconds = "fasterRouteAutoAcceptSeconds" // default 180

    // Stage 10: fuel
    static let fuelType = "fuelType" // E10 default

    // Stage 11: planner
    static let litresPerFill = "litresPerFill"                 // 25
    static let valueOfTimePerHour = "valueOfTimePerHour"       // £12
    static let mpg = "mpg"                                     // 40
    static let favouriteBonusPence = "favouriteBonusPence"     // 2p/l
    static let maxAbovePenceCheapest = "maxAbovePenceCheapest" // 5p/l
    static let tankRangeMiles = "tankRangeMiles"               // 350
    static let fuelLevelPercent = "fuelLevelPercent"           // -1 = unknown

    // Stage 13: parking
    static let plannedStayMinutes = "plannedStayMinutes"       // 60
    static let maxWalkMetres = "maxWalkMetres"                 // 400
    static let parkingPriority = "parkingPriority"             // freeFirst / cheapestFirst
    static let walkingWeight = "walkingWeight"                 // 2.0

    // Map style picker (optional later stage)
    static let mapStyleChoice = "mapStyleChoice"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            avoidMotorways: false,
            avoidTolls: false,
            avoidFerries: false,
            travelMode: TravelMode.driving.rawValue,
            fasterRouteThresholdSeconds: 60.0,
            fasterRouteAutoAccept: false,
            fasterRouteAutoAcceptSeconds: 180.0,
            fuelType: FuelType.e10.rawValue,
            litresPerFill: 25.0,
            valueOfTimePerHour: 12.0,
            mpg: 40.0,
            favouriteBonusPence: 2.0,
            maxAbovePenceCheapest: 5.0,
            tankRangeMiles: 350.0,
            fuelLevelPercent: -1.0,
            plannedStayMinutes: 60.0,
            maxWalkMetres: 400.0,
            parkingPriority: ParkingPriority.freeFirst.rawValue,
            walkingWeight: 2.0,
        ])
    }
}

enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case driving
    case walking
    var id: String { rawValue }
    var label: String { self == .driving ? "Driving" : "Walking" }
}

enum ParkingPriority: String, CaseIterable, Identifiable {
    case freeFirst
    case cheapestFirst
    var id: String { rawValue }
    var label: String { self == .freeFirst ? "Free first" : "Cheapest first" }
}
