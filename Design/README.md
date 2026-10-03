# Design

Drop exported screens from Claude Design here (PNG or PDF): home map, route preview, saved places, settings.

Then ask Claude Code:

> Look at the images in /Design. Restyle the existing SwiftUI views to match them exactly: colours, fonts, spacing, corner radii and icons. Put all colours, fonts and spacing into Wayfinder/Theme/Theme.swift. Do not change any logic. Build and fix errors.

The map skin is separate: make a style in Mapbox Studio, then set `MapStyle.current` in `Wayfinder/Theme/MapStyle.swift`. Guidance picks it up through `WayfinderDayStyle`.
