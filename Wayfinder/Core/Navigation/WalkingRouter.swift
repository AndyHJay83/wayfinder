import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Walking leg from a parking spot to the real destination (stage 13).
@MainActor
enum WalkingRouter {
    struct Walk {
        let coordinates: [CLLocationCoordinate2D]
        let distance: CLLocationDistance
        let duration: TimeInterval
    }

    static func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> Walk {
        let options = NavigationRouteOptions(
            waypoints: [Waypoint(coordinate: origin), Waypoint(coordinate: destination)],
            profileIdentifier: .walking
        )
        options.includesAlternativeRoutes = false
        RequestCounter.shared.record(.directions)
        let routes = try await NavigationEngine.shared.mapboxNavigation.routingProvider().calculateRoutes(options: options).value
        let route = routes.mainRoute.route
        return Walk(coordinates: route.shape?.coordinates ?? [origin, destination], distance: route.distance, duration: route.expectedTravelTime)
    }

    /// Straight-line estimate used to rank many options before routing the chosen one.
    static func estimate(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> (distance: CLLocationDistance, minutes: Double) {
        // Streets aren't straight: 1.3 × crow-flies at 80 m/min (≈ 3 mph).
        let distance = GeoMath.distance(origin, destination) * 1.3
        return (distance, distance / 80)
    }
}
