import SwiftUI

struct LocationRequestView: View {
    @EnvironmentObject private var permission: LocationPermission

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "location.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.Colors.accent)
            Text("Wayfinder needs your location")
                .font(Theme.Fonts.title)
            Text("It's used to show you on the map, find places near you and give directions. It never leaves your phone except to ask Mapbox for routes.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                permission.requestWhenInUse()
            } label: {
                Text("Allow location").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.xl)
    }
}

struct LocationDeniedView: View {
    @EnvironmentObject private var permission: LocationPermission

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "location.slash.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.Colors.warning)
            Text("Location is turned off")
                .font(Theme.Fonts.title)
            Text("No problem. To use maps and directions, open Settings, tap Location and choose \"While Using the App\". For spoken directions with the screen locked, choose \"Always\".")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                permission.openSettings()
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.xl)
    }
}

struct MissingTokenView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "key.slash")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Colors.danger)
            Text("Mapbox token missing")
                .font(Theme.Fonts.title)
            Text("Create Secrets.xcconfig in the repo root with\nMAPBOX_ACCESS_TOKEN = pk.your_public_token\nthen rebuild. See README.md.")
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }
}
