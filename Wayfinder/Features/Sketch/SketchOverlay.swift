import CoreLocation
import SwiftUI

/// Transparent drawing layer over the map. Draw mode captures one-finger strokes; Move mode
/// lets touches through so you can pinch and pan between strokes. Each finished stroke is
/// converted to coordinates immediately (at the zoom it was drawn), simplified in screen
/// pixels, and pinned to the map.
struct SketchOverlay: View {
    @EnvironmentObject private var app: AppModel
    let map: MapController

    @State private var drawMode = true
    @State private var current: [CGPoint] = []
    @State private var strokes: [SketchStroke] = []
    @State private var anchors: [SketchAnchor] = []
    @State private var isWorking = false
    @State private var followLine = false
    @State private var editingAnchor: SketchAnchor?
    @State private var processTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if drawMode {
                Color.white.opacity(0.001) // catches touches without hiding the map
                    .gesture(drawGesture)
                Path { path in
                    guard let first = current.first else { return }
                    path.move(to: first)
                    current.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color(Theme.Colors.sketchStroke), style: StrokeStyle(lineWidth: Theme.Line.sketchWidth, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            VStack {
                toolbar
                if !anchors.isEmpty { anchorChips }
                Spacer()
                if let proposal = app.sketchProposal {
                    SketchResultCard(proposal: proposal, followLine: $followLine,
                                     onAccept: accept, onCancel: cancel,
                                     onModeChange: { Task { await propose() } })
                } else if isWorking {
                    ProgressView("Snapping your line to roads…").cardStyle()
                } else {
                    Text(drawMode ? "Draw a rough line with your finger" : "Pinch and pan, then switch back to Draw")
                        .font(Theme.Fonts.caption).cardStyle()
                }
            }
            .padding(Theme.Spacing.l)
        }
        .coordinateSpace(name: "sketch")
        .sheet(item: $editingAnchor) { anchor in
            AnchorEditSheet(anchor: anchor) { replacement in
                if let i = anchors.firstIndex(of: anchor) {
                    if let replacement { anchors[i] = replacement } else { anchors.remove(at: i) }
                }
                editingAnchor = nil
                map.showSketchAnchors(anchors)
                Task { await propose() }
            }
            .presentationDetents([.medium])
        }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                processTask?.cancel()
                current.append(value.location)
            }
            .onEnded { _ in finishStroke() }
    }

    private var toolbar: some View {
        HStack {
            Button("Cancel", role: .cancel, action: cancel)
            Spacer()
            Picker("Mode", selection: $drawMode) {
                Text("Draw").tag(true)
                Text("Move").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Spacer()
            Button("Clear") {
                strokes = []; anchors = []; app.sketchProposal = nil
                map.clearSketch()
            }
        }
        .cardStyle()
    }

    private var anchorChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(anchors) { anchor in
                    Button { editingAnchor = anchor } label: {
                        Label(anchor.name, systemImage: "smallcircle.filled.circle")
                            .font(Theme.Fonts.caption)
                            .padding(.horizontal, Theme.Spacing.s).padding(.vertical, Theme.Spacing.xs)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func finishStroke() {
        let points = current
        current = []
        guard points.count > 1 else { return }
        let metresPerPoint = map.metresPerPoint
        let anchorPoints = SketchMath.anchors(fromScreen: points)
        let stroke = SketchStroke(
            coordinates: points.map(map.coordinate(forGlobalPoint:)),
            anchors: anchorPoints.map(map.coordinate(forGlobalPoint:)),
            metresPerPoint: metresPerPoint
        )
        strokes.append(stroke)
        map.addSketchStroke(stroke.coordinates)
        // Wait briefly in case another stroke follows, then snap and route.
        processTask?.cancel()
        processTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            isWorking = true
            anchors = await SketchRouter(engine: NavigationEngine.shared).anchors(for: strokes)
            map.showSketchAnchors(anchors)
            await propose()
        }
    }

    private func propose() async {
        guard !anchors.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let router = SketchRouter(engine: NavigationEngine.shared)
            let proposal = try await router.propose(
                strokes: strokes, anchors: anchors, existingTrip: app.trip,
                mode: followLine ? .followLineClosely : .guideThroughPoints
            )
            app.sketchProposal = proposal
            map.showRoutes(proposal.routes)
        } catch {
            app.routeError = error.localizedDescription
        }
    }

    private func accept() {
        guard let proposal = app.sketchProposal else { return }
        app.setPreview(proposal.routes, trip: proposal.trip)
        close()
        app.sheet = proposal.trip.items.count > 1 ? .tripBuilder : .routePreview
    }

    private func cancel() {
        close()
        if let routes = app.previewRoutes { map.showRoutes(routes) } else { map.showRoutes(nil) }
    }

    private func close() {
        processTask?.cancel()
        app.sketchProposal = nil
        map.clearSketch()
        app.isSketching = false
    }
}

/// Move a sketch anchor to a nearby named place, or delete it.
struct AnchorEditSheet: View {
    let anchor: SketchAnchor
    /// nil = delete.
    let onDone: (SketchAnchor?) -> Void
    @State private var options: [Place] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section("Move to a nearby place") {
                    if loading { ProgressView() }
                    ForEach(options) { place in
                        Button(place.name) {
                            onDone(SketchAnchor(name: place.name, coordinate: place.coordinate, snapRadius: nil))
                        }
                    }
                }
                Section {
                    Button("Delete this point", role: .destructive) { onDone(nil) }
                }
            }
            .navigationTitle(anchor.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            options = (try? await PlaceSearchService.shared.namedPlaces(near: anchor.coordinate, limit: 6))?
                .filter { $0.name != anchor.name } ?? []
            loading = false
        }
    }
}

struct SketchResultCard: View {
    let proposal: SketchProposal
    @Binding var followLine: Bool
    let onAccept: () -> Void
    let onCancel: () -> Void
    let onModeChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text((proposal.isEstimate ? "≈ " : "") + Formatters.duration(proposal.duration)).font(Theme.Fonts.eta)
                Text("· \(Formatters.distance(proposal.distance))").foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
            }
            if let baseline = proposal.baselineDuration, let baseDistance = proposal.baselineDistance {
                let dt = proposal.duration - baseline
                let dd = proposal.distance - baseDistance
                Text("\(dt >= 0 ? "+" : "−")\(Formatters.duration(abs(dt))), \(dd >= 0 ? "+" : "−")\(Formatters.distance(abs(dd))) compared with the normal route")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            if proposal.isEstimate {
                Text("Estimate: live traffic far ahead isn't known yet.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            ForEach(proposal.notices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
            }
            if proposal.followLineAvailable {
                Picker("How closely", selection: $followLine) {
                    Text("Guide through my points").tag(false)
                    Text("Follow my line closely").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: followLine) { _, _ in onModeChange() }
            } else {
                Text("Guide through my points").font(Theme.Fonts.caption.weight(.semibold))
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
            }
        }
        .cardStyle()
    }
}
