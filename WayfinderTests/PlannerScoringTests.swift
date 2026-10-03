import CoreLocation
import XCTest
@testable import Wayfinder

@MainActor
final class PlannerScoringTests: XCTestCase {
    let settings = PlannerSettings() // defaults: 25 l, £12/h, 40 mpg, 2p bonus, 5p max above, 350 mi

    func testKmPerLitreFromMPG() {
        // 40 UK mpg = 40 × 1.609344 / 4.54609 ≈ 14.16 km/l
        XCTAssertEqual(settings.kmPerLitre, 14.16, accuracy: 0.01)
    }

    /// Worked example printed in the test log.
    func testExampleCalculation() {
        // Shell Wimborne Rd: 142.9p, 3 extra minutes, 2 km detour, a favourite.
        let shell = PlannerScoring.fuelStopCost(driveMinutes: 3, pricePencePerLitre: 142.9, detourKm: 2, isFavourite: true, settings: settings)
        // BP Castle Lane: 145.9p, no extra time, no detour.
        let bp = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 145.9, detourKm: 0, isFavourite: false, settings: settings)

        // Shell: 3 × 0.20 = 0.60 time; 25 × 1.429 = 35.725 fill; 2 / 14.16 × 1.429 = 0.202 detour; −25 × 0.02 = −0.50 bonus
        XCTAssertEqual(shell, 0.60 + 35.725 + 0.2018 - 0.50, accuracy: 0.01)
        // BP: 25 × 1.459 = 36.475
        XCTAssertEqual(bp, 36.475, accuracy: 0.001)

        let line = PlannerScoring.breakdown(name: "Shell, Wimborne Rd", pricePence: 142.9, addedMinutes: 3, cost: shell, against: ("BP Castle Lane", bp))
        print("""
        ── Example planner calculation ──
        Shell, Wimborne Rd: 3 min × £0.20 + 25 l × £1.429 + 2 km ÷ \(String(format: "%.2f", settings.kmPerLitre)) km/l × £1.429 − 25 l × 2p = \(Formatters.pounds(shell))
        BP Castle Lane:     0 min + 25 l × £1.459 = \(Formatters.pounds(bp))
        → \(line)
        """)
        XCTAssertEqual(line, "Shell, Wimborne Rd, 142.9p, adds 3 min, saves £0.45 against BP Castle Lane")
    }

    func testDetourCostScalesWithDistanceAndPrice() {
        let none = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 150, detourKm: 0, isFavourite: false, settings: settings)
        let ten = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 150, detourKm: 10, isFavourite: false, settings: settings)
        XCTAssertEqual(ten - none, 10 / settings.kmPerLitre * 1.5, accuracy: 0.0001)
        // Negative detours never pay you.
        let negative = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 150, detourKm: -5, isFavourite: false, settings: settings)
        XCTAssertEqual(negative, none, accuracy: 0.0001)
    }

    func testFavouriteBonus() {
        let plain = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 140, detourKm: 0, isFavourite: false, settings: settings)
        let fav = PlannerScoring.fuelStopCost(driveMinutes: 0, pricePencePerLitre: 140, detourKm: 0, isFavourite: true, settings: settings)
        XCTAssertEqual(plain - fav, 0.50, accuracy: 0.0001) // 25 l × 2p
    }

    // MARK: Filtering

    private func quote(_ id: String, _ price: Double?, ageHours: Double? = 1, favourite: Bool = false, extra: Double = 0) -> PlannerScoring.StationQuote {
        .init(id: id, name: id, pricePence: price, priceAge: ageHours.map { $0 * 3600 }, isFavourite: favourite, isMotorwayServices: false, extraMinutes: extra)
    }

    func testExcludesMissingAndStalePrices() {
        let result = PlannerScoring.filter([quote("fresh", 140), quote("stale", 130, ageHours: 30), quote("none", nil)], settings: settings)
        XCTAssertEqual(result.kept.map(\.id), ["fresh"])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testFallsBackToStalePricesWhenNothingElseAndSaysSo() {
        let result = PlannerScoring.filter([quote("stale", 130, ageHours: 30), quote("none", nil)], settings: settings)
        XCTAssertEqual(result.kept.map(\.id), ["stale"])
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testExcludesStationsTooFarAboveCheapestUnlessFavouriteWithinDetour() {
        let result = PlannerScoring.filter([
            quote("cheap", 140),
            quote("ok", 144.9),
            quote("dear", 146),
            quote("dearFavNear", 147, favourite: true, extra: 5),
            quote("dearFavFar", 147, favourite: true, extra: 25),
        ], settings: settings, detourAllowanceMinutes: 10)
        XCTAssertEqual(result.kept.map(\.id), ["cheap", "ok", "dearFavNear"])
    }

    // MARK: Long trips

    func testPreferredFuelWindowForLongTrips() {
        XCTAssertNil(PlannerScoring.preferredFuelWindow(tripMiles: 100, settings: settings))
        let window = PlannerScoring.preferredFuelWindow(tripMiles: 300, settings: settings)
        XCTAssertEqual(window?.lowerBound ?? 0, 210, accuracy: 0.01)
        XCTAssertEqual(window?.upperBound ?? 0, 280, accuracy: 0.01)

        var halfTank = settings
        halfTank.fuelLevel = 0.5
        let half = PlannerScoring.preferredFuelWindow(tripMiles: 150, settings: halfTank)
        XCTAssertEqual(half?.lowerBound ?? 0, 105, accuracy: 0.01)
    }

    // MARK: Arrival time

    func testLateness() {
        let arriveBy = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(PlannerScoring.lateness(arrival: arriveBy.addingTimeInterval(-60), arriveBy: arriveBy))
        XCTAssertEqual(PlannerScoring.lateness(arrival: arriveBy.addingTimeInterval(600), arriveBy: arriveBy), 600)
        XCTAssertNil(PlannerScoring.lateness(arrival: arriveBy, arriveBy: nil))
    }

    // MARK: Ordering rules

    func testOrderingRules() {
        let a = UUID(), b = UUID(), c = UUID()
        let order: [PlannerScoring.OrderNode] = [.init(id: a, rule: .before(b)), .init(id: b, rule: nil), .init(id: c, rule: .last)]
        XCTAssertTrue(PlannerScoring.isValid(order: order))
        XCTAssertFalse(PlannerScoring.isValid(order: [order[1], order[0], order[2]]))
        XCTAssertFalse(PlannerScoring.isValid(order: [order[2], order[0], order[1]]))
        XCTAssertEqual(PlannerScoring.permutations([1, 2, 3]).count, 6)
    }

    // MARK: Solver

    func testSolverPicksCheaperStationAndReportsLateness() {
        // Nodes: 0 origin, 1 destination, 2 cheap station (+4 min), 3 dear station (on route)
        let destination = TripItem(kind: .stop, name: "Pavilion", coordinate: .init(latitude: 50.716, longitude: -1.875))
        let petrol = TripItem(kind: .category(PlaceCategory.petrol.id), name: "Petrol", coordinate: nil)
        let cheap = PlannerCandidate(id: "cheap", name: "Shell", coordinate: .init(latitude: 0, longitude: 0), pricePence: 140, priceAge: 3600)
        let dear = PlannerCandidate(id: "dear", name: "BP", coordinate: .init(latitude: 0, longitude: 0), pricePence: 150, priceAge: 3600)
        let minutes: [[Double]] = [
            [0, 10, 5, 4],
            [10, 0, 7, 6],
            [5, 7, 0, 3],
            [4, 6, 3, 0],
        ]
        let km: [[Double]] = [
            [0, 8, 4, 3],
            [8, 0, 6, 5],
            [4, 6, 0, 2],
            [3, 5, 2, 0],
        ]
        var problem = PlanningProblem(
            slots: [
                .init(item: destination, node: 1, candidates: []),
                .init(item: petrol, node: nil, candidates: [(node: 2, candidate: cheap), (node: 3, candidate: dear)]),
            ],
            durations: minutes.map { $0.map { $0 * 60 } },
            distances: km.map { $0.map { $0 * 1000 } },
            departure: Date(timeIntervalSince1970: 0)
        )
        var options = TripPlanner.solve(problem, settings: settings)
        // Destination is implicitly last, so petrol comes first.
        XCTAssertEqual(options.first?.orderedItemIDs, [petrol.id, destination.id])
        XCTAssertEqual(options.first?.choices[petrol.id]?.id, "cheap")
        TripPlanner.describe(&options, problem: problem, settings: settings)
        print("Planner winner: \(options[0].lines.joined(separator: " | "))")

        // Arrive-by 9 minutes after departure: the cheap station (12 min) is 3 min late,
        // the dearer on-route station (10 min) is 1 min late, so the planner switches to it
        // and reports the lateness.
        var late = destination
        late.arriveBy = Date(timeIntervalSince1970: 540)
        problem.slots[0] = .init(item: late, node: 1, candidates: [])
        options = TripPlanner.solve(problem, settings: settings)
        XCTAssertEqual(options.first?.choices[petrol.id]?.id, "dear")
        XCTAssertEqual(options.first?.latenessSeconds ?? 0, 60, accuracy: 0.1)
    }
}
