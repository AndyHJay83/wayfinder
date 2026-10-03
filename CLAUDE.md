# Wayfinder

Personal iOS navigation app (driving and walking), SwiftUI, iOS 17+, TestFlight only, for one user.

## Stack
- Mapbox Navigation SDK v3 via Swift Package Manager (pinned: Navigation 3.26.0, Maps 11.26.0, Search 2.26.0; they share MapboxCommon 24.26.0 and must be bumped together)
- Mapbox Search (destination search and category search)
- SwiftData with CloudKit sync for saved places
- One free Supabase project that caches UK Fuel Finder petrol prices (stage 10) and OpenStreetMap parking (stage 13)
- The Xcode project is generated from `project.yml` with XcodeGen (`xcodegen generate`). Edit `project.yml`, not the .xcodeproj.

## Rules
- Never read, print, log or commit secrets.
- The public Mapbox token comes from Secrets.xcconfig through the Info.plist key MBXAccessToken.
- The secret download token lives only in ~/.netrc. Never touch that file.
- The Fuel Finder client ID and client secret live only in Supabase Edge Function secrets. They never go in the app, the repo, or Secrets.xcconfig. The app only holds the Supabase project URL and publishable key. Never use the Supabase service role key in the app.
- Secrets.xcconfig must stay in .gitignore. Check this before every commit (`scripts/check-secrets.sh`).
- Always check the current Mapbox documentation for exact API names before writing code. SDK versions change and names in prompts may be out of date.
- Run xcodebuild after every stage and fix all errors before moving on.
- Keep UI in small SwiftUI views so a new design can be dropped in later.
- Put colours, fonts and spacing in Wayfinder/Theme/Theme.swift.
- Keep the map style URI in the single constant `MapStyle.current` (Wayfinder/Theme/MapStyle.swift).
- Stay inside the Mapbox free tier. Use the metered trips pricing mode.
- After each stage, summarise what was built and list any manual Xcode steps I need to do.

## Layout
- `Wayfinder/App` – app entry, `AppModel` (central state), settings keys, config
- `Wayfinder/Core` – non-UI logic: Navigation (engine, guidance, faster-route checker), Trip (model + `RouteCalculator`), Search, Sketch, Fuel, Planner (pure `PlannerScoring` + `TripPlanner`), Parking (`ParkingRules` + `ParkingService`), Persistence (SwiftData models)
- `Wayfinder/Features` – SwiftUI screens, one folder per feature
- `WayfinderTests` – unit tests for the pure logic
- `supabase/` – migrations and Edge Functions (`sync-fuel`, `parking-osm`); `deno test supabase/functions/tests/`

## Build
```
xcodegen generate
xcodebuild -project Wayfinder.xcodeproj -scheme Wayfinder -destination 'platform=iOS Simulator,name=iPhone 16' build test
```
