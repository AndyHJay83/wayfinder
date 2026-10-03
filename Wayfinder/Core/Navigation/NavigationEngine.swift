import Combine
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Owns the one-and-only `MapboxNavigationProvider` (the SDK allows a single instance) and
/// exposes the live location to SwiftUI.
@MainActor
final class NavigationEngine: ObservableObject {
    static let shared = NavigationEngine()

    let provider: MapboxNavigationProvider
    var mapboxNavigation: MapboxNavigation { provider.mapboxNavigation }

    @Published private(set) var location: CLLocation?
    @Published private(set) var isGuiding = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let config = CoreConfig(
            routingConfig: RoutingConfig(
                // We run our own faster-route checker (stage 9) with anti-nag rules, so the
                // SDK's automatic faster-route switching is turned off.
                fasterRouteDetectionConfig: nil
            ),
            locationSource: .live
        )
        provider = MapboxNavigationProvider(coreConfig: config)

        mapboxNavigation.navigation().locationMatching
            .map { $0.enhancedLocation }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.location = $0 }
            .store(in: &cancellables)

        mapboxNavigation.tripSession().session
            .map { if case .activeGuidance = $0.state { return true } else { return false } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isGuiding = $0 }
            .store(in: &cancellables)
    }

    var calculator: RouteCalculator { RouteCalculator(navigation: mapboxNavigation) }

    /// Start passive location tracking (shows the puck, no route).
    func startFreeDrive() {
        mapboxNavigation.tripSession().startFreeDrive()
    }
}
