import SwiftData
import SwiftUI

/// Destination search with Mapbox autocomplete, plus saved places and chain shortcuts.
struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.createdAt, order: .reverse) private var saved: [SavedPlace]
    @Query(sort: \ChainShortcut.createdAt) private var chains: [ChainShortcut]

    @State private var query = ""
    @State private var suggestions: [PlaceSearchService.Suggestion] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var searchPresented = true

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(Theme.Colors.warning)
                }
                if !suggestions.isEmpty {
                    Section("Results") {
                        ForEach(suggestions) { suggestion in
                            Button { pick(suggestion) } label: {
                                SuggestionRow(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if query.isEmpty {
                    if !chains.isEmpty {
                        Section("Chains") {
                            ForEach(chains) { chain in
                                Button {
                                    app.sheet = .chainBranches(chain.name)
                                } label: {
                                    Label(chain.name, systemImage: chain.icon)
                                }
                            }
                        }
                    }
                    if !saved.isEmpty {
                        Section("Saved places") {
                            ForEach(saved.prefix(8)) { place in
                                Button {
                                    app.choose(destination: place.asPlace)
                                } label: {
                                    Label(place.name, systemImage: place.icon)
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if isSearching && suggestions.isEmpty { ProgressView() } }
            .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address, place or postcode")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task(id: query) {
                // Debounce typing.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await runSearch()
            }
        }
    }

    private func runSearch() async {
        guard query.count >= 2 else { suggestions = []; return }
        isSearching = true
        defer { isSearching = false }
        do {
            let center = app.map?.searchCenter ?? app.currentLocation?.coordinate
            suggestions = try await PlaceSearchService.shared.suggestions(for: query, near: center)
            error = nil
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
        }
    }

    private func pick(_ suggestion: PlaceSearchService.Suggestion) {
        Task {
            do {
                let place = try await PlaceSearchService.shared.resolve(suggestion)
                app.choose(destination: place)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SuggestionRow: View {
    let suggestion: PlaceSearchService.Suggestion
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name).font(Theme.Fonts.body)
                if let subtitle = suggestion.subtitle {
                    Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            if let distance = suggestion.distance {
                Text(Formatters.distance(distance)).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}
