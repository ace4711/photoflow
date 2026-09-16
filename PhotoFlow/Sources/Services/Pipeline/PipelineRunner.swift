import Foundation
import AppKit
import CoreLocation

@MainActor
class PipelineRunner: ObservableObject {
    // Stored properties can't live in extensions, so everything the split-out
    // Pipeline/*.swift extension files need stays here as `internal` (no
    // modifier) rather than `private`.
    let state: PipelineState
    let audio = AudioService.shared
    var currentTask: Process?
    var pipelineLogHandle: FileHandle?

    /// Owns the running pipeline's Task so `cancel()` can actually stop it —
    /// previously `RunnerWrapper.start` created an untracked, un-cancellable Task
    /// and `cancel()` only terminated whatever single Process happened to be
    /// running at that instant, so the pipeline just moved on to its next step.
    var pipelineTask: Task<Void, Never>?

    /// Calendar address mappings for organizing output
    var calendarMappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = []

    /// Cached AI tags: filename -> PhotoTags
    var aiTagResults: [String: VisionTaggingService.PhotoTags] = [:]

    /// Cached Vision quality analysis (Fas 3b): filename -> Result. Populated
    /// by `runAITagging()`/`runVisionQualityAnalysis()`, read back in
    /// `loadBracketGroups` to fill in `PhotoItem`'s quality fields.
    var photoQualityResults: [String: PhotoQualityService.Result] = [:]

    /// Fas 5: en `DateFormatter` per loggrad var en billig men helt
    /// onödig allokering (`pipelineLog` anropas hundratals gånger per
    /// körning) — samma statiska-formatter-mönster som `PipelineState`
    /// redan använder (`LogLine.timeFormatter`, sedan Fas 1a). Bara
    /// `PipelineRunner` (en `@MainActor`-klass) läser/skriver den, så ingen
    /// samtidig mutation är möjlig.
    private static let pipelineLogTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // internal: called from other PipelineRunner extension files.
    func pipelineLog(_ message: String) {
        let line = "[\(Self.pipelineLogTimeFormatter.string(from: Date()))] \(message)\n"
        pipelineLogHandle?.write(line.data(using: .utf8)!)
        pipelineLogHandle?.synchronizeFile()
        state.appendLog(message)
    }

    // MARK: - Decision Log (structured JSONL for debugging across runs)

    /// Se `pipelineLogTimeFormatter` ovan — samma motivering, en ny
    /// `ISO8601DateFormatter` per beslutsrad var onödigt.
    private static let decisionLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Logs a key pipeline decision to `decision_log.jsonl` in the output directory.
    /// Each line is a JSON object with timestamp, step, decision, and context details.
    /// This file persists across runs so we can trace why steps were skipped or re-run.
    // internal: called from other PipelineRunner extension files.
    func logDecision(step: String, decision: String, details: [String: String] = [:]) {
        guard let outputDir = state.outputDirectory else { return }
        let logFile = outputDir.appendingPathComponent("decision_log.jsonl")

        var entry: [String: Any] = [
            "timestamp": Self.decisionLogTimestampFormatter.string(from: Date()),
            "step": step,
            "decision": decision
        ]
        if !details.isEmpty {
            entry["details"] = details
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let line = jsonString + "\n"
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = FileHandle(forWritingAtPath: logFile.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    init(state: PipelineState) {
        self.state = state
    }

    // MARK: - Tool resolution

    // internal: called from other PipelineRunner extension files.
    func requireExiftool() throws -> String {
        guard let path = ToolLocator.exiftool else {
            throw PipelineError.toolNotFound("exiftool saknas. Installera med: brew install exiftool")
        }
        return path
    }

    // internal: called from HDR extension file.
    func requirePython3WithOpenCV() throws -> String {
        guard let path = ToolLocator.python3WithOpenCV else {
            throw PipelineError.toolNotFound("python3 med OpenCV (cv2) och numpy saknas — krävs för HDR-sammanslagning. Installera med: pip3 install opencv-python numpy")
        }
        return path
    }

    /// Starts the pipeline in a Task owned by this runner, so `cancel()` can
    /// actually cancel it (see `pipelineTask`). Callers that previously wrapped
    /// `startPipeline` in their own `Task { }` (RunnerWrapper.start) should call
    /// this instead.
    func start(inputDir: URL, outputDir: URL? = nil) {
        pipelineTask = Task { [weak self] in
            await self?.startPipeline(inputDir: inputDir, outputDir: outputDir)
        }
    }

    func startPipeline(inputDir: URL, outputDir: URL? = nil) async {
        guard !state.isRunning else {
            pipelineLog("Pipeline redan aktiv — ignorerar nytt startanrop (inputDir: \(inputDir.path))")
            return
        }
        state.reset()
        state.inputDirectory = inputDir
        state.outputDirectory = outputDir ?? inputDir.appendingPathComponent("processed")
        state.isRunning = true

        // Mark upcoming steps as queued so cards aren't grey
        let settings = AppSettings.shared
        state.updateStep(.watchSources, phase: .complete)  // Already found files
        state.updateStep(.copyToInput, phase: .queued)
        state.updateStep(.convertToDNG, phase: .queued)
        state.updateStep(.generatePreviews, phase: .queued)
        state.updateStep(.createHDR, phase: settings.hdrMergeEnabled ? .queued : .disabled)
        state.updateStep(.findCalendarInfo, phase: settings.calendarMatchEnabled ? .queued : .disabled)
        state.updateStep(.writeIPTCTags, phase: settings.calendarMatchEnabled ? .queued : .disabled)
        state.updateStep(.aiTagging, phase: settings.aiTaggingEnabled ? .queued : .disabled)
        state.updateStep(.manualReview, phase: .queued)
        state.updateStep(.moveToFolders, phase: .queued)

        // Write pipeline log to output directory
        let logFile = state.outputDirectory!.appendingPathComponent("pipeline.log")
        try? FileManager.default.createDirectory(at: state.outputDirectory!, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        pipelineLogHandle = FileHandle(forWritingAtPath: logFile.path)

        pipelineLog("=== Pipeline startad ===")
        pipelineLog("inputDir: \(inputDir.path)")
        pipelineLog("outputDir: \(state.outputDirectory!.path)")
        pipelineLog("inputDir finns: \(FileManager.default.fileExists(atPath: inputDir.path))")

        logDecision(step: "pipeline", decision: "start", details: [
            "inputDir": inputDir.path,
            "outputDir": state.outputDirectory!.path,
            "hdrEnabled": "\(AppSettings.shared.hdrMergeEnabled)",
            "calendarEnabled": "\(AppSettings.shared.calendarMatchEnabled)",
            "aiTaggingEnabled": "\(AppSettings.shared.aiTaggingEnabled)"
        ])

        let nefFiles = findNEFFiles(in: inputDir)
        pipelineLog("NEF-filer hittade (rekursivt): \(nefFiles.count)")
        for f in nefFiles.prefix(10) {
            pipelineLog("  \(f.lastPathComponent)")
        }
        if nefFiles.count > 10 { pipelineLog("  ... och \(nefFiles.count - 10) till") }

        do {
            // Step: Copy (already done by selecting input dir)
            state.appendStepLog(.copyToInput, "\(nefFiles.count) NEF-filer hittade i \(inputDir.lastPathComponent)")
            state.completeStep(.copyToInput, count: nefFiles.count)

            // Step: Convert NEF -> DNG
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: DNG-konvertering")
            state.updateStep(.convertToDNG, phase: .active)
            try await runDNGConversion(inputDir: inputDir)
            state.completeStep(.convertToDNG, count: nefFiles.count)
            pipelineLog("<<< DNG-konvertering klar")

            // Step: Analyze brackets (grouping — needed even without HDR)
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: Bracket-analys")
            let hdrEnabled = AppSettings.shared.hdrMergeEnabled
            if hdrEnabled {
                state.updateStep(.createHDR, phase: .active)
            }
            try await runBracketAnalysis(inputDir: inputDir)
            pipelineLog("<<< Bracket-analys klar")

            // Step: Generate previews
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: Preview-generering")
            state.updateStep(.generatePreviews, phase: .active)
            try await runPreviewGeneration(inputDir: inputDir)
            state.completeStep(.generatePreviews, count: nefFiles.count)
            pipelineLog("<<< Preview-generering klar")

            // Step: Match photos to calendar bookings
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: Kalendermatchning")
            if AppSettings.shared.calendarMatchEnabled {
                state.updateStep(.findCalendarInfo, phase: .active)
                await matchCalendarBookings()
                state.completeStep(.findCalendarInfo)
                state.updateStep(.writeIPTCTags, phase: .queued)
            } else {
                state.updateStep(.findCalendarInfo, phase: .disabled)
                state.updateStep(.writeIPTCTags, phase: .disabled)
            }
            pipelineLog("<<< Kalendermatchning klar")

            // Step: AI-tag photos + Vision-baserad kvalitetsanalys (Fas 3b)
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: AI-taggning / Vision-analys")
            if AppSettings.shared.aiTaggingEnabled {
                state.updateStep(.aiTagging, phase: .active)
                try await runAITagging()
                state.completeStep(.aiTagging, count: aiTagResults.count)
            } else {
                state.updateStep(.aiTagging, phase: .disabled)
                state.appendStepLog(.aiTagging, "AI-taggning/Vision-analys avaktiverad i installningar", type: .info)
            }
            pipelineLog("<<< AI-taggning / Vision-analys klar")

            try await checkCancellationAndWaitIfPaused()
            if hdrEnabled {
                // Step: Merge HDR brackets
                try await runHDRMerge()
                state.completeStep(.createHDR)
            } else {
                state.updateStep(.createHDR, phase: .disabled)
                state.appendStepLog(.createHDR, "HDR-merge avaktiverad i inställningar", type: .info)
            }

            pipelineLog(">>> Steg: Laddar bracket-grupper")
            try await loadBracketGroups()
            pipelineLog("<<< Bracket-grupper laddade")

            // Step: Sort files into address folders (before review)
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: Sortera filer till adressmappar")
            state.updateStep(.moveToFolders, phase: .active)
            await exportToAddressFolders()
            // exportToAddressFolders can return early on cancellation (it already
            // marked its own step + log for that); don't stomp that by unconditionally
            // marking it complete right after.
            try Task.checkCancellation()
            state.completeStep(.moveToFolders)
            pipelineLog("<<< Filsortering klar")

            // Step: Write metadata (GPS, IPTC, AI-tags) to sorted files
            try await checkCancellationAndWaitIfPaused()
            pipelineLog(">>> Steg: Skriv metadata")
            if AppSettings.shared.calendarMatchEnabled {
                state.updateStep(.writeIPTCTags, phase: .active)
                await writeIPTCMetadata()
                // Same reasoning as exportToAddressFolders above: don't overwrite an
                // early-cancellation marker with "complete".
                try Task.checkCancellation()
                state.completeStep(.writeIPTCTags)
            } else {
                state.updateStep(.writeIPTCTags, phase: .disabled)
                state.appendStepLog(.writeIPTCTags, "Metadata-skrivning avaktiverad (ingen kalendermatchning)", type: .info)
            }
            pipelineLog("<<< Metadata klar")

            // Pipeline done — review/culling is optional from here
            state.updateStep(.manualReview, phase: .needsAttention)
            let photoCount = state.allPhotos.count
            let groupCount = state.bracketGroups.count
            state.appendStepLog(.manualReview, "Filer sorterade — \(groupCount) grupper, \(photoCount) bilder redo för valfri granskning")
            state.currentStep = hdrEnabled ? .reviewingBrackets : .culling
            state.statusMessage = "Filer sorterade i adressmappar — granska vid behov"
            state.isRunning = false
            audio.playNeedsAttention()
            NotificationService.shared.notifyReviewReady()

        } catch is CancellationError {
            state.statusMessage = "Avbrutet"
            state.isRunning = false
            state.isPaused = false
            markActiveStepsCancelled()
        } catch {
            state.errorMessage = error.localizedDescription
            state.statusMessage = "Fel: \(error.localizedDescription)"
            state.isRunning = false
            state.appendLog(error.localizedDescription, type: .error)
            audio.playError()
            NotificationService.shared.notifyError(error.localizedDescription)
        }
    }

    func cancel() {
        // Cancels the owning Task — runProcess's withTaskCancellationHandler
        // terminates whatever Process is currently running (or refuses to start
        // the next one), and every checkCancellation()/waitIfPaused() call point
        // between steps and inside chunk loops turns that into a CancellationError
        // that unwinds startPipeline's `do` block (see its `catch is
        // CancellationError`). Also terminate any in-flight process directly as a
        // belt-and-suspenders fallback.
        pipelineTask?.cancel()
        currentTask?.terminate()
        state.isPaused = false
        state.isRunning = false
        state.statusMessage = "Avbrutet av användaren"
    }

    func togglePause() {
        state.isPaused.toggle()
        if state.isPaused {
            state.appendLog("Pipeline pausad.", type: .warning)
        } else {
            state.appendLog("Pipeline återupptagen.", type: .info)
        }
    }

    /// Re-run a single pipeline step
    func rerunStep(_ step: DashboardStep) async {
        guard let inputDir = state.inputDirectory else {
            state.appendLog("Kan inte kora om — ingen inputmapp.", type: .error)
            return
        }

        logDecision(step: "\(step)", decision: "rerun_triggered")
        state.appendStepLog(step, "Kor om steget...")
        state.updateStep(step, phase: .active)

        do {
            switch step {
            case .convertToDNG:
                // Delete existing DNG folder to force reconversion
                if let outputDir = state.outputDirectory {
                    let dngDir = outputDir.appendingPathComponent("dng")
                    try? FileManager.default.removeItem(at: dngDir)
                }
                try await runDNGConversion(inputDir: inputDir)
                state.completeStep(step, count: state.totalFiles)

            case .createHDR:
                // Delete artifacts to force re-analysis and re-merge
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("bracket_groups.json"))
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("exif_data.csv"))
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("hdr"))
                }
                try await runBracketAnalysis(inputDir: inputDir)
                try await runHDRMerge()
                try await loadBracketGroups()
                state.completeStep(step)

            case .findCalendarInfo:
                // Delete saved matches to force re-match
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("calendar_matches.json"))
                }
                await matchCalendarBookings()
                state.completeStep(step)

            case .writeIPTCTags:
                // Rensa marker så steget körs om
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
                }
                await writeIPTCMetadata()
                state.completeStep(step)

            case .aiTagging:
                // Delete saved tags/quality analysis to force re-run of both
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("ai_tags.json"))
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("photo_quality.json"))
                }
                try await runAITagging()
                state.completeStep(step)

            case .manualReview:
                try await loadBracketGroups()
                state.updateStep(step, phase: .needsAttention)
                state.currentStep = .reviewingBrackets
                state.appendLog("Redo for granskning.", type: .success)
                return

            case .moveToFolders:
                // Rensa marker så steget körs om
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("files_sorted.json"))
                }
                await exportToAddressFolders()
                state.completeStep(step)

            case .importToLightroom:
                await sendToLightroom(groups: state.bracketGroups)
                state.completeStep(step)

            default:
                state.appendLog("\(step.title) kan inte koras om manuellt.", type: .warning)
                state.updateStep(step, phase: .complete)
                return
            }
            state.appendStepLog(step, "Klar", type: .success)
        } catch {
            state.updateStep(step, phase: .error(error.localizedDescription))
            state.appendStepLog(step, "Fel: \(error.localizedDescription)", type: .error)
        }
    }

    /// Waits while pipeline is paused. Call between work units. Also breaks out
    /// (without un-pausing) as soon as the surrounding Task is cancelled, so a
    /// cancel while paused doesn't spin forever waiting for a resume that will
    /// never come.
    func waitIfPaused() async {
        while state.isPaused && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

    /// Throwing convenience for use between work units in `throws` functions:
    /// bail out immediately if cancelled, otherwise wait out any pause, then
    /// check cancellation again (a cancel while paused should still stop us
    /// before the next unit of work starts).
    func checkCancellationAndWaitIfPaused() async throws {
        try Task.checkCancellation()
        await waitIfPaused()
        try Task.checkCancellation()
    }

    /// Non-throwing equivalent for `async` (non-`throws`) functions: waits out
    /// any pause, then reports whether the caller should abort.
    func shouldAbort() async -> Bool {
        if Task.isCancelled { return true }
        await waitIfPaused()
        return Task.isCancelled
    }

    /// Marks whichever step(s) were `.active` as idle with an "Avbrutet" log line,
    /// instead of leaving a step's card stuck showing "Arbetar..." forever after a
    /// cancel. Called from `startPipeline`'s `catch is CancellationError` and from
    /// non-throwing steps that notice cancellation via `shouldAbort()`.
    func markActiveStepsCancelled() {
        for step in DashboardStep.allCases where state.stepStatuses[step]?.phase == .active {
            state.updateStep(step, phase: .idle)
            state.appendStepLog(step, "Avbrutet", type: .warning)
        }
    }

    /// Recursively find all NEF files under a directory, sorted by filename.
    /// Excludes output directories and pipeline artifacts to avoid duplicates.
    /// Bump when the metadata-writing logic changes in a way that would make
    /// previously-written `metadata_written.json` markers untrustworthy (e.g. the
    /// DNG-folder-suffix fix and the NEF-symlink/XMP-sidecar fix). Markers without
    /// a matching version are treated as stale and metadata is written again.
    static let metadataMarkerVersion = 2

    private static let excludedDirNames: Set<String> = [
        "processed", "bracket_groups", "dng", "hdr", "previews"
    ]

    func findNEFFiles(in directory: URL) -> [URL] {
        let outputDir = state.outputDirectory
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            // Skip output directory
            if let outputDir, url.path.hasPrefix(outputDir.path) {
                enumerator.skipDescendants()
                continue
            }
            // Skip known pipeline artifact directories
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir && Self.excludedDirNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.uppercased() == "NEF" {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Recursively find all files with the given extension under a directory.
    /// Synchronous, so it's safe to call an NSEnumerator's iterator from
    /// async contexts (FileManager.enumerator's makeIterator is unavailable there).
    static func findFiles(withExtension ext: String, in directory: URL) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == ext.lowercased() {
                result.append(fileURL)
            }
        }
        return result
    }
}

enum PipelineError: LocalizedError {
    case toolNotFound(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let msg): return msg
        case .processError(let msg): return "Process-fel: \(msg)"
        }
    }
}
