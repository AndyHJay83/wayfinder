import Combine
import CoreLocation
import MapboxDirections
import MapboxMaps
import MapboxNavigationCore
import MapboxNavigationUIKit
import SwiftData
import SwiftUI
import UIKit

/// Guidance map styles that follow `MapStyle`, so a Mapbox Studio skin applies during
/// navigation too.
final class WayfinderDayStyle: DayStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: MapStyle.current.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .day
    }
}

final class WayfinderNightStyle: NightStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: MapStyle.night.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .night
    }
}

/// Presents the prebuilt Mapbox `NavigationViewController` full screen and attaches the
/// faster-route checker. The SDK supports swapping routes mid-journey through
/// `tripSession().startActiveGuidance(with:startLegIndex:)`, and the view controller updates
/// itself, so the prebuilt UI is enough for stage 9.
@MainActor
final class GuidancePresenter: NSObject {
    static let shared = GuidancePresenter()

    private weak var appModel: AppModel?
    private weak var navigationViewController: NavigationViewController?
    private var fasterRouteChecker: FasterRouteChecker?
    private var bannerHost: UIHostingController<FasterRouteBannerContainer>?
    private let bannerModel = FasterRouteBannerModel()
    private var progressSubscription: AnyCancellable?
    private var parkingOffered = false
    private var destination: Place?

    func start(routes: NavigationRoutes, trip: Trip, appModel: AppModel) {
        self.appModel = appModel
        let engine = NavigationEngine.shared
        let provider = engine.provider

        let options = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager(),
            styles: [WayfinderDayStyle(), WayfinderNightStyle()],
            predictiveCacheManager: provider.predictiveCacheManager
        )
        let viewController = NavigationViewController(navigationRoutes: routes, navigationOptions: options)
        viewController.modalPresentationStyle = .fullScreen
        viewController.routeLineTracksTraversal = true
        viewController.usesNightStyleInDarkMode = true
        viewController.delegate = self
        navigationViewController = viewController

        attachBanner(to: viewController)
        watchForParkingPrompt(trip: trip, appModel: appModel)

        let isDriving = !(routes.mainRoute.route.legs.first?.profileIdentifier.isWalking ?? false)
        if isDriving {
            let checker = FasterRouteChecker(navigation: provider.mapboxNavigation, trip: trip, banner: bannerModel)
            fasterRouteChecker = checker
            checker.start()
        }

        appModel.sheet = nil
        Self.topViewController()?.present(viewController, animated: true)
    }

    private func attachBanner(to viewController: UIViewController) {
        let host = UIHostingController(rootView: FasterRouteBannerContainer(model: bannerModel))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        viewController.addChild(host)
        viewController.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor, constant: 12),
            host.view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor, constant: -12),
            host.view.bottomAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])
        host.didMove(toParent: viewController)
        // Let touches outside the banner reach the map.
        host.view.isUserInteractionEnabled = true
        bannerHost = host
    }

    func tripChanged(_ trip: Trip) {
        fasterRouteChecker?.replaceTrip(trip)
    }

    /// Within about a mile of the final destination, offer "Park nearby" once.
    private func watchForParkingPrompt(trip: Trip, appModel: AppModel) {
        parkingOffered = false
        let final = trip.routableItems.last
        destination = appModel.walkingDestination ?? final.flatMap { item in
            item.coordinate.map { Place(name: item.name, coordinate: $0, source: .mapPress) }
        }
        bannerModel.onParkNearby = { [weak self] in self?.presentParking() }
        progressSubscription = NavigationEngine.shared.mapboxNavigation.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self, !self.parkingOffered, appModel.walkingDestination == nil,
                      progress.isFinalLeg, progress.distanceRemaining < 1609,
                      !progress.currentLeg.profileIdentifier.isWalking,
                      let destination = self.destination else { return }
                self.parkingOffered = true
                self.bannerModel.parkingPrompt = destination.name
            }
    }

    private func presentParking() {
        bannerModel.parkingPrompt = nil
        guard let destination, let appModel, let navigationViewController else { return }
        let sheet = UIHostingController(rootView:
            ParkNearbySheet(destination: destination)
                .environmentObject(appModel)
                .modelContainer(Persistence.shared)
        )
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
        }
        navigationViewController.present(sheet, animated: true)
    }

    private func finish() {
        progressSubscription = nil
        fasterRouteChecker?.stop()
        fasterRouteChecker = nil
        bannerModel.suggestion = nil
        navigationViewController?.dismiss(animated: true)
        navigationViewController = nil
        appModel?.guidanceEnded()
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension GuidancePresenter: NavigationViewControllerDelegate {
    nonisolated func navigationViewControllerDidDismiss(_ navigationViewController: NavigationViewController, byCanceling canceled: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func navigationViewController(_ navigationViewController: NavigationViewController, didArriveAt waypoint: Waypoint) {
        Task { @MainActor in
            // Close guidance a few seconds after the final arrival.
            let progress = NavigationEngine.shared.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
            guard progress?.isFinalLeg ?? true else { return }
            try? await Task.sleep(for: .seconds(4))
            if self.navigationViewController != nil { self.finish() }
        }
    }
}
