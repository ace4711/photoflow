import Foundation
import Speech
import AVFoundation

/// Diktering på enheten (Fas 3c). Skrev om från `SFSpeechRecognizer` till det
/// nya `SpeechAnalyzer`-API:t — verifierat i SDK:n
/// (`grep -rn "SpeechAnalyzer\|SpeechTranscriber\|AssetInventory"` i
/// `Speech.framework/Modules/`) att `SpeechAnalyzer`/`AssetInventory` finns,
/// macOS 26+ (matchar projektets deployment target).
///
/// **Viktigt SDK-fynd som avgjorde vilken modul som används**: `Speech`
/// innehåller två olika "transcriber"-moduler för `SpeechAnalyzer`:
/// `SpeechTranscriber` (tänkt för längre/kvalitetstranskribering av inspelat
/// tal) och `DictationTranscriber` (tänkt för live-diktering, samma
/// användningsfall som appens gamla `SFSpeechAudioBufferRecognitionRequest`).
/// Testat direkt mot SDK:n (scratchpad, körning mot en riktig
/// `AVAudioFile`): `SpeechTranscriber.supportedLocales` innehåller **inte**
/// svenska (45 språk, inget `sv-SE`) på den här SDK-versionen, medan
/// `DictationTranscriber.supportedLocales` gör det (54 språk, inklusive
/// `sv-SE`, verifierat via `DictationTranscriber.supportedLocale(equivalentTo:)`
/// som returnerar `sv_SE (fixed sv_SE)`). Appens UI-texter och dikterade
/// anteckningar är i huvudsak svenska, så `DictationTranscriber` används —
/// `SpeechTranscriber` hade tyst gjort svensk diktering omöjlig.
/// `SFSpeechRecognizer.requestAuthorization` behålls oförändrad för
/// behörighetsflödet — den styr samma Taligenkänning-TCC-behörighet och
/// kostar inget att fortsätta använda även om den nya (rent on-device, ingen
/// server) motorn kanske inte strikt kräver den.
///
/// Flöde: `AVAudioEngine`s mikrofon-tapp konverterar varje buffert till
/// `SpeechAnalyzer`s bästa kompatibla format (`AVAudioConverter`, samma
/// mönster som `RAWRenderer`/`HDRWriter` använder för andra format-
/// konverteringar — verifierat i scratchpad: mikrofonens 22050 Hz Float32
/// konverteras korrekt till modulens 16000 Hz Int16) och matar in dem i en
/// `AsyncStream<AnalyzerInput>` som `SpeechAnalyzer.start(inputSequence:)`
/// konsumerar. `DictationTranscriber`s `results`-asyncsekvens ger både
/// flyktiga (`isFinal == false`, uppdateras löpande) och slutgiltiga
/// resultat; **verifierat i scratchpad** (syntetiskt svenskt tal via `say`,
/// inklusive ett "stopp"-slutord) att varje resultats `text` bara är den
/// NYA textbiten sedan senaste finalisering (inte hela sessionens text från
/// början) — `liveTranscript` byggs därför som
/// `finalizedText (ackumulerad) + senaste flyktiga texten`, som ger samma
/// "visa allt hittills"-modell som `SFSpeechRecognitionResult.bestTranscription`
/// gav förut. Samma scratchpad-körning visade att "stopp" dyker upp i ett
/// FLYKTIGT resultat innan finalisering (`'...vatten stopp'` med
/// `isFinal=false`), så stoppordsreaktionen är fortfarande snabb, inte
/// fördröjd till nästa finalisering.
///
/// **Modellnedladdning**: `AssetInventory.status(forModules:)` +
/// `assetInstallationRequest(supporting:)` laddar ner språkmodellen om den
/// saknas (samma mönster som `TranslationService`), med svensk statustext.
///
/// **Behållet oförändrat** (samma publika kontrakt som förut, så
/// `DictationPanelView` inte behövde skrivas om i grunden): `liveTranscript`,
/// `stoppedByVoice`, stoppordslogiken ("stopp"/"stop" som sista ord
/// avslutar), `isRecording`, `authorized`, `error`.
@MainActor
class DictationService: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var error: String?
    @Published var authorized = false
    /// Set to true when recording was stopped via voice command ("stopp"/"stop")
    @Published var stoppedByVoice = false
    /// Kort svensk statustext för långsamma delsteg (idag bara nedladdning av
    /// taligenkänningsmodellen) — visas i panelen i stället för att bara se
    /// ut som att inspelningen hänger innan den startar.
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

    /// Ackumulerad slutgiltig text ("isFinal"-resultat) + den senaste
    /// flyktiga (ej slutgiltiga) texten — se klasskommentaren.
    private var finalizedText = ""
    private var volatileText = ""

    /// Stop words that end dictation (case-insensitive). Fas 7: den faktiska
    /// listan bor nu i `DictationTextAccumulator` (Sources/Shared), delad med
    /// iOS-appens fält-diktering — kvar här som en alias så befintliga
    /// anropsställen/tester inte behövde ändras.
    static let stopWords: Set<String> = DictationTextAccumulator.stopWords

    var currentLanguage: PhotoNote.NoteLanguage = .swedish

    init() {
        checkAuthorization()
    }

    /// `nonisolated` är nödvändigt: Speech anropar completion-blocket på en
    /// bakgrundskö. Med default MainActor-isolering blir blocket annars
    /// MainActor-isolerat, och Swift 6:s isoleringskontroll kraschar appen
    /// (dispatch_assert_queue) redan innan blockets kropp körs.
    nonisolated func checkAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorized = (status == .authorized)
                if status != .authorized {
                    self?.error = "Taligenkänning ej behörig. Aktivera i Systeminställningar → Integritet → Taligenkänning."
                }
            }
        }
    }

    /// Request speech authorization without needing an instance.
    /// `nonisolated` av samma skäl som `checkAuthorization()` ovan.
    nonisolated static func requestAuthorizationOnce() {
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
        guard !isStartingUp else { return }

        // Stop any existing session
        if isRecording {
            stopRecording()
        }

        currentLanguage = language
        isStartingUp = true
        Task { [weak self] in
            await self?.startRecordingAsync(language: language)
            self?.isStartingUp = false
        }
    }

    private func startRecordingAsync(language: PhotoNote.NoteLanguage) async {
        error = nil
        statusText = nil

        let requestedLocale = language == .swedish ? Locale(identifier: "sv-SE") : Locale(identifier: "en-US")
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            error = "Taligenkänning stöder inte \(language.displayName) på den här enheten."
            return
        }

        // Explicit konfiguration i stället för en `Preset`: `.punctuation`
        // matchar den gamla `request.addsPunctuation = true`, `.volatileResults`
        // ger löpande delresultat (samma som gamla `shouldReportPartialResults`),
        // `.frequentFinalization` finaliserar oftare (kortare, snabbare
        // "commit"-segment) vilket håller `finalizedText` uppdaterad tidigare
        // och minskar risken att tappa text vid en krasch/avbrott mitt i en
        // lång mening.
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )

        // Ladda ner språkmodellen om den saknas — samma mönster som
        // `TranslationService.performPendingTranslation`.
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .unsupported:
            error = "Taligenkänningsmodellen för \(language.displayName) stöds inte på den här enheten."
            return
        case .supported, .downloading:
            statusText = "Laddar ner språkmodell (\(language.displayName))…"
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
        stoppedByVoice = false
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

        // `installTap(onBus:bufferSize:format:block:)` deprecerad i macOS 27
        // till förmån för `installAudioTap(onBus:bufferSize:format:tapProvider:)`
        // — verifierat i SDK:n (`.swiftinterface` för `AVFAudio`, se
        // `AVAudioNode`-utökningen) eftersom `AVAudioNode.h` bara exponerar den
        // nya varianten via `NS_REFINED_FOR_SWIFT` (den råa ObjC-signaturen med
        // en `NSError**`-parameter syns inte direkt i Swift). Den nya varianten
        // kastar fel och ger buffertar som en read-only, `Sendable`
        // `AVReadOnlyAudioPCMBuffer` i stället för den gamla klassen
        // `AVAudioPCMBuffer` — konverteras direkt tillbaka med den nya
        // `AVAudioPCMBuffer(copying:)`-initieraren så att resten av flödet
        // (`enqueue`/`makeAnalyzerInput`) inte behövde skrivas om. Projektets
        // deployment target är macOS 26, så den nya varianten (macOS 27+) väljs
        // bara via `#available` — då kallas den deprecerade varianten aldrig på
        // en körning där den faktiskt ÄR deprecerad, så ingen varning uppstår
        // (verifierat: `swiftc -typecheck` mot mål macOS 26 ger ingen varning
        // för den gamla varianten, bara mot mål macOS 27). Tapproviderns
        // stängning är `@Sendable` i den nya API:t (till skillnad från den
        // gamla), så anropet till den MainActor-isolerade `enqueue` görs via
        // `Task { @MainActor in … }` i stället för direkt.
        if #available(macOS 27.0, *) {
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
            // Fas 8: SAMMA krasch-mönster som `checkAuthorization`/
            // `NotificationService` hade (se FORBATTRINGAR, commit 4cb01db) —
            // den gamla `installTap`s blocktyp är INTE `@Sendable`-märkt i
            // SDK:n (se doc-kommentaren på `enqueue` nedan), så utan explicit
            // `@Sendable` här skulle SWIFT_DEFAULT_ACTOR_ISOLATION göra
            // blocket MainActor-isolerat, och AVAudioEngine anropar det från
            // sin egen realtids-ljudtråd — Swift 6:s isoleringskontroll
            // kraschar appen (dispatch_assert_queue) på just den vägen. Bara
            // ett teoretiskt riskläge på DEN HÄR utvecklingsmaskinen (macOS
            // 27 tar alltid `installAudioTap`-grenen ovan), men skulle
            // krascha varje gång diktering startas på en riktig macOS
            // 26-installation.
            //
            // `buffer` (en vanlig, muterbar `AVAudioPCMBuffer` — ägd av
            // AVAudioEngines interna tapp-maskineri, kan återanvändas för
            // nästa anrop) är inte `Sendable` och kan inte skickas direkt
            // till `@MainActor`-Task:en utan att regionbaserad isolerings-
            // kontroll klagar ("sending risks causing data races"). Samma
            // lösning som `installAudioTap`-grenen ovan i idé, men
            // `AVAudioPCMBuffer.init(copying:)` kräver macOS 27 (verifierat
            // i SDK:n) — just den API:n finns alltså inte på grenen som
            // körs på macOS 26. `Self.copyPCMBuffer` gör samma sak manuellt
            // (fungerar från macOS 10.10) genom att memcpy:a varje kanals
            // rådata till en helt egen, oaliaserad buffert.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [weak self] buffer, _ in
                guard let copy = Self.copyPCMBuffer(buffer) else { return }
                Task { @MainActor in
                    self?.enqueue(buffer: copy.buffer)
                }
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

    /// Fas 8: manuell djup kopia av en `AVAudioPCMBuffer` — used av den
    /// gamla `installTap`-grenen ovan (macOS < 27) för att göra bufferten
    /// säker att skicka till `@MainActor` innan den (eventuellt) återanvänds
    /// av AVAudioEngine. `AVAudioPCMBuffer.init(copying:)` (macOS 27+) gör
    /// samma sak men fanns inte innan dess (verifierat i SDK:n), så den här
    /// grenen behöver en egen, äldre-macOS-kompatibel variant.
    ///
    /// Returnerar en `SendableAudioBuffer` (inte den råa `AVAudioPCMBuffer`
    /// direkt): Swifts regionbaserade isoleringskontroll kan inte se att den
    /// nya bufferten är helt oaliaserad bara för att den byggs upp via
    /// råpekare (den klagade fortfarande på "sending risks causing data
    /// races" trots att `buffer`-parametern bara LÄSTS, aldrig behållits) —
    /// samma `@unchecked Sendable`-escape-hatch som `ProcessCancellationBox`
    /// (se den filens klasskommentar) löser det pragmatiskt: vi VET att den
    /// nya bufferten inte delas med någon annan kod.
    /// `nonisolated`: anropas direkt från den `@Sendable` tapp-closuren
    /// ovan, INTE från MainActor.
    nonisolated private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> SendableAudioBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        copy.frameLength = buffer.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<srcList.count {
            guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else { continue }
            dstData.copyMemory(from: srcData, byteCount: Int(srcList[i].mDataByteSize))
            dstList[i].mDataByteSize = srcList[i].mDataByteSize
        }
        return SendableAudioBuffer(buffer: copy)
    }

    /// Konverterar (vid behov) och matar in en ljudbuffert i analyzer-strömmen.
    /// Anropas från BÅDA tapp-varianterna ovan via `Task { @MainActor in }` —
    /// aldrig direkt från `AVAudioEngine`s egen (icke-MainActor) ljudtråd (se
    /// Fas 8-kommentaren på `installTap`-grenen ovan för varför ett direkt
    /// anrop där kraschar appen).
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

    /// Hanterar ett resultat (flyktigt eller slutgiltigt) från
    /// `transcriber.results` — se klasskommentaren för modellen
    /// `finalizedText + volatileText`. Den faktiska logiken är utbruten i
    /// rena, statiska funktioner (`accumulate`/`stripTrailingStopWord`) så
    /// den går att enhetstesta utan Speech-ramverket eller ljud — se
    /// `DictationServiceTests`.
    private func handle(result: DictationTranscriber.Result) {
        guard !isStopping else { return }

        let text = String(result.text.characters)
        (finalizedText, volatileText) = Self.accumulate(
            finalizedText: finalizedText, volatileText: volatileText, newText: text, isFinal: result.isFinal
        )

        let combined = finalizedText + volatileText
        if let cleaned = Self.stripTrailingStopWord(from: combined, stopWords: Self.stopWords) {
            liveTranscript = cleaned
            stoppedByVoice = true
            stopRecording()
            return
        }

        liveTranscript = combined
    }

    // MARK: - Ren logik (testbar utan Speech/ljud)

    /// Given den hittills ackumulerade slutgiltiga texten och ett nytt
    /// resultats text/`isFinal`-flagga: returnerar det uppdaterade
    /// `(finalizedText, volatileText)`-paret. **Verifierat mot en riktig
    /// `DictationTranscriber`-körning i scratchpad** (syntetiskt svenskt tal
    /// via `say`, se klasskommentaren): varje resultats `text` är bara den
    /// NYA textbiten sedan senaste finalisering, inte hela sessionens text
    /// från början — därför ackumuleras `finalizedText` genom att lägga
    /// till, inte ersätta.
    static func accumulate(
        finalizedText: String, volatileText: String, newText: String, isFinal: Bool
    ) -> (finalizedText: String, volatileText: String) {
        DictationTextAccumulator.accumulate(finalizedText: finalizedText, volatileText: volatileText, newText: newText, isFinal: isFinal)
    }

    /// Om `combined`s sista mellanslagsseparerade ord (skiftlägesokänsligt)
    /// är ett stoppord: returnerar texten med det ordet borttaget. `nil` om
    /// inget stoppord hittades.
    static func stripTrailingStopWord(from combined: String, stopWords: Set<String>) -> String? {
        DictationTextAccumulator.stripTrailingStopWord(from: combined, stopWords: stopWords)
    }

    func stopRecording() {
        guard !isStopping else { return }
        isStopping = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        inputContinuation?.finish()
        inputContinuation = nil

        resultsTask?.cancel()
        resultsTask = nil

        // Best-effort, "fire and forget" nedstängning av analyzern —
        // `liveTranscript` innehåller redan den senaste (flyktiga eller
        // slutgiltiga) texten, exakt samma acceptanskriterium som den
        // tidigare SFSpeechRecognizer-varianten hade (den avbröt också
        // `recognitionTask` direkt efter `endAudio()` i stället för att
        // vänta på ett slutgiltigt, putsat resultat).
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
