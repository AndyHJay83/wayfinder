import Foundation

/// A plan returned by the `plan-trip` Edge Function (Claude, structured output).
/// Empty strings and -1 mean "not given".
struct NaturalTripPlan: Decodable, Equatable {
    struct Destination: Decodable, Equatable {
        let savedPlace: String
        let query: String
        enum CodingKeys: String, CodingKey { case savedPlace = "saved_place", query }
    }

    struct Stop: Decodable, Equatable {
        let category: String
        let query: String
        let dietary: [String]
        let stayMinutes: Int
        let needsFreeParking: Bool
        enum CodingKeys: String, CodingKey {
            case category, query, dietary
            case stayMinutes = "stay_minutes"
            case needsFreeParking = "needs_free_parking"
        }
    }

    struct Parking: Decodable, Equatable {
        let needed: Bool
        let stayMinutes: Int
        let freePreferred: Bool
        enum CodingKeys: String, CodingKey {
            case needed
            case stayMinutes = "stay_minutes"
            case freePreferred = "free_preferred"
        }
    }

    let question: String
    let summary: String
    let destination: Destination
    let stops: [Stop]
    let parking: Parking

    /// Flexible trip items for the stops (and parking), in the order asked for. The
    /// planner picks the actual places along the route.
    var flexibleItems: [TripItem] {
        var items: [TripItem] = stops.compactMap { stop in
            guard let category = PlaceCategory.with(id: stop.category) else { return nil }
            let query = stop.query.trimmingCharacters(in: .whitespaces)
            if category.id == PlaceCategory.search.id, query.isEmpty { return nil }
            let diets = stop.dietary.filter { DietaryFilter(rawValue: $0) != nil }
            let label = category.id == PlaceCategory.search.id ? query.capitalized
                : ([category.displayName] + diets.compactMap { DietaryFilter(rawValue: $0)?.label.lowercased() }).joined(separator: ", ")
            return TripItem(
                kind: .category(category.id), name: label, coordinate: nil,
                query: category.id == PlaceCategory.search.id ? query : nil,
                dietary: diets,
                stayMinutes: stop.stayMinutes > 0 ? stop.stayMinutes : nil,
                freeParkingPreferred: stop.needsFreeParking
            )
        }
        if parking.needed {
            let stay = parking.stayMinutes > 0 ? parking.stayMinutes : nil
            items.append(TripItem(
                kind: .category(PlaceCategory.carPark.id),
                name: parking.freePreferred ? "Free parking" : "Parking",
                coordinate: nil, stayMinutes: stay, freeParkingPreferred: parking.freePreferred
            ))
        }
        return items
    }
}

/// Calls `plan-trip`. The Anthropic API key lives only in Supabase secrets.
enum NaturalLanguagePlanner {
    struct Turn: Codable, Equatable {
        let role: String     // "user" | "assistant"
        let content: String
    }

    private struct Request: Encodable {
        let text: String
        let history: [Turn]
        let saved_places: [String]
        let current_destination: String
    }

    enum PlanError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self { case .server(let message): message }
        }
    }

    static func plan(text: String, history: [Turn], savedPlaces: [String], currentDestination: String?) async throws -> NaturalTripPlan {
        guard let client = SupabaseClient.shared else { throw SupabaseClient.ClientError.notConfigured }
        do {
            return try await client.invoke(
                function: "plan-trip",
                body: Request(text: text, history: history, saved_places: savedPlaces, current_destination: currentDestination ?? "")
            )
        } catch SupabaseClient.ClientError.http(let status, let body) {
            // The function returns { "error": "..." } with a readable message.
            struct Message: Decodable { let error: String }
            if let message = try? JSONDecoder().decode(Message.self, from: Data(body.utf8)) { throw PlanError.server(message.error) }
            if status == 404 { throw PlanError.server("The plan-trip function isn't deployed yet. Merge to main so Supabase deploys it.") }
            throw SupabaseClient.ClientError.http(status, body)
        }
    }
}
