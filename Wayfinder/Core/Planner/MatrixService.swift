import CoreLocation
import Foundation

/// Mapbox Matrix API: drive times between many points, batched under the per-request
/// coordinate limit and cached in memory.
actor MatrixService {
    static let shared = MatrixService()

    struct Matrix {
        /// seconds, [from][to]; .infinity when unreachable
        var durations: [[Double]]
        /// metres, [from][to]
        var distances: [[Double]]
    }

    enum MatrixError: LocalizedError {
        case noToken, http(Int)
        var errorDescription: String? {
            switch self {
            case .noToken: "Mapbox token missing."
            case .http(let code): "Matrix request failed (\(code))."
            }
        }
    }

    private struct Response: Decodable {
        let code: String
        let durations: [[Double?]]?
        let distances: [[Double?]]?
    }

    private var cache: [String: (Double, Double)] = [:]

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", c.latitude, c.longitude)
    }

    /// Full N×N matrix. Uses the `driving` profile (25 coordinates per request) for planning;
    /// live traffic is applied later when the chosen order is routed.
    func matrix(for points: [CLLocationCoordinate2D]) async throws -> Matrix {
        let n = points.count
        var durations = Array(repeating: Array(repeating: Double.infinity, count: n), count: n)
        var distances = Array(repeating: Array(repeating: Double.infinity, count: n), count: n)
        for i in 0..<n { durations[i][i] = 0; distances[i][i] = 0 }

        var missingSources = Set<Int>(), missingDestinations = Set<Int>()
        for i in 0..<n {
            for j in 0..<n where i != j {
                if let hit = cache["\(Self.key(points[i]))>\(Self.key(points[j]))"] {
                    durations[i][j] = hit.0
                    distances[i][j] = hit.1
                } else {
                    missingSources.insert(i)
                    missingDestinations.insert(j)
                }
            }
        }

        let chunk = RouteLimits.maxMatrixCoordinates / 2 // sources + destinations ≤ 25
        let sources = missingSources.sorted().chunked(into: chunk)
        let destinations = missingDestinations.sorted().chunked(into: chunk)
        for sourceChunk in sources {
            for destinationChunk in destinations {
                try await fetch(points: points, sources: sourceChunk, destinations: destinationChunk, durations: &durations, distances: &distances)
            }
        }
        return Matrix(durations: durations, distances: distances)
    }

    private func fetch(points: [CLLocationCoordinate2D], sources: [Int], destinations: [Int], durations: inout [[Double]], distances: inout [[Double]]) async throws {
        guard let token = AppConfig.mapboxAccessToken else { throw MatrixError.noToken }
        let indices = Array(Set(sources + destinations)).sorted()
        let local = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) })
        let coordinateString = indices.map { String(format: "%.6f,%.6f", points[$0].longitude, points[$0].latitude) }.joined(separator: ";")
        var components = URLComponents(string: "https://api.mapbox.com/directions-matrix/v1/mapbox/driving/\(coordinateString)")!
        components.queryItems = [
            URLQueryItem(name: "sources", value: sources.map { String(local[$0]!) }.joined(separator: ";")),
            URLQueryItem(name: "destinations", value: destinations.map { String(local[$0]!) }.joined(separator: ";")),
            URLQueryItem(name: "annotations", value: "duration,distance"),
            URLQueryItem(name: "access_token", value: token),
        ]
        RequestCounter.shared.record(.matrix)
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MatrixError.http(status) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        for (si, source) in sources.enumerated() {
            for (di, destination) in destinations.enumerated() where source != destination {
                let d = decoded.durations?[si][di] ?? nil
                let m = decoded.distances?[si][di] ?? nil
                durations[source][destination] = d ?? .infinity
                distances[source][destination] = m ?? .infinity
                if let d, let m { cache["\(Self.key(points[source]))>\(Self.key(points[destination]))"] = (d, m) }
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
