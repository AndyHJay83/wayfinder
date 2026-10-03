import Foundation
import os

/// Counts Mapbox API requests we make ourselves so we can keep an eye on the free tier.
/// In debug builds it logs a per-hour tally (stage 9 requirement).
final class RequestCounter: @unchecked Sendable {
    enum Kind: String, CaseIterable {
        case directions, mapMatching, matrix, search, reverseGeocode, fasterRouteCheck
    }

    static let shared = RequestCounter()

    private let lock = NSLock()
    private var events: [(Date, Kind)] = []
    private let log = Logger(subsystem: "Wayfinder", category: "Requests")

    func record(_ kind: Kind) {
        lock.lock()
        let now = Date()
        events.append((now, kind))
        events.removeAll { now.timeIntervalSince($0.0) > 3600 }
        let total = events.count
        let ofKind = events.filter { $0.1 == kind }.count
        lock.unlock()
        #if DEBUG
        log.debug("Mapbox request \(kind.rawValue, privacy: .public): \(ofKind) of this kind, \(total) total in the last hour")
        #endif
    }

    func countLastHour(_ kind: Kind? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return events.filter { now.timeIntervalSince($0.0) <= 3600 && (kind == nil || $0.1 == kind) }.count
    }
}
