import Combine
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore
import SwiftData
import SwiftUI

/// Central app state. Views stay small and call into this; the map is driven through
/// `MapController`.
@MainActor
final class AppModel: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case search
        case savedPlaces
        case settings
        case tripBuilder
        case savePlace(Place)
        case localPlaces(PlaceCategory)
        case parkNearby(Place)
        case chainBranches(String)
        case plannerResult
        case naturalLanguage

        var id: String {
            switch self {
            case .search: "search"
            case .savedPlaces: "savedPlaces"
            case .settings: "settings"
            case .tripBuilder: "tripBuilder"
            case .savePlace(let p): "save-\(p.id)"
            case .localPlaces(let c): "local-\(c.id)"
            case .parkNearby(let p): "park-\(p.id)"
            case .chainBranches(let n): "chain-\(n)"
            case .plannerResult: "planner"
            case .naturalLanguage: "naturalLanguage"
            }
        }
    }

    let engine = NavigationEngine.shared
    weak var map: MapController?

    // Routing
    @Published var trip = Trip() { didSet { if trip != oldValue { scheduleRecalculation() } } }
    @Published private(set) var previewRoutes: NavigationRoutes?
    @Published private(set) var isCalculating = false
    @Published var routeError: String?
    @Published var statusMessage: String?

    // UI
    @Published var sheet: Sheet?
    @Published var selectedPlace: Place?
    /// Press-and-slide menus (TRIP button and map).
    let pressMenu = PressMenuModel()
    /// The point last pressed on the map, named once reverse geocoding returns.
    private var pressedPlace: Place?
    /// When search is opened from the trip builder, a pick adds a stop instead of starting a new trip.
    @Published var searchAddsToTrip = false

    // Category chips (stage 5 + 12)
    @Published private(set) var categoryResults: [Place] = []
    @Published private(set) var activeCategory: PlaceCategory?
    @Published private(set) var armedCategoryIDs: Set<String> = []
    private var armTimeout: Task<Void, Never>?

    // Sketch (stage 8)
    @Published var isSketching = false
    @Published var sketchProposal: SketchProposal?

    // Planner (stage 11)
    @Published var plannerOutcome: PlannerOutcome?

    // Parking (stage 13)
    /// Original destination when the user has chosen to drive to a parking spot instead.
    @Published var walkingDestination: Place?

    private var recalcTask: Task<Void, Never>?
    private var suppressRecalc = false

    var currentLocation: CLLocation? { engine.location }

    // MARK: Destinations

    /// The one entry point for "the user picked somewhere to go".
    func choose(destination place: Place) {
        if searchAddsToTrip {
            searchAddsToTrip = false
            addToTrip(place)
            sheet = .tripBuilder
            return
        }
        selectedPlace = place
        if !armedCategoryIDs.isEmpty {
            buildArmedTrip(to: place)
            return
        }
        walkingDestination = nil
        plannerOutcome = nil
        trip = Trip(items: [place.asTripItem(kind: .stop)])
        sheet = nil
    }

    func addToTrip(_ place: Place, kind: TripItem.Kind = .stop) {
        trip.append(place.asTripItem(kind: kind))
        statusMessage = "Added \(place.name) to the trip"
    }

    /// The line stops are ordered along: the live route during guidance, else the preview.
    var currentRouteShape: [CLLocationCoordinate2D] {
        if engine.isGuiding, let live = engine.mapboxNavigation.navigation().currentRouteProgress?.routeProgress.route.shape?.coordinates {
            return live
        }
        return previewRoutes?.mainRoute.route.shape?.coordinates ?? []
    }

    /// Adds a stop or via where it falls along the route, before the destination.
    /// With no trip yet, a stop becomes the destination.
    func insertAlongRoute(_ place: Place, kind: TripItem.Kind = .stop) {
        guard !trip.isEmpty else {
            if kind == .via {
                statusMessage = "Pick a destination first, then add via points."
            } else {
                choose(destination: place)
            }
            return
        }
        if engine.isGuiding { pruneVisitedStops() }
        var item = place.asTripItem(kind: kind)
        if kind == .via { item.snapRadius = 50 }
        trip.insert(item, at: trip.insertionIndex(for: place.coordinate, along: currentRouteShape))
        statusMessage = kind == .via ? "Route now goes via \(place.name)" : "Added \(place.name) on the way"
    }

    /// Mid-journey edits re-route from here, so drop stops the user has already driven past.
    private func pruneVisitedStops() {
        guard let progress = engine.mapboxNavigation.navigation().currentRouteProgress?.routeProgress,
              let shape = progress.route.shape?.coordinates else { return }
        let travelled = progress.distanceTraveled
        let remaining = trip.items.filter { item in
            guard let c = item.coordinate, let p = GeoMath.project(c, onto: shape) else { return true }
            return p.distanceAlong >= travelled - 50
        }
        if !remaining.isEmpty, remaining.count != trip.items.count {
            suppressRecalc = true
            trip = Trip(items: remaining)
            suppressRecalc = false
        }
    }

    /// A saved destination picked from the TRIP menu: start a trip, or add it on the way.
    func useSavedDestination(_ place: Place) {
        if trip.isEmpty {
            choose(destination: place)
        } else {
            insertAlongRoute(place)
        }
    }

    func startSketch() {
        sheet = nil
        isSketching = true
    }

    /// The destination as a Place (for parking, saving and the banner title).
    var destinationPlace: Place? {
        if let walkingDestination { return walkingDestination }
        guard let last = trip.routableItems.last(where: { $0.kind != .via }), let c = last.coordinate else { return nil }
        if let selectedPlace, GeoMath.distance(selectedPlace.coordinate, c) < 30 { return selectedPlace }
        return Place(name: last.name, coordinate: c, source: .manual, savedPlaceID: last.savedPlaceID)
    }

    func clearRoute() {
        recalcTask?.cancel()
        suppressRecalc = true
        trip = Trip()
        suppressRecalc = false
        previewRoutes = nil
        walkingDestination = nil
        plannerOutcome = nil
        routeError = nil
        map?.showRoutes(nil)
        map?.showWalkingLeg(nil)
    }

    // MARK: Route calculation

    private func scheduleRecalculation() {
        guard !suppressRecalc else { return }
        recalcTask?.cancel()
        guard !trip.routableItems.isEmpty else {
            previewRoutes = nil
            map?.showRoutes(nil)
            return
        }
        recalcTask = Task { [weak self] in
            // Short debounce so dragging rows or via points redraws once, not on every frame.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.recalculate()
        }
    }

    func recalculate() async {
        guard !trip.routableItems.isEmpty else { return }
        isCalculating = true
        defer { isCalculating = false }
        do {
            let routes = try await engine.calculator.calculate(origin: currentLocation, trip: trip)
            guard !Task.isCancelled else { return }
            previewRoutes = routes
            routeError = nil
            if engine.isGuiding {
                // e.g. a parking spot chosen mid-journey: swap the live route, keep guiding.
                engine.mapboxNavigation.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
                GuidancePresenter.shared.tripChanged(trip)
            } else {
                map?.showRoutes(routes)
            }
            if let walkingDestination { await updateWalkingLeg(to: walkingDestination) }
        } catch is CancellationError {
        } catch {
            routeError = error.localizedDescription
        }
    }

    func selectAlternative(_ alternative: AlternativeRoute) async {
        guard let routes = previewRoutes, let selected = await routes.selecting(alternativeRoute: alternative) else { return }
        previewRoutes = selected
        map?.showRoutes(selected)
    }

    /// Replace the preview with externally calculated routes (sketch, planner).
    func setPreview(_ routes: NavigationRoutes, trip newTrip: Trip) {
        suppressRecalc = true
        trip = newTrip
        suppressRecalc = false
        previewRoutes = routes
        map?.showRoutes(routes)
    }

    // MARK: Guidance

    func startGuidance() {
        guard let routes = previewRoutes else { return }
        GuidancePresenter.shared.start(routes: routes, trip: trip, appModel: self)
    }

    func guidanceEnded(thenSketch: Bool = false) {
        engine.startFreeDrive()
        sheet = nil
        guard thenSketch else {
            clearRoute()
            return
        }
        // Keep the trip, recalculated from here, and open sketch mode on it.
        Task {
            await recalculate()
            startSketch()
        }
    }

    // MARK: Map press menu

    /// Press and hold on the map (before GO): Sketch, Natural language, Navigate here, …
    func openMapMenu(at point: CGPoint, coordinate: CLLocationCoordinate2D) {
        let pin = Place(
            name: "Dropped pin",
            subtitle: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
            coordinate: coordinate,
            source: .mapPress
        )
        pressedPlace = pin
        let hasDestination = !trip.isEmpty
        let items: [PressMenuItem] = [
            PressMenuItem(id: "sketch", title: "Sketch", subtitle: "Draw the way you want to go", icon: "scribble.variable") { [weak self] in
                self?.startSketch()
            },
            PressMenuItem(id: "language", title: "Natural language", subtitle: "Say or type what you need", icon: "text.bubble") { [weak self] in
                self?.sheet = .naturalLanguage
            },
            PressMenuItem(id: "navigate", title: "Navigate here", icon: "arrow.triangle.turn.up.right.diamond.fill", isProminent: true) { [weak self] in
                guard let self, let place = self.pressedPlace else { return }
                self.choose(destination: place)
            },
            PressMenuItem(id: "stop", title: "Add as stop", subtitle: hasDestination ? nil : "Becomes your destination", icon: "mappin.and.ellipse") { [weak self] in
                guard let self, let place = self.pressedPlace else { return }
                self.insertAlongRoute(place, kind: .stop)
            },
            PressMenuItem(id: "via", title: "Add as via point", subtitle: hasDestination ? nil : "Pick a destination first", icon: "smallcircle.filled.circle", isEnabled: hasDestination) { [weak self] in
                guard let self, let place = self.pressedPlace else { return }
                self.insertAlongRoute(place, kind: .via)
            },
            PressMenuItem(id: "save", title: "Save place", icon: "star") { [weak self] in
                guard let self, let place = self.pressedPlace else { return }
                self.sheet = .savePlace(place)
            },
        ]
        pressMenu.present(title: "Dropped pin", items: items, at: point)
        Task { [weak self] in
            guard let name = try? await PlaceSearchService.shared.addressName(at: coordinate) else { return }
            guard let self, self.pressedPlace?.coordinate.latitude == coordinate.latitude else { return }
            self.pressedPlace?.name = name
            self.pressMenu.updateTitle(name)
        }
    }

    // MARK: Categories (stage 5 + 12)

    func showCategory(_ category: PlaceCategory) async {
        let center = map?.searchCenter ?? currentLocation?.coordinate
        guard let center else { routeError = RouteCalculationError.noOrigin.localizedDescription; return }
        activeCategory = category
        do {
            categoryResults = try await PlaceSearchService.shared.search(category: category, near: center)
            map?.showResults(categoryResults)
        } catch {
            routeError = "Category search failed: \(error.localizedDescription)"
        }
    }

    func clearCategoryResults() {
        activeCategory = nil
        categoryResults = []
        map?.showResults([])
    }

    func isArmed(_ category: PlaceCategory) -> Bool { armedCategoryIDs.contains(category.id) }

    /// Tap on a chip: arm or disarm it. Armed chips add a flexible stop to the next trip.
    func toggleArmed(_ category: PlaceCategory) {
        if armedCategoryIDs.contains(category.id) {
            armedCategoryIDs.remove(category.id)
        } else {
            armedCategoryIDs.insert(category.id)
            Theme.Haptics.light()
        }
        armTimeout?.cancel()
        guard !armedCategoryIDs.isEmpty else { return }
        armTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.armedCategoryIDs = []
        }
    }

    func disarmAll() {
        armTimeout?.cancel()
        armedCategoryIDs = []
    }

    var armedBannerText: String? {
        let names = PlaceCategory.all.filter { armedCategoryIDs.contains($0.id) }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: " and ")) on this trip: now pick a destination"
    }

    private func buildArmedTrip(to destination: Place) {
        var items: [TripItem] = PlaceCategory.all
            .filter { armedCategoryIDs.contains($0.id) }
            .map { TripItem(kind: .category($0.id), name: $0.displayName, coordinate: nil) }
        items.append(destination.asTripItem(kind: .stop))
        suppressRecalc = true
        trip = Trip(items: items)
        suppressRecalc = false
        disarmAll()
        sheet = .tripBuilder
        Task { await runPlanner() }
    }

    // MARK: Planner (stage 11)

    func runPlanner() async {
        guard let origin = currentLocation else { routeError = RouteCalculationError.noOrigin.localizedDescription; return }
        isCalculating = true
        defer { isCalculating = false }
        do {
            let outcome = try await TripPlanner(engine: engine).plan(trip: trip, origin: origin, settings: .current)
            plannerOutcome = outcome
            trip = outcome.trip // triggers a normal route recalculation
        } catch {
            routeError = error.localizedDescription
        }
    }

    func applyPlannerAlternative(_ option: PlannerOption) {
        guard var outcome = plannerOutcome else { return }
        outcome.select(option)
        plannerOutcome = outcome
        trip = outcome.trip
    }

    // MARK: Natural language

    enum NaturalPlanError: LocalizedError {
        case noDestination, notFound(String)
        var errorDescription: String? {
            switch self {
            case .noDestination: "Where are you heading? Say a place or a saved destination."
            case .notFound(let query): "Couldn't find \"\(query)\". Try saying it another way."
            }
        }
    }

    /// Turns a natural-language plan into a trip: resolves the destination (saved place or
    /// search), adds the flexible stops in order, and lets the planner pick them along the route.
    func apply(_ plan: NaturalTripPlan) async throws {
        let destination = try await resolveDestination(plan.destination)
        let items = plan.flexibleItems + [destination.asTripItem(kind: .stop)]
        selectedPlace = destination
        walkingDestination = nil
        plannerOutcome = nil
        suppressRecalc = true
        trip = Trip(items: items)
        suppressRecalc = false
        statusMessage = plan.summary.isEmpty ? nil : plan.summary
        if items.contains(where: { $0.categoryID != nil }) {
            await runPlanner()
        } else {
            await recalculate()
        }
    }

    private func resolveDestination(_ destination: NaturalTripPlan.Destination) async throws -> Place {
        let savedName = destination.savedPlace.trimmingCharacters(in: .whitespaces)
        if !savedName.isEmpty {
            let saved = (try? Persistence.shared.mainContext.fetch(FetchDescriptor<SavedPlace>())) ?? []
            if let match = saved.first(where: { $0.name.compare(savedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                return match.asPlace
            }
        }
        let query = destination.query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let near = currentLocation?.coordinate
            guard let first = try await PlaceSearchService.shared.suggestions(for: query, near: near).first else {
                throw NaturalPlanError.notFound(query)
            }
            return try await PlaceSearchService.shared.resolve(first)
        }
        if let current = destinationPlace { return current }
        throw NaturalPlanError.noDestination
    }

    // MARK: Parking (stage 13)

    /// Drive to `spot`, keep `destination` as a walking leg.
    func driveToParking(_ spot: ParkingOption, destination: Place) {
        walkingDestination = destination
        var items = trip.items
        let parkingItem = TripItem(kind: .stop, name: spot.title, coordinate: spot.coordinate)
        if let index = items.lastIndex(where: { $0.coordinate.map { GeoMath.distance($0, destination.coordinate) < 30 } ?? false }) {
            items[index] = parkingItem
        } else {
            items.append(parkingItem)
        }
        trip = Trip(items: items)
        if !engine.isGuiding { sheet = nil }
    }

    private func updateWalkingLeg(to destination: Place) async {
        guard let parking = trip.routableItems.last?.coordinate else { return }
        do {
            let walk = try await WalkingRouter.route(from: parking, to: destination.coordinate)
            map?.showWalkingLeg(walk.coordinates)
            statusMessage = "Then walk \(Formatters.duration(walk.duration)) to \(destination.name)"
        } catch {
            map?.showWalkingLeg(nil)
        }
    }
}
