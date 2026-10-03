import CoreGraphics
import CoreLocation
import Foundation

/// Small, dependency-free geometry helpers. Pure functions so they can be unit tested.
enum GeoMath {
    static let earthRadius: Double = 6_371_000

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Total length of a polyline in metres.
    static func length(of line: [CLLocationCoordinate2D]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Projects coordinates onto a local flat plane (metres) around `origin`. Accurate enough
    /// for distances up to a few hundred km, which is all we use it for.
    static func localXY(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> CGPoint {
        let x = (c.longitude - origin.longitude) * .pi / 180 * earthRadius * cos(origin.latitude * .pi / 180)
        let y = (c.latitude - origin.latitude) * .pi / 180 * earthRadius
        return CGPoint(x: x, y: y)
    }

    struct Projection: Equatable {
        /// Closest point on the line.
        var coordinate: CLLocationCoordinate2D
        /// Distance from the query point to the line, metres.
        var distanceFromLine: Double
        /// Distance along the line from its start to the closest point, metres.
        var distanceAlong: Double
        /// Index of the segment start.
        var segmentIndex: Int

        static func == (l: Projection, r: Projection) -> Bool {
            l.segmentIndex == r.segmentIndex && abs(l.distanceAlong - r.distanceAlong) < 0.01
        }
    }

    /// Closest point on `line` to `point`.
    static func project(_ point: CLLocationCoordinate2D, onto line: [CLLocationCoordinate2D]) -> Projection? {
        guard let first = line.first else { return nil }
        guard line.count > 1 else {
            return Projection(coordinate: first, distanceFromLine: distance(point, first), distanceAlong: 0, segmentIndex: 0)
        }
        var best: Projection?
        var travelled = 0.0
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let pa = localXY(a, origin: point), pb = localXY(b, origin: point)
            let abx = pb.x - pa.x, aby = pb.y - pa.y
            let len2 = abx * abx + aby * aby
            var t = len2 > 0 ? -(pa.x * abx + pa.y * aby) / len2 : 0
            t = max(0, min(1, t))
            let cx = pa.x + t * abx, cy = pa.y + t * aby
            let d = Double(sqrt(cx * cx + cy * cy))
            let segLen = distance(a, b)
            if best == nil || d < best!.distanceFromLine {
                let c = CLLocationCoordinate2D(
                    latitude: a.latitude + Double(t) * (b.latitude - a.latitude),
                    longitude: a.longitude + Double(t) * (b.longitude - a.longitude)
                )
                best = Projection(coordinate: c, distanceFromLine: d, distanceAlong: travelled + Double(t) * segLen, segmentIndex: i)
            }
            travelled += segLen
        }
        return best
    }

    /// The coordinate `metres` along the line from its start (clamped to the ends).
    static func coordinate(along line: [CLLocationCoordinate2D], at metres: Double) -> CLLocationCoordinate2D? {
        guard var previous = line.first else { return nil }
        if metres <= 0 { return previous }
        var travelled = 0.0
        for next in line.dropFirst() {
            let seg = distance(previous, next)
            if travelled + seg >= metres, seg > 0 {
                let t = (metres - travelled) / seg
                return CLLocationCoordinate2D(
                    latitude: previous.latitude + t * (next.latitude - previous.latitude),
                    longitude: previous.longitude + t * (next.longitude - previous.longitude)
                )
            }
            travelled += seg
            previous = next
        }
        return line.last
    }

    /// Ramer-Douglas-Peucker simplification on screen points. `tolerance` is in points.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDist: CGFloat = 0
            var index = start
            for i in (start + 1)..<end {
                let d = perpendicularDistance(points[i], points[start], points[end])
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist > tolerance {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Simplifies, then if still above `maxPoints` raises the tolerance until it fits.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat, maxPoints: Int) -> [CGPoint] {
        var tol = tolerance
        var result = simplify(points, tolerance: tol)
        while result.count > maxPoints, tol < 10_000 {
            tol *= 1.25
            result = simplify(points, tolerance: tol)
        }
        if result.count > maxPoints {
            // Degenerate input; keep evenly spaced points including both ends.
            let step = Double(result.count - 1) / Double(maxPoints - 1)
            result = (0..<maxPoints).map { result[Int((Double($0) * step).rounded())] }
        }
        return result
    }

    static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Distance in screen points from `p` to the polyline `line`.
    static func distance(from p: CGPoint, toPolyline line: [CGPoint]) -> CGFloat {
        guard line.count > 1 else { return line.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .infinity }
        return zip(line, line.dropFirst()).map { perpendicularDistance(p, $0.0, $0.1) }.min() ?? .infinity
    }

    /// Evenly resamples a polyline to at most `count` coordinates (keeps both ends).
    static func resample(_ line: [CLLocationCoordinate2D], count: Int) -> [CLLocationCoordinate2D] {
        guard line.count > count, count >= 2 else { return line }
        let total = length(of: line)
        return (0..<count).compactMap { coordinate(along: line, at: total * Double($0) / Double(count - 1)) }
    }
}
