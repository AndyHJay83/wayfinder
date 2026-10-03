import Combine
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore
import SwiftUI

/// Central app state. Views stay small and call into this; the map is driven through
/// `MapController`.
@MainActor
final class AppModel: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case search
        case routePreview
        case savedPlaces
        case settings
        case tripBuilder
        case savePlace(Place)
        case localPlaces(PlaceCategory)
        case parkNearby(Place)
        case chainBranches(String)
        case plannerResult

        var id: String {
            switch self {
            case .search: "search"
            case .routePreview: "routePreview"
            case .savedPlaces: "savedPlaces"
            case .settings: "settings"
            case .tripBuilder: "tripBuilder"
            case .savePlace(let p): "save-\(p.id)"
            case .localPlaces(let c): "local-\(c.id)"
            case .parkNearby(let p): "park-\(p.id)"
            case .chainBranches(let n): "chain-\(n)"
            case .plannerResult: "planner"
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
    @Published var pendingMapPress: Place?
    @Published var selectedPlace: Place?
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
        trip = Trip(items: [place.asTripItem(kind: .stop)])
        sheet = .routePreview
    }

    func addToTrip(_ place: Place, kind: TripItem.Kind = .stop) {
        trip.append(place.asTripItem(kind: kind))
        statusMessage = "Added \(place.name) to the trip"
    }

    func clearRoute() {
        recalcTask?.cancel()
        suppressRecalc = true
        trip = Trip()
        suppressRecalc = false
        previewRoutes = nil
        walkingDestination = nil
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

    func guidanceEnded() {
        engine.startFreeDrive()
        clearRoute()
        sheet = nil
    }

    // MARK: Map interactions

    func handleLongPress(at coordinate: CLLocationCoordinate2D, name: String?) {
        pendingMapPress = Place(
            name: name ?? "Dropped pin",
            subtitle: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
            coordinate: coordinate,
            source: .mapPress
        )
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
        if !engine.isGuiding { sheet = .routePreview }
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
