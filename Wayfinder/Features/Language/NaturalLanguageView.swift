import SwiftData
import SwiftUI

/// Speak or type a trip request ("I need to go to work, but stop at a laundrette first,
/// I've got no change for parking"). Claude turns it into a plan; it only asks a question
/// when it can't plan without one.
struct NaturalLanguageView: View {
    @EnvironmentObject private var app: AppModel
    @Query(sort: \SavedPlace.name) private var saved: [SavedPlace]
    @StateObject private var speech = SpeechInput()

    @State private var text = ""
    @State private var history: [NaturalLanguagePlanner.Turn] = []
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.m) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if history.isEmpty {
                            Text("Tell me where you're going and anything you need on the way.")
                                .font(Theme.Fonts.body)
                            Text("\"Work, but a laundrette first. I've no change for parking.\"\n\"Petrol and a gluten free cafe on the way to Mum's.\"")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        ForEach(Array(history.enumerated()), id: \.offset) { _, turn in
                            bubble(turn)
                        }
                        if working {
                            HStack { ProgressView(); Text("Planning…").font(Theme.Fonts.caption) }
                        }
                        if let message = error ?? speech.problem {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                inputBar
            }
            .padding(Theme.Spacing.l)
            .navigationTitle("Plan with words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { speech.stop(); app.sheet = nil } } }
            .onChange(of: speech.transcript) { _, new in if speech.isListening { text = new } }
            .onChange(of: speech.isListening) { was, now in
                // Finished speaking: send what was heard.
                if was, !now, !text.trimmingCharacters(in: .whitespaces).isEmpty { Task { await send() } }
            }
            .onAppear { focused = true }
            .onDisappear { speech.stop() }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            TextField(history.isEmpty ? "Where to, and what on the way?" : "Your answer", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await send() } }
                .padding(Theme.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surface))
            Button {
                if speech.isListening { speech.stop() } else { focused = false; Task { await speech.start() } }
            } label: {
                Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(speech.isListening ? Theme.Colors.danger : Theme.Colors.accent)
                    .symbolEffect(.pulse, isActive: speech.isListening)
            }
            .accessibilityLabel(speech.isListening ? "Stop listening" : "Speak")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 36))
            }
            .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
    }

    private func bubble(_ turn: NaturalLanguagePlanner.Turn) -> some View {
        let mine = turn.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(turn.content)
                .padding(Theme.Spacing.m)
                .foregroundStyle(mine ? Color.white : Theme.Colors.textPrimary)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(mine ? Theme.Colors.accent : Theme.Colors.surface))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func send() async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !working else { return }
        speech.stop()
        working = true
        error = nil
        defer { working = false }
        let earlier = history
        history.append(.init(role: "user", content: request))
        text = ""
        do {
            let plan = try await NaturalLanguagePlanner.plan(
                text: request, history: earlier, savedPlaces: saved.map(\.name),
                currentDestination: app.destinationPlace?.name
            )
            if !plan.question.isEmpty {
                history.append(.init(role: "assistant", content: plan.question))
                focused = true
                return
            }
            history.append(.init(role: "assistant", content: plan.summary))
            try await app.apply(plan)
            app.sheet = nil
        } catch {
            self.error = error.localizedDescription
            // Put the request back so it can be retried without retyping.
            if history.last?.role == "user" { history.removeLast() }
            text = request
        }
    }
}
