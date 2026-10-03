import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Route preferences from Settings (stage 4), read straight from UserDefaults so non-view
/// code can use them.
struct RoutePreferences: Equatable {
    var avoidMotorways: Bool
    var avoidTolls: Bool
    var avoidFerries: Bool
    var travelMode: TravelMode

    static var current: RoutePreferences {
        let d = UserDefaults.standard
        return RoutePreferences(
            avoidMotorways: d.bool(forKey: SettingsKeys.avoidMotorways),
            avoidTolls: d.bool(forKey: SettingsKeys.avoidTolls),
            avoidFerries: d.bool(forKey: SettingsKeys.avoidFerries),
            travelMode: TravelMode(rawValue: d.string(forKey: SettingsKeys.travelMode) ?? "") ?? .driving
        )
    }

    var profile: ProfileIdentifier {
        travelMode == .walking ? .walking : .automobileAvoidingTraffic
    }

    var roadClassesToAvoid: RoadClasses {
        guard travelMode == .driving else { return [] } // exclusions are a driving feature
        var classes: RoadClasses = []
        if avoidMotorways { classes.insert(.motorway) }
        if avoidTolls { classes.insert(.toll) }
        if avoidFerries { classes.insert(.ferry) }
        return classes
    }
}

enum RouteCalculationError: LocalizedError {
    case noOrigin
    case noDestination
    case tooManyWaypoints(Int)
    case unresolvedFlexibleStops
    case routing(String)

    var errorDescription: String? {
        switch self {
        case .noOrigin: "Your location isn't available yet. Check location permission and try again."
        case .noDestination: "Add at least one stop to plan a route."
        case .tooManyWaypoints(let n):
            "This trip has \(n) points, but a single route can have at most \(RouteLimits.maxDirectionsCoordinates) including your start. Remove some via points."
        case .unresolvedFlexibleStops: "Run the planner to choose places for the flexible stops first."
        case .routing(let message): "Couldn't calculate a route: \(message)"
        }
    }
}

/// Mapbox API limits. Verified against the Mapbox docs at the time of writing
/// (Directions: 25 coordinates per request; Map Matching: 100 coordinates, radius ≤ 50 m;
/// Matrix: 25 coordinates, or 10 for driving-traffic). Re-check if requests start failing.
enum RouteLimits {
    static let maxDirectionsCoordinates = 25
    static let maxMapMatchingCoordinates = 100
    static let maxMapMatchingRadius: Double = 50
    static let maxMatrixCoordinates = 25
    static let maxMatrixCoordinatesTraffic = 10
}

/// Turns a `Trip` into one Directions request and calculates it. Separate from views so
/// later stages (faster-route checker, planner, sketch) reuse it.
@MainActor
struct RouteCalculator {
    let navigation: MapboxNavigation

    /// Builds Directions waypoints: origin, then each routable item. Via items get
    /// `separatesLegs = false` so they bend the route silently. The last waypoint always
    /// separates legs (the API requires it).
    static func waypoints(origin: CLLocation, items: [TripItem]) throws -> [Waypoint] {
        let routable = items.filter { $0.coordinate != nil }
        guard !routable.isEmpty else { throw RouteCalculationError.noDestination }
        guard routable.count + 1 <= RouteLimits.maxDirectionsCoordinates else {
            throw RouteCalculationError.tooManyWaypoints(routable.count + 1)
        }
        var result: [Waypoint] = []
        var start = Waypoint(location: origin, heading: origin.course >= 0 ? origin.course : nil, name: "Start")
        if origin.course >= 0 { start.headingAccuracy = 90 }
        result.append(start)

        for (index, item) in routable.enumerated() {
            var waypoint = Waypoint(coordinate: item.coordinate!, name: item.name)
            let isLast = index == routable.count - 1
            waypoint.separatesLegs = isLast || !item.kind.isSilent
            result.append(waypoint)
        }
        return result
    }

    static func options(
        waypoints: [Waypoint],
        items: [TripItem],
        preferences: RoutePreferences,
        alternatives: Bool = true
    ) -> NavigationRouteOptions {
        let options = NavigationRouteOptions(waypoints: waypoints, profileIdentifier: preferences.profile)
        options.roadClassesToAvoid = preferences.roadClassesToAvoid
        options.includesAlternativeRoutes = alternatives
        // NavigationRouteOptions resets every waypoint's accuracy to "unlimited"; re-apply
        // per-item snapping radii (used by sketch and drag-to-reshape for road snapping).
        let routable = items.filter { $0.coordinate != nil }
        for (offset, item) in routable.enumerated() where item.snapRadius != nil {
            let index = offset + 1
            guard index < options.waypoints.count else { continue }
            options.waypoints[index].coordinateAccuracy = item.snapRadius
        }
        return options
    }

    func calculate(
        origin: CLLocation?,
        trip: Trip,
        preferences: RoutePreferences = .current,
        alternatives: Bool = true
    ) async throws -> NavigationRoutes {
        guard let origin else { throw RouteCalculationError.noOrigin }
        guard !trip.hasUnresolvedCategoryItems else { throw RouteCalculationError.unresolvedFlexibleStops }
        let waypoints = try Self.waypoints(origin: origin, items: trip.items)
        let options = Self.options(waypoints: waypoints, items: trip.items, preferences: preferences, alternatives: alternatives)
        RequestCounter.shared.record(.directions)
        switch await navigation.routingProvider().calculateRoutes(options: options).result {
        case .success(let routes): return routes
        case .failure(let error): throw RouteCalculationError.routing(error.localizedDescription)
        }
    }

    /// Map Matching ("follow my line closely"). Up to 100 coordinates, each snapped within
    /// `radius` metres (max 50).
    func match(origin: CLLocation, line: [CLLocationCoordinate2D], radius: Double, preferences: RoutePreferences = .current) async throws -> NavigationRoutes {
        let points = [origin.coordinate] + GeoMath.resample(line, count: RouteLimits.maxMapMatchingCoordinates - 1)
        let waypoints: [Waypoint] = points.enumerated().map { index, coordinate in
            var w = Waypoint(coordinate: coordinate, coordinateAccuracy: min(radius, RouteLimits.maxMapMatchingRadius))
            w.separatesLegs = index == 0 || index == points.count - 1
            return w
        }
        let options = NavigationMatchOptions(waypoints: waypoints, profileIdentifier: preferences.profile)
        RequestCounter.shared.record(.mapMatching)
        switch await navigation.routingProvider().calculateRoutes(options: options).result {
        case .success(let routes): return routes
        case .failure(let error): throw RouteCalculationError.routing(error.localizedDescription)
        }
    }
}

/// Summary of a single leg for the trip builder and route preview.
struct LegSummary: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let destinationName: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

extension Route {
    var legSummaries: [LegSummary] {
        legs.enumerated().map { index, leg in
            LegSummary(
                index: index,
                destinationName: leg.destination?.name ?? "Stop \(index + 1)",
                distance: leg.distance,
                expectedTravelTime: leg.expectedTravelTime
            )
        }
    }
}
