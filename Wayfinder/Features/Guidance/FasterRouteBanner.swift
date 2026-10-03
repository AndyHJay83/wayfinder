import SwiftUI

/// Glanceable banner shown over guidance: "Via A31, saves 2 min, 2 changes" [Ignore] [Accept].
struct FasterRouteBannerContainer: View {
    @ObservedObject var model: FasterRouteBannerModel

    var body: some View {
        VStack {
            if let suggestion = model.suggestion {
                FasterRouteBanner(
                    suggestion: suggestion,
                    onAccept: { model.onAccept?() },
                    onIgnore: { model.onIgnore?() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let destination = model.parkingPrompt {
                HStack {
                    Image(systemName: "parkingsign.circle.fill").font(.title2).foregroundStyle(Theme.Colors.accent)
                    Text("Nearly at \(destination). Park nearby?").font(Theme.Fonts.headline)
                    Spacer(minLength: 0)
                    Button("Not now") { model.parkingPrompt = nil }.buttonStyle(.bordered)
                    Button("Show") { model.onParkNearby?() }.buttonStyle(.borderedProminent)
                }
                .cardStyle()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.suggestion)
        .animation(.spring(duration: 0.3), value: model.parkingPrompt)
    }
}

struct FasterRouteBanner: View {
    let suggestion: FasterRouteSuggestion
    let onAccept: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "bolt.car.fill")
                .font(.title2)
                .foregroundStyle(Theme.Colors.positive)
            Text(suggestion.text)
                .font(Theme.Fonts.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if !suggestion.wasAutoAccepted {
                Button("Ignore", action: onIgnore)
                    .buttonStyle(.bordered)
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.positive)
            }
        }
        .cardStyle()
    }
}
