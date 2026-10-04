import MapboxDirections
import MapboxNavigationCore
import SwiftUI

/// One route option: duration, distance, arrival, traffic and main road.
struct RouteSummaryCard: View {
    let route: Route
    let isSelected: Bool
    let label: String
    var delta: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(Formatters.duration(route.expectedTravelTime)).font(Theme.Fonts.eta)
                Text("· \(Formatters.distance(route.distance))").foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text("Arrive \(Formatters.arrival(after: route.expectedTravelTime))").font(Theme.Fonts.caption)
            }
            HStack {
                Text(label).font(Theme.Fonts.caption.weight(.semibold))
                if let delta {
                    Text(delta >= 0 ? "+\(Formatters.duration(delta))" : "−\(Formatters.duration(-delta))")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(delta > 0 ? Theme.Colors.warning : Theme.Colors.positive)
                }
                Spacer()
                trafficText
            }
            if let road = mainRoad {
                Text("Via \(road)").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.surface)
        )
    }

    /// Traffic-aware duration vs a typical day.
    @ViewBuilder
    private var trafficText: some View {
        if let typical = route.typicalTravelTime, typical > 0 {
            let extra = route.expectedTravelTime - typical
            if extra > 120 {
                Text("\(Formatters.duration(extra)) traffic delay").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
            } else {
                Text("Traffic normal").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.positive)
            }
        }
    }

    private var mainRoad: String? {
        route.legs.flatMap(\.steps).max { $0.distance < $1.distance }?.names?.first
    }
}
