import Foundation

/// Planner settings (stage 11), all stored in @AppStorage.
struct PlannerSettings: Equatable {
    var litresPerFill: Double = 25
    var valueOfTimePerHour: Double = 12        // £/h
    var mpg: Double = 40                       // UK mpg
    var favouriteBonusPence: Double = 2        // p/l
    var maxAbovePenceCheapest: Double = 5      // p/l
    var tankRangeMiles: Double = 350
    /// 0...1, nil when unknown. The app can't read the fuel gauge.
    var fuelLevel: Double?
    /// Stage 13: walking minutes count this many times driving minutes.
    var walkingWeight: Double = 2

    static var current: PlannerSettings {
        let d = UserDefaults.standard
        let level = d.double(forKey: SettingsKeys.fuelLevelPercent)
        return PlannerSettings(
            litresPerFill: d.double(forKey: SettingsKeys.litresPerFill),
            valueOfTimePerHour: d.double(forKey: SettingsKeys.valueOfTimePerHour),
            mpg: d.double(forKey: SettingsKeys.mpg),
            favouriteBonusPence: d.double(forKey: SettingsKeys.favouriteBonusPence),
            maxAbovePenceCheapest: d.double(forKey: SettingsKeys.maxAbovePenceCheapest),
            tankRangeMiles: d.double(forKey: SettingsKeys.tankRangeMiles),
            fuelLevel: level < 0 ? nil : level / 100,
            walkingWeight: d.double(forKey: SettingsKeys.walkingWeight)
        )
    }

    /// UK gallon = 4.54609 l, mile = 1.609344 km.
    var kmPerLitre: Double { mpg * 1.609344 / 4.54609 }
    var poundsPerMinute: Double { valueOfTimePerHour / 60 }
}

/// Pure scoring functions. Every amount is in pounds.
enum PlannerScoring {
    static let maxPriceAge: TimeInterval = 24 * 3600

    // MARK: Core formula

    /// total = drive minutes × (value of time / 60)
    ///       + litres × price per litre
    ///       + detour km / km per litre × price per litre
    ///       − litres × favourite bonus (if a favourite)
    static func fuelStopCost(
        driveMinutes: Double,
        pricePencePerLitre: Double,
        detourKm: Double,
        isFavourite: Bool,
        settings: PlannerSettings
    ) -> Double {
        let price = pricePencePerLitre / 100
        let time = driveMinutes * settings.poundsPerMinute
        let fill = settings.litresPerFill * price
        let detourFuel = max(0, detourKm) / settings.kmPerLitre * price
        let bonus = isFavourite ? settings.litresPerFill * settings.favouriteBonusPence / 100 : 0
        return time + fill + detourFuel - bonus
    }

    /// Time cost of driving plus (stage 13) weighted walking and any parking fee.
    static func journeyCost(driveMinutes: Double, walkMinutes: Double = 0, parkingFeePounds: Double = 0, settings: PlannerSettings) -> Double {
        (driveMinutes + walkMinutes * settings.walkingWeight) * settings.poundsPerMinute + parkingFeePounds
    }

    // MARK: Station filtering

    struct StationQuote: Equatable {
        let id: String
        let name: String
        let pricePence: Double?
        let priceAge: TimeInterval?
        let isFavourite: Bool
        let isMotorwayServices: Bool
        /// Extra minutes this station adds to the trip (used for the favourite exception).
        let extraMinutes: Double

        var hasFreshPrice: Bool { pricePence != nil && (priceAge ?? .infinity) <= PlannerScoring.maxPriceAge }
    }

    struct FilterResult: Equatable {
        var kept: [StationQuote]
        var notes: [String]
    }

    /// Applies the stage 11 exclusion rules:
    /// - no price or price older than 24 h is excluded, unless nothing else is available;
    /// - more than `maxAbovePenceCheapest` above the cheapest is excluded, unless it's a
    ///   favourite that fits inside `detourAllowanceMinutes`.
    static func filter(_ quotes: [StationQuote], settings: PlannerSettings, detourAllowanceMinutes: Double = 10) -> FilterResult {
        var notes: [String] = []
        var pool = quotes.filter(\.hasFreshPrice)
        if pool.isEmpty {
            pool = quotes.filter { $0.pricePence != nil }
            if !pool.isEmpty {
                notes.append("No prices from the last 24 hours nearby, so older prices are used. Check the price at the pump.")
            } else {
                notes.append("No stations nearby have reported a price.")
                return FilterResult(kept: quotes, notes: notes)
            }
        }
        guard let cheapest = pool.compactMap(\.pricePence).min() else { return FilterResult(kept: pool, notes: notes) }
        let kept = pool.filter { quote in
            guard let price = quote.pricePence else { return false }
            if price - cheapest <= settings.maxAbovePenceCheapest { return true }
            return quote.isFavourite && quote.extraMinutes <= detourAllowanceMinutes
        }
        return FilterResult(kept: kept, notes: notes)
    }

    // MARK: Long trips

    /// For trips longer than 60% of range, the window (miles from start) where a fill-up
    /// should happen: 60–80% of the range you have now.
    static func preferredFuelWindow(tripMiles: Double, settings: PlannerSettings) -> ClosedRange<Double>? {
        let available = settings.tankRangeMiles * (settings.fuelLevel ?? 1)
        guard tripMiles > 0.6 * settings.tankRangeMiles || tripMiles > 0.6 * available else { return nil }
        return (0.6 * available)...(0.8 * available)
    }

    static func isLongTrip(tripMiles: Double, settings: PlannerSettings) -> Bool {
        preferredFuelWindow(tripMiles: tripMiles, settings: settings) != nil
    }

    // MARK: Arrive-by

    /// Seconds late, or nil if on time.
    static func lateness(arrival: Date, arriveBy: Date?) -> TimeInterval? {
        guard let arriveBy, arrival > arriveBy else { return nil }
        return arrival.timeIntervalSince(arriveBy)
    }

    // MARK: Explanation

    /// "Shell, Wimborne Rd, 142.9p, adds 3 min, saves £1.80 against BP Castle Lane"
    static func breakdown(name: String, pricePence: Double?, addedMinutes: Double, cost: Double, against other: (name: String, cost: Double)?, isMotorway: Bool = false) -> String {
        var parts = [name]
        if let pricePence { parts.append(String(format: "%.1fp", pricePence)) }
        parts.append("adds \(max(0, Int(addedMinutes.rounded()))) min")
        if let other {
            let diff = other.cost - cost
            if diff >= 0.005 {
                parts.append("saves \(Formatters.pounds(diff)) against \(other.name)")
            } else if diff <= -0.005 {
                parts.append("costs \(Formatters.pounds(-diff)) more than \(other.name)")
            }
        }
        if isMotorway { parts.append("motorway services, usually dearer") }
        return parts.joined(separator: ", ")
    }

    // MARK: Ordering

    struct OrderNode: Equatable {
        let id: UUID
        let rule: TripItem.OrderingRule?
    }

    /// Whether an ordering satisfies every before / after / last rule.
    static func isValid(order: [OrderNode]) -> Bool {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
        for (index, node) in order.enumerated() {
            switch node.rule {
            case .before(let other): if let o = position[other], index > o { return false }
            case .after(let other): if let o = position[other], index < o { return false }
            case .last: if index != order.count - 1 { return false }
            case nil: break
            }
        }
        return true
    }

    /// All permutations (fine for the handful of stops a personal trip has; capped at 8).
    static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        guard items.count <= 8 else { return [items] }
        var result: [[T]] = []
        for (i, item) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for perm in permutations(rest) { result.append([item] + perm) }
        }
        return result
    }
}
