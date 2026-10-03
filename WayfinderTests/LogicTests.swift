import CoreGraphics
import CoreLocation
import XCTest
@testable import Wayfinder

// MARK: - Geometry

final class GeoMathTests: XCTestCase {
    let bournemouth = CLLocationCoordinate2D(latitude: 50.7192, longitude: -1.8808)
    let london = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    func testDistance() {
        // Bournemouth to central London is about 152 km as the crow flies.
        XCTAssertEqual(GeoMath.distance(bournemouth, london) / 1000, 152, accuracy: 3)
    }

    func testProjectionAlongLine() {
        let line = [CLLocationCoordinate2D(latitude: 50, longitude: -1), CLLocationCoordinate2D(latitude: 50, longitude: 0)]
        let p = GeoMath.project(CLLocationCoordinate2D(latitude: 50.001, longitude: -0.5), onto: line)!
        XCTAssertEqual(p.distanceFromLine, 111, accuracy: 2)
        XCTAssertEqual(p.distanceAlong, GeoMath.length(of: line) / 2, accuracy: 200)
    }

    func testDouglasPeuckerKeepsCornersDropsNoise() {
        // An L shape with small wiggles.
        var points: [CGPoint] = (0...50).map { CGPoint(x: CGFloat($0) * 4, y: CGFloat($0 % 2) * 3) }
        points += (1...50).map { CGPoint(x: 200 + CGFloat($0 % 2) * 3, y: CGFloat($0) * 4) }
        let simplified = GeoMath.simplify(points, tolerance: 16)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)
    }

    func testSimplifyCapsPointCount() {
        let zigzag = (0..<400).map { CGPoint(x: CGFloat($0) * 5, y: CGFloat($0 % 2) * 60) }
        let capped = GeoMath.simplify(zigzag, tolerance: 16, maxPoints: 23)
        XCTAssertLessThanOrEqual(capped.count, 23)
        XCTAssertEqual(capped.first, zigzag.first)
        XCTAssertEqual(capped.last, zigzag.last)
    }

    func testResample() {
        let line = [bournemouth, london]
        let r = GeoMath.resample(line + [london], count: 2)
        XCTAssertEqual(r.count, 2)
    }
}

// MARK: - Sketch scale rules

final class SketchMathTests: XCTestCase {
    func testScaleDecidesSnapping() {
        // Street level: ~0.6 m/pt → 16 px ≈ 10 m → road snapping, can follow line.
        XCTAssertFalse(SketchMath.usesNamedPlaces(metresPerPoint: 0.6))
        XCTAssertTrue(SketchMath.canFollowLine(metresPerPoint: 0.6))
        // City level: 10 m/pt → 160 m → roads, but too coarse to follow the line.
        XCTAssertFalse(SketchMath.usesNamedPlaces(metresPerPoint: 10))
        XCTAssertFalse(SketchMath.canFollowLine(metresPerPoint: 10))
        // Country level: 300 m/pt → 4.8 km → named places.
        XCTAssertTrue(SketchMath.usesNamedPlaces(metresPerPoint: 300))
    }

    func testAnchorCap() {
        XCTAssertEqual(SketchMath.maxAnchors, 23)
        let coords = (0..<60).map { CLLocationCoordinate2D(latitude: 50 + Double($0) * 0.01, longitude: -1 + Double($0 % 3) * 0.01) }
        XCTAssertLessThanOrEqual(SketchMath.cap(coords).count, 23)
    }

    func testFarAnchorWarning() {
        let route = [CLLocationCoordinate2D(latitude: 50.72, longitude: -1.88), CLLocationCoordinate2D(latitude: 51.5, longitude: -0.13)]
        let near = SketchAnchor(name: "On route", coordinate: GeoMath.coordinate(along: route, at: 50_000)!, snapRadius: nil)
        let far = SketchAnchor(name: "Salisbury", coordinate: CLLocationCoordinate2D(latitude: 51.07, longitude: -1.79), snapRadius: nil)
        XCTAssertEqual(SketchMath.anchorsFarFromRoute([near, far], route: route).map(\.name), ["Salisbury"])
    }
}

// MARK: - Parking rules

final class ParkingRulesTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// Monday 5 October 2026 at the given London time.
    func monday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour, minute: minute))!
    }

    func testDurations() {
        XCTAssertEqual(ParkingRules.minutes(fromDuration: "2 hours"), 120)
        XCTAssertEqual(ParkingRules.minutes(fromDuration: "90 minutes"), 90)
        XCTAssertEqual(ParkingRules.minutes(fromDuration: "1 hour 30 minutes"), 90)
        XCTAssertEqual(ParkingRules.minutes(fromDuration: "2h"), 120)
        XCTAssertEqual(ParkingRules.minutes(fromDuration: "02:00"), 120)
        XCTAssertNil(ParkingRules.minutes(fromDuration: "no"))
        XCTAssertNil(ParkingRules.minutes(fromDuration: "fortnight"))
    }

    func testSchedules() {
        let s = ParkingRules.schedule("Mo-Sa 08:00-18:00")!
        XCTAssertTrue(ParkingRules.contains(s, monday(10), calendar: calendar))
        XCTAssertFalse(ParkingRules.contains(s, monday(19), calendar: calendar))
        XCTAssertNil(ParkingRules.schedule("Mo-Fr 08:00-18:00; PH off"))
        XCTAssertNotNil(ParkingRules.schedule("24/7"))
    }

    func testFreeUntilPaidPeriodStarts() {
        // Pay-and-display Mon–Sat 08:00–18:00. Arriving 07:00 Monday: free until 08:00.
        let e = ParkingRules.evaluate(
            fee: nil, feeConditional: "yes @ (Mo-Sa 08:00-18:00)", maxstay: nil, maxstayConditional: nil,
            restriction: nil, restrictionConditional: nil, access: nil,
            arrival: monday(7), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(e.status, .free)
        XCTAssertEqual(e.until, monday(8))
    }

    func testPaidUntilEvening() {
        let e = ParkingRules.evaluate(
            fee: nil, feeConditional: "yes @ (Mo-Sa 08:00-18:00)", maxstay: "2 hours", maxstayConditional: nil,
            restriction: nil, restrictionConditional: nil, access: nil,
            arrival: monday(17), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(e.status, .paid)
        XCTAssertEqual(e.until, monday(18))
        XCTAssertEqual(e.maxStayMinutes, 120)
        XCTAssertEqual(e.staySupported, true)
    }

    func testRestrictionsAndAccess() {
        let noParking = ParkingRules.evaluate(
            fee: nil, feeConditional: nil, maxstay: nil, maxstayConditional: nil,
            restriction: nil, restrictionConditional: "no_parking @ (Mo-Fr 07:00-19:00)", access: nil,
            arrival: monday(9), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(noParking.status, .restricted)
        XCTAssertEqual(noParking.until, monday(19))

        // Arrive 19:30 for an hour: the no-parking window has ended and doesn't start again until 07:00.
        let evening = ParkingRules.evaluate(
            fee: "no", feeConditional: nil, maxstay: nil, maxstayConditional: nil,
            restriction: nil, restrictionConditional: "no_parking @ (Mo-Fr 07:00-19:00)", access: nil,
            arrival: monday(19, 30), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(evening.status, .free)
        XCTAssertNotEqual(evening.staySupported, false)

        let residents = ParkingRules.evaluate(
            fee: nil, feeConditional: nil, maxstay: nil, maxstayConditional: nil,
            restriction: nil, restrictionConditional: nil, access: "private",
            arrival: monday(9), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(residents.status, .restricted)
    }

    func testUnknownStaysUnknown() {
        let e = ParkingRules.evaluate(
            fee: nil, feeConditional: "yes @ (sunrise-sunset)", maxstay: nil, maxstayConditional: nil,
            restriction: nil, restrictionConditional: nil, access: nil,
            arrival: monday(9), stayMinutes: 60, calendar: calendar
        )
        XCTAssertEqual(e.status, .unknown)
    }

    func testTariffCost() {
        let tariff = [TariffBand(upToMinutes: 60, pricePence: 280), TariffBand(upToMinutes: 180, pricePence: 650)]
        XCTAssertEqual(ParkingRules.cost(for: 45, tariff: tariff), 280)
        XCTAssertEqual(ParkingRules.cost(for: 120, tariff: tariff), 650)
        XCTAssertNil(ParkingRules.cost(for: 300, tariff: tariff))
        XCTAssertEqual(ParkingRules.cost(for: 90, pencePerHour: 280), 420)
    }

    @MainActor
    func testChargeParsing() {
        XCTAssertEqual(ParkingService.pencePerHour(from: "£1.50/hour"), 150)
        XCTAssertEqual(ParkingService.pencePerHour(from: "GBP 2 per hour"), 200)
        XCTAssertNil(ParkingService.pencePerHour(from: "£5 per day"))
    }
}

// MARK: - Faster route anti-nag rules

final class FasterRoutePolicyTests: XCTestCase {
    let policy = FasterRoutePolicy(thresholdSeconds: 60, autoAccept: false, autoAcceptSeconds: 180)

    func testNeedsTwoChecksInARow() {
        XCTAssertEqual(policy.decide(saving: 90, consecutive: 0, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .keepWatching(consecutive: 1))
        XCTAssertEqual(policy.decide(saving: 90, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .suggest)
        XCTAssertEqual(policy.decide(saving: 30, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .keepWatching(consecutive: 0))
    }

    func testAntiNagRules() {
        XCTAssertEqual(policy.decide(saving: 90, consecutive: 1, distanceToNextManoeuvre: 200, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .skip("too close to next manoeuvre"))
        XCTAssertEqual(policy.decide(saving: 90, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: 100, candidateWasIgnored: false), .skip("suggested recently"))
        XCTAssertEqual(policy.decide(saving: 90, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: true), .skip("already ignored"))
    }

    func testAutoAccept() {
        var auto = policy
        auto.autoAccept = true
        XCTAssertEqual(auto.decide(saving: 200, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .autoAccept)
        XCTAssertEqual(auto.decide(saving: 90, consecutive: 1, distanceToNextManoeuvre: 2000, secondsSinceLastSuggestion: nil, candidateWasIgnored: false), .suggest)
    }
}

// MARK: - Trip model

final class TripTests: XCTestCase {
    func testMoveToggleRemove() {
        let a = TripItem(kind: .stop, name: "A", coordinate: .init(latitude: 1, longitude: 1))
        let b = TripItem(kind: .stop, name: "B", coordinate: .init(latitude: 2, longitude: 2))
        let c = TripItem(kind: .via, name: "C", coordinate: .init(latitude: 3, longitude: 3))
        var trip = Trip(items: [a, b, c])
        trip.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(trip.items.map(\.name), ["C", "A", "B"])
        trip.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(trip.items.map(\.name), ["A", "B", "C"])
        trip.toggleKind(id: c.id)
        XCTAssertEqual(trip.items[2].kind, .stop)
        trip.remove(id: a.id)
        XCTAssertEqual(trip.items.map(\.name), ["B", "C"])
    }

    func testFlexibleItemsAreUnresolvedUntilPlanned() {
        var trip = Trip(items: [TripItem(kind: .category("petrol"), name: "Petrol", coordinate: nil)])
        XCTAssertTrue(trip.hasUnresolvedCategoryItems)
        trip.items[0].coordinate = .init(latitude: 50, longitude: -1)
        XCTAssertFalse(trip.hasUnresolvedCategoryItems)
    }
}
