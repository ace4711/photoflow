import Foundation
import Speech
import AVFoundation

@MainActor
class DictationService: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var error: String?
    @Published var authorized = false
    /// Set to true when recording was stopped via voice command ("stopp"/"stop")
    @Published var stoppedByVoice = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var isStopping = false

    /// Stop words that end dictation (case-insensitive)
    private let stopWords: Set<String> = ["stopp", "stop", "stopp.", "stop."]

    var currentLanguage: PhotoNote.NoteLanguage = .swedish

    init() {
        checkAuthorization()
    }

    func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorized = (status == .authorized)
                if status != .authorized {
                    self?.error = "Taligenkänning ej behörig. Aktivera i Systeminställningar → Integritet → Taligenkänning."
                }
            }
        }
    }

    /// Request speech authorization without needing an instance
    static func requestAuthorizationOnce() {
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                print("[Rättigheter] Taligenkänning ej beviljad: \(status.rawValue)")
            }
        }
    }

    func startRecording(language: PhotoNote.NoteLanguage) {
        guard authorized else {
            error = "Taligenkänning ej behörig."
            return
        }

        // Stop any existing session
        if isRecording {
            stopRecording()
        }

        currentLanguage = language
        let locale = language == .swedish ? Locale(identifier: "sv-SE") : Locale(identifier: "en-US")
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Taligenkänning ej tillgänglig för \(language.displayName)."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        // Reset audio engine
        let inputNode = audioEngine.inputNode
        // Remove any existing tap first
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        isStopping = false
        stoppedByVoice = false

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.isStopping else { return }

                if let result {
                    let text = result.bestTranscription.formattedString

                    // Check if the last word is a stop command
                    let lastWord = text.split(separator: " ").last.map { String($0).lowercased() } ?? ""
                    if self.stopWords.contains(lastWord) {
                        // Remove the stop word from transcript
                        let cleaned = text.split(separator: " ").dropLast().joined(separator: " ")
                        self.liveTranscript = cleaned
                        self.stoppedByVoice = true
                        self.stopRecording()
                        return
                    }

                    self.liveTranscript = text

                    if result.isFinal {
                        self.stopRecording()
                    }
                }

                if let error {
                    let nsError = error as NSError
                    // Ignore cancellation (codes 1, 216, 301) and "no speech detected" (code 1110)
                    let ignoredCodes: Set<Int> = [1, 216, 301, 1110]
                    if !ignoredCodes.contains(nsError.code) {
                        self.error = error.localizedDescription
                    }
                    if self.isRecording {
                        self.stopRecording()
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            error = nil
            liveTranscript = ""
        } catch {
            self.error = "Kunde inte starta mikrofon: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard !isStopping else { return }
        isStopping = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        isRecording = false
    }
}
