import Foundation

/// A price for stays up to `upToMinutes` (e.g. up to 60 min: 280p).
struct TariffBand: Codable, Hashable {
    var upToMinutes: Int
    var pricePence: Int
}

/// Pure parsing and evaluation of parking time rules. Supports the common OSM forms:
///   maxstay: "2 hours", "90 minutes", "1 hour 30 minutes", "2h"
///   conditional: "yes @ (Mo-Sa 08:00-18:00)", "no_parking @ (07:00-19:00); loading_only @ (Su)"
///   opening_hours: "24/7", "Mo-Fr 08:00-18:00; Sa 09:00-13:00"
/// Anything it can't understand returns nil so the UI says "Unverified" rather than guessing.
enum ParkingRules {
    // MARK: Durations

    static func minutes(fromDuration text: String) -> Int? {
        let s = text.lowercased().trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "no" || s == "none" { return nil }
        // "HH:MM" form
        if s.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            return parts[0] * 60 + parts[1]
        }
        let scanner = Scanner(string: s.replacingOccurrences(of: ",", with: " "))
        var total = 0.0
        var found = false
        while !scanner.isAtEnd {
            guard let value = scanner.scanDouble() else { _ = scanner.scanCharacter(); continue }
            let unit = scanner.scanCharacters(from: .letters) ?? ""
            found = true
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += value * 60
            case "d", "day", "days": total += value * 1440
            case "", "m", "min", "mins", "minute", "minutes": total += value
            default: return nil
            }
        }
        return found ? Int(total.rounded()) : nil
    }

    // MARK: Opening-hours style schedules

    struct Interval: Equatable {
        /// Calendar weekday numbers (1 = Sunday … 7 = Saturday).
        var weekdays: Set<Int>
        var startMinute: Int
        var endMinute: Int
    }

    private static let dayCodes = ["Su": 1, "Mo": 2, "Tu": 3, "We": 4, "Th": 5, "Fr": 6, "Sa": 7]
    private static let allDays: Set<Int> = Set(1...7)

    /// Parses a simple schedule. Returns nil for anything unsupported (PH, sunrise, months…).
    static func schedule(_ text: String) -> [Interval]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "24/7" { return [Interval(weekdays: allDays, startMinute: 0, endMinute: 1440)] }
        var result: [Interval] = []
        for rule in trimmed.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !rule.isEmpty {
            if rule.contains("PH") || rule.contains("SH") || rule.contains("sun") || rule.contains("off") { return nil }
            var days = allDays
            var timesPart = rule
            if let first = rule.first, first.isLetter {
                let pieces = rule.split(separator: " ", maxSplits: 1).map(String.init)
                guard let parsedDays = weekdays(pieces[0]) else { return nil }
                days = parsedDays
                timesPart = pieces.count > 1 ? pieces[1] : "00:00-24:00"
            }
            for range in timesPart.split(separator: ",") {
                let ends = range.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                guard ends.count == 2, let start = clock(ends[0]), let end = clock(ends[1]) else { return nil }
                result.append(Interval(weekdays: days, startMinute: start, endMinute: end))
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func weekdays(_ text: String) -> Set<Int>? {
        var days = Set<Int>()
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-").map(String.init)
            guard let a = dayCodes[ends[0]] else { return nil }
            if ends.count == 2 {
                guard let b = dayCodes[ends[1]] else { return nil }
                var d = a
                while true { days.insert(d); if d == b { break }; d = d % 7 + 1 }
            } else {
                days.insert(a)
            }
        }
        return days
    }

    private static func clock(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func contains(_ intervals: [Interval], _ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return false }
        let now = hour * 60 + minute
        return intervals.contains { interval in
            if interval.endMinute > interval.startMinute {
                return interval.weekdays.contains(weekday) && now >= interval.startMinute && now < interval.endMinute
            }
            // Overnight, e.g. 18:00-08:00
            let yesterday = (weekday + 5) % 7 + 1
            return (interval.weekdays.contains(weekday) && now >= interval.startMinute)
                || (interval.weekdays.contains(yesterday) && now < interval.endMinute)
        }
    }

    /// Next minute-boundary change of `contains` after `date`, searching up to 7 days.
    static func nextChange(_ intervals: [Interval], after date: Date, calendar: Calendar = .current) -> Date? {
        let initial = contains(intervals, date, calendar: calendar)
        var probe = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        for _ in 0..<(7 * 24 * 4) {
            probe = probe.addingTimeInterval(15 * 60)
            if contains(intervals, probe, calendar: calendar) != initial {
                // Refine to the minute.
                var back = probe
                while contains(intervals, back.addingTimeInterval(-60), calendar: calendar) != initial { back = back.addingTimeInterval(-60) }
                return back
            }
        }
        return nil
    }

    // MARK: Conditional values

    struct Conditional: Equatable {
        var value: String
        var schedule: [Interval]
    }

    /// Parses "value @ (schedule); value2 @ (schedule2)". nil if any part is unsupported.
    static func conditionals(_ text: String) -> [Conditional]? {
        var result: [Conditional] = []
        var depth = 0
        var current = ""
        var parts: [String] = []
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == ";", depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        for part in parts {
            let pieces = part.split(separator: "@", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { return nil }
            let condition = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            guard let schedule = schedule(condition) else { return nil }
            result.append(Conditional(value: pieces[0], schedule: schedule))
        }
        return result
    }

    static func activeValue(_ conditionals: [Conditional], at date: Date, calendar: Calendar = .current) -> String? {
        conditionals.first { contains($0.schedule, date, calendar: calendar) }?.value
    }

    // MARK: Evaluation

    struct Evaluation: Equatable {
        enum Status: Equatable { case free, paid, restricted, unknown }
        var status: Status
        /// When the current status ends, if known ("free until 18:00").
        var until: Date?
        var maxStayMinutes: Int?
        /// The planned stay fits within the max stay and before any restriction starts.
        var staySupported: Bool?
    }

    /// Evaluates normalised tags (see `OSMParkingSpot`) at `arrival` for a stay of `stayMinutes`.
    static func evaluate(
        fee: String?, feeConditional: String?,
        maxstay: String?, maxstayConditional: String?,
        restriction: String?, restrictionConditional: String?,
        access: String?,
        arrival: Date, stayMinutes: Int, calendar: Calendar = .current
    ) -> Evaluation {
        if let access, ["private", "no", "permit", "customers"].contains(access) {
            return Evaluation(status: .restricted, until: nil, maxStayMinutes: nil, staySupported: false)
        }
        if let restriction, ["no_parking", "no_stopping", "no_standing", "loading_only", "charging_only"].contains(restriction) {
            return Evaluation(status: .restricted, until: nil, maxStayMinutes: nil, staySupported: false)
        }
        let leave = arrival.addingTimeInterval(TimeInterval(stayMinutes * 60))

        // Restriction windows (e.g. no parking 07:00-19:00).
        var restrictedLater = false
        if let restrictionConditional {
            guard let rules = conditionals(restrictionConditional) else {
                return Evaluation(status: .unknown, until: nil, maxStayMinutes: nil, staySupported: nil)
            }
            let blocking = rules.filter { ["no_parking", "no_stopping", "loading_only", "no_standing"].contains($0.value) }
            if blocking.contains(where: { contains($0.schedule, arrival, calendar: calendar) }) {
                let ends = blocking.compactMap { nextChange($0.schedule, after: arrival, calendar: calendar) }.min()
                return Evaluation(status: .restricted, until: ends, maxStayMinutes: nil, staySupported: false)
            }
            let starts = blocking.compactMap { nextChange($0.schedule, after: arrival, calendar: calendar) }.min()
            if let starts, starts < leave { restrictedLater = true }
        }

        // Max stay, possibly conditional.
        var maxStay = maxstay.flatMap(minutes(fromDuration:))
        if let maxstayConditional, let rules = conditionals(maxstayConditional) {
            if let active = activeValue(rules, at: arrival, calendar: calendar) { maxStay = minutes(fromDuration: active) }
        }

        // Fee, possibly conditional.
        var status: Evaluation.Status = .unknown
        var until: Date?
        switch fee?.lowercased() {
        case "yes": status = .paid
        case "no": status = .free
        default: break
        }
        if let feeConditional {
            guard let rules = conditionals(feeConditional) else {
                return Evaluation(status: .unknown, until: nil, maxStayMinutes: maxStay, staySupported: nil)
            }
            let paidRules = rules.filter { $0.value == "yes" }
            if paidRules.contains(where: { contains($0.schedule, arrival, calendar: calendar) }) {
                status = .paid
                until = paidRules.compactMap { nextChange($0.schedule, after: arrival, calendar: calendar) }.min()
            } else if !paidRules.isEmpty {
                status = .free
                until = paidRules.compactMap { nextChange($0.schedule, after: arrival, calendar: calendar) }.min()
            }
        }

        var supported: Bool? = nil
        if let maxStay { supported = stayMinutes <= maxStay }
        if restrictedLater { supported = false }
        return Evaluation(status: status, until: until, maxStayMinutes: maxStay, staySupported: supported)
    }

    // MARK: Cost

    /// Cost in pence for a stay, from tariff bands (cheapest band that covers the stay).
    static func cost(for stayMinutes: Int, tariff: [TariffBand]) -> Int? {
        tariff.filter { $0.upToMinutes >= stayMinutes }.map(\.pricePence).min()
    }

    static func cost(for stayMinutes: Int, pencePerHour: Int) -> Int {
        Int((Double(pencePerHour) * Double(stayMinutes) / 60).rounded(.up))
    }
}
