import MapboxMaps

/// The single place the map style lives. Swap `current` for your Mapbox Studio style URL
/// (mapbox://styles/yourname/styleid) and both the home map and guidance will use it.
enum MapStyle {
    static let current: StyleURI = .streets

    /// Night variant used by guidance when the system is in dark mode.
    static let night: StyleURI = .dark
}
