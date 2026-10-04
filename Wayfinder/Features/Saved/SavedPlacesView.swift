import SwiftData
import SwiftUI

struct SavedPlacesView: View {
    /// Pushed inside another NavigationStack (Settings) rather than shown as a sheet.
    var embedded = false
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    @Query(sort: \PlaceCollection.name) private var collections: [PlaceCollection]
    @State private var search = ""
    @State private var collectionFilter: PlaceCollection?

    private var filtered: [SavedPlace] {
        places.filter { place in
            (search.isEmpty || place.name.localizedCaseInsensitiveContains(search) || place.note.localizedCaseInsensitiveContains(search))
                && (collectionFilter == nil || (place.collections ?? []).contains { $0 === collectionFilter })
        }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                if !collections.isEmpty {
                    Picker("Collection", selection: $collectionFilter) {
                        Text("All").tag(PlaceCollection?.none)
                        ForEach(collections) { Text($0.name).tag(PlaceCollection?.some($0)) }
                    }
                }
                ForEach(filtered) { place in
                    HStack {
                        Image(systemName: place.icon).foregroundStyle(SavedPlaceColour.color(place.colour))
                        VStack(alignment: .leading) {
                            Text(place.name)
                            if !place.note.isEmpty {
                                Text(place.note).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let here = app.currentLocation?.coordinate {
                            Text(Formatters.distance(GeoMath.distance(here, place.coordinate)))
                                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                        }
                        Button("Navigate") { app.choose(destination: place.asPlace) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Add stop") { app.addToTrip(place.asPlace) }.tint(.orange)
                    }
                }
                .onDelete { offsets in
                    offsets.map { filtered[$0] }.forEach(context.delete)
                }
                if places.isEmpty {
                    Text("Save places from search results, the route preview, or by pressing and holding the map.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .searchable(text: $search, prompt: "Search saved places")
            .navigationTitle("Saved places")
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Collections") { CollectionsView() }
                }
            }
    }
}

struct CollectionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PlaceCollection.name) private var collections: [PlaceCollection]
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New collection (e.g. Home, Favourites)", text: $newName)
                    Button("Add") {
                        context.insert(PlaceCollection(name: newName.trimmingCharacters(in: .whitespaces)))
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(collections) { collection in
                HStack {
                    Text(collection.name)
                    Spacer()
                    Text("\(collection.places?.count ?? 0)").foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .onDelete { $0.map { collections[$0] }.forEach(context.delete) }
        }
        .navigationTitle("Collections")
    }
}

enum SavedPlaceColour {
    static let options = ["yellow", "red", "blue", "green", "purple", "orange"]
    static let icons = ["star.fill", "house.fill", "briefcase.fill", "heart.fill", "cup.and.saucer.fill", "fuelpump.fill", "parkingsign", "mappin"]

    static func color(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "orange": .orange
        default: .yellow
        }
    }
}

struct SavePlaceView: View {
    let place: Place
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PlaceCollection.name) private var collections: [PlaceCollection]

    @State private var name = ""
    @State private var note = ""
    @State private var icon = "star.fill"
    @State private var colour = "yellow"
    @State private var selectedCollections = Set<PersistentIdentifier>()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Note", text: $note, axis: .vertical)
                Picker("Icon", selection: $icon) {
                    ForEach(SavedPlaceColour.icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                Picker("Colour", selection: $colour) {
                    ForEach(SavedPlaceColour.options, id: \.self) { Text($0.capitalized).tag($0) }
                }
                if !collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections) { collection in
                            Toggle(collection.name, isOn: Binding(
                                get: { selectedCollections.contains(collection.persistentModelID) },
                                set: { on in
                                    if on { selectedCollections.insert(collection.persistentModelID) }
                                    else { selectedCollections.remove(collection.persistentModelID) }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Save place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = place.name; note = place.subtitle ?? "" }
        }
    }

    private func save() {
        let saved = SavedPlace(name: name, coordinate: place.coordinate, note: note, icon: icon, colour: colour)
        context.insert(saved)
        saved.collections = collections.filter { selectedCollections.contains($0.persistentModelID) }
        app.statusMessage = "Saved \(name)"
        dismiss()
    }
}
