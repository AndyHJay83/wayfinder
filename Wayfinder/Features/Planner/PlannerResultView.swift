import CoreLocation
import SwiftUI

/// The winning plan with a plain breakdown, plus two alternatives to swap in. For long trips
/// the petrol stop can be slid along the route to see other stations and prices.
struct PlannerResultView: View {
    @EnvironmentObject private var app: AppModel

    @State private var corridor: [FuelStation] = []
    @State private var milesIn: Double = 0
    @State private var routeMiles: Double = 0

    var body: some View {
        NavigationStack {
            List {
                if let outcome = app.plannerOutcome {
                    ForEach(outcome.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(Theme.Fonts.caption)
                    }
                    ForEach(Array(outcome.options.enumerated()), id: \.element.id) { index, option in
                        Section(index == 0 ? "Best plan" : "Alternative \(index)") {
                            ForEach(option.lines, id: \.self) { Text($0).font(index == 0 ? Theme.Fonts.body : Theme.Fonts.caption) }
                            if index != outcome.selectedIndex {
                                Button("Use this plan") { app.applyPlannerAlternative(option) }
                            } else {
                                Label("In your trip", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Colors.positive)
                            }
                        }
                    }
                    if !corridor.isEmpty {
                        Section("Slide the petrol stop along the route") {
                            Slider(value: $milesIn, in: 0...max(1, routeMiles), step: 1)
                            Text("\(Int(milesIn)) miles in").font(Theme.Fonts.caption)
                            ForEach(stationsNearSlider) { station in
                                Button {
                                    swapPetrol(to: station)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(station.displayName)
                                            PriceLabel(station: station)
                                        }
                                        Spacer()
                                        Text("\(Int(((station.distanceAlongMetres ?? 0) / 1609.344).rounded())) mi")
                                            .font(Theme.Fonts.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text("Run the planner from the trip screen.")
                }
            }
            .navigationTitle("Planner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { app.sheet = .tripBuilder } }
            }
            .task { await loadCorridor() }
        }
    }

    private var stationsNearSlider: [FuelStation] {
        corridor.filter { abs(($0.distanceAlongMetres ?? 0) / 1609.344 - milesIn) <= 5 }
            .sorted { ($0.pricePence ?? 999) < ($1.pricePence ?? 999) }
            .prefix(6).map { $0 }
    }

    private var petrolItem: TripItem? {
        app.trip.items.first { $0.categoryID == PlaceCategory.petrol.id }
    }

    private func loadCorridor() async {
        guard petrolItem != nil, let shape = app.previewRoutes?.mainRoute.route.shape?.coordinates else { return }
        routeMiles = GeoMath.length(of: shape) / 1609.344
        guard PlannerScoring.isLongTrip(tripMiles: routeMiles, settings: .current) else { return }
        corridor = (try? await FuelService.shared.stationsAlong(route: shape)) ?? []
        if let c = petrolItem?.coordinate, let p = GeoMath.project(c, onto: shape) {
            milesIn = p.distanceAlong / 1609.344
        }
    }

    private func swapPetrol(to station: FuelStation) {
        guard var item = petrolItem else { return }
        let miles = Int(((station.distanceAlongMetres ?? 0) / 1609.344).rounded())
        item.name = "Petrol, \(station.displayName), \(miles) miles in"
        item.coordinate = station.coordinate
        app.trip.update(item)
    }
}
