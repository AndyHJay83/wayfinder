import Combine
import CoreLocation
import MapboxDirections
import MapboxMaps
import MapboxNavigationCore
import SwiftUI
import UIKit

/// Owns the UIKit `NavigationMapView` and everything drawn on it. SwiftUI talks to the map
/// only through this class.
@MainActor
final class MapController: NSObject, ObservableObject {
    let navigationMapView: NavigationMapView
    private weak var appModel: AppModel?

    private var resultPins: PointAnnotationManager!
    private var savedPins: PointAnnotationManager!
    private var viaPins: PointAnnotationManager!
    private var sketchAnchorPins: PointAnnotationManager!
    private var lines: PolylineAnnotationManager!

    /// True once the user has panned away from their location; category search then uses the map centre.
    @Published private(set) var isFollowingUser = true

    private var routeDrag: UILongPressGestureRecognizer!
    private var menuPress: UILongPressGestureRecognizer!
    private var settingsPress: UILongPressGestureRecognizer!
    private var dragInsertIndex: Int?
    private var dragNeighbours: (CLLocationCoordinate2D, CLLocationCoordinate2D)?
    private var cancellables = Set<AnyCancellable>()

    private var currentRouteShape: [CLLocationCoordinate2D] = []
    private var sketchLineIDs: [String] = []
    private var walkingLineID = "walking-leg"
    private var dragPreviewID = "drag-preview"

    init(appModel: AppModel) {
        let navigation = NavigationEngine.shared.mapboxNavigation
        navigationMapView = NavigationMapView(
            location: navigation.navigation().locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.navigation().routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            routeRefreshing: navigation.navigation().routeRefreshing,
            predictiveCacheManager: NavigationEngine.shared.provider.predictiveCacheManager
        )
        self.appModel = appModel
        super.init()

        navigationMapView.mapView.mapboxMap.loadStyle(MapStyle.current)
        navigationMapView.delegate = self
        navigationMapView.puckType = .puck2D(.makeDefault(showBearing: true))
        navigationMapView.showsAlternatives = true

        let annotations = navigationMapView.mapView.annotations!
        lines = annotations.makePolylineAnnotationManager(id: "wayfinder-lines")
        resultPins = annotations.makePointAnnotationManager(id: "wayfinder-results")
        savedPins = annotations.makePointAnnotationManager(id: "wayfinder-saved")
        viaPins = annotations.makePointAnnotationManager(id: "wayfinder-vias")
        sketchAnchorPins = annotations.makePointAnnotationManager(id: "wayfinder-sketch-anchors")

        setUpRouteDrag()
        setUpPressMenus()

        navigationMapView.navigationCamera.cameraStates
            .map { $0 == .following }
            .removeDuplicates()
            .sink { [weak self] in self?.isFollowingUser = $0 }
            .store(in: &cancellables)

        navigationMapView.navigationCamera.update(cameraState: .following)
        appModel.map = self
    }

    var mapView: MapView { navigationMapView.mapView }

    // MARK: Camera

    func recenter() {
        navigationMapView.navigationCamera.update(cameraState: .following)
    }

    /// Where to search "nearby": the map centre if the user has panned, else their location.
    var searchCenter: CLLocationCoordinate2D? {
        if isFollowingUser, let location = NavigationEngine.shared.location { return location.coordinate }
        return mapView.mapboxMap.cameraState.center
    }

    var zoom: CGFloat { mapView.mapboxMap.cameraState.zoom }

    /// Metres represented by one screen point at the current zoom and map centre.
    var metresPerPoint: Double {
        Projection.metersPerPoint(for: mapView.mapboxMap.cameraState.center.latitude, zoom: zoom)
    }

    /// Converts a point in window coordinates (SwiftUI `.global`) to a map coordinate.
    func coordinate(forGlobalPoint point: CGPoint) -> CLLocationCoordinate2D {
        let local = mapView.convert(point, from: nil)
        return mapView.mapboxMap.coordinate(for: local)
    }

    func fit(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        let padding = UIEdgeInsets(top: 120, left: 40, bottom: 320, right: 40)
        if let camera = try? mapView.mapboxMap.camera(for: coordinates, camera: CameraOptions(), coordinatesPadding: padding, maxZoom: 16, offset: nil) {
            navigationMapView.navigationCamera.stop()
            mapView.camera.ease(to: camera, duration: 0.6)
        }
    }

    // MARK: Routes

    func showRoutes(_ routes: NavigationRoutes?) {
        guard let routes else {
            navigationMapView.removeRoutes()
            currentRouteShape = []
            showViaPoints([])
            return
        }
        currentRouteShape = routes.mainRoute.route.shape?.coordinates ?? []
        navigationMapView.showcase(routes, routesPresentationStyle: .all(shouldFit: true), animated: true)
        if let trip = appModel?.trip { showViaPoints(trip.items.filter { $0.kind == .via }) }
    }

    func showWalkingLeg(_ coordinates: [CLLocationCoordinate2D]?) {
        lines.annotations.removeAll { $0.id == walkingLineID }
        guard let coordinates, coordinates.count > 1 else { return }
        var line = PolylineAnnotation(id: walkingLineID, lineCoordinates: coordinates)
        line.lineColor = StyleColor(Theme.Colors.walkingLeg)
        line.lineWidth = Theme.Line.walkingWidth
        lines.annotations.append(line)
    }

    // MARK: Pins

    func showResults(_ places: [Place]) {
        resultPins.annotations = places.map { place in
            var pin = PointAnnotation(id: "result-\(place.id)", coordinate: place.coordinate)
            pin.image = .init(image: Self.pinImage(symbol: place.iconName ?? "mappin", colour: Theme.Colors.resultPin), name: "pin-\(place.iconName ?? "mappin")")
            pin.iconAnchor = .bottom
            pin.textField = place.name
            pin.textSize = 11
            pin.textOffset = [0, 0.6]
            pin.textAnchor = .top
            pin.tapHandler = { [weak self] _ in
                guard let appModel = self?.appModel else { return true }
                if appModel.previewRoutes != nil {
                    // A route is showing: a result becomes a stop on the way.
                    appModel.insertAlongRoute(place)
                    appModel.clearCategoryResults()
                    appModel.sheet = nil
                } else {
                    appModel.choose(destination: place)
                }
                return true
            }
            return pin
        }
        if !places.isEmpty { fit(places.map(\.coordinate)) }
    }

    func showSavedPlaces(_ places: [SavedPlace]) {
        savedPins.annotations = places.map { saved in
            let place = saved.asPlace
            var pin = PointAnnotation(id: "saved-\(saved.uuid)", coordinate: saved.coordinate)
            pin.image = .init(image: Self.pinImage(symbol: saved.icon, colour: Theme.Colors.savedPin), name: "saved-\(saved.icon)")
            pin.iconAnchor = .bottom
            pin.tapHandler = { [weak self] _ in
                self?.appModel?.selectedPlace = place
                self?.appModel?.choose(destination: place)
                return true
            }
            return pin
        }
    }

    /// Via points are draggable to move them and tappable to delete them.
    func showViaPoints(_ vias: [TripItem]) {
        viaPins.annotations = vias.compactMap { item in
            guard let coordinate = item.coordinate else { return nil }
            var pin = PointAnnotation(id: "via-\(item.id)", coordinate: coordinate, isDraggable: true)
            pin.image = .init(image: Self.dotImage(colour: Theme.Colors.viaPin), name: "via-dot")
            pin.tapHandler = { [weak self] _ in
                self?.appModel?.trip.remove(id: item.id)
                self?.appModel?.statusMessage = "Via point removed"
                return true
            }
            pin.dragEndHandler = { [weak self] annotation, _ in
                guard let self, var updated = self.appModel?.trip.items.first(where: { $0.id == item.id }) else { return }
                updated.coordinate = annotation.point.coordinates
                updated.snapRadius = 50
                self.appModel?.trip.update(updated)
            }
            return pin
        }
    }

    // MARK: Sketch drawing (geo-anchored once a stroke is finished)

    func addSketchStroke(_ coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1 else { return }
        let id = "sketch-\(sketchLineIDs.count)"
        var line = PolylineAnnotation(id: id, lineCoordinates: coordinates)
        line.lineColor = StyleColor(Theme.Colors.sketchStroke)
        line.lineWidth = Double(Theme.Line.sketchWidth)
        lines.annotations.append(line)
        sketchLineIDs.append(id)
    }

    func showSketchAnchors(_ anchors: [SketchAnchor]) {
        sketchAnchorPins.annotations = anchors.map { anchor in
            var pin = PointAnnotation(id: "anchor-\(anchor.id)", coordinate: anchor.coordinate)
            pin.image = .init(image: Self.dotImage(colour: Theme.Colors.viaPin), name: "via-dot")
            pin.textField = anchor.name
            pin.textSize = 11
            pin.textOffset = [0, 1]
            pin.textAnchor = .top
            return pin
        }
    }

    func clearSketch() {
        lines.annotations.removeAll { sketchLineIDs.contains($0.id) }
        sketchLineIDs = []
        sketchAnchorPins.annotations = []
    }

    func setMapGesturesEnabled(_ enabled: Bool) {
        mapView.gestures.options.panEnabled = enabled
        mapView.gestures.options.pinchEnabled = enabled
        mapView.gestures.options.rotateEnabled = enabled
        mapView.gestures.options.pitchEnabled = enabled
    }

    // MARK: Hold-and-drag the route (stage 8)

    private func setUpRouteDrag() {
        routeDrag = UILongPressGestureRecognizer(target: self, action: #selector(handleRouteDrag(_:)))
        routeDrag.minimumPressDuration = 0.4
        routeDrag.delegate = self
        mapView.addGestureRecognizer(routeDrag)
    }

    // MARK: Press-and-hold menus

    /// One finger: the map menu (Sketch, Natural language, Navigate here, …), unless the press
    /// is on the route line (that drags the route). Two fingers: Settings.
    private func setUpPressMenus() {
        // Replace the SDK's own long press (drop a pin) with our menu.
        for recognizer in navigationMapView.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            recognizer.isEnabled = false
        }

        menuPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        menuPress.minimumPressDuration = 0.45
        menuPress.delegate = self
        menuPress.require(toFail: routeDrag)
        mapView.addGestureRecognizer(menuPress)

        settingsPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSettingsPress(_:)))
        settingsPress.numberOfTouchesRequired = 2
        settingsPress.minimumPressDuration = 0.6
        settingsPress.allowableMovement = 20
        settingsPress.delegate = self
        mapView.addGestureRecognizer(settingsPress)
    }

    @objc private func handleMenuPress(_ gesture: UILongPressGestureRecognizer) {
        guard let appModel else { return }
        let global = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            setMapGesturesEnabled(false)
            Theme.Haptics.medium()
            let coordinate = mapView.mapboxMap.coordinate(for: gesture.location(in: mapView))
            appModel.openMapMenu(at: global, coordinate: coordinate)
        case .changed:
            appModel.pressMenu.track(global)
        case .ended:
            setMapGesturesEnabled(true)
            appModel.pressMenu.release(at: global)
        default:
            setMapGesturesEnabled(true)
        }
    }

    @objc private func handleSettingsPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let appModel else { return }
        Theme.Haptics.medium()
        appModel.pressMenu.dismiss()
        appModel.sheet = .settings
    }

    private func isNearRoute(_ point: CGPoint, threshold: CGFloat = 22) -> Bool {
        guard currentRouteShape.count > 1 else { return false }
        let bounds = mapView.bounds.insetBy(dx: -50, dy: -50)
        let screen = currentRouteShape.map { mapView.mapboxMap.point(for: $0) }
        // Only test segments that are on screen.
        var best = CGFloat.infinity
        for (a, b) in zip(screen, screen.dropFirst()) where bounds.contains(a) || bounds.contains(b) {
            best = min(best, GeoMath.perpendicularDistance(point, a, b))
        }
        return best <= threshold
    }

    @objc private func handleRouteDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let appModel else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.mapboxMap.coordinate(for: point)

        switch gesture.state {
        case .began:
            setMapGesturesEnabled(false)
            Theme.Haptics.light()
            let (index, neighbours) = insertionIndex(for: coordinate, in: appModel)
            dragInsertIndex = index
            dragNeighbours = neighbours
            drawDragPreview(to: coordinate)
        case .changed:
            drawDragPreview(to: coordinate)
        case .ended:
            setMapGesturesEnabled(true)
            clearDragPreview()
            if let index = dragInsertIndex {
                let via = TripItem(kind: .via, name: "Via", coordinate: coordinate, snapRadius: 50)
                appModel.trip.insert(via, at: index)
                Task { [weak appModel] in
                    if let name = try? await PlaceSearchService.shared.nearestNamedPlace(to: coordinate)?.name,
                       var item = appModel?.trip.items.first(where: { $0.id == via.id }) {
                        item.name = "Via \(name)"
                        appModel?.trip.update(item)
                    }
                }
            }
            dragInsertIndex = nil
        default:
            setMapGesturesEnabled(true)
            clearDragPreview()
            dragInsertIndex = nil
        }
    }

    /// Where along the trip a new via at `coordinate` belongs, based on how far along the
    /// current route line it is.
    private func insertionIndex(for coordinate: CLLocationCoordinate2D, in appModel: AppModel) -> (Int, (CLLocationCoordinate2D, CLLocationCoordinate2D)?) {
        let shape = currentRouteShape
        guard let touch = GeoMath.project(coordinate, onto: shape) else { return (appModel.trip.items.count, nil) }
        var previous = shape.first ?? coordinate
        var next = shape.last ?? coordinate
        var insertAt = appModel.trip.items.count
        for (index, item) in appModel.trip.items.enumerated() {
            guard let c = item.coordinate, let projected = GeoMath.project(c, onto: shape) else { continue }
            if projected.distanceAlong <= touch.distanceAlong {
                previous = c
            } else {
                insertAt = index
                next = c
                break
            }
        }
        return (insertAt, (previous, next))
    }

    private func drawDragPreview(to coordinate: CLLocationCoordinate2D) {
        guard let (a, b) = dragNeighbours else { return }
        clearDragPreview()
        var line = PolylineAnnotation(id: dragPreviewID, lineCoordinates: [a, coordinate, b])
        line.lineColor = StyleColor(Theme.Colors.dragPreview)
        line.lineWidth = Theme.Line.dragPreviewWidth
        lines.annotations.append(line)
    }

    private func clearDragPreview() {
        lines.annotations.removeAll { $0.id == dragPreviewID }
    }

    // MARK: Pin images

    private static var imageCache: [String: UIImage] = [:]

    static func pinImage(symbol: String, colour: UIColor) -> UIImage {
        let key = "pin-\(symbol)-\(colour.description)"
        if let cached = imageCache[key] { return cached }
        let size = CGSize(width: 34, height: 42)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 30, height: 30))
            colour.setFill()
            circle.fill()
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: 11, y: 28)); tail.addLine(to: CGPoint(x: 17, y: 41)); tail.addLine(to: CGPoint(x: 23, y: 28))
            tail.close(); tail.fill()
            let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: 17 - glyph.size.width / 2, y: 17 - glyph.size.height / 2))
            }
        }
        imageCache[key] = image
        return image
    }

    static func dotImage(colour: UIColor) -> UIImage {
        let key = "dot-\(colour.description)"
        if let cached = imageCache[key] { return cached }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 22, height: 22)).fill()
            colour.setFill(); UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 14, height: 14)).fill()
        }
        imageCache[key] = image
        return image
    }
}

// MARK: - NavigationMapViewDelegate

extension MapController: NavigationMapViewDelegate {
    func navigationMapView(_ navigationMapView: NavigationMapView, didSelect alternativeRoute: AlternativeRoute) {
        Task { await appModel?.selectAlternative(alternativeRoute) }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MapController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let appModel else { return true }
        if gestureRecognizer === routeDrag {
            return !appModel.isSketching && isNearRoute(gestureRecognizer.location(in: mapView))
        }
        if gestureRecognizer === menuPress || gestureRecognizer === settingsPress {
            return !appModel.isSketching && !appModel.engine.isGuiding && !appModel.pressMenu.isPresented
        }
        return true
    }

    /// The two-finger press must not be blocked by pinch and rotate, which use two fingers too.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === settingsPress
    }
}
