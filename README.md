# Wayfinder

A personal iOS navigation app for driving and walking. It's built with SwiftUI and the Mapbox Navigation SDK v3, uses a small Supabase backend for UK fuel prices and OpenStreetMap parking, and ships through TestFlight.

All 13 stages from the handoff are written. The code has **not been compiled yet**: it was written in a Linux environment with no Xcode. The Supabase SQL and Edge Functions *were* tested locally (Postgres + PostGIS and Deno). Expect a short round of build fixes on your Mac, see [First build](#4-first-build).

## What you need to provide

| Item | Where it goes | Never put it in |
|---|---|---|
| Mapbox **public** token (`pk.…`) | `Secrets.xcconfig` → `MAPBOX_ACCESS_TOKEN` | — |
| Mapbox **secret** download token (`sk.…`, scope *Downloads:Read*) | `~/.netrc` on your Mac only | the repo, Xcode, Secrets.xcconfig |
| Apple Developer **Team ID** and a **bundle ID** | `Secrets.xcconfig` → `DEVELOPMENT_TEAM`, `WAYFINDER_BUNDLE_ID` | — |
| Supabase project URL and **publishable** key | `Secrets.xcconfig` → `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | — |
| Fuel Finder **client ID** and **client secret** | Supabase Edge Function secrets only | the app, the repo, Secrets.xcconfig |
| A random `SYNC_FUEL_SECRET` (e.g. `openssl rand -hex 32`) | Supabase Edge Function secret **and** Supabase Vault | the repo |

The Supabase *service role* key is never used by the app.

## 1. Mapbox (about 10 minutes)

1. Create a free account at mapbox.com. A card is required, but you aren't charged inside the free tier. **Set a usage alert** in the account billing page.
2. Copy your **default public token** (`pk.`).
3. Create a token called `ios-sdk-download` with only the **Downloads:Read** scope. Copy the `sk.` token (it is shown once). Then:
   ```sh
   cat >> ~/.netrc <<'EOF'
   machine api.mapbox.com
   login mapbox
   password sk.YOUR_SECRET_TOKEN
   EOF
   chmod 600 ~/.netrc
   ```

## 2. Project setup on your Mac

You need **Xcode 26 or newer**: the Mapbox SDK binaries are built with Swift 6.2 and won't load in Xcode 16.

1. In Xcode's start window choose **Clone Git Repository…** and paste `https://github.com/AndyHJay83/wayfinder`. Xcode opens `Wayfinder.xcodeproj`.
2. In Finder, duplicate `Config/Secrets.example.xcconfig`, move the copy to the repo root and rename it `Secrets.xcconfig`. It then appears in Xcode's sidebar; fill in your values there.
3. (Optional) `ln -s ../../scripts/check-secrets.sh .git/hooks/pre-commit` adds the secrets check as a pre-commit hook.

`Wayfinder.xcodeproj` is generated from `project.yml` by CI and committed automatically. New Swift files added under `Wayfinder/` are picked up on the next CI run; if you'd rather regenerate locally, `brew install xcodegen && xcodegen generate`.

## 3. Manual Xcode steps

The project file already declares the Info.plist keys, background modes and entitlements. In Xcode you only need to confirm them for your team:

1. **Signing & Capabilities** for the Wayfinder target: tick *Automatically manage signing* and pick your team.
2. **Background Modes** should show *Location updates*, *Audio, AirPlay, and Picture in Picture* and *Remote notifications*. These are needed for spoken guidance with the screen locked and for CloudKit sync.
3. **iCloud**: tick *CloudKit*, then click **+** under Containers and create `iCloud.<your bundle ID>`. It must match exactly, because the entitlements use `iCloud.$(WAYFINDER_BUNDLE_ID)`.
4. **Push Notifications** should be present (`aps-environment`). CloudKit uses silent pushes to sync.
5. First SPM resolve: Xcode downloads the Mapbox packages using `~/.netrc`. If it fails with 401/403, check the `sk.` token's scope.

### CloudKit model rules (already followed in `Core/Persistence/Models.swift`)
- Every stored property has a default value or is optional.
- No `@Attribute(.unique)`.
- Every relationship is optional and has an inverse (`SavedPlace.collections` ↔ `PlaceCollection.places`).
- If iCloud isn't set up yet, the app falls back to a local-only store so it still runs.
- After the first run on a device, open the CloudKit Console and **deploy the schema to Production** before you ship a TestFlight build. TestFlight uses the production CloudKit environment.

## 4. First build

```sh
xcodebuild -project Wayfinder.xcodeproj -scheme Wayfinder \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

Every SDK call was checked against the Mapbox source code for the pinned versions, but nothing has been through the Swift compiler. The quickest fix loop is to open the folder in Claude Code on your Mac and ask it to "run xcodebuild and fix all errors".

## 5. Supabase (stages 10 and 13)

1. Create a free Supabase project named `wayfinder` (London region is closest). Note the **project URL** and **publishable key** and put them in `Secrets.xcconfig`. The URL must be written as `https:/$()/REF.supabase.co`, because `//` starts a comment in xcconfig files. The app also accepts a bare host.
2. Register for Fuel Finder API access at https://www.developer.fuel-finder.service.gov.uk (guidance: https://www.gov.uk/guidance/access-fuel-price-data). Read the terms. You will get a client ID and a client secret.
3. Install the CLI and deploy:
   ```sh
   brew install supabase/tap/supabase
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push                       # PostGIS, tables, RLS, SQL functions, cron schedule
   supabase secrets set FUEL_FINDER_CLIENT_ID=… FUEL_FINDER_CLIENT_SECRET=… SYNC_FUEL_SECRET=…
   supabase functions deploy sync-fuel --no-verify-jwt
   supabase functions deploy parking-osm --no-verify-jwt
   ```
4. In the Supabase SQL editor, store the two values the cron job needs (they stay out of the repo):
   ```sql
   select vault.create_secret('https://YOUR_PROJECT_REF.supabase.co', 'project_url');
   select vault.create_secret('SAME_VALUE_AS_SYNC_FUEL_SECRET', 'sync_fuel_secret');
   ```
5. Run the first sync now rather than waiting until 06:00: `select public.invoke_sync_fuel();`. Check the result in *Edge Functions → sync-fuel → Logs*, or with `select count(*) from stations;` (expect around 7,500 stations).
6. Optional: `supabase secrets set APP_PUBLISHABLE_KEY=<publishable key>` makes `parking-osm` reject calls that don't carry your key.

The sync runs at 06:00 and 18:00 **UTC**. That is 07:00/19:00 UK time in summer and 06:00/18:00 in winter. I left it on UTC rather than shifting it when the clocks change. Edit `supabase/migrations/20261003000002_fuel_schedule.sql` if you want different times.

## 6. TestFlight

Product → Archive → Distribute App → App Store Connect → Upload. Then in App Store Connect → TestFlight, add yourself as an internal tester. Builds expire after 90 days.

## What's where (by stage)

| Stage | Main files |
|---|---|
| 1 Dependencies, permissions | `project.yml`, `Config/` |
| 2 Map + location | `Features/Home/HomeView.swift`, `MapController.swift`, `Core/Location/`, `Theme/MapStyle.swift` |
| 3 Driving navigation | `Features/Home/SearchView.swift`, `Core/Navigation/GuidancePresenter.swift` |
| 4 Preferences, walking, preview | `Features/Settings/`, `Core/Trip/RouteCalculator.swift`, `Features/Preview/` |
| 5 Category search | `Core/Search/PlaceCategory.swift` (the editable array), `PlaceSearchService.swift` (MapKit fallback for car parks) |
| 6 Saved places + CloudKit | `Core/Persistence/Models.swift`, `Features/Saved/` |
| 7 Trip builder | `Core/Trip/Trip.swift`, `Features/Trip/TripBuilderView.swift` |
| 8 Drag + sketch | `MapController.swift` (hold and drag), `Core/Sketch/SketchRouter.swift`, `Features/Sketch/` |
| 9 Faster-route checker | `Core/Navigation/FasterRouteChecker.swift`, `Features/Guidance/` |
| 10 Fuel cache | `supabase/`, `Core/Fuel/FuelService.swift`, `Features/Fuel/` |
| 11 Planner | `Core/Planner/PlannerScoring.swift` (pure), `TripPlanner.swift`, `MatrixService.swift`, tests in `WayfinderTests/` |
| 12 Armed chips, local prices | `AppModel` (arming), `Features/Home/CategoryChipsView.swift`, `Features/Fuel/LocalPlacesSheet.swift` |
| 13 Parking + chains | `Core/Parking/`, `Features/Parking/`, `supabase/functions/parking-osm` |

## Design notes and known limits

- **Stage 9 uses the prebuilt `NavigationViewController`.** The SDK documents that you can swap routes mid-journey with `tripSession().startActiveGuidance(with:startLegIndex:)`, and the view controller updates itself. No custom guidance screen was needed. The SDK's own automatic faster-route switching is turned off so that the anti-nag rules decide. In debug builds, Mapbox request counts per hour are logged and shown in Settings.
- **Car parks:** Mapbox POI coverage for UK car parks is patchy, so that one category also queries MapKit's `MKLocalSearch` and merges the results.
- **Sketch:** zoomed out (16 px > 500 m) snaps to named places by reverse geocoding. Zoomed in, it snaps to roads with Directions `radiuses`. "Follow my line closely" is only offered when 16 px ≤ 50 m (the Map Matching limit). If Map Matching fails, it falls back to via points automatically and tells you.
- **Drag the route:** while you drag, a straight "rubber band" preview is drawn. The real road route is calculated once you let go, which avoids a Directions request on every finger movement.
- **Planner:** uses the Matrix API with the `driving` profile (25 coordinates per request, batched and cached). Live traffic is applied when the chosen order is routed.
- **Parking:** an option is never shown as definitely free or legal. Every option carries a trust badge, and the list always ends with "Check the signs when you arrive."
- Everything in the handoff's *Known limits* list still applies (no speed cameras, no live car park occupancy, stale prices possible, and so on).
