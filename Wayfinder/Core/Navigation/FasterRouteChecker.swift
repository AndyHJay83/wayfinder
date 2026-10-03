import AVFoundation
import Combine
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Pure decision rules for the faster-route checker, separated so they can be unit tested.
struct FasterRoutePolicy {
    var thresholdSeconds: TimeInterval = 60
    var autoAccept = false
    var autoAcceptSeconds: TimeInterval = 180
    var requiredConsecutiveChecks = 2
    var minimumManoeuvreDistance: CLLocationDistance = 300
    var minimumGapBetweenSuggestions: TimeInterval = 180

    static var current: FasterRoutePolicy {
        let d = UserDefaults.standard
        return FasterRoutePolicy(
            thresholdSeconds: d.double(forKey: SettingsKeys.fasterRouteThresholdSeconds),
            autoAccept: d.bool(forKey: SettingsKeys.fasterRouteAutoAccept),
            autoAcceptSeconds: d.double(forKey: SettingsKeys.fasterRouteAutoAcceptSeconds)
        )
    }

    enum Decision: Equatable {
        case skip(String)
        case keepWatching(consecutive: Int)
        case suggest
        case autoAccept
    }

    /// - Parameters:
    ///   - saving: seconds the candidate saves over the remaining time on the current route.
    ///   - consecutive: how many previous checks in a row already beat the threshold.
    func decide(
        saving: TimeInterval,
        consecutive: Int,
        distanceToNextManoeuvre: CLLocationDistance,
        secondsSinceLastSuggestion: TimeInterval?,
        candidateWasIgnored: Bool
    ) -> Decision {
        guard saving >= thresholdSeconds else { return .keepWatching(consecutive: 0) }
        let streak = consecutive + 1
        guard streak >= requiredConsecutiveChecks else { return .keepWatching(consecutive: streak) }
        if candidateWasIgnored { return .skip("already ignored") }
        if distanceToNextManoeuvre < minimumManoeuvreDistance { return .skip("too close to next manoeuvre") }
        if let since = secondsSinceLastSuggestion, since < minimumGapBetweenSuggestions { return .skip("suggested recently") }
        if autoAccept, saving >= autoAcceptSeconds { return .autoAccept }
        return .suggest
    }
}

/// What the banner shows.
struct FasterRouteSuggestion: Equatable, Identifiable {
    let id = UUID()
    let roadName: String?
    let savingSeconds: TimeInterval
    let changes: Int
    let wasAutoAccepted: Bool

    var text: String {
        let saves = "saves \(Formatters.duration(savingSeconds))"
        let changeText = changes == 1 ? "1 change" : "\(changes) changes"
        let lead = wasAutoAccepted ? "Switched to a faster route" : (roadName.map { "Via \($0)" } ?? "Faster route")
        return "\(lead), \(saves), \(changeText)"
    }

    var spoken: String {
        wasAutoAccepted
            ? "Switched to a faster route, saving \(Int((savingSeconds / 60).rounded())) minutes."
            : "Faster route\(roadName.map { " via \($0)" } ?? ""), saves \(Int((savingSeconds / 60).rounded())) minutes."
    }
}

@MainActor
final class FasterRouteBannerModel: ObservableObject {
    @Published var suggestion: FasterRouteSuggestion?
    /// Destination name when we're within about a mile and could offer parking.
    @Published var parkingPrompt: String?
    var onAccept: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onParkNearby: (() -> Void)?
}

/// Every 45 s during guidance, asks for a fresh traffic-aware route from the current position
/// through the remaining stops (and via points still ahead), and suggests it if it is
/// reliably faster.
@MainActor
final class FasterRouteChecker {
    private let navigation: MapboxNavigation
    private var trip: Trip
    private let banner: FasterRouteBannerModel
    private let interval: TimeInterval = 45

    private var timer: Task<Void, Never>?
    private var consecutive = 0
    private var lastSuggestionAt: Date?
    private var ignoredSignatures = Set<String>()
    private var pending: (routes: NavigationRoutes, remaining: Trip, signature: String)?
    private var dismissTask: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()

    init(navigation: MapboxNavigation, trip: Trip, banner: FasterRouteBannerModel) {
        self.navigation = navigation
        self.trip = trip
        self.banner = banner
        banner.onAccept = { [weak self] in self?.accept() }
        banner.onIgnore = { [weak self] in self?.ignore() }
    }

    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 45))
                guard !Task.isCancelled else { return }
                await self?.check()
            }
        }
    }

    func replaceTrip(_ newTrip: Trip) {
        trip = newTrip
        consecutive = 0
        pending = nil
    }

    func stop() {
        timer?.cancel()
        dismissTask?.cancel()
        banner.suggestion = nil
    }

    private func check() async {
        guard banner.suggestion == nil,
              let progress = navigation.navigation().currentRouteProgress?.routeProgress,
              let location = navigation.navigation().currentLocationMatching?.enhancedLocation
        else { return }

        let remaining = remainingTrip(progress: progress)
        guard !remaining.routableItems.isEmpty else { return }

        RequestCounter.shared.record(.fasterRouteCheck)
        let calculator = RouteCalculator(navigation: navigation)
        guard let candidate = try? await calculator.calculate(origin: location, trip: remaining, alternatives: false) else { return }

        let candidateTime = candidate.mainRoute.route.expectedTravelTime
        let saving = progress.durationRemaining - candidateTime
        let signature = Self.signature(of: candidate.mainRoute.route)
        let currentNames = Set(progress.remainingSteps.flatMap { $0.names ?? [] })

        let decision = FasterRoutePolicy.current.decide(
            saving: saving,
            consecutive: consecutive,
            distanceToNextManoeuvre: progress.currentLegProgress.currentStepProgress.distanceRemaining,
            secondsSinceLastSuggestion: lastSuggestionAt.map { Date().timeIntervalSince($0) },
            candidateWasIgnored: ignoredSignatures.contains(signature)
        )

        switch decision {
        case .keepWatching(let streak):
            consecutive = streak
        case .skip:
            break
        case .suggest, .autoAccept:
            consecutive = 0
            lastSuggestionAt = Date()
            let newSteps = candidate.mainRoute.route.legs.flatMap(\.steps).filter { step in
                !(step.names ?? []).contains(where: currentNames.contains)
            }
            let road = newSteps.max { $0.distance < $1.distance }?.names?.first
            let changes = max(1, Set(newSteps.compactMap { $0.names?.first }).count)
            pending = (candidate, remaining, signature)
            let suggestion = FasterRouteSuggestion(
                roadName: road, savingSeconds: saving, changes: changes,
                wasAutoAccepted: decision == .autoAccept
            )
            if decision == .autoAccept { accept() }
            show(suggestion)
        }
    }

    /// Stops not yet reached, plus via points that are still ahead on the current route.
    private func remainingTrip(progress: RouteProgress) -> Trip {
        let shape = progress.route.shape?.coordinates ?? []
        let travelled = progress.distanceTraveled
        var legIndex = 0
        var remaining: [TripItem] = []
        let routable = trip.routableItems
        for (offset, item) in routable.enumerated() {
            let isLast = offset == routable.count - 1
            let separates = isLast || item.kind != .via
            defer { if separates { legIndex += 1 } }
            if legIndex < progress.legIndex { continue }
            if item.kind == .via, legIndex == progress.legIndex,
               let c = item.coordinate, let projected = GeoMath.project(c, onto: shape),
               projected.distanceAlong < travelled {
                continue // already passed this via
            }
            remaining.append(item)
        }
        return Trip(items: remaining)
    }

    private func accept() {
        guard let pending else { return }
        navigation.tripSession().startActiveGuidance(with: pending.routes, startLegIndex: 0)
        trip = pending.remaining
        self.pending = nil
        if banner.suggestion?.wasAutoAccepted == false { banner.suggestion = nil }
    }

    private func ignore() {
        if let pending { ignoredSignatures.insert(pending.signature) }
        pending = nil
        banner.suggestion = nil
    }

    private func show(_ suggestion: FasterRouteSuggestion) {
        banner.suggestion = suggestion
        speech.speak(AVSpeechUtterance(string: suggestion.spoken))
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if self?.banner.suggestion?.id == suggestion.id {
                // Auto-dismiss counts as ignoring, so we don't nag about the same route.
                if suggestion.wasAutoAccepted { self?.banner.suggestion = nil } else { self?.ignore() }
            }
        }
    }

    /// Identifies a route by its sequence of major road names.
    static func signature(of route: Route) -> String {
        route.legs.flatMap(\.steps)
            .filter { $0.distance > 500 }
            .compactMap { $0.names?.first }
            .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
            .joined(separator: ">")
    }
}
