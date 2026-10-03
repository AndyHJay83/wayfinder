import SwiftData
import SwiftUI

@main
struct WayfinderApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var permission = LocationPermission()

    init() {
        SettingsKeys.registerDefaults()
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(permission)
        }
        .modelContainer(Persistence.shared)
    }
}

/// Gates the app on configuration and location permission.
struct RootView: View {
    @EnvironmentObject private var permission: LocationPermission

    var body: some View {
        Group {
            if !AppConfig.isMapboxConfigured {
                MissingTokenView()
            } else if permission.isAuthorized {
                HomeView()
            } else if permission.isDenied {
                LocationDeniedView()
            } else {
                LocationRequestView()
            }
        }
        .animation(.default, value: permission.status)
    }
}
