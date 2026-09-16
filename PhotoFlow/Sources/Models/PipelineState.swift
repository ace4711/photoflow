import Foundation
import Combine
import CoreLocation
import os

@MainActor
class PipelineState: ObservableObject {
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

    @Published var inputDirectory: URL?
    @Published var outputDirectory: URL?

    @Published var bracketGroups: [BracketGroup] = []
    @Published var allPhotos: [PhotoItem] = [] {
        didSet { rebuildPhotoIndex() }
    }

    /// O(1) lookup from `PhotoItem.id` to its index in `allPhotos`, kept in sync
    /// via `allPhotos`'s `didSet`. `allPhotos` is the single source of truth for
    /// cull decisions — `BracketGroup` only stores `photoIDs`, resolved through
    /// this index by `photos(in:)`.
    private var photoIndexByID: [String: Int] = [:]

    private func rebuildPhotoIndex() {
        photoIndexByID = Dictionary(uniqueKeysWithValues: allPhotos.enumerated().map { ($1.id, $0) })
    }

    /// Resolves a group's photos from `allPhotos`, in the group's original order.
    /// IDs with no match in `allPhotos` (shouldn't normally happen) are skipped.
    func photos(in group: BracketGroup) -> [PhotoItem] {
        group.photoIDs.compactMap { photoIndexByID[$0].map { allPhotos[$0] } }
    }

    /// Sets a photo's accept/reject decision by ID. Since `allPhotos` is the only
    /// place decisions are stored, this is the one function both BracketReviewView
    /// and PreviewCullView should call to change a decision.
    func setDecision(photoID: String, accepted: Bool, rejected: Bool) {
        guard let idx = photoIndexByID[photoID] else { return }
        allPhotos[idx].accepted = accepted
        allPhotos[idx].rejected = rejected
    }

    func setAlgorithmSuggested(photoID: String, suggested: Bool) {
        guard let idx = photoIndexByID[photoID] else { return }
        allPhotos[idx].algorithmSuggested = suggested
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
    }

    func updateStepProgress(_ step: DashboardStep, processed: Int, total: Int) {
        stepStatuses[step]?.processedCount = processed
        stepStatuses[step]?.totalCount = total
        stepStatuses[step]?.phase = .active
        stepStatuses[step]?.lastUpdated = Date()
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

    // MARK: - Persist cull decisions

    func saveCullDecisions() {
        guard let outputDir = outputDirectory else { return }
        let file = outputDir.appendingPathComponent("cull_decisions.json")
        var decisions: [String: String] = [:]

        // allPhotos is the single source of truth for cull decisions — BracketGroup
        // only stores photoIDs, so there's no second copy to reconcile here anymore.
        for photo in allPhotos {
            if photo.accepted {
                decisions[photo.id] = "accepted"
            } else if photo.rejected {
                decisions[photo.id] = "rejected"
            }
        }

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
