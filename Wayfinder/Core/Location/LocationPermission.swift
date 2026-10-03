import CoreLocation
import Foundation
import UIKit

/// Wraps location authorisation so SwiftUI can show a friendly screen when it is denied.
@MainActor
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Asked for only when guidance starts, so spoken directions continue with the screen locked.
    func requestAlwaysIfNeeded() {
        if status == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in self.status = newStatus }
    }
}
