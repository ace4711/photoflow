import Foundation
import Speech
import AVFoundation

/// iOS-motsvarigheten till macOS-appens `DictationService` (Fas 3c) —
/// samma `SpeechAnalyzer`/`DictationTranscriber`-mönster (se den filens
/// utförliga klasskommentar för SDK-research kring varför
/// `DictationTranscriber`, inte `SpeechTranscriber`, används för svenska),
/// men med de plattformsskillnader iOS kräver:
///
/// - **`AVAudioSession`**: macOS har ingen delad ljudsession att konfigurera,
///   men iOS kräver att appen sätter kategori (`.record`) och aktiverar
///   sessionen innan `AVAudioEngine` får mikrofonåtkomst.
/// - **`installAudioTap`-tillgänglighet**: precis som på macOS-sidan
///   (`@available(macOS 27.0, *)`) finns den nya, `throws`-baserade
///   `installAudioTap` bara från iOS 27 (verifierat i SDK:n — se
///   `PipelineRunner`/`DictationService`s motsvarande kommentarer för macOS).
///   Fältappens deployment target är iOS 26, så den äldre `installTap`
///   används som fallback precis som på macOS-sidan.
///
/// Den rena textackumuleringen (`finalizedText`/`volatileText`-modellen och
/// stoppordslogiken) är INTE duplicerad — den återanvänds direkt från
/// `DictationTextAccumulator` i `Sources/Shared` (Fas 7), som macOS-appens
/// `DictationService` också vidarebefordrar till sedan samma fas.
@MainActor
final class FieldDictationService: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var error: String?
    @Published var authorized = false
    @Published var statusText: String?

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var audioEngine = AVAudioEngine()
    private var isStopping = false
    private var isStartingUp = false

    private var finalizedText = ""
    private var volatileText = ""

    init() {
        checkAuthorization()
    }

    func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorized = (status == .authorized)
                if status != .authorized {
                    self?.error = "Taligenkänning ej behörig. Aktivera i Inställningar → Integritetsskydd → Taligenkänning."
                }
            }
        }
    }

    func startRecording() {
        guard authorized else {
            error = "Taligenkänning ej behörig."
            return
        }
        guard !isStartingUp, !isRecording else { return }

        isStartingUp = true
        Task { [weak self] in
            await self?.startRecordingAsync()
            self?.isStartingUp = false
        }
    }

    private func startRecordingAsync() async {
        error = nil
        statusText = nil

        let requestedLocale = Locale(identifier: "sv-SE")
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            error = "Taligenkänning stöder inte svenska på den här enheten."
            return
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )

        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .unsupported:
            error = "Taligenkänningsmodellen för svenska stöds inte på den här enheten."
            return
        case .supported, .downloading:
            statusText = "Laddar ner språkmodell (svenska)…"
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                statusText = nil
                self.error = "Kunde inte ladda ner taligenkänningsmodellen: \(error.localizedDescription)"
                return
            }
        @unknown default:
            break
        }
        statusText = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Kunde inte aktivera ljudsessionen: \(error.localizedDescription)"
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: inputFormat
        ) else {
            error = "Inget kompatibelt ljudformat för taligenkänning hittades."
            return
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.audioConverter = (inputFormat == analyzerFormat) ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        isStopping = false
        finalizedText = ""
        volatileText = ""
        liveTranscript = ""

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    self.handle(result: result)
                }
            } catch {
                if !self.isStopping {
                    self.error = "Taligenkänning avbröts: \(error.localizedDescription)"
                }
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            self.error = "Kunde inte starta taligenkänning: \(error.localizedDescription)"
            stopRecording()
            return
        }

        if #available(iOS 27.0, *) {
            do {
                try inputNode.installAudioTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    let copy = AVAudioPCMBuffer(copying: buffer)
                    Task { @MainActor in
                        self.enqueue(buffer: copy)
                    }
                }
            } catch {
                self.error = "Kunde inte lyssna på mikrofonen: \(error.localizedDescription)"
                stopRecording()
                return
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.enqueue(buffer: buffer)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            self.error = "Kunde inte starta mikrofon: \(error.localizedDescription)"
            stopRecording()
        }
    }

    private func enqueue(buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }
        guard let input = makeAnalyzerInput(from: buffer) else { return }
        continuation.yield(input)
    }

    private func makeAnalyzerInput(from buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        guard let analyzerFormat else { return nil }
        guard let converter = audioConverter else {
            return AnalyzerInput(buffer: buffer)
        }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: converted)
    }

    private func handle(result: DictationTranscriber.Result) {
        guard !isStopping else { return }

        let text = String(result.text.characters)
        (finalizedText, volatileText) = DictationTextAccumulator.accumulate(
            finalizedText: finalizedText, volatileText: volatileText, newText: text, isFinal: result.isFinal
        )
        liveTranscript = finalizedText + volatileText
    }

    func stopRecording() {
        guard !isStopping else { return }
        isStopping = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        inputContinuation?.finish()
        inputContinuation = nil

        resultsTask?.cancel()
        resultsTask = nil

        let analyzerToStop = analyzer
        analyzer = nil
        transcriber = nil
        audioConverter = nil
        analyzerFormat = nil
        Task {
            await analyzerToStop?.cancelAndFinishNow()
        }

        isRecording = false
    }
}
