import AVFoundation
import Foundation
import Speech

/// Live speech-to-text for trip requests (on-device where the phone supports it).
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        problem = nil
        guard await Self.authorised() else {
            problem = "Allow Speech Recognition and the microphone for Wayfinder in Settings to speak requests."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. You can type instead."
            return
        }
        stop()
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard isListening || task != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorised() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
