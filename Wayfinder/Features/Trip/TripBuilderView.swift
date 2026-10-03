import MapboxDirections
import SwiftData
import SwiftUI

/// Ordered stops and via points with drag-to-reorder, Stop/Via toggle, swipe to delete and
/// per-leg ETA. The route redraws after every change (AppModel debounces).
struct TripBuilderView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var permission: LocationPermission
    @Query(sort: \SavedPlace.name) private var saved: [SavedPlace]
    @State private var showingSavedPicker = false

    var body: some View {
        NavigationStack {
            List {
                if app.trip.isEmpty {
                    Text("Add stops from search, saved places or by pressing and holding the map.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Section {
                    ForEach(app.trip.items) { item in
                        TripItemRow(item: item, leg: leg(for: item)) {
                            app.trip.toggleKind(id: item.id)
                        }
                    }
                    .onMove { app.trip.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        offsets.map { app.trip.items[$0].id }.forEach { app.trip.remove(id: $0) }
                    }
                } header: {
                    Text("From your location")
                } footer: {
                    totals
                }

                if let outcome = app.plannerOutcome {
                    Section("Planner") {
                        Button {
                            app.sheet = .plannerResult
                        } label: {
                            Label(outcome.headline, systemImage: "sparkles")
                        }
                    }
                }

                Section {
                    Button { app.searchAddsToTrip = true; app.sheet = .search } label: { Label("Add from search", systemImage: "magnifyingglass") }
                    Button { showingSavedPicker = true } label: { Label("Add saved place", systemImage: "star") }
                    Menu {
                        ForEach(PlaceCategory.all) { category in
                            Button(category.displayName) {
                                app.trip.append(TripItem(kind: .category(category.id), name: category.displayName, coordinate: nil))
                            }
                        }
                    } label: {
                        Label("Add flexible stop", systemImage: "sparkle.magnifyingglass")
                    }
                    if app.trip.items.contains(where: { $0.categoryID != nil }) {
                        Button { Task { await app.runPlanner() } } label: {
                            Label("Plan best order", systemImage: "wand.and.stars")
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { app.sheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        permission.requestAlwaysIfNeeded()
                        app.startGuidance()
                    }
                    .disabled(app.previewRoutes == nil || app.isCalculating)
                }
                ToolbarItem(placement: .bottomBar) {
                    if app.isCalculating { ProgressView() }
                    else if let error = app.routeError { Text(error).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning) }
                }
            }
            .sheet(isPresented: $showingSavedPicker) {
                NavigationStack {
                    List(saved) { place in
                        Button(place.name) {
                            app.addToTrip(place.asPlace)
                            showingSavedPicker = false
                        }
                    }
                    .navigationTitle("Saved places")
                }
                .presentationDetents([.medium])
            }
        }
    }

    /// Legs end at stops (vias are silent), so each stop maps to the next leg summary.
    private func leg(for item: TripItem) -> LegSummary? {
        guard item.kind != .via, let legs = app.previewRoutes?.mainRoute.route.legSummaries else { return nil }
        let stops = app.trip.routableItems.enumerated().filter { offset, it in
            it.kind != .via || offset == app.trip.routableItems.count - 1
        }.map(\.element)
        guard let index = stops.firstIndex(where: { $0.id == item.id }), index < legs.count else { return nil }
        return legs[index]
    }

    @ViewBuilder
    private var totals: some View {
        if let route = app.previewRoutes?.mainRoute.route {
            HStack {
                Text("Total \(Formatters.duration(route.expectedTravelTime)) · \(Formatters.distance(route.distance))")
                Spacer()
                Text("Arrive \(Formatters.arrival(after: route.expectedTravelTime))")
            }
            .font(Theme.Fonts.caption.weight(.semibold))
        }
    }
}

struct TripItemRow: View {
    let item: TripItem
    let leg: LegSummary?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Theme.Fonts.body).lineLimit(1)
                if let leg {
                    Text("\(Formatters.duration(leg.expectedTravelTime)) · \(Formatters.distance(leg.distance)) · arrive \(Formatters.arrival(after: leg.expectedTravelTime))")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                } else if item.categoryID != nil, item.coordinate == nil {
                    Text("Flexible: the planner will pick one").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                } else if item.kind == .via {
                    Text("Silent via point").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            if item.categoryID == nil {
                Button(action: onToggle) {
                    Text(item.kind == .via ? "Via" : "Stop")
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .frame(width: 44)
                }
                .buttonStyle(.bordered)
                .tint(item.kind == .via ? .purple : .red)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .stop: Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
        case .via: Image(systemName: "smallcircle.filled.circle").foregroundStyle(.purple)
        case .category(let id): Image(systemName: PlaceCategory.with(id: id)?.iconName ?? "sparkle").foregroundStyle(.orange)
        }
    }
}
