import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore
import SwiftData

/// A place the planner could use for a flexible stop.
struct PlannerCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    var pricePence: Double?
    var priceAge: TimeInterval?
    var isFavourite = false
    var isMotorwayServices = false
    /// Stage 11 ranked car park preference (0 = best).
    var preferredRank: Int?
    /// Walk from this car park to the destination (stage 13 weighting).
    var walkMinutes: Double = 0
    var parkingFeePounds: Double = 0
    /// Minutes spent stopped here (refuelling ≈ 5).
    var dwellMinutes: Double = 0
    /// Label such as "Petrol near Winchester, 55 miles in".
    var label: String?

    static func == (l: PlannerCandidate, r: PlannerCandidate) -> Bool { l.id == r.id }
}

/// Input to the pure solver. Node 0 is the origin.
struct PlanningProblem {
    struct Slot {
        let item: TripItem
        /// Matrix node for fixed stops.
        let node: Int?
        /// Candidate matrix nodes for flexible stops.
        let candidates: [(node: Int, candidate: PlannerCandidate)]
        var isFlexible: Bool { node == nil }
    }

    var slots: [Slot]
    var durations: [[Double]]   // seconds
    var distances: [[Double]]   // metres
    var departure: Date = Date()
}

struct PlannerOption: Identifiable, Equatable {
    let id = UUID()
    let orderedItemIDs: [UUID]
    let choices: [UUID: PlannerCandidate]
    let totalPounds: Double
    let driveSeconds: Double
    let latenessSeconds: TimeInterval?
    var lines: [String] = []

    static func == (l: PlannerOption, r: PlannerOption) -> Bool { l.id == r.id }
}

struct PlannerOutcome {
    var baseTrip: Trip
    var options: [PlannerOption]
    var selectedIndex = 0
    var notes: [String]

    var selected: PlannerOption? { options.indices.contains(selectedIndex) ? options[selectedIndex] : nil }

    mutating func select(_ option: PlannerOption) {
        if let i = options.firstIndex(of: option) { selectedIndex = i }
    }

    /// The final ordered list handed to the trip builder.
    var trip: Trip {
        guard let selected else { return baseTrip }
        let byID = Dictionary(uniqueKeysWithValues: baseTrip.items.map { ($0.id, $0) })
        let items: [TripItem] = selected.orderedItemIDs.compactMap { id in
            guard var item = byID[id] else { return nil }
            if let candidate = selected.choices[id] {
                item.name = candidate.label ?? candidate.name
                item.coordinate = candidate.coordinate
            }
            return item
        }
        // Keep via points that the planner didn't order, just before the final stop.
        let vias = baseTrip.items.filter { $0.kind == .via }
        var result = items
        if !vias.isEmpty { result.insert(contentsOf: vias, at: max(0, result.count - 1)) }
        return Trip(items: result)
    }

    var headline: String {
        guard let selected else { return "No plan" }
        return selected.lines.first ?? "Total \(Formatters.pounds(selected.totalPounds))"
    }
}

enum PlannerError: LocalizedError {
    case nothingToPlan, noCandidates(String)
    var errorDescription: String? {
        switch self {
        case .nothingToPlan: "Add a flexible stop (petrol, car park, …) and a destination first."
        case .noCandidates(let category): "Couldn't find any \(category.lowercased()) near your route."
        }
    }
}

/// Stage 11: turns fixed stops plus flexible category stops into the best ordered trip.
@MainActor
struct TripPlanner {
    let engine: NavigationEngine
    var maxCandidatesPerStop = 4

    func plan(trip: Trip, origin: CLLocation, settings: PlannerSettings) async throws -> PlannerOutcome {
        let fixed = trip.items.filter { $0.kind != .via && $0.coordinate != nil }
        let flexible = trip.items.filter { $0.categoryID != nil && $0.coordinate == nil }
        guard !flexible.isEmpty, !fixed.isEmpty else { throw PlannerError.nothingToPlan }

        // 1. Baseline route through the fixed stops, for corridor searches and detour maths.
        let baselineTrip = Trip(items: trip.items.filter { $0.coordinate != nil })
        let baseline = try await engine.calculator.calculate(origin: origin, trip: baselineTrip, alternatives: false)
        let shape = baseline.mainRoute.route.shape?.coordinates ?? fixed.compactMap(\.coordinate)
        let tripMiles = baseline.mainRoute.route.distance / 1609.344
        let destination = fixed.last!.coordinate!

        var notes: [String] = []
        var points: [CLLocationCoordinate2D] = [origin.coordinate] + fixed.map { $0.coordinate! }
        var slots: [PlanningProblem.Slot] = fixed.enumerated().map { .init(item: $1, node: $0 + 1, candidates: []) }

        // 2. Candidates for each flexible stop.
        for item in flexible {
            guard let category = PlaceCategory.with(id: item.categoryID!) else { continue }
            var (candidates, candidateNotes) = try await findCandidates(
                for: category, item: item, routeShape: shape, origin: origin.coordinate, destination: destination,
                tripMiles: tripMiles, settings: settings
            )
            candidates = Array(candidates.prefix(maxCandidatesPerStop))
            if item.freeParkingPreferred, !category.isParking {
                let checked = await preferFreeParking(candidates, stayMinutes: item.stayMinutes ?? 30)
                candidates = checked.candidates
                candidateNotes += checked.notes
            }
            notes += candidateNotes
            guard !candidates.isEmpty else { throw PlannerError.noCandidates(item.query ?? category.displayName) }
            var nodes: [(node: Int, candidate: PlannerCandidate)] = []
            for candidate in candidates {
                points.append(candidate.coordinate)
                nodes.append((node: points.count - 1, candidate: candidate))
            }
            slots.append(.init(item: item, node: nil, candidates: nodes))
        }

        // 3. Drive times between everything.
        let matrix = try await MatrixService.shared.matrix(for: points)
        let problem = PlanningProblem(slots: slots, durations: matrix.durations, distances: matrix.distances)
        var options = Self.solve(problem, settings: settings)
        guard !options.isEmpty else { throw PlannerError.nothingToPlan }
        Self.describe(&options, problem: problem, settings: settings)

        if let late = options.first?.latenessSeconds {
            notes.append("You'd be \(Formatters.duration(late)) late for your arrive-by time on the best plan.")
        }
        return PlannerOutcome(baseTrip: trip, options: Array(options.prefix(3)), notes: notes)
    }

    private func findCandidates(
        for category: PlaceCategory,
        item: TripItem,
        routeShape: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        tripMiles: Double,
        settings: PlannerSettings
    ) async throws -> ([PlannerCandidate], [String]) {
        var notes: [String] = []
        switch category.id {
        case PlaceCategory.petrol.id:
            let favourites = FavouriteStationStore.ids()
            var stations: [FuelStation] = []
            let window = PlannerScoring.preferredFuelWindow(tripMiles: tripMiles, settings: settings)
            do {
                stations = try await FuelService.shared.stationsAlong(route: routeShape, corridor: PlaceSearchService.corridorMetres)
                if let window {
                    let inWindow = stations.filter { s in
                        guard let along = s.distanceAlongMetres else { return false }
                        return window.contains(along / 1609.344)
                    }
                    if !inWindow.isEmpty { stations = inWindow }
                    else { notes.append("No stations in the ideal 60–80% range window, so the planner looked along the whole route.") }
                }
            } catch {
                notes.append("Fuel prices unavailable (\(error.localizedDescription)). Choosing by distance only.")
                let places = try await PlaceSearchService.shared.search(category: category, near: origin)
                stations = places.map {
                    FuelStation(id: $0.id, name: $0.name, brand: nil, latitude: $0.latitude, longitude: $0.longitude,
                                isMotorwayServices: false, pricePence: nil, reportedAt: nil, distanceMetres: $0.distance, distanceAlongMetres: nil)
                }
            }
            let quotes = stations.map {
                PlannerScoring.StationQuote(
                    id: $0.id, name: $0.displayName, pricePence: $0.pricePence, priceAge: $0.priceAge(),
                    isFavourite: favourites.contains($0.id), isMotorwayServices: $0.isMotorwayServices,
                    extraMinutes: (($0.distanceMetres ?? 0) * 2 / 1000) / 0.8 // rough: off-route km at 48 km/h
                )
            }
            let filtered = PlannerScoring.filter(quotes, settings: settings)
            notes += filtered.notes
            let keptIDs = Set(filtered.kept.map(\.id))
            let candidates = stations.filter { keptIDs.contains($0.id) }
                .sorted { ($0.pricePence ?? 999) < ($1.pricePence ?? 999) }
                .map { s -> PlannerCandidate in
                    var label: String?
                    if window != nil, let along = s.distanceAlongMetres {
                        label = "Petrol, \(s.displayName), \(Int((along / 1609.344).rounded())) miles in"
                    }
                    return PlannerCandidate(
                        id: s.id, name: s.displayName, coordinate: s.coordinate, pricePence: s.pricePence,
                        priceAge: s.priceAge(), isFavourite: favourites.contains(s.id),
                        isMotorwayServices: s.isMotorwayServices, dwellMinutes: 5, label: label
                    )
                }
            return (candidates, notes)

        case PlaceCategory.carPark.id:
            // Ranked preferred car parks near the destination first, then priced options for
            // the planned stay (OpenStreetMap + my own), then the best car parks nearby.
            let preferred = PreferredCarParkStore.all()
                .filter { GeoMath.distance($0.coordinate, destination) < 1500 }
            if preferred.isEmpty, SupabaseClient.shared != nil {
                var parking = ParkingService.Settings.current
                if let stay = item.stayMinutes { parking.stayMinutes = stay }
                let found = await ParkingService.shared.options(near: destination, radius: max(parking.maxWalkMetres, 600), settings: parking)
                var usable = found.options.filter { $0.validNow != false && $0.staySupported != false }
                if item.freeParkingPreferred {
                    let free = usable.filter(\.kind.isFree)
                    if free.isEmpty { notes.append("No free parking found near the destination, so paid options are included.") }
                    else { usable = free }
                }
                if !usable.isEmpty {
                    return (usable.prefix(6).map { option in
                        PlannerCandidate(
                            id: option.id, name: option.title, coordinate: option.coordinate,
                            walkMinutes: option.walkMinutes,
                            // Unknown prices count as £3 so known-cheap options win.
                            parkingFeePounds: option.stayCostPence.map { Double($0) / 100 } ?? (option.kind.isFree ? 0 : 3),
                            label: "\(option.title), \(option.costText) for \(StayPicker.label(parking.stayMinutes).lowercased())"
                        )
                    }, notes)
                }
            }
            if !preferred.isEmpty {
                return (preferred.map { p in
                    let walk = WalkingRouter.estimate(from: p.coordinate, to: destination)
                    return PlannerCandidate(id: "pref-\(p.rank)", name: p.name, coordinate: p.coordinate, preferredRank: p.rank, walkMinutes: walk.minutes)
                }, notes)
            }
            let places = try await PlaceSearchService.shared.search(category: category, near: destination)
            return (places.map { p in
                let walk = WalkingRouter.estimate(from: p.coordinate, to: destination)
                return PlannerCandidate(id: p.id, name: p.name, coordinate: p.coordinate, walkMinutes: walk.minutes)
            }.sorted { $0.walkMinutes < $1.walkMinutes }, notes)

        default:
            // Cafes, food and free-text stops ("laundromat"): along the route within the
            // detour allowance, falling back to near the middle of the route.
            let search = PlaceSearchService.shared
            let dietary = item.dietary.compactMap(DietaryFilter.init(rawValue:))
            var places: [Place]
            if category.id == PlaceCategory.search.id {
                guard let query = item.query, !query.isEmpty else { return ([], notes) }
                places = try await search.textSearch(query, alongRoute: routeShape)
                if places.isEmpty {
                    places = try await search.textSearch(query, near: origin)
                    if !places.isEmpty { notes.append("No \(query) right on your route, so the planner looked near you.") }
                }
            } else if !dietary.isEmpty, category.supportsDietary {
                let result = try await search.dietarySearch(category: category, filters: dietary, alongRoute: routeShape)
                places = result.places
                if let note = result.note { notes.append(note) }
            } else {
                places = try await search.search(category: category, alongRoute: routeShape)
            }
            if places.isEmpty, category.id != PlaceCategory.search.id {
                let middle = GeoMath.coordinate(along: routeShape, at: GeoMath.length(of: routeShape) / 2) ?? origin
                places = try await search.search(category: category, near: middle)
            }
            let dwell = Double(item.stayMinutes ?? 0)
            return (places.map { PlannerCandidate(id: $0.id, name: $0.name, coordinate: $0.coordinate, dwellMinutes: dwell) }, notes)
        }
    }

    /// "No change for parking": prefer stops with free parking close by. Stops without it
    /// cost an extra £5 in the score, so they only win when nothing else is close.
    private func preferFreeParking(_ candidates: [PlannerCandidate], stayMinutes: Int) async -> (candidates: [PlannerCandidate], notes: [String]) {
        guard SupabaseClient.shared != nil else {
            return (candidates, ["Connect Supabase to check for free parking at stops."])
        }
        var parking = ParkingService.Settings.current
        parking.stayMinutes = stayMinutes
        var checked: [PlannerCandidate] = []
        var anyFree = false
        for var candidate in candidates {
            let options = await ParkingService.shared.options(near: candidate.coordinate, radius: 250, settings: parking).options
            if let free = options.first(where: { $0.kind.isFree && $0.validNow != false && $0.staySupported != false }) {
                anyFree = true
                candidate.walkMinutes += free.walkMinutes
                candidate.label = "\(candidate.name) (free parking, \(max(1, Int(free.walkMinutes.rounded()))) min walk)"
            } else {
                candidate.parkingFeePounds += 5
            }
            checked.append(candidate)
        }
        return (checked, anyFree ? [] : ["Couldn't confirm free parking at any of these stops. Check the signs."])
    }

    // MARK: Pure solver

    /// Tries every valid ordering and candidate combination and scores each in pounds.
    /// On-time plans come first; if none is on time, the least late.
    nonisolated static func solve(_ problem: PlanningProblem, settings: PlannerSettings) -> [PlannerOption] {
        let slots = problem.slots
        let hasExplicitLast = slots.contains { $0.item.orderingRule == .last }
        let finalFixedID = slots.last { !$0.isFlexible }?.item.id

        let orderNodes = slots.map { slot -> PlannerScoring.OrderNode in
            var rule = slot.item.orderingRule
            if !hasExplicitLast, slot.item.id == finalFixedID, rule == nil { rule = .last }
            return PlannerScoring.OrderNode(id: slot.item.id, rule: rule)
        }
        let slotByID = Dictionary(uniqueKeysWithValues: slots.map { ($0.item.id, $0) })
        let flexibleSlots = slots.filter(\.isFlexible)

        var options: [PlannerOption] = []
        for order in PlannerScoring.permutations(orderNodes) where PlannerScoring.isValid(order: order) {
            let orderedSlots = order.compactMap { slotByID[$0.id] }
            let fixedOnly = orderedSlots.compactMap(\.node)
            let baselineMetres = pathLength([0] + fixedOnly, problem.distances)

            for combo in cartesian(flexibleSlots.map { $0.candidates.indices.map { $0 } }) {
                var choice: [UUID: (node: Int, candidate: PlannerCandidate)] = [:]
                for (k, slot) in flexibleSlots.enumerated() { choice[slot.item.id] = slot.candidates[combo[k]] }

                let nodes = [0] + orderedSlots.map { $0.node ?? choice[$0.item.id]!.node }
                let driveSeconds = pathLength(nodes, problem.durations)
                guard driveSeconds.isFinite else { continue }
                let metres = pathLength(nodes, problem.distances)
                let detourKm = max(0, (metres - baselineMetres) / 1000)

                // Arrival times and lateness.
                var clock = problem.departure
                var worstLate: TimeInterval?
                for (index, slot) in orderedSlots.enumerated() {
                    clock += problem.durations[nodes[index]][nodes[index + 1]]
                    if let late = PlannerScoring.lateness(arrival: clock, arriveBy: slot.item.arriveBy) {
                        worstLate = max(worstLate ?? 0, late)
                    }
                    clock += (choice[slot.item.id]?.candidate.dwellMinutes ?? 0) * 60
                }

                var total = PlannerScoring.journeyCost(driveMinutes: driveSeconds / 60, settings: settings)
                for (_, picked) in choice {
                    let c = picked.candidate
                    if let price = c.pricePence {
                        total += PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: price, detourKm: detourKm, isFavourite: c.isFavourite, settings: settings)
                    }
                    total += PlannerScoring.journeyCost(driveMinutes: 0, walkMinutes: c.walkMinutes, parkingFeePounds: c.parkingFeePounds, settings: settings)
                    if let rank = c.preferredRank { total += Double(rank) * 0.01 } // tie-break by rank
                }

                options.append(PlannerOption(
                    orderedItemIDs: order.map(\.id),
                    choices: choice.mapValues { $0.candidate },
                    totalPounds: total,
                    driveSeconds: driveSeconds,
                    latenessSeconds: worstLate
                ))
            }
        }

        return options.sorted { a, b in
            switch (a.latenessSeconds, b.latenessSeconds) {
            case (nil, nil): return a.totalPounds < b.totalPounds
            case (nil, _): return true
            case (_, nil): return false
            case let (la?, lb?): return la == lb ? a.totalPounds < b.totalPounds : la < lb
            }
        }
        .reduce(into: [PlannerOption]()) { unique, option in
            // Drop options that pick the same places in the same order.
            let key = option.orderedItemIDs.map { option.choices[$0]?.id ?? $0.uuidString }
            if !unique.contains(where: { u in u.orderedItemIDs.map { u.choices[$0]?.id ?? $0.uuidString } == key }) {
                unique.append(option)
            }
        }
    }

    /// Fills in the plain-English breakdown lines.
    nonisolated static func describe(_ options: inout [PlannerOption], problem: PlanningProblem, settings: PlannerSettings) {
        guard let best = options.first else { return }
        let fastest = options.map(\.driveSeconds).min() ?? best.driveSeconds
        for i in options.indices {
            let option = options[i]
            let other: PlannerOption? = i == 0 ? options.dropFirst().first : best
            var lines: [String] = []
            for id in option.orderedItemIDs {
                guard let c = option.choices[id] else { continue }
                let comparison: (String, Double)? = other.flatMap { o in
                    guard let oc = o.choices[id], oc.id != c.id else { return nil }
                    return (oc.name, o.totalPounds)
                }
                lines.append(PlannerScoring.breakdown(
                    name: c.name, pricePence: c.pricePence,
                    addedMinutes: (option.driveSeconds - fastest) / 60 + c.dwellMinutes,
                    cost: option.totalPounds,
                    against: comparison.map { (name: $0.0, cost: $0.1) },
                    isMotorway: c.isMotorwayServices
                ))
            }
            lines.append("Total \(Formatters.pounds(option.totalPounds)) · drive \(Formatters.duration(option.driveSeconds))")
            if let late = option.latenessSeconds { lines.append("\(Formatters.duration(late)) late for arrive-by") }
            options[i].lines = lines
        }
    }

    nonisolated static func pathLength(_ nodes: [Int], _ matrix: [[Double]]) -> Double {
        zip(nodes, nodes.dropFirst()).reduce(0) { $0 + matrix[$1.0][$1.1] }
    }

    nonisolated static func cartesian(_ ranges: [[Int]]) -> [[Int]] {
        ranges.reduce([[]]) { partial, range in partial.flatMap { prefix in range.map { prefix + [$0] } } }
    }
}

/// Lightweight read access to SwiftData-backed settings for non-view code.
@MainActor
enum FavouriteStationStore {
    static func ids() -> Set<String> {
        let context = Persistence.shared.mainContext
        let stations = (try? context.fetch(FetchDescriptor<FavouriteStation>())) ?? []
        return Set(stations.map(\.stationID))
    }
}

@MainActor
enum PreferredCarParkStore {
    static func all() -> [PreferredCarPark] {
        let context = Persistence.shared.mainContext
        let descriptor = FetchDescriptor<PreferredCarPark>(sortBy: [SortDescriptor(\.rank)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
