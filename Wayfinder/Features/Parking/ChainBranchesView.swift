import SwiftUI

/// Nearest branches of a saved chain shortcut, by distance.
struct ChainBranchesView: View {
    let chain: String
    @EnvironmentObject private var app: AppModel
    @State private var branches: [Place] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.Colors.warning) }
                ForEach(branches) { branch in
                    PlaceRow(place: branch, onNavigate: { app.choose(destination: branch) }, onAdd: { app.addToTrip(branch) })
                }
                if !loading && branches.isEmpty && error == nil {
                    Text("No \(chain) branches found nearby.").foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(chain)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                defer { loading = false }
                guard let center = app.map?.searchCenter ?? app.currentLocation?.coordinate else { return }
                do {
                    branches = try await PlaceSearchService.shared.branches(of: chain, near: center)
                    app.map?.showResults(branches)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
