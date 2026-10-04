import Foundation

/// Minimal Supabase REST client: calls Postgres functions (`/rest/v1/rpc/...`) and Edge
/// Functions with the publishable key. No SDK dependency, and never the service role key.
struct SupabaseClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Supabase isn't set up: " + (AppConfig.supabaseProblem ?? "check Secrets.xcconfig.")
            case .http(let code, let body): "Server error \(code): \(body.prefix(200))"
            }
        }
    }

    let baseURL: URL
    let key: String
    var session: URLSession = .shared

    static var shared: SupabaseClient? {
        guard let url = AppConfig.supabaseURL, let key = AppConfig.supabasePublishableKey else { return nil }
        return SupabaseClient(baseURL: url, key: key)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
            // Postgres timestamptz without "T"
            let pg = DateFormatter()
            pg.locale = Locale(identifier: "en_US_POSIX")
            pg.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX"
            if let date = pg.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return d
    }()

    func rpc<Response: Decodable>(_ function: String, params: some Encodable) async throws -> Response {
        try await post(path: "rest/v1/rpc/\(function)", body: params)
    }

    func invoke<Response: Decodable>(function: String, body: some Encodable) async throws -> Response {
        try await post(path: "functions/v1/\(function)", body: body)
    }

    private func post<Response: Decodable>(path: String, body: some Encodable) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decoder.decode(Response.self, from: data)
    }
}
