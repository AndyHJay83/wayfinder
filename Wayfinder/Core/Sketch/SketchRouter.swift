import CoreGraphics
import CoreLocation
import Foundation
import MapboxDirections
import MapboxNavigationCore

/// One finished finger stroke, converted to coordinates at the zoom it was drawn at.
struct SketchStroke {
    /// Raw stroke in coordinates (for map matching).
    let coordinates: [CLLocationCoordinate2D]
    /// Simplified anchors (Douglas-Peucker in screen pixels).
    let anchors: [CLLocationCoordinate2D]
    /// Metres per screen point when drawn.
    let metresPerPoint: Double
}

struct SketchAnchor: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// Snap radius sent to Directions (`radiuses`), nil when snapped to a named place.
    var snapRadius: Double?

    static func == (l: SketchAnchor, r: SketchAnchor) -> Bool { l.id == r.id && l.name == r.name }
}

enum SketchMode: Equatable {
    case guideThroughPoints
    case followLineClosely
}

/// The result shown in the sketch preview.
struct SketchProposal: Identifiable {
    let id = UUID()
    var anchors: [SketchAnchor]
    var routes: NavigationRoutes
    var trip: Trip
    var mode: SketchMode
    var baselineDuration: TimeInterval?
    var baselineDistance: CLLocationDistance?
    var followLineAvailable: Bool
    var notices: [String]

    var duration: TimeInterval { routes.mainRoute.route.expectedTravelTime }
    var distance: CLLocationDistance { routes.mainRoute.route.distance }
    /// Long trips: traffic far ahead isn't known, so the ETA is an estimate.
    var isEstimate: Bool { duration > 3600 }
}

/// Pure sketch maths, unit tested.
enum SketchMath {
    static let simplifyTolerancePoints: CGFloat = 16
    /// Directions takes 25 coordinates in total: origin + final destination + 23 anchors.
    static let maxAnchors = RouteLimits.maxDirectionsCoordinates - 2
    /// Above this many metres per 16 px we snap to named places instead of roads.
    static let namedPlaceThresholdMetres: Double = 500
    /// Map Matching only snaps within 50 m, so the line must be that accurate.
    static let followLineMaxMetres: Double = 50
    /// Warn if the route passes further than this from an anchor.
    static let anchorWarningMetres: Double = 3000

    static func toleranceMetres(metresPerPoint: Double) -> Double {
        Double(simplifyTolerancePoints) * metresPerPoint
    }

    static func usesNamedPlaces(metresPerPoint: Double) -> Bool {
        toleranceMetres(metresPerPoint: metresPerPoint) > namedPlaceThresholdMetres
    }

    static func canFollowLine(metresPerPoint: Double) -> Bool {
        toleranceMetres(metresPerPoint: metresPerPoint) <= followLineMaxMetres
    }

    /// Simplifies screen points and caps the count.
    static func anchors(fromScreen points: [CGPoint], maxAnchors: Int = maxAnchors) -> [CGPoint] {
        GeoMath.simplify(points, tolerance: simplifyTolerancePoints, maxPoints: maxAnchors)
    }

    /// Caps combined anchors from several strokes by re-simplifying in metres.
    static func cap(_ coordinates: [CLLocationCoordinate2D], to maxCount: Int = maxAnchors) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxCount, let origin = coordinates.first else { return coordinates }
        let xy = coordinates.map { GeoMath.localXY($0, origin: origin) }
        let kept = GeoMath.simplify(xy, tolerance: 1, maxPoints: maxCount)
        return kept.compactMap { p in xy.firstIndex(of: p).map { coordinates[$0] } }
    }

    /// Anchors further than `anchorWarningMetres` from the route line.
    static func anchorsFarFromRoute(_ anchors: [SketchAnchor], route: [CLLocationCoordinate2D]) -> [SketchAnchor] {
        anchors.filter { anchor in
            (GeoMath.project(anchor.coordinate, onto: route)?.distanceFromLine ?? 0) > anchorWarningMetres
        }
    }
}

/// Turns finished strokes into a route proposal.
@MainActor
struct SketchRouter {
    let engine: NavigationEngine
    let search = PlaceSearchService.shared

    /// Builds anchors for strokes, snapping by scale.
    func anchors(for strokes: [SketchStroke]) async -> [SketchAnchor] {
        var anchors: [SketchAnchor] = []
        for stroke in strokes {
            let usesPlaces = SketchMath.usesNamedPlaces(metresPerPoint: stroke.metresPerPoint)
            for coordinate in stroke.anchors {
                if usesPlaces {
                    if let place = try? await search.nearestNamedPlace(to: coordinate) {
                        // Skip repeats (two anchors in the same town).
                        if anchors.last?.name == place.name { continue }
                        anchors.append(SketchAnchor(name: place.name, coordinate: place.coordinate, snapRadius: nil))
                    }
                } else {
                    // Snap to the nearest road through the Directions `radiuses` parameter.
                    let radius = max(25, min(200, SketchMath.toleranceMetres(metresPerPoint: stroke.metresPerPoint) * 2))
                    anchors.append(SketchAnchor(name: "Point \(anchors.count + 1)", coordinate: coordinate, snapRadius: radius))
                }
            }
        }
        let capped = SketchMath.cap(anchors.map(\.coordinate))
        return anchors.filter { anchor in capped.contains { $0.latitude == anchor.coordinate.latitude && $0.longitude == anchor.coordinate.longitude } }
    }

    /// Inserts anchors as via points before the trip's final stop. With no trip, the last
    /// anchor becomes the destination.
    func trip(byAdding anchors: [SketchAnchor], to existing: Trip) -> Trip {
        var vias = anchors.map { TripItem(kind: .via, name: $0.name, coordinate: $0.coordinate, snapRadius: $0.snapRadius) }
        var trip = existing
        if trip.routableItems.isEmpty {
            guard var last = vias.popLast() else { return trip }
            last.kind = .stop
            trip.items = vias + [last]
        } else {
            let insertAt = trip.items.lastIndex { $0.kind != .via } ?? trip.items.count
            trip.items.insert(contentsOf: vias, at: insertAt)
        }
        return trip
    }

    func propose(strokes: [SketchStroke], anchors: [SketchAnchor], existingTrip: Trip, mode requested: SketchMode) async throws -> SketchProposal {
        guard let origin = engine.location else { throw RouteCalculationError.noOrigin }
        let followAvailable = strokes.allSatisfy { SketchMath.canFollowLine(metresPerPoint: $0.metresPerPoint) }
        var notices: [String] = []
        let trip = trip(byAdding: anchors, to: existingTrip)

        var mode = followAvailable ? requested : .guideThroughPoints
        var routes: NavigationRoutes
        if mode == .followLineClosely {
            do {
                let line = strokes.flatMap(\.coordinates)
                routes = try await engine.calculator.match(origin: origin, line: line, radius: SketchMath.followLineMaxMetres)
            } catch {
                notices.append("Couldn't follow your line exactly, so the route goes through your points instead.")
                mode = .guideThroughPoints
                routes = try await engine.calculator.calculate(origin: origin, trip: trip, alternatives: false)
            }
        } else {
            routes = try await engine.calculator.calculate(origin: origin, trip: trip, alternatives: false)
        }

        // Compare with the route you'd get without the sketch.
        var baselineDuration: TimeInterval?
        var baselineDistance: CLLocationDistance?
        let baselineTrip = existingTrip.routableItems.isEmpty
            ? Trip(items: trip.items.filter { $0.kind != .via })
            : existingTrip
        if let baseline = try? await engine.calculator.calculate(origin: origin, trip: baselineTrip, alternatives: false) {
            baselineDuration = baseline.mainRoute.route.expectedTravelTime
            baselineDistance = baseline.mainRoute.route.distance
        }

        let shape = routes.mainRoute.route.shape?.coordinates ?? []
        let far = SketchMath.anchorsFarFromRoute(anchors, route: shape)
        if !far.isEmpty {
            notices.append("The route passes more than 3 km from \(far.map(\.name).joined(separator: ", ")). Move or delete that point if it matters.")
        }

        return SketchProposal(
            anchors: anchors, routes: routes, trip: trip, mode: mode,
            baselineDuration: baselineDuration, baselineDistance: baselineDistance,
            followLineAvailable: followAvailable, notices: notices
        )
    }
}
