import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Stage 4
    @AppStorage(SettingsKeys.avoidMotorways) private var avoidMotorways = false
    @AppStorage(SettingsKeys.avoidTolls) private var avoidTolls = false
    @AppStorage(SettingsKeys.avoidFerries) private var avoidFerries = false
    @AppStorage(SettingsKeys.travelMode) private var travelMode: TravelMode = .driving
    // Stage 9
    @AppStorage(SettingsKeys.fasterRouteThresholdSeconds) private var fasterThreshold = 60.0
    @AppStorage(SettingsKeys.fasterRouteAutoAccept) private var autoAccept = false
    @AppStorage(SettingsKeys.fasterRouteAutoAcceptSeconds) private var autoAcceptSeconds = 180.0
    // Stage 10
    @AppStorage(SettingsKeys.fuelType) private var fuelType: FuelType = .e10
    // Stage 11
    @AppStorage(SettingsKeys.litresPerFill) private var litres = 25.0
    @AppStorage(SettingsKeys.valueOfTimePerHour) private var valueOfTime = 12.0
    @AppStorage(SettingsKeys.mpg) private var mpg = 40.0
    @AppStorage(SettingsKeys.favouriteBonusPence) private var favouriteBonus = 2.0
    @AppStorage(SettingsKeys.maxAbovePenceCheapest) private var maxAbove = 5.0
    @AppStorage(SettingsKeys.tankRangeMiles) private var tankRange = 350.0
    @AppStorage(SettingsKeys.fuelLevelPercent) private var fuelLevel = -1.0
    // Stage 13
    @AppStorage(SettingsKeys.plannedStayMinutes) private var stay = 60.0
    @AppStorage(SettingsKeys.maxWalkMetres) private var maxWalk = 400.0
    @AppStorage(SettingsKeys.parkingPriority) private var parkingPriority: ParkingPriority = .freeFirst
    @AppStorage(SettingsKeys.walkingWeight) private var walkingWeight = 2.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Picker("Travel by", selection: $travelMode) {
                        ForEach(TravelMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Avoid motorways", isOn: $avoidMotorways)
                    Toggle("Avoid tolls", isOn: $avoidTolls)
                    Toggle("Avoid ferries", isOn: $avoidFerries)
                    if travelMode == .walking {
                        Text("Walking routes have no live traffic, and avoid options apply to driving only.")
                            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                }

                Section {
                    Stepper("Suggest if it saves \(Int(fasterThreshold)) s", value: $fasterThreshold, in: 30...600, step: 15)
                    Toggle("Auto-accept big savings", isOn: $autoAccept)
                    if autoAccept {
                        Stepper("Auto-accept above \(Formatters.duration(autoAcceptSeconds))", value: $autoAcceptSeconds, in: 60...1200, step: 30)
                    }
                } header: {
                    Text("Faster route during guidance")
                } footer: {
                    Text("Checks every 45 seconds. A saving must show up twice in a row, never within 300 m of a turn, and at most once every 3 minutes.")
                }

                Section("Fuel") {
                    Picker("Fuel type", selection: $fuelType) {
                        ForEach(FuelType.allCases) { Text($0.label).tag($0) }
                    }
                    NavigationLink("Favourite stations") { FavouriteStationsView() }
                }

                Section {
                    numberRow("Litres per fill", value: $litres, unit: "l", range: 5...100, step: 1)
                    numberRow("Value of my time", value: $valueOfTime, unit: "£/h", range: 0...100, step: 1)
                    numberRow("Car consumption", value: $mpg, unit: "mpg", range: 10...100, step: 1)
                    numberRow("Favourite station bonus", value: $favouriteBonus, unit: "p/l", range: 0...20, step: 0.5)
                    numberRow("Max above cheapest nearby", value: $maxAbove, unit: "p/l", range: 0...30, step: 0.5)
                    numberRow("Range on a full tank", value: $tankRange, unit: "mi", range: 50...1000, step: 10)
                    Picker("Fuel level now", selection: $fuelLevel) {
                        Text("Unknown").tag(-1.0)
                        ForEach([10.0, 25, 50, 75, 100], id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                    NavigationLink("Preferred car parks") { PreferredCarParksView() }
                } header: {
                    Text("Trip planner")
                } footer: {
                    Text("The app can't read your fuel gauge. Adding Petrol to a trip means you want a fill-up on the way.")
                }

                Section("Parking") {
                    Stepper("Planned stay \(Formatters.duration(stay * 60))", value: $stay, in: 15...600, step: 15)
                    Stepper("Max walk \(Int(maxWalk)) m", value: $maxWalk, in: 100...2000, step: 50)
                    Picker("Order", selection: $parkingPriority) {
                        ForEach(ParkingPriority.allCases) { Text($0.label).tag($0) }
                    }
                    numberRow("Walking minutes count as", value: $walkingWeight, unit: "× driving", range: 1...5, step: 0.5)
                    NavigationLink("My car parks and tariffs") { ManualCarParksView() }
                }

                Section("Shortcuts") {
                    NavigationLink("Chain shortcuts") { ChainShortcutsView() }
                }

                Section("Status") {
                    LabeledContent("Mapbox token", value: AppConfig.isMapboxConfigured ? "Set" : "Missing")
                    LabeledContent("Supabase", value: AppConfig.isSupabaseConfigured ? "Set" : "Not set up")
                    LabeledContent("Mapbox requests (last hour)", value: "\(RequestCounter.shared.countLastHour())")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

struct FavouriteStationsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FavouriteStation.name) private var stations: [FavouriteStation]

    var body: some View {
        List {
            ForEach(stations) { Text($0.name) }
                .onDelete { $0.map { stations[$0] }.forEach(context.delete) }
            if stations.isEmpty {
                Text("Touch and hold the Petrol chip on the map, then tap the star next to a station.")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .navigationTitle("Favourite stations")
    }
}

struct PreferredCarParksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PreferredCarPark.rank) private var parks: [PreferredCarPark]
    @Query(sort: \SavedPlace.name) private var saved: [SavedPlace]

    var body: some View {
        List {
            Section {
                ForEach(parks) { park in
                    Text("\(park.rank + 1). \(park.name)")
                }
                .onMove { from, to in
                    var ordered = parks
                    ordered.move(fromOffsets: from, toOffset: to)
                    for (i, p) in ordered.enumerated() { p.rank = i }
                }
                .onDelete { offsets in
                    offsets.map { parks[$0] }.forEach(context.delete)
                    for (i, p) in parks.filter({ !$0.isDeleted }).enumerated() { p.rank = i }
                }
            } footer: {
                Text("The planner uses these first when they're within about a mile of your destination, then falls back to the best car park nearby.")
            }
            Section("Add from saved places") {
                ForEach(saved) { place in
                    Button(place.name) {
                        context.insert(PreferredCarPark(name: place.name, coordinate: place.coordinate, rank: parks.count))
                    }
                }
            }
        }
        .toolbar { EditButton() }
        .navigationTitle("Preferred car parks")
    }
}

struct ManualCarParksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ManualCarPark.name) private var parks: [ManualCarPark]
    @Query(sort: \SavedPlace.name) private var saved: [SavedPlace]
    @State private var editing: ManualCarPark?

    var body: some View {
        List {
            ForEach(parks) { park in
                Button {
                    editing = park
                } label: {
                    VStack(alignment: .leading) {
                        Text(park.name)
                        Text(park.tariff.isEmpty ? "No tariff yet" : park.tariff.map { "\($0.upToMinutes) min \(Formatters.pounds(Double($0.pricePence) / 100))" }.joined(separator: " · "))
                            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            .onDelete { $0.map { parks[$0] }.forEach(context.delete) }
            Section("Add from saved places") {
                ForEach(saved) { place in
                    Button(place.name) {
                        let park = ManualCarPark(name: place.name, coordinate: place.coordinate)
                        context.insert(park)
                        editing = park
                    }
                }
            }
        }
        .navigationTitle("My car parks")
        .sheet(item: $editing) { TariffEditor(park: $0) }
    }
}

struct TariffEditor: View {
    @Bindable var park: ManualCarPark
    @Environment(\.dismiss) private var dismiss
    @State private var bands: [TariffBand] = []
    @State private var maxStayHours = 0.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $park.name)
                Stepper("Max stay \(maxStayHours == 0 ? "none" : "\(Int(maxStayHours)) h")", value: $maxStayHours, in: 0...24)
                Section("Tariff") {
                    ForEach(bands.indices, id: \.self) { i in
                        HStack {
                            Stepper("Up to \(Formatters.duration(Double(bands[i].upToMinutes) * 60))", value: $bands[i].upToMinutes, in: 15...1440, step: 15)
                            TextField("pence", value: $bands[i].pricePence, format: .number)
                                .keyboardType(.numberPad).frame(width: 70).multilineTextAlignment(.trailing)
                        }
                    }
                    .onDelete { bands.remove(atOffsets: $0) }
                    Button("Add band") {
                        bands.append(TariffBand(upToMinutes: (bands.last?.upToMinutes ?? 0) + 60, pricePence: 0))
                    }
                }
                TextField("Note", text: $park.note)
            }
            .navigationTitle("Car park")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        park.tariff = bands.sorted { $0.upToMinutes < $1.upToMinutes }
                        park.maxStayMinutes = Int(maxStayHours * 60)
                        dismiss()
                    }
                }
            }
            .onAppear {
                bands = park.tariff
                maxStayHours = Double(park.maxStayMinutes) / 60
            }
        }
    }
}

struct ChainShortcutsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var app: AppModel
    @Query(sort: \ChainShortcut.createdAt) private var chains: [ChainShortcut]
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Chain name, e.g. Coffee #1", text: $newName)
                    Button("Add") {
                        context.insert(ChainShortcut(name: newName.trimmingCharacters(in: .whitespaces)))
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Shortcuts appear in search. Tap one to list the nearest branches.")
            }
            ForEach(chains) { chain in
                Button(chain.name) { app.sheet = .chainBranches(chain.name) }
            }
            .onDelete { $0.map { chains[$0] }.forEach(context.delete) }
        }
        .navigationTitle("Chain shortcuts")
    }
}
