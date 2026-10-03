import SwiftData
import SwiftUI

/// Stage 13: parking options near a destination, with a one-glance summary and filters.
struct ParkNearbySheet: View {
    let destination: Place
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.plannedStayMinutes) private var stayMinutes: Double = 60
    @AppStorage(SettingsKeys.maxWalkMetres) private var maxWalk: Double = 400

    enum Filter: String, CaseIterable, Identifiable { case all = "All", free = "Free only", paid = "Paid"; var id: String { rawValue } }

    @State private var options: [ParkingOption] = []
    @State private var notes: [String] = []
    @State private var filter: Filter = .all
    @State private var radius: Double?
    @State private var loading = true
    @State private var showNoLuck = false

    private var filtered: [ParkingOption] {
        switch filter {
        case .all: options
        case .free: options.filter(\.kind.isFree)
        case .paid: options.filter(\.kind.isPaid)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let summary = ParkingService.shared.summary(for: options, stayMinutes: Int(stayMinutes))
                if !summary.isEmpty {
                    Section {
                        ForEach(summary) { line in
                            Button(line.text) { choose(line.option) }
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Stay \(Formatters.duration(stayMinutes * 60))", value: $stayMinutes, in: 15...600, step: 15)
                }
                Section {
                    ForEach(filtered) { option in
                        ParkingOptionRow(option: option).contentShape(Rectangle()).onTapGesture { choose(option) }
                            .swipeActions {
                                Button("Not valid", role: .destructive) {
                                    ParkingService.shared.markNotValid(option)
                                    options.removeAll { $0.id == option.id }
                                }
                            }
                    }
                    if !loading && filtered.isEmpty {
                        Text("No parking found within \(Formatters.distance(radius ?? maxWalk)).").foregroundStyle(Theme.Colors.textSecondary)
                    }
                } footer: {
                    Text("Check the signs when you arrive.").font(Theme.Fonts.caption.weight(.semibold))
                }
                ForEach(notes, id: \.self) { Text($0).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary) }
                Section {
                    Button("No luck? More options") { showNoLuck = true }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Park near \(destination.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
            .task(id: "\(stayMinutes)-\(radius ?? 0)") { await load() }
            .sheet(isPresented: $showNoLuck) {
                NoLuckPanel(destination: destination, options: options) { action in
                    showNoLuck = false
                    switch action {
                    case .widen(let metres): radius = metres
                    case .choose(let option): choose(option)
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func load() async {
        loading = true
        let result = await ParkingService.shared.options(near: destination.coordinate, radius: radius)
        options = result.options
        notes = result.notes
        loading = false
    }

    private func choose(_ option: ParkingOption) {
        let guiding = app.engine.isGuiding
        app.driveToParking(option, destination: destination)
        if guiding { dismiss() }
    }

    private func close() {
        if app.engine.isGuiding { dismiss() } else { app.sheet = .routePreview }
    }
}

struct ParkingOptionRow: View {
    let option: ParkingOption

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(option.isAtDestination ? "At destination" : option.title).font(Theme.Fonts.body.weight(.semibold))
                Spacer()
                Text(option.costText).font(Theme.Fonts.price)
            }
            HStack(spacing: 8) {
                Label("\(Int(option.walkMinutes.rounded())) min · \(Formatters.distance(option.walkDistance))", systemImage: "figure.walk")
                if let max = option.maxStayMinutes { Text("max \(Formatters.duration(Double(max) * 60))") }
                if let validity = option.validityText {
                    Text(validity).foregroundStyle(option.validNow == false ? Theme.Colors.danger : Theme.Colors.positive)
                }
            }
            .font(Theme.Fonts.caption)
            HStack(spacing: 8) {
                ConfidenceBadge(confidence: option.confidence)
                if option.staySupported == false {
                    Text("Your stay is longer than allowed").font(.caption2).foregroundStyle(Theme.Colors.warning)
                }
                if let tariff = option.tariffText, !tariff.isEmpty {
                    Text(tariff).font(.caption2).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                }
            }
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: ParkingOption.Confidence
    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
    }
    private var colour: Color {
        switch confidence {
        case .verifiedByMe: Theme.Colors.positive
        case .fromMapData: Theme.Colors.accent
        case .unverified: Theme.Colors.warning
        }
    }
}

/// Shown when street parking didn't work out.
struct NoLuckPanel: View {
    enum Action { case widen(Double), choose(ParkingOption) }

    let destination: Place
    let options: [ParkingOption]
    let onAction: (Action) -> Void
    @EnvironmentObject private var app: AppModel
    @AppStorage(SettingsKeys.plannedStayMinutes) private var stayMinutes: Double = 60
    @State private var savingSpot = false
    @State private var spotFree = true
    @State private var spotNote = ""
    @State private var spotMaxStay = 0.0

    private var paid: [ParkingOption] { options.filter { !$0.kind.isFree && !$0.kind.isStreet } }

    var body: some View {
        NavigationStack {
            List {
                Section("More street parking") {
                    ForEach(ParkingService.widenSteps, id: \.self) { metres in
                        Button {
                            onAction(.widen(metres))
                        } label: {
                            Text("Within \(Int(metres)) m (about \(Int((metres * 1.3 / 80).rounded())) min walk)")
                        }
                    }
                }
                Section("Paid parking") {
                    if let own = paid.first(where: \.isAtDestination) {
                        Button("Destination car park · \(own.costText)") { onAction(.choose(own)) }
                    }
                    if let nearest = paid.min(by: { $0.walkDistance < $1.walkDistance }) {
                        Button("Nearest: \(nearest.title) · \(Int(nearest.walkMinutes.rounded())) min walk") { onAction(.choose(nearest)) }
                    }
                    if let cheapest = paid.filter({ $0.stayCostPence != nil }).min(by: { $0.stayCostPence! < $1.stayCostPence! }) {
                        Button("Cheapest for your stay: \(cheapest.title) · \(cheapest.costText)") { onAction(.choose(cheapest)) }
                    }
                    if let best = bestValue {
                        Button("Best value: \(best.title)") { onAction(.choose(best)) }
                    }
                    if paid.isEmpty { Text("No paid car parks found nearby.").foregroundStyle(Theme.Colors.textSecondary) }
                }
                Section {
                    Button("I parked here") { savingSpot = true }
                } footer: {
                    Text("Saved spots show as \"Verified by me\" next time.")
                }
            }
            .navigationTitle("No luck?")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Save this spot", isPresented: $savingSpot) {
                TextField("Time limit note (e.g. max 2h)", text: $spotNote)
                Button("Free") { save(free: true) }
                Button("Paid") { save(free: false) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Stage 11 scoring: walking minutes weighted, plus the fee for the planned stay.
    private var bestValue: ParkingOption? {
        let settings = PlannerSettings.current
        return paid.filter { $0.stayCostPence != nil }.min { a, b in
            cost(a, settings) < cost(b, settings)
        }
    }

    private func cost(_ o: ParkingOption, _ s: PlannerSettings) -> Double {
        PlannerScoring.journeyCost(driveMinutes: 0, walkMinutes: o.walkMinutes * 2, parkingFeePounds: Double(o.stayCostPence ?? 0) / 100, settings: s)
    }

    private func save(free: Bool) {
        guard let here = app.currentLocation?.coordinate else { return }
        let maxStay = ParkingRules.minutes(fromDuration: spotNote.replacingOccurrences(of: "max", with: "")) ?? 0
        ParkingService.shared.saveMySpot(at: here, isFree: free, note: spotNote, maxStayMinutes: maxStay)
        app.statusMessage = "Parking spot saved"
    }
}
