import Foundation
import Combine
import CoreLocation
import AppKit
import os

@MainActor
class PipelineState: ObservableObject {
    /// Fas 10 (prestanda vid stora sessioner): bevakar `NSApplication.willTerminateNotification`
    /// så en väntande debounced gallringsskrivning (se `saveCullDecisions()`) ALDRIG
    /// går förlorad bara för att appen stängs innan 1-sekunderstimern hinner löpa
    /// ut — se `flushCullDecisions()`. Registrerad med `queue: .main` och en
    /// icke-isolerad ytterklosur som hoppar till MainActor inuti, samma mönster
    /// som agent-rules.md beskriver för C-/ObjC-callbacks under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` (annars riskerar man en krasch
    /// om AppKit någon gång levererar notisen på en bakgrundskö).
    ///
    /// Ingen `deinit`/explicit `removeObserver` — `PipelineState` är ett
    /// `@StateObject` som lever hela appens livstid (skapas en gång av
    /// `PhotoFlowApp`), och `[weak self]` gör closuren ofarlig om den ändå
    /// skulle överleva (den blir bara en no-op). Att ta bort observatören i en
    /// `deinit` hade dessutom krävt att komma åt en icke-`Sendable`
    /// `NSObjectProtocol` från `deinit`s icke-isolerade kontext.
    private func observeAppTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushCullDecisions()
            }
        }
    }

    init() {
        observeAppTermination()
    }

    @Published var currentStep: PipelineStep = .idle
    @Published var progress: Double = 0.0
    @Published var currentFileIndex: Int = 0
    @Published var totalFiles: Int = 0
    @Published var statusMessage: String = "Välj en mapp med NEF-filer för att börja"
    @Published var errorMessage: String?
    @Published var isRunning: Bool = false
    @Published var isPaused: Bool = false

    /// Fas 3e: satt av `NotificationService.onReviewNowRequested` (knappen
    /// "Granska nu" på en systemnotis) — `DashboardView` observerar den för
    /// att öppna granskningsvyn, och nollställer den direkt igen. En bool +
    /// `onChange` i stället för en direkt referens till dashboardens lokala
    /// `@State`, eftersom `PipelineState` (till skillnad från vyn) redan är
    /// nåbar från både `PhotoFlowApp`/`NotificationService` och vyerna.
    @Published var reviewRequestedFromNotification: Bool = false

    /// Fas 7: satt av `PhotoFlowApp`s `.onOpenURL` när användaren
    /// dubbelklickar en `.photoflownotes`-fil i Finder (eller "Öppna med" →
    /// PhotoFlow). `DashboardView` observerar den, kör importen, och
    /// nollställer den direkt igen — samma mönster som
    /// `reviewRequestedFromNotification` ovan.
    @Published var pendingFieldNotesImportURL: URL?

    @Published var inputDirectory: URL?
    @Published var outputDirectory: URL?

    /// Fas 6: sessionens manifest (se `SessionManifest`/`SessionManifestStore`)
    /// — lazily skapad/inläst/migrerad av `syncManifest()` första gången den
    /// behövs (första `updateStep`/`completeStep`/... efter att
    /// `outputDirectory` satts). `nil` bara innan en outputmapp är känd.
    @Published var sessionManifest: SessionManifest?

    /// Fingerprints ett steg har räknat ut men ännu inte hunnit committa till
    /// `sessionManifest` via `syncManifest(step:)` — satt av pipeline-stegen
    /// (t.ex. `runBracketAnalysis`) INNAN de anropar `updateStep`/
    /// `completeStep` för samma steg, se `setPendingFingerprint`.
    private var pendingStepFingerprints: [DashboardStep: String] = [:]

    func setPendingFingerprint(_ fingerprint: String, for step: DashboardStep) {
        pendingStepFingerprints[step] = fingerprint
    }

    @Published var bracketGroups: [BracketGroup] = []
    @Published var allPhotos: [PhotoItem] = [] {
        // Fas 10 (prestanda vid stora sessioner, se FORBATTRINGAR.md): tidigare
        // byggdes `photoIndexByID` om (O(n)) på VARJE mutation av `allPhotos`,
        // inklusive ett enda `setDecision`-anrop (som dessutom skrev TVÅ separata
        // fält => två ombyggnader). Över en hel 2000-bilders gallringssession
        // (ett `setDecision`-anrop per accept/avvisa) blev det en O(n²)-kostnad
        // — uppmätt till ~2.5s för 2000 sekventiella beslut, se
        // scratchpad-mätningen i FORBATTRINGAR.md.
        //
        // Ombyggnaden behövs bara när `allPhotos` STRUKTURELLT ändras (bulk-
        // laddning av en session, `reset()`, `clearAllCullDecisions()`) — inte
        // när ett enskilt fälts värde (accepted/rejected/algorithmSuggested)
        // ändras på en redan existerande bild. `oldValue.count != allPhotos.count`
        // är en billig (O(1)) proxy för "strukturellt ändrad": verifierat (grep)
        // att ingen kod någonstans omordnar `allPhotos` på plats med OFÖRÄNDRAT
        // antal — om det någonsin blir sant måste den koden anropa
        // `rebuildPhotoIndexAndCounts()` explicit, annars blir `photoIndexByID`/
        // de cachade räknarna nedan felaktiga (tyst, utan krasch).
        didSet {
            if oldValue.count != allPhotos.count {
                rebuildPhotoIndexAndCounts()
            }
        }
    }

    /// O(1) lookup from `PhotoItem.id` to its index in `allPhotos`, kept in sync
    /// via `allPhotos`'s `didSet`. `allPhotos` is the single source of truth for
    /// cull decisions — `BracketGroup` only stores `photoIDs`, resolved through
    /// this index by `photos(in:)`.
    private var photoIndexByID: [String: Int] = [:]

    /// Cachade O(1)-räknare för gallringsläget — ersätter de tre
    /// `allPhotos.filter { $0.accepted }.count`-genomlöpningarna som tidigare
    /// kördes VARJE gång `PreviewCullView`/`BracketReviewView`/`StepCardView`/
    /// `DashboardView` ritades om (dvs. vid varje beslut, eftersom `allPhotos`
    /// är `@Published`). Hålls i synk inkrementellt av `setDecision`
    /// (O(1) per anrop) och fullständigt av `rebuildPhotoIndexAndCounts()` vid
    /// strukturella ändringar. Antar (liksom all tidigare kod) att en bild
    /// aldrig är både `accepted` och `rejected` samtidigt — det är precis vad
    /// `setDecision` garanterar, se dess implementation.
    @Published private(set) var acceptedCount: Int = 0
    @Published private(set) var rejectedCount: Int = 0
    // `max(0, ...)` som ett rent defensivt skydd (matchar hur `syncManifest`
    // redan klampade sin gamla `.filter`-baserade uträkning) — kan aldrig bli
    // negativt om invarianten ovan hålls, vilket `PipelineStateCullDecisionsTests`
    // verifierar efter varje typ av mutation.
    var unreviewedCount: Int { max(0, allPhotos.count - acceptedCount - rejectedCount) }

    private func rebuildPhotoIndexAndCounts() {
        photoIndexByID = Dictionary(uniqueKeysWithValues: allPhotos.enumerated().map { ($1.id, $0) })
        acceptedCount = allPhotos.reduce(0) { $0 + ($1.accepted ? 1 : 0) }
        rejectedCount = allPhotos.reduce(0) { $0 + ($1.rejected ? 1 : 0) }
    }

    /// Resolves a group's photos from `allPhotos`, in the group's original order.
    /// IDs with no match in `allPhotos` (shouldn't normally happen) are skipped.
    func photos(in group: BracketGroup) -> [PhotoItem] {
        group.photoIDs.compactMap { photoIndexByID[$0].map { allPhotos[$0] } }
    }

    /// Sets a photo's accept/reject decision by ID. Since `allPhotos` is the only
    /// place decisions are stored, this is the one function both BracketReviewView
    /// and PreviewCullView should call to change a decision.
    ///
    /// Fas 10: writes BOTH fields in a single array assignment (one `didSet`
    /// firing instead of two) and updates `acceptedCount`/`rejectedCount`
    /// incrementally instead of relying on the (now count-guarded) full
    /// recompute — see `allPhotos`'s `didSet` doc comment.
    func setDecision(photoID: String, accepted: Bool, rejected: Bool) {
        guard let idx = photoIndexByID[photoID] else { return }
        let old = allPhotos[idx]
        guard old.accepted != accepted || old.rejected != rejected else { return }
        var photo = old
        photo.accepted = accepted
        photo.rejected = rejected
        allPhotos[idx] = photo
        if old.accepted != accepted { acceptedCount += accepted ? 1 : -1 }
        if old.rejected != rejected { rejectedCount += rejected ? 1 : -1 }
    }

    func setAlgorithmSuggested(photoID: String, suggested: Bool) {
        guard let idx = photoIndexByID[photoID] else { return }
        allPhotos[idx].algorithmSuggested = suggested
    }

    /// Clears every photo's accept/reject decision in ONE array assignment
    /// (`DashboardView`'s "Radera all granskningsdata" — tidigare en `for`-loop
    /// som mutera `allPhotos[i]` styck för styck, vilket med den gamla ovillkorade
    /// `didSet`-ombyggnaden hade varit O(n²); med dagens count-baserade guard är
    /// loopen i sig inte längre farlig, men en enda tilldelning är ändå
    /// tydligare och billigare — se `flushCullDecisions()`'s doc för varför en
    /// väntande debounced skrivning också avbryts här) och nollställer de
    /// cachade räknarna direkt i stället för att förlita sig på
    /// count-oförändrad-guarden (som INTE hade triggat en ombyggnad här).
    func clearAllCullDecisions() {
        pendingCullSaveTask?.cancel()
        pendingCullSaveTask = nil
        guard !allPhotos.isEmpty else { return }
        allPhotos = allPhotos.map { photo in
            var p = photo
            p.accepted = false
            p.rejected = false
            return p
        }
        acceptedCount = 0
        rejectedCount = 0
    }

    func selectedCount(in group: BracketGroup) -> Int {
        photos(in: group).filter { $0.accepted }.count
    }

    /// Vacuously true for an empty group, matching the pre-refactor behavior.
    func allReviewed(_ group: BracketGroup) -> Bool {
        photos(in: group).allSatisfy { $0.accepted || $0.rejected }
    }

    func label(for group: BracketGroup) -> String {
        let photos = photos(in: group)
        if group.isBracket {
            return "HDR \(group.id) - \(selectedCount(in: group))/\(photos.count) exp (f/\(group.fNumber))"
        } else {
            return "Grupp \(group.id) - \(photos.count) bilder (f/\(group.fNumber))"
        }
    }

    // For bracket review
    @Published var currentBracketIndex: Int = 0
    @Published var currentPhotoIndexInBracket: Int = 0

    // For culling
    @Published var currentCullIndex: Int = 0

    // Calendar-matched addresses for current session
    @Published var matchedAddress: String?
    @Published var matchedEventTitle: String?
    @Published var allMatchedAddresses: [(address: String, eventTitle: String, hasGPS: Bool, coordinate: CLLocationCoordinate2D?)] = []

    @Published var logLines: [LogLine] = []

    // Dashboard per-step status
    @Published var stepStatuses: [DashboardStep: StepStatus] = {
        var dict: [DashboardStep: StepStatus] = [:]
        for step in DashboardStep.allCases { dict[step] = .idle }
        return dict
    }()
    @Published var isWatchMode: Bool = false

    // Detailed progress: current merge visualization
    @Published var currentMergeInputURLs: [URL] = []
    @Published var currentMergeOutputURL: URL?
    @Published var currentMergeGroupId: Int?

    var currentBracketGroup: BracketGroup? {
        guard currentBracketIndex < bracketGroups.count else { return nil }
        return bracketGroups[currentBracketIndex]
    }

    var progressText: String {
        guard totalFiles > 0 else { return "" }
        return "Fil \(currentFileIndex) av \(totalFiles)"
    }

    var progressPercent: String {
        guard totalFiles > 0 else { return "0%" }
        let pct = Int((Double(currentFileIndex) / Double(totalFiles)) * 100)
        return "\(pct)%"
    }

    // Standard per-app location for log files, not the user's Desktop —
    // ~/Library/Logs/<App>/ is where Console.app and macOS conventions expect them.
    private static let logFileURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PhotoFlow")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("photoflow.log")
    }()

    /// Kept open for the process lifetime instead of opening/closing the file on
    /// every single log line.
    private static let logFileHandle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logFileURL)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static let logTimestampFormatter = ISO8601DateFormatter()

    /// Also logged via os.Logger so entries show up in Console.app, independent of
    /// whether the in-app log view or the file on disk are checked.
    private static let osLogger = Logger(subsystem: "com.photoflow.app", category: "general")

    func appendLog(_ text: String, type: LogLine.LogType = .info) {
        let line = LogLine(text: text, type: type)
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(100)
        }

        switch type {
        case .info, .success: Self.osLogger.info("\(text, privacy: .public)")
        case .warning: Self.osLogger.warning("\(text, privacy: .public)")
        case .error: Self.osLogger.error("\(text, privacy: .public)")
        }

        // Also write to file for debugging
        let prefix = switch type {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERR "
        case .success: "OK  "
        }
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(prefix) \(text)\n"
        if let data = logLine.data(using: .utf8) {
            Self.logFileHandle?.write(data)
        }
    }

    func reset() {
        // Fas 10: en väntande debounced gallringsskrivning (se
        // `saveCullDecisions()`) får ALDRIG hinna bli irrelevant bara för att
        // pipelinen laddar om en ny/annan session — flusha den gamla sessionens
        // beslut (med det ÄNNU giltiga `outputDirectory`/`allPhotos` nedanför)
        // innan de nollställs.
        flushCullDecisions()
        currentStep = .idle
        progress = 0.0
        currentFileIndex = 0
        totalFiles = 0
        statusMessage = "Välj en mapp med NEF-filer för att börja"
        errorMessage = nil
        isRunning = false
        isPaused = false
        bracketGroups = []
        allPhotos = []
        currentBracketIndex = 0
        currentPhotoIndexInBracket = 0
        currentCullIndex = 0
        logLines = []
        currentMergeInputURLs = []
        currentMergeOutputURL = nil
        currentMergeGroupId = nil
        matchedAddress = nil
        matchedEventTitle = nil
        allMatchedAddresses = []
        isWatchMode = false
        for step in DashboardStep.allCases {
            stepStatuses[step] = .idle
        }
        sessionManifest = nil
        pendingStepFingerprints = [:]
    }

    /// Correct a mismatched address with new name and GPS coordinates
    func correctAddress(at index: Int, newAddress: String, coordinate: CLLocationCoordinate2D) {
        guard index < allMatchedAddresses.count else { return }
        allMatchedAddresses[index] = (address: newAddress, eventTitle: allMatchedAddresses[index].eventTitle, hasGPS: true, coordinate: coordinate)
        appendLog("Adress rättad: \(newAddress) (\(String(format: "%.6f", coordinate.latitude)), \(String(format: "%.6f", coordinate.longitude)))", type: .success)
        // Store corrected coordinates for metadata writing
        correctedCoordinates[newAddress] = coordinate
        // Persist correction (address + lat/lon + a "corrected" flag) to
        // calendar_matches.json so it survives a restart — previously only the
        // address text was written, so re-geocoding on the next load silently
        // threw the manual GPS correction away again.
        saveCalendarMatches()
        invalidateWrittenMetadataIfNeeded()
        syncManifest()
    }

    /// Write current address matches back to calendar_matches.json so corrections survive restarts.
    private func saveCalendarMatches() {
        guard let outputDir = outputDirectory else { return }
        let matchesFile = outputDir.appendingPathComponent("calendar_matches.json")

        // Read existing file to preserve date ranges
        guard let savedData = try? Data(contentsOf: matchesFile),
              var savedJSON = try? JSONSerialization.jsonObject(with: savedData) as? [[String: Any]] else { return }

        // Update addresses (and, when corrected, GPS coordinates) from current in-memory state
        for (index, match) in allMatchedAddresses.enumerated() {
            guard index < savedJSON.count else { continue }
            savedJSON[index]["address"] = match.address
            if let coord = correctedCoordinates[match.address] {
                savedJSON[index]["latitude"] = coord.latitude
                savedJSON[index]["longitude"] = coord.longitude
                savedJSON[index]["corrected"] = true
            }
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: savedJSON, options: .prettyPrinted) {
            try? jsonData.write(to: matchesFile)
        }
    }

    /// If metadata was already written before this correction, the marker must be
    /// removed so `writeIPTCMetadata` runs again next time — otherwise the wrong
    /// GPS/address that prompted the correction would stay baked into the already
    /// tagged files forever.
    private func invalidateWrittenMetadataIfNeeded() {
        guard let outputDir = outputDirectory else { return }
        let marker = outputDir.appendingPathComponent("metadata_written.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        appendLog("Metadata var redan skriven — tar bort markören så den skrivs om med den rättade adressen/GPS-positionen.", type: .warning)
    }

    /// Corrected coordinates from manual address corrections
    var correctedCoordinates: [String: CLLocationCoordinate2D] = [:]

    func updateStep(_ step: DashboardStep, phase: StepPhase) {
        stepStatuses[step]?.phase = phase
        stepStatuses[step]?.lastUpdated = Date()
        if phase == .active {
            stepStatuses[step]?.startedAt = Date()
        }
        syncManifest(step: step)
    }

    func updateStepProgress(_ step: DashboardStep, processed: Int, total: Int) {
        stepStatuses[step]?.processedCount = processed
        stepStatuses[step]?.totalCount = total
        stepStatuses[step]?.phase = .active
        stepStatuses[step]?.lastUpdated = Date()
        syncManifest(step: step)
    }

    func completeStep(_ step: DashboardStep, count: Int = 0) {
        let now = Date()
        if let startedAt = stepStatuses[step]?.startedAt {
            stepStatuses[step]?.lastDuration = now.timeIntervalSince(startedAt)
        }
        stepStatuses[step]?.phase = .complete
        stepStatuses[step]?.processedCount = count
        stepStatuses[step]?.totalCount = count
        stepStatuses[step]?.lastUpdated = now
        syncManifest(step: step)
    }

    // MARK: - Fas 6: sessionsmanifest (photoflow_session.json)

    /// Skapar (läser in/migrerar via `SessionManifestStore.loadOrMigrate`)
    /// manifestet om det inte redan finns i minnet. En no-op om
    /// `outputDirectory` inte är satt än (t.ex. innan användaren valt en
    /// mapp) eller om manifestet redan är inläst.
    private func ensureManifestLoaded() {
        guard sessionManifest == nil, let outputDir = outputDirectory else { return }
        let inputDir = inputDirectory ?? outputDir
        if let loaded = SessionManifestStore.loadOrMigrate(inputDir: inputDir, outputDir: outputDir) {
            sessionManifest = loaded
        } else {
            sessionManifest = SessionManifest(
                schemaVersion: SessionManifest.currentSchemaVersion,
                sessionID: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                inputDirectory: inputDir.path,
                outputDirectory: outputDir.path,
                photoCount: 0,
                groupCount: 0,
                addresses: [],
                steps: [:],
                cullSummary: SessionManifest.CullSummary(accepted: 0, rejected: 0, unreviewed: 0)
            )
        }
    }

    /// Enda stället som skriver `sessionManifest` till disk — anropas från
    /// `updateStep`/`updateStepProgress`/`completeStep` (med `step` satt) och
    /// från `saveCullDecisions`/`correctAddress` (utan `step`, bara för att
    /// uppdatera adresser/gallringssammanfattning). Uppdaterar också
    /// sessionshistorikregistret (`SessionHistoryStore`) så "Historik"-vyn
    /// alltid speglar den senaste kända statusen.
    func syncManifest(step: DashboardStep? = nil) {
        guard let outputDir = outputDirectory else { return }
        ensureManifestLoaded()
        guard var manifest = sessionManifest else { return }

        if let step, let status = stepStatuses[step] {
            var record = manifest.steps[step.manifestKey] ?? SessionManifest.StepRecord(
                stepID: step.manifestKey, phase: "", processedCount: 0, totalCount: 0,
                duration: nil, finishedAt: nil, inputFingerprint: nil
            )
            record.phase = "\(status.phase)"
            record.processedCount = status.processedCount
            record.totalCount = status.totalCount
            record.duration = status.lastDuration
            if status.phase == .complete {
                record.finishedAt = Date()
            }
            if let fingerprint = pendingStepFingerprints[step] {
                record.inputFingerprint = fingerprint
            }
            manifest.steps[step.manifestKey] = record
        }

        manifest.photoCount = allPhotos.count
        manifest.groupCount = bracketGroups.count
        manifest.addresses = allMatchedAddresses.map { match in
            SessionManifest.AddressRecord(
                address: match.address,
                eventTitle: match.eventTitle,
                latitude: match.coordinate?.latitude,
                longitude: match.coordinate?.longitude,
                manuallyCorrected: correctedCoordinates[match.address] != nil
            )
        }
        // Fas 10: läser de cachade räknarna i stället för två `allPhotos.filter`-
        // genomlöpningar — `syncManifest()` anropas synkront från VARJE
        // `updateStep`/`updateStepProgress`/`completeStep`/`saveCullDecisions`,
        // så det här var ytterligare en O(n)-kostnad per tangenttryck under
        // gallring innan cachningen fanns.
        manifest.cullSummary = SessionManifest.CullSummary(
            accepted: acceptedCount, rejected: rejectedCount,
            unreviewed: unreviewedCount
        )
        manifest.inputDirectory = (inputDirectory ?? outputDir).path
        manifest.outputDirectory = outputDir.path
        manifest.updatedAt = Date()

        sessionManifest = manifest
        SessionManifestStore.save(manifest, to: outputDir)
        SessionHistoryStore.record(manifest)
    }

    func appendStepLog(_ step: DashboardStep, _ text: String, type: LogLine.LogType = .info) {
        let line = LogLine(text: text, type: type)
        stepStatuses[step]?.logEntries.append(line)
        // Keep per-step log history bounded — a long-running pipeline could
        // otherwise grow this array without limit across many re-runs.
        if let count = stepStatuses[step]?.logEntries.count, count > 1000 {
            stepStatuses[step]?.logEntries.removeFirst(200)
        }

        // Category = step, so Console.app can filter to one pipeline step.
        let stepLogger = Logger(subsystem: "com.photoflow.app", category: "\(step)")
        switch type {
        case .info, .success: stepLogger.info("\(text, privacy: .public)")
        case .warning: stepLogger.warning("\(text, privacy: .public)")
        case .error: stepLogger.error("\(text, privacy: .public)")
        }

        // Also add to global log
        appendLog("[\(step.title)] \(text)", type: type)
    }

    // MARK: - Persist cull decisions (Fas 10: debounced, se FORBATTRINGAR.md)

    /// Väntande debounced skrivning schemalagd av `saveCullDecisions()` —
    /// avbryts av varje ny `saveCullDecisions()`-anrop (debounce) och av
    /// `flushCullDecisions()`/`clearAllCullDecisions()`/`reset()`.
    private var pendingCullSaveTask: Task<Void, Never>?

    /// 1s — kort nog att kännas "sparat direkt" om man pausar, lång nog att
    /// slå ihop en snabb serie tangenttryck (accept/avvisa/ångra/förslag) till
    /// en enda diskskrivning.
    nonisolated private static let cullSaveDebounceNanoseconds: UInt64 = 1_000_000_000

    /// Schemalägger en debounced skrivning av gallringsbesluten till disk.
    /// Anropas idag från VARJE accept/avvisa/ångra/"Föreslå gallring"
    /// (PreviewCullView/BracketReviewView) — innan Fas 10 serialiserade det
    /// hela beslutsordboken till JSON SYNKRONT på huvudtråden vid varje sådant
    /// anrop (mätt: se FORBATTRINGAR.md "Prestanda vid stora sessioner").
    ///
    /// GARANTIN att inget beslut går förlorat kommer INTE från att den här
    /// timern hinner löpa ut — den kommer från att `flushCullDecisions()`
    /// anropas synkront överallt ett beslut MÅSTE finnas på disk innan nästa
    /// steg tar vid: `PreviewCullView.performFinishCulling()` (innan
    /// `finishCullingAction()` kör), `.onDisappear` i `PreviewCullView`/
    /// `BracketReviewView` (vyn stängs), `reset()` (pipelinen laddar om en ny
    /// session), och `NSApplication.willTerminateNotification` (appen
    /// avslutas) — se `terminationObserver` i `init()`.
    ///
    /// Läser INTE `allPhotos` här (bara vid den faktiska skrivningen, se
    /// `writeCullDecisionsInBackground()`) — annars skulle det tidigare
    /// per-tangenttryck-jobbet (dictionary-bygget) fortfarande köras vid varje
    /// anrop, bara den faktiska diskskrivningen sköts upp. Genom att skjuta
    /// upp ALLT till when timern faktiskt löper ut (om ingen nyare
    /// `saveCullDecisions()`/flush hunnit avbryta den) läses alltid det
    /// SENASTE beslutet, utan risk för en inaktuell ögonblicksbild.
    func saveCullDecisions() {
        pendingCullSaveTask?.cancel()
        pendingCullSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.cullSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.writeCullDecisionsInBackground()
        }
        // Manifestets gallringssammanfattning läser nu de cachade räknarna
        // (O(1), se syncManifest()) så det är billigt nog att hållas synkront
        // och behöver inte vänta på den debouncade diskskrivningen ovan.
        syncManifest()
    }

    /// Läser `allPhotos` (MainActor, O(1) COW-kopiering av arrayreferensen —
    /// inget per-bild-arbete sker här) och gör själva O(n)-arbetet (bygga
    /// beslutsordboken + JSON-serialisera + skriva till disk) på en fristående
    /// bakgrundstask, så varken debounce-timerns avfyrning eller huvudtråden
    /// blockeras av en stor sessions gallringsbeslut.
    private func writeCullDecisionsInBackground() async {
        guard let outputDir = outputDirectory else { return }
        let photos = allPhotos
        await Task.detached(priority: .utility) {
            let decisions = Self.buildCullDecisionsDict(photos)
            Self.writeCullDecisionsDict(decisions, to: outputDir)
        }.value
    }

    /// Skriver gallringsbesluten till disk OMEDELBART, synkront på anropande
    /// tråd, och avbryter en eventuell väntande debounced skrivning från
    /// `saveCullDecisions()`. Medvetet INTE bakgrundad (till skillnad från
    /// `saveCullDecisions()`) — den här anropas bara vid sällsynta
    /// "garanti"-tillfällen (se `saveCullDecisions()`s doc-kommentar), och att
    /// invänta en bakgrundstask precis när appen avslutas riskerar att
    /// processen hinner dö innan skrivningen är klar. Att blockera
    /// huvudtråden i de här enstaka fallen (inte per tangenttryck) för en
    /// JSON-skrivning av ett par tusen poster är i praktiken omärkbart.
    func flushCullDecisions() {
        pendingCullSaveTask?.cancel()
        pendingCullSaveTask = nil
        guard let outputDir = outputDirectory else { return }
        let decisions = Self.buildCullDecisionsDict(allPhotos)
        Self.writeCullDecisionsDict(decisions, to: outputDir)
    }

    // `nonisolated static` — måste INTE hoppa till MainActor eftersom de bara
    // rör lokala (Sendable) parametrar, vilket gör dem säkra att anropa från
    // `Task.detached` i `writeCullDecisionsInBackground()` ovan. Utan
    // `nonisolated` hade de (som alla members av en `@MainActor`-klass, se
    // agent-rules.md Swift 6-fällan) implicit blivit MainActor-isolerade och
    // tvingat en onödig MainActor-hopp mitt i bakgrundsarbetet.
    nonisolated private static func buildCullDecisionsDict(_ photos: [PhotoItem]) -> [String: String] {
        var decisions: [String: String] = [:]
        decisions.reserveCapacity(photos.count)
        // allPhotos is the single source of truth for cull decisions — BracketGroup
        // only stores photoIDs, so there's no second copy to reconcile here anymore.
        for photo in photos {
            if photo.accepted {
                decisions[photo.id] = "accepted"
            } else if photo.rejected {
                decisions[photo.id] = "rejected"
            }
        }
        return decisions
    }

    nonisolated private static func writeCullDecisionsDict(_ decisions: [String: String], to outputDir: URL) {
        let file = outputDir.appendingPathComponent("cull_decisions.json")
        if let data = try? JSONSerialization.data(withJSONObject: decisions, options: .prettyPrinted) {
            try? data.write(to: file)
        }
    }

    func loadCullDecisions() -> [String: String] {
        guard let outputDir = outputDirectory else { return [:] }
        let file = outputDir.appendingPathComponent("cull_decisions.json")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let text: String
    let type: LogType

    enum LogType {
        case info, warning, error, success
    }

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    var timeString: String {
        Self.timeFormatter.string(from: timestamp)
    }
}
