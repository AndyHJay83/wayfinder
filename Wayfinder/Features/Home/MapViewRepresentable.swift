import MapboxNavigationCore
import SwiftUI

/// Hosts the `NavigationMapView` owned by `MapController` (the SwiftUI-recommended way to embed
/// the navigation map, which also draws routes and alternatives).
struct MapViewRepresentable: UIViewRepresentable {
    let controller: MapController

    func makeUIView(context: Context) -> NavigationMapView {
        controller.navigationMapView
    }

    func updateUIView(_ uiView: NavigationMapView, context: Context) {}
}
