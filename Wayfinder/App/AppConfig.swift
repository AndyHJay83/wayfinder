import Foundation

/// Reads non-secret configuration that was injected into Info.plist from Secrets.xcconfig.
/// Never log the values returned here.
enum AppConfig {
    /// Public Mapbox token (pk.). The SDKs read `MBXAccessToken` themselves; this is used
    /// for the few REST calls we make directly (Matrix, Map Matching fallbacks).
    static var mapboxAccessToken: String? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              token.hasPrefix("pk.") else { return nil }
        return token
    }

    static var isMapboxConfigured: Bool { mapboxAccessToken != nil }

    /// Supabase project URL. Accepts either a full URL or a bare host, because `//` in an
    /// xcconfig file starts a comment and can truncate the value.
    static var supabaseURL: URL? {
        guard var raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "https:" else { return nil }
        if !raw.contains("://") {
            raw = raw.hasPrefix("https:/") ? raw.replacingOccurrences(of: "https:/", with: "https://") : "https://\(raw)"
        }
        guard let url = URL(string: raw), url.host?.contains(".") == true else { return nil }
        return url
    }

    /// Supabase publishable (anon) key. Never the service role key.
    static var supabasePublishableKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              !key.isEmpty else { return nil }
        return key
    }

    static var isSupabaseConfigured: Bool { supabaseURL != nil && supabasePublishableKey != nil }

    /// Plain-English reason Supabase isn't usable, or nil when it is. Never includes key values.
    static var supabaseProblem: String? {
        let rawURL = (Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawURL.isEmpty {
            return "SUPABASE_URL is empty. In Secrets.xcconfig add: SUPABASE_URL = YOUR_REF.supabase.co"
        }
        if rawURL == "https:" || rawURL == "http:" {
            return "SUPABASE_URL was cut off after \"https:\" because // starts a comment in .xcconfig files. Write it without https:// (SUPABASE_URL = YOUR_REF.supabase.co), then rebuild."
        }
        if supabaseURL == nil {
            return "SUPABASE_URL doesn't look like a web address. Use the form YOUR_REF.supabase.co"
        }
        if supabasePublishableKey == nil {
            return "SUPABASE_PUBLISHABLE_KEY is empty. Copy the publishable key from Supabase → Project Settings → API Keys into Secrets.xcconfig, then rebuild."
        }
        return nil
    }
}
