import Foundation
import AppKit

@MainActor
class PipelineRunner: ObservableObject {
    private let state: PipelineState
    private let audio = AudioService.shared
    private var currentTask: Process?
    private var pipelineLogHandle: FileHandle?

    private func pipelineLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        pipelineLogHandle?.write(line.data(using: .utf8)!)
        pipelineLogHandle?.synchronizeFile()
        state.appendLog(message)
    }

    // MARK: - Decision Log (structured JSONL for debugging across runs)

    /// Logs a key pipeline decision to `decision_log.jsonl` in the output directory.
    /// Each line is a JSON object with timestamp, step, decision, and context details.
    /// This file persists across runs so we can trace why steps were skipped or re-run.
    private func logDecision(step: String, decision: String, details: [String: String] = [:]) {
        guard let outputDir = state.outputDirectory else { return }
        let logFile = outputDir.appendingPathComponent("decision_log.jsonl")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entry: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
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

    func loadExistingSession(inputDir: URL, outputDir: URL? = nil) async {
        state.reset()
        state.inputDirectory = inputDir
        state.outputDirectory = outputDir ?? inputDir.appendingPathComponent("processed")

        do {
            try await loadBracketGroups()
            state.currentStep = .reviewingBrackets
            state.statusMessage = "Granska bracket-grupper och välj bilder för HDR"
            audio.playNeedsAttention()
        } catch {
            state.errorMessage = error.localizedDescription
            state.appendLog(error.localizedDescription, type: .error)
            audio.playError()
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
            pipelineLog(">>> Steg: DNG-konvertering")
            state.updateStep(.convertToDNG, phase: .active)
            try await runDNGConversion(inputDir: inputDir)
            state.completeStep(.convertToDNG, count: nefFiles.count)
            pipelineLog("<<< DNG-konvertering klar")

            // Step: Analyze brackets (grouping — needed even without HDR)
            pipelineLog(">>> Steg: Bracket-analys")
            let hdrEnabled = AppSettings.shared.hdrMergeEnabled
            if hdrEnabled {
                state.updateStep(.createHDR, phase: .active)
            }
            try await runBracketAnalysis(inputDir: inputDir)
            pipelineLog("<<< Bracket-analys klar")

            // Step: Generate previews
            pipelineLog(">>> Steg: Preview-generering")
            state.updateStep(.generatePreviews, phase: .active)
            try await runPreviewGeneration(inputDir: inputDir)
            state.completeStep(.generatePreviews, count: nefFiles.count)
            pipelineLog("<<< Preview-generering klar")

            // Step: Match photos to calendar bookings
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

            // Step: AI-tag photos (temporarily disabled to unblock pipeline)
            // TODO: Re-enable AI tagging once pipeline flow is verified end-to-end
            do {
                state.updateStep(.aiTagging, phase: .disabled)
                state.appendStepLog(.aiTagging, "AI-taggning temporärt avaktiverad", type: .info)
            }

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
            pipelineLog(">>> Steg: Sortera filer till adressmappar")
            state.updateStep(.moveToFolders, phase: .active)
            await exportToAddressFolders()
            state.completeStep(.moveToFolders)
            pipelineLog("<<< Filsortering klar")

            // Step: Write metadata (GPS, IPTC, AI-tags) to sorted files
            pipelineLog(">>> Steg: Skriv metadata")
            if AppSettings.shared.calendarMatchEnabled {
                state.updateStep(.writeIPTCTags, phase: .active)
                await writeIPTCMetadata()
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

        } catch is CancellationError {
            state.statusMessage = "Avbrutet"
            state.isRunning = false
        } catch {
            state.errorMessage = error.localizedDescription
            state.statusMessage = "Fel: \(error.localizedDescription)"
            state.isRunning = false
            state.appendLog(error.localizedDescription, type: .error)
            audio.playError()
        }
    }

    func cancel() {
        currentTask?.terminate()
        state.isRunning = false
        state.isPaused = false
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
                // Delete saved tags to force re-tagging
                if let outputDir = state.outputDirectory {
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("ai_tags.json"))
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

    /// Waits while pipeline is paused. Call between work units.
    private func waitIfPaused() async {
        while state.isPaused {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

    /// Recursively find all NEF files under a directory, sorted by filename.
    /// Excludes output directories and pipeline artifacts to avoid duplicates.
    private static let excludedDirNames: Set<String> = [
        "processed", "bracket_groups", "dng", "hdr", "previews"
    ]

    private func findNEFFiles(in directory: URL) -> [URL] {
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

    // MARK: - Step 1: DNG Conversion

    private func runDNGConversion(inputDir: URL) async throws {
        state.currentStep = .convertingDNG
        pipelineLog("--- Steg 1: DNG-konvertering ---")
        pipelineLog("inputDir: \(inputDir.path)")

        guard let outputDir = state.outputDirectory else { throw PipelineError.toolNotFound("Ingen outputmapp") }
        let dngDir = outputDir.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        pipelineLog("dngDir: \(dngDir.path)")

        let nefFiles = findNEFFiles(in: inputDir)
        pipelineLog("NEF-filer hittade (rekursivt): \(nefFiles.count)")
        if nefFiles.isEmpty {
            pipelineLog("VARNING: Inga NEF-filer hittades!")
        }

        state.totalFiles = nefFiles.count
        state.statusMessage = "Konverterar \(nefFiles.count) NEF-filer till DNG..."

        // Check which DNG files already exist — search entire output dir (files may be in dng/ or address folders)
        var existingDNGNames = Set<String>()
        if let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "dng" {
                    existingDNGNames.insert(fileURL.deletingPathExtension().lastPathComponent.lowercased())
                }
            }
        }
        let nefNames = Set(nefFiles.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
        let missingDNG = nefNames.subtracting(existingDNGNames)

        if missingDNG.isEmpty {
            logDecision(step: "dng_conversion", decision: "skipped", details: [
                "reason": "all_exist",
                "existingCount": "\(existingDNGNames.count)",
                "nefCount": "\(nefFiles.count)",
                "dngDir": dngDir.path
            ])
            state.appendStepLog(.convertToDNG, "Alla \(nefFiles.count) DNG-filer finns redan — hoppar över", type: .info)
            state.appendLog("DNG-konvertering redan klar (\(nefFiles.count) filer) — hoppar över.", type: .info)
            state.currentFileIndex = nefFiles.count
            state.progress = 1.0
            return
        }
        logDecision(step: "dng_conversion", decision: "converting", details: [
            "missingCount": "\(missingDNG.count)",
            "existingCount": "\(existingDNGNames.count)",
            "nefCount": "\(nefFiles.count)",
            "dngDir": dngDir.path
        ])
        state.appendStepLog(.convertToDNG, "Konverterar \(missingDNG.count) av \(nefFiles.count) NEF → DNG (befintliga: \(existingDNGNames.count))")

        let converterPath = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"

        guard FileManager.default.fileExists(atPath: converterPath) else {
            throw PipelineError.toolNotFound("Adobe DNG Converter saknas. Installera från Adobe.")
        }

        // Convert only NEF files that don't have a corresponding DNG yet
        let filesToConvert = nefFiles.filter { nef in
            missingDNG.contains(nef.deletingPathExtension().lastPathComponent.lowercased())
        }
        let filePaths = filesToConvert.map { $0.path }

        state.updateStepProgress(.convertToDNG, processed: existingDNGNames.count, total: nefFiles.count)

        // Process in chunks for continuous progress updates
        let chunkSize = 50
        let chunks = stride(from: 0, to: filePaths.count, by: chunkSize).map {
            Array(filePaths[$0..<min($0 + chunkSize, filePaths.count)])
        }

        var convertedSoFar = existingDNGNames.count
        for chunk in chunks {
            _ = try await runProcess(
                executablePath: converterPath,
                arguments: ["-c", "-d", dngDir.path] + chunk
            ) { _ in }

            convertedSoFar += chunk.count
            state.currentFileIndex = convertedSoFar
            state.progress = Double(convertedSoFar) / Double(nefFiles.count)
            state.updateStepProgress(.convertToDNG, processed: convertedSoFar, total: nefFiles.count)
            state.appendStepLog(.convertToDNG, "Konverterade \(convertedSoFar)/\(nefFiles.count)...")
        }

        let finalDNGFiles = try FileManager.default.contentsOfDirectory(at: dngDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dng" }
        let finalCount = finalDNGFiles.count

        // Log each converted file
        for dngFile in finalDNGFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let wasExisting = existingDNGNames.contains(dngFile.deletingPathExtension().lastPathComponent.lowercased())
            if !wasExisting {
                state.appendStepLog(.convertToDNG, "✓ \(dngFile.lastPathComponent)")
            }
        }

        state.currentFileIndex = finalCount
        state.progress = 1.0
        state.appendLog("DNG-konvertering klar: \(finalCount) filer.", type: .success)
        audio.playStepComplete()
    }

    // MARK: - Step 2: Bracket Analysis

    private func runBracketAnalysis(inputDir: URL) async throws {
        state.currentStep = .analyzingBrackets
        state.statusMessage = "Analyserar EXIF-data och detekterar brackets..."
        state.progress = 0.0

        guard let outputDir = state.outputDirectory else { throw PipelineError.toolNotFound("Ingen outputmapp") }

        // Skip if bracket_groups.json already exists with matching file count
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        let nefFiles = findNEFFiles(in: inputDir)
        if FileManager.default.fileExists(atPath: groupsJSON.path) {
            if let data = try? Data(contentsOf: groupsJSON),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let totalImages = json["total_images"] as? Int,
               totalImages == nefFiles.count {
                logDecision(step: "bracket_analysis", decision: "skipped", details: [
                    "reason": "json_exists_matching_count",
                    "totalImages": "\(totalImages)",
                    "nefCount": "\(nefFiles.count)"
                ])
                state.appendStepLog(.createHDR, "Bracket-analys redan klar (\(totalImages) filer) — hoppar over", type: .info)
                state.appendLog("Bracket-analys redan klar — hoppar over.", type: .info)
                // Still log group details
                if let groups = json["groups"] as? [[String: Any]] {
                    let bracketCount = groups.filter { ($0["is_bracket"] as? Bool) == true }.count
                    let singleCount = groups.count - bracketCount
                    state.appendStepLog(.createHDR, "\(groups.count) grupper: \(bracketCount) brackets, \(singleCount) singlar", type: .success)
                }
                state.progress = 1.0
                return
            }
        }

        state.appendLog("Analyserar EXIF-data...", type: .info)

        let groupsDir = outputDir.appendingPathComponent("bracket_groups")
        try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

        // Use exiftool to extract EXIF data — pass paths via stdin (-@ -) to avoid
        // argument-list limits and hangs with large file counts
        let exifCSV = outputDir.appendingPathComponent("exif_data.csv")
        let nefPathsList = nefFiles.map { $0.path }.joined(separator: "\n")

        pipelineLog("  bracket: startar exiftool...")
        _ = try await runProcess(
            executablePath: "/opt/homebrew/bin/exiftool",
            arguments: ["-csv", "-FileName", "-ExposureTime", "-FNumber", "-ISO",
                        "-DateTimeOriginal", "-SubSecTimeOriginal",
                        "-ExposureCompensation", "-ShutterCount", "-@", "-"],
            outputFile: exifCSV,
            stdinData: nefPathsList.data(using: .utf8)
        )
        pipelineLog("  bracket: exiftool klar")

        state.progress = 0.5

        // Run Python bracket analysis
        pipelineLog("  bracket: startar python bracket-analys...")
        let pythonScript = bracketAnalysisPython()

        _ = try await runProcess(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", pythonScript, exifCSV.path, groupsJSON.path, "15", "3"]
        )
        pipelineLog("  bracket: python bracket-analys klar")

        // Create symlinked bracket group folders
        pipelineLog("  bracket: startar python organize...")
        let organizeScript = organizeGroupsPython()
        _ = try await runProcess(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", organizeScript, groupsJSON.path, inputDir.path,
                        outputDir.appendingPathComponent("dng").path, groupsDir.path]
        )
        pipelineLog("  bracket: python organize klar")

        // Log summary of detected groups (avoid per-group spam that bogs down UI)
        if let groupData = try? Data(contentsOf: groupsJSON),
           let groupJson = try? JSONSerialization.jsonObject(with: groupData) as? [String: Any],
           let detectedGroups = groupJson["groups"] as? [[String: Any]] {
            let bracketCount = detectedGroups.filter { ($0["is_bracket"] as? Bool) == true }.count
            let singleCount = detectedGroups.count - bracketCount
            state.appendStepLog(.createHDR, "\(detectedGroups.count) grupper: \(bracketCount) brackets, \(singleCount) singlar", type: .success)
        }

        state.progress = 1.0
        state.appendLog("Bracket-analys klar.", type: .success)
        audio.playStepComplete()
    }

    // MARK: - Step 2.5: Calendar Matching

    /// Calendar address mappings for organizing output
    private var calendarMappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = []

    private func matchCalendarBookings() async {
        guard let outputDir = state.outputDirectory else { return }

        // Check if calendar_matches.json already exists
        let matchesFile = outputDir.appendingPathComponent("calendar_matches.json")
        if let savedData = try? Data(contentsOf: matchesFile),
           let savedJSON = try? JSONSerialization.jsonObject(with: savedData) as? [[String: Any]],
           !savedJSON.isEmpty {
            // Load from disk
            let dateFormatter = ISO8601DateFormatter()
            calendarMappings = []
            state.allMatchedAddresses = []
            for entry in savedJSON {
                guard let address = entry["address"] as? String,
                      let eventTitle = entry["event_title"] as? String,
                      let startStr = entry["range_start"] as? String,
                      let endStr = entry["range_end"] as? String,
                      let start = dateFormatter.date(from: startStr),
                      let end = dateFormatter.date(from: endStr) else { continue }
                calendarMappings.append((address: address, eventTitle: eventTitle, photoDateRange: start...end))
                state.allMatchedAddresses.append((address: address, eventTitle: eventTitle, hasGPS: false, coordinate: nil))
            }
            state.matchedAddress = state.allMatchedAddresses.first?.address
            state.matchedEventTitle = state.allMatchedAddresses.first?.eventTitle
            logDecision(step: "calendar_match", decision: "skipped", details: [
                "reason": "json_exists",
                "matchCount": "\(calendarMappings.count)"
            ])
            state.appendStepLog(.findCalendarInfo, "Kalendermatchningar redan sparade (\(calendarMappings.count) st) — hoppar over", type: .info)
            state.appendLog("Kalendermatchning redan klar — laddar fran calendar_matches.json.", type: .info)
            for mapping in calendarMappings {
                state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle)", type: .success)
            }
            // Geocode cached addresses to show GPS status
            let calendar = CalendarService.shared
            _ = await calendar.requestAccess()
            for (idx, mapping) in calendarMappings.enumerated() {
                let coord = await calendar.geocodeAddress(mapping.address)
                if let coord {
                    state.appendStepLog(.findCalendarInfo, "GPS hittad: \"\(mapping.address)\" → \(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))", type: .success)
                    if idx < state.allMatchedAddresses.count {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    state.appendStepLog(.findCalendarInfo, "GPS saknas: \"\(mapping.address)\" — kunde inte geokoda", type: .warning)
                }
            }
            return
        }

        let calendar = CalendarService.shared

        state.appendLog("Matchar bilder mot kalenderbokningar...", type: .info)

        let granted = await calendar.requestAccess()
        guard granted else {
            state.appendLog("Ingen kalenderåtkomst — hoppar över adressmatchning.", type: .warning)
            return
        }

        // Read photo dates from bracket_groups.json
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard let data = try? Data(contentsOf: groupsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var photoDates: [Date] = []
        for group in groups {
            if let dateStr = group["date_start"] as? String,
               let date = dateFormatter.date(from: dateStr) {
                photoDates.append(date)
            }
        }

        state.appendStepLog(.findCalendarInfo, "\(photoDates.count) fotodatum extraherade fran \(groups.count) grupper")

        guard !photoDates.isEmpty else {
            state.appendStepLog(.findCalendarInfo, "Inga fotodatum — hoppar over", type: .warning)
            return
        }

        calendarMappings = calendar.matchPhotosToAddresses(photoDates: photoDates)

        if calendarMappings.isEmpty {
            state.appendLog("Inga matchande kalenderbokningar hittades.", type: .info)
            state.appendStepLog(.findCalendarInfo, "Inga kalenderbokningar matchade nagot fotodatum", type: .warning)
        } else {
            state.allMatchedAddresses = []
            for mapping in calendarMappings {
                state.appendLog("Kalender: \"\(mapping.address)\" (\(mapping.eventTitle))", type: .success)
                let rangeFmt = DateFormatter()
                rangeFmt.dateFormat = "HH:mm"
                let rangeStr = "\(rangeFmt.string(from: mapping.photoDateRange.lowerBound))–\(rangeFmt.string(from: mapping.photoDateRange.upperBound))"
                state.appendStepLog(.findCalendarInfo, "Match: \"\(mapping.address)\" — \(mapping.eventTitle) (foton \(rangeStr))", type: .success)
                state.allMatchedAddresses.append((address: mapping.address, eventTitle: mapping.eventTitle, hasGPS: false, coordinate: nil))
            }
            state.matchedAddress = state.allMatchedAddresses.first?.address
            state.matchedEventTitle = state.allMatchedAddresses.first?.eventTitle
            pipelineLog("Kalender-matchningar: \(calendarMappings.count)")

            // Geocode addresses and report GPS status on this step card
            for (idx, mapping) in calendarMappings.enumerated() {
                let coord = await calendar.geocodeAddress(mapping.address)
                if let coord {
                    state.appendStepLog(.findCalendarInfo, "GPS hittad: \"\(mapping.address)\" → \(String(format: "%.4f", coord.latitude)), \(String(format: "%.4f", coord.longitude))", type: .success)
                    if idx < state.allMatchedAddresses.count {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    state.appendStepLog(.findCalendarInfo, "GPS saknas: \"\(mapping.address)\" — kunde inte geokoda", type: .warning)
                }
            }

            // Save to JSON for persistence
            let isoFormatter = ISO8601DateFormatter()
            let matchArray: [[String: Any]] = calendarMappings.map { mapping in
                [
                    "address": mapping.address,
                    "event_title": mapping.eventTitle,
                    "range_start": isoFormatter.string(from: mapping.photoDateRange.lowerBound),
                    "range_end": isoFormatter.string(from: mapping.photoDateRange.upperBound)
                ]
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: matchArray, options: .prettyPrinted) {
                try? jsonData.write(to: matchesFile)
            }
        }
    }

    /// Organize all files into address-named folders.
    func exportToAddressFolders() async {
        guard let outputDir = state.outputDirectory else { return }

        // Check if sorting has already been done
        let sortMarkerFile = outputDir.appendingPathComponent("files_sorted.json")
        if FileManager.default.fileExists(atPath: sortMarkerFile.path),
           let data = try? Data(contentsOf: sortMarkerFile),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedCount = saved["photos_sorted"] as? Int,
           savedCount == state.allPhotos.count {
            logDecision(step: "move_to_folders", decision: "skipped", details: [
                "reason": "marker_exists",
                "photosSorted": "\(savedCount)"
            ])
            state.appendStepLog(.moveToFolders, "Filer redan sorterade (\(savedCount) bilder) — hoppar över", type: .info)
            state.appendLog("Filsortering redan klar — hoppar över.", type: .info)
            return
        }

        state.currentStep = .sortingFiles
        state.statusMessage = "Sorterar filer i adressmappar..."

        let calendar = CalendarService.shared
        let fm = FileManager.default

        if calendarMappings.isEmpty {
            state.appendStepLog(.moveToFolders, "Inga kalendermatchningar — alla bilder sorteras till \"Osorterade\"", type: .warning)
        }

        state.appendLog("Organiserar filer i adressmappar...", type: .info)

        // Geocode all unique addresses and build metadata per address
        var addressMeta: [String: (lat: Double, lon: Double, bookingInfo: String?)] = [:]
        for mapping in calendarMappings {
            let address = calendar.addressFolder(for: mapping.photoDateRange.lowerBound, mappings: calendarMappings) ?? mapping.address
            if addressMeta[address] == nil {
                let coord = await calendar.geocodeAddress(mapping.address)
                let bookingInfo = CalendarService.extractBookingInfo(from: mapping.eventTitle)
                if let coord {
                    addressMeta[address] = (lat: coord.latitude, lon: coord.longitude, bookingInfo: bookingInfo)
                    state.appendLog("Geokodade \"\(mapping.address)\" → \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))", type: .success)
                    state.appendStepLog(.moveToFolders, "Geokodad: \"\(mapping.address)\" → \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))")
                    // Update GPS status and coordinate in address banner
                    if let idx = state.allMatchedAddresses.firstIndex(where: { $0.address == mapping.address }) {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    addressMeta[address] = (lat: 0, lon: 0, bookingInfo: bookingInfo)
                    state.appendLog("Kunde inte geokoda \"\(mapping.address)\" — GPS-data utelämnas.", type: .warning)
                    state.appendStepLog(.moveToFolders, "Geokodning misslyckades: \"\(mapping.address)\"", type: .warning)
                }
            }
        }

        // Kopiera alla foton (sortering sker före gallring)
        let photosToOrganize = state.allPhotos
        var organized = 0
        var unmatched = 0
        var taggedFiles: [String] = []

        let maxConcurrentCopy = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        state.appendStepLog(.moveToFolders, "Sorterar \(photosToOrganize.count) bilder till adressmappar (\(maxConcurrentCopy) parallella)...")
        state.updateStepProgress(.moveToFolders, processed: 0, total: photosToOrganize.count)
        pipelineLog("exportToAddressFolders: \(photosToOrganize.count) bilder, outputDir=\(outputDir.path)")

        // Pre-create all needed directories (must be done before parallel copies)
        var photoFolders: [(photo: PhotoItem, folderName: String)] = []
        for photo in photosToOrganize {
            let folderName: String
            if let matched = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) {
                folderName = matched
            } else {
                folderName = "Osorterade"
                unmatched += 1
            }
            photoFolders.append((photo: photo, folderName: folderName))

            let previewDir = outputDir.appendingPathComponent("\(folderName) TITTBILDER")
            let dngDir = outputDir.appendingPathComponent(folderName)
            let extrasDir = outputDir.appendingPathComponent("\(folderName) ÖVRIGA")
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dngDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: extrasDir, withIntermediateDirectories: true)
        }

        // Create symlinks for all files into address folders (fast, no heavy I/O)
        for (index, (photo, folderName)) in photoFolders.enumerated() {
            let previewDestDir = outputDir.appendingPathComponent("\(folderName) TITTBILDER")
            let dngDestDir = outputDir.appendingPathComponent(folderName)
            let extrasDestDir = outputDir.appendingPathComponent("\(folderName) ÖVRIGA")
            var linkedFiles = 0

            // Symlink preview JPEG → TITTBILDER
            if let previewURL = photo.previewURL, fm.fileExists(atPath: previewURL.path) {
                let dest = previewDestDir.appendingPathComponent(previewURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: previewURL)
                }
                linkedFiles += 1
            }

            // Symlink DNG → address folder
            if let dngURL = photo.dngURL, fm.fileExists(atPath: dngURL.path) {
                let dest = dngDestDir.appendingPathComponent(dngURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: dngURL)
                }
                linkedFiles += 1
            }

            // Symlink original NEF → ÖVRIGA
            if fm.fileExists(atPath: photo.nefURL.path) {
                let dest = extrasDestDir.appendingPathComponent(photo.nefURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: photo.nefURL)
                }
                linkedFiles += 1
            }

            if linkedFiles > 0 {
                state.appendStepLog(.moveToFolders, "\(photo.filename) → \(folderName)/ (\(linkedFiles) symlinks)")
            } else {
                state.appendStepLog(.moveToFolders, "\(photo.filename) → \(folderName)/ — INGA filer länkades!", type: .error)
                pipelineLog("VARNING: Inga filer länkades för \(photo.filename)")
            }
            organized += 1

            // Update progress every 50 files so the UI step card shows activity
            if index % 50 == 0 || index == photoFolders.count - 1 {
                state.updateStepProgress(.moveToFolders, processed: organized, total: photosToOrganize.count)
                state.statusMessage = "Sorterar filer: \(organized)/\(photosToOrganize.count)..."
            }
        }

        // Staging folders (dng/, previews/) kept intact — address folders use symlinks

        // Copy HDR TIFF results into address folders (only if HDR merge is enabled)
        let hdrEnabled = AppSettings.shared.hdrMergeEnabled
        let hdrDir = outputDir.appendingPathComponent("hdr")
        for group in state.bracketGroups where group.isBracket && hdrEnabled {
            guard let firstPhoto = group.photos.first,
                  let folderName = calendar.addressFolder(for: firstPhoto.dateTime, mappings: calendarMappings) else { continue }
            let previewDir = outputDir.appendingPathComponent("\(folderName) TITTBILDER")
            let extrasDir = outputDir.appendingPathComponent("\(folderName) ÖVRIGA")
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: extrasDir, withIntermediateDirectories: true)

            // Move the 16-bit TIFF → ÖVRIGA
            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(group.id).tiff")
            if fm.fileExists(atPath: hdrTiff.path) {
                let dest = extrasDir.appendingPathComponent(hdrTiff.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: hdrTiff, to: dest)
                } else {
                    try? fm.removeItem(at: hdrTiff)
                }
                taggedFiles.append(dest.path)
                state.appendStepLog(.moveToFolders, "HDR \(hdrTiff.lastPathComponent) → \(folderName) ÖVRIGA/")
            }

            // Move HDR JPEG preview → TITTBILDER
            let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(group.id).jpg")
            if fm.fileExists(atPath: hdrJpeg.path) {
                let dest = previewDir.appendingPathComponent(hdrJpeg.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: hdrJpeg, to: dest)
                } else {
                    try? fm.removeItem(at: hdrJpeg)
                }
                taggedFiles.append(dest.path)
            }
        }

        if organized > 0 || unmatched > 0 {
            state.appendStepLog(.moveToFolders, "Sorterat: \(organized) bilder i adressmappar" + (unmatched > 0 ? ", \(unmatched) i Osorterade" : ""), type: .success)
            state.appendLog("Organiserade \(organized) bilder i adressmappar" + (unmatched > 0 ? " (\(unmatched) osorterade)" : "") + ".", type: .success)

            // Persist marker so we skip on re-run
            let sortMarker: [String: Any] = [
                "photos_sorted": organized + unmatched,
                "organized": organized,
                "unmatched": unmatched,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let markerData = try? JSONSerialization.data(withJSONObject: sortMarker, options: .prettyPrinted) {
                try? markerData.write(to: sortMarkerFile)
            }
        }
    }

    /// Delete rejected photos from address folders after culling is done
    func deleteRejectedFiles() async {
        guard let outputDir = state.outputDirectory else { return }

        let fm = FileManager.default
        let calendar = CalendarService.shared
        let rejectedPhotos = state.allPhotos.filter { $0.rejected }

        guard !rejectedPhotos.isEmpty else {
            state.appendLog("Inga gallrade bilder att ta bort.", type: .info)
            return
        }

        var deletedCount = 0
        let getBaseName = { (url: URL) in url.deletingPathExtension().lastPathComponent }

        for photo in rejectedPhotos {
            let folderName = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) ?? "Osorterade"
            let photoBase = getBaseName(photo.nefURL)

            // DNG files are in the address folder directly, previews and originals in suffixed folders
            let searchDirs = [
                outputDir.appendingPathComponent(folderName),
                outputDir.appendingPathComponent("\(folderName) TITTBILDER"),
                outputDir.appendingPathComponent("\(folderName) ÖVRIGA"),
            ]

            for dir in searchDirs {
                guard fm.fileExists(atPath: dir.path),
                      let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

                for file in files where getBaseName(file) == photoBase {
                    do {
                        try fm.removeItem(at: file)
                        deletedCount += 1
                        state.appendStepLog(.manualReview, "✗ Raderade \(file.lastPathComponent)")
                    } catch {
                        pipelineLog("Kunde inte radera \(file.lastPathComponent): \(error)")
                    }
                }
            }
        }

        logDecision(step: "cull_delete", decision: "deleted", details: [
            "rejectedPhotos": "\(rejectedPhotos.count)",
            "deletedFiles": "\(deletedCount)"
        ])
        state.appendLog("Raderade \(deletedCount) filer från gallrade bilder.", type: .success)
        state.appendStepLog(.manualReview, "Gallring klar: \(deletedCount) filer raderade", type: .success)
    }

    /// Write GPS + IPTC + AI tags to files in address folders
    func writeIPTCMetadata(outputDir: URL? = nil, addressMeta: [String: (lat: Double, lon: Double, bookingInfo: String?)]? = nil) async {
        let outputDir = outputDir ?? state.outputDirectory
        guard let outputDir else {
            state.appendLog("Ingen outputmapp — kan inte skriva metadata.", type: .error)
            return
        }

        state.currentStep = .writingMetadata
        state.statusMessage = "Skriver metadata (GPS, IPTC, AI-taggar)..."

        let calendar = CalendarService.shared
        let fm = FileManager.default

        // Check if metadata has already been written (skip if so)
        let metadataMarkerFile = outputDir.appendingPathComponent("metadata_written.json")
        if fm.fileExists(atPath: metadataMarkerFile.path),
           let data = try? Data(contentsOf: metadataMarkerFile),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedFolderCount = saved["folders_written"] as? Int,
           let savedFileCount = saved["files_written"] as? Int,
           savedFolderCount == calendarMappings.count {
            logDecision(step: "write_iptc", decision: "skipped", details: [
                "reason": "marker_exists",
                "filesWritten": "\(savedFileCount)",
                "foldersWritten": "\(savedFolderCount)"
            ])
            state.appendStepLog(.writeIPTCTags, "Metadata redan skriven (\(savedFileCount) filer, \(savedFolderCount) adresser) — hoppar över", type: .info)
            state.appendLog("Metadata redan skriven — hoppar över.", type: .info)
            return
        }

        // If no addressMeta provided, rebuild it from calendarMappings
        var meta = addressMeta ?? [:]
        if meta.isEmpty && !calendarMappings.isEmpty {
            for mapping in calendarMappings {
                let address = calendar.addressFolder(for: mapping.photoDateRange.lowerBound, mappings: calendarMappings) ?? mapping.address
                if meta[address] == nil {
                    let coord = await calendar.geocodeAddress(mapping.address)
                    let bookingInfo = CalendarService.extractBookingInfo(from: mapping.eventTitle)
                    if let coord {
                        meta[address] = (lat: coord.latitude, lon: coord.longitude, bookingInfo: bookingInfo)
                    } else {
                        meta[address] = (lat: 0, lon: 0, bookingInfo: bookingInfo)
                    }
                }
            }
        }

        // Build AI tag lookup: baseName -> (tags, description)
        var aiTagLookup: [String: (tags: [String], description: String)] = [:]
        if AppSettings.shared.aiTaggingEnabled {
            for photo in state.allPhotos where !photo.aiTags.isEmpty {
                let baseName = photo.filename.replacingOccurrences(of: ".NEF", with: "")
                aiTagLookup[baseName] = (tags: photo.aiTags, description: photo.aiDescription)
            }
        }

        // Collect ALL files and their combined metadata into a single argfile
        // Each file gets one entry with GPS + IPTC + AI tags combined
        var argfileLines: [String] = []
        var totalFiles = 0
        // Track per-file description for detailed logging
        var fileDescriptions: [String] = []

        for (folderName, folderMeta) in meta {
            let subfolderSuffixes = ["TITTBILDER", "DNG", "ÖVRIGA"]

            // Find the matching address/title for IPTC
            let mapping = calendarMappings.first(where: {
                calendar.addressFolder(for: $0.photoDateRange.lowerBound, mappings: calendarMappings) == folderName
            })

            // NFC-normalize all strings
            let address = (mapping?.address ?? folderName).precomposedStringWithCanonicalMapping
            let eventTitle = (mapping?.eventTitle ?? "").precomposedStringWithCanonicalMapping
            let bookingInfo = (folderMeta.bookingInfo ?? "").precomposedStringWithCanonicalMapping
            let description = [address, bookingInfo].filter { !$0.isEmpty }.joined(separator: " — ")

            let hasGPS = folderMeta.lat != 0 || folderMeta.lon != 0

            for suffix in subfolderSuffixes {
                let subDir = outputDir.appendingPathComponent("\(folderName) \(suffix)")
                guard fm.fileExists(atPath: subDir.path),
                      let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }

                for file in files {
                    // Common args for this file
                    argfileLines.append("-overwrite_original")
                    argfileLines.append("-charset")
                    argfileLines.append("iptc=UTF8")

                    // Build per-file log description
                    var parts: [String] = []

                    // GPS data
                    if hasGPS {
                        let latRef = folderMeta.lat >= 0 ? "N" : "S"
                        let lonRef = folderMeta.lon >= 0 ? "E" : "W"
                        argfileLines.append("-GPSLatitude=\(abs(folderMeta.lat))")
                        argfileLines.append("-GPSLatitudeRef=\(latRef)")
                        argfileLines.append("-GPSLongitude=\(abs(folderMeta.lon))")
                        argfileLines.append("-GPSLongitudeRef=\(lonRef)")
                        parts.append("GPS \(String(format: "%.4f", folderMeta.lat)),\(String(format: "%.4f", folderMeta.lon))")
                    }

                    // IPTC/XMP address metadata
                    argfileLines.append("-IPTC:Headline=\(address)")
                    argfileLines.append("-IPTC:ObjectName=\(address)")
                    argfileLines.append("-XMP:Title=\(address)")
                    argfileLines.append("-IPTC:Sub-location=\(address)")
                    parts.append("adress=\"\(address)\"")

                    if !eventTitle.isEmpty {
                        argfileLines.append("-IPTC:SpecialInstructions=\(eventTitle)")
                    }

                    // Per-file AI tags (merged into the same exiftool call)
                    let baseName = file.deletingPathExtension().lastPathComponent
                    if let aiData = aiTagLookup[baseName] {
                        for tag in aiData.tags {
                            let nfcTag = tag.precomposedStringWithCanonicalMapping
                            argfileLines.append("-IPTC:Keywords+=\(nfcTag)")
                            argfileLines.append("-XMP:Subject+=\(nfcTag)")
                        }
                        // Combine address description + AI description
                        let combinedDesc = [description, aiData.description.precomposedStringWithCanonicalMapping]
                            .filter { !$0.isEmpty }.joined(separator: " — ")
                        argfileLines.append("-IPTC:Caption-Abstract=\(combinedDesc)")
                        argfileLines.append("-XMP:Description=\(combinedDesc)")
                        parts.append("AI: \(aiData.tags.joined(separator: ", "))")
                    } else {
                        argfileLines.append("-IPTC:Caption-Abstract=\(description)")
                        argfileLines.append("-XMP:Description=\(description)")
                    }

                    // Target file path (must be last before -execute)
                    argfileLines.append(file.path)
                    argfileLines.append("-execute")

                    fileDescriptions.append("✓ \(file.lastPathComponent) ← \(parts.joined(separator: ", "))")
                    totalFiles += 1
                }
            }
        }

        // Also handle AI-tagged files in "Osorterade" (no calendar match)
        if AppSettings.shared.aiTaggingEnabled {
            let osortDir = outputDir.appendingPathComponent("Osorterade")
            if fm.fileExists(atPath: osortDir.path) {
                let subDirs = ["Osorterade TITTBILDER", "Osorterade DNG", "Osorterade ÖVRIGA", "Osorterade"]
                for subDirName in subDirs {
                    let subDir = outputDir.appendingPathComponent(subDirName)
                    guard fm.fileExists(atPath: subDir.path),
                          let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }
                    for file in files {
                        let baseName = file.deletingPathExtension().lastPathComponent
                        guard let aiData = aiTagLookup[baseName] else { continue }

                        argfileLines.append("-overwrite_original")
                        argfileLines.append("-charset")
                        argfileLines.append("iptc=UTF8")
                        for tag in aiData.tags {
                            let nfcTag = tag.precomposedStringWithCanonicalMapping
                            argfileLines.append("-IPTC:Keywords+=\(nfcTag)")
                            argfileLines.append("-XMP:Subject+=\(nfcTag)")
                        }
                        if !aiData.description.isEmpty {
                            let nfcDesc = aiData.description.precomposedStringWithCanonicalMapping
                            argfileLines.append("-IPTC:Caption-Abstract=\(nfcDesc)")
                            argfileLines.append("-XMP:Description=\(nfcDesc)")
                        }
                        argfileLines.append(file.path)
                        argfileLines.append("-execute")

                        fileDescriptions.append("✓ \(file.lastPathComponent) ← AI: \(aiData.tags.joined(separator: ", "))")
                        totalFiles += 1
                    }
                }
            }
        }

        guard totalFiles > 0 else {
            state.appendStepLog(.writeIPTCTags, "Inga filer att skriva metadata till", type: .warning)
            return
        }

        state.updateStepProgress(.writeIPTCTags, processed: 0, total: totalFiles)

        // Split argfile lines into chunks of ~100 files for continuous progress
        // Each file's block ends with "-execute", so split on those boundaries
        let chunkSize = 100
        var chunks: [[String]] = []
        var currentChunk: [String] = []
        var filesInCurrentChunk = 0

        for line in argfileLines {
            currentChunk.append(line)
            if line == "-execute" {
                filesInCurrentChunk += 1
                if filesInCurrentChunk >= chunkSize {
                    chunks.append(currentChunk)
                    currentChunk = []
                    filesInCurrentChunk = 0
                }
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        state.appendStepLog(.writeIPTCTags, "Skriver metadata till \(totalFiles) filer...")

        var totalUpdated = 0
        var processedSoFar = 0

        for (chunkIndex, chunk) in chunks.enumerated() {
            let argfileURL = outputDir.appendingPathComponent(".exiftool_argfile_\(chunkIndex).txt")
            let argfileContent = chunk.joined(separator: "\n")
            try? argfileContent.write(to: argfileURL, atomically: true, encoding: .utf8)

            let filesInChunk = chunk.filter { $0 == "-execute" }.count

            do {
                let output = try await runProcess(
                    executablePath: "/opt/homebrew/bin/exiftool",
                    arguments: ["-@", argfileURL.path]
                )
                pipelineLog("Exiftool chunk \(chunkIndex + 1)/\(chunks.count) output: \(output)")

                let updatedPattern = try? NSRegularExpression(pattern: "(\\d+) image files? updated")
                let matches = updatedPattern?.matches(in: output, range: NSRange(output.startIndex..., in: output)) ?? []
                for match in matches {
                    if let range = Range(match.range(at: 1), in: output), let count = Int(output[range]) {
                        totalUpdated += count
                    }
                }

                // Log per-file details for this chunk
                let startIdx = processedSoFar
                let endIdx = min(startIdx + filesInChunk, fileDescriptions.count)
                for i in startIdx..<endIdx {
                    state.appendStepLog(.writeIPTCTags, fileDescriptions[i])
                }
            } catch {
                state.appendStepLog(.writeIPTCTags, "Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .error)
                state.appendLog("Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .warning)
            }

            try? fm.removeItem(at: argfileURL)

            processedSoFar += filesInChunk
            state.updateStepProgress(.writeIPTCTags, processed: processedSoFar, total: totalFiles)
        }

        state.appendStepLog(.writeIPTCTags, "Metadata skriven till \(totalUpdated) av \(totalFiles) filer", type: .success)
        state.updateStepProgress(.writeIPTCTags, processed: totalFiles, total: totalFiles)

        state.appendLog("Metadata skriven till \(totalFiles) filer.", type: .success)

        // Persist marker so we skip on re-run
        let marker: [String: Any] = [
            "folders_written": meta.count,
            "files_written": totalFiles,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "addresses": Array(meta.keys)
        ]
        if let markerData = try? JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted) {
            try? markerData.write(to: metadataMarkerFile)
        }
    }

    // MARK: - Step 3: Preview Generation

    private func runPreviewGeneration(inputDir: URL) async throws {
        state.currentStep = .generatingPreviews

        guard let outputDir = state.outputDirectory else { throw PipelineError.toolNotFound("Ingen outputmapp") }
        let previewDir = outputDir.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let nefFiles = findNEFFiles(in: inputDir)

        // Check if all previews already exist
        let existingPreviews = (try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }.count ?? 0
        if existingPreviews >= nefFiles.count {
            logDecision(step: "preview_generation", decision: "skipped", details: [
                "reason": "all_exist",
                "existingCount": "\(existingPreviews)",
                "nefCount": "\(nefFiles.count)"
            ])
            state.appendLog("Alla \(existingPreviews) previews finns redan — hoppar over.", type: .info)
            state.appendStepLog(.generatePreviews, "Alla \(existingPreviews) previews finns redan — hoppar over", type: .info)
            state.progress = 1.0
            return
        }

        state.appendLog("Genererar JPEG-previews...", type: .info)
        state.appendStepLog(.generatePreviews, "Genererar previews for \(nefFiles.count) NEF-filer...")

        state.totalFiles = nefFiles.count
        state.currentFileIndex = 0
        state.statusMessage = "Genererar previews för \(nefFiles.count) bilder..."

        // Filter to only files that need processing
        let filesToProcess = nefFiles.filter { nef in
            let baseName = nef.deletingPathExtension().lastPathComponent
            let previewFile = previewDir.appendingPathComponent("\(baseName).jpg")
            return !FileManager.default.fileExists(atPath: previewFile.path)
        }
        let alreadyDone = nefFiles.count - filesToProcess.count

        state.currentFileIndex = alreadyDone
        state.progress = Double(alreadyDone) / Double(nefFiles.count)

        if !filesToProcess.isEmpty {
            // Use a single exiftool call to extract all embedded JPEG previews at once.
            // -W creates output files using the format string: %d = source dir, %f = filename
            // We write to previewDir/%f.jpg for each input NEF.
            let pathsList = filesToProcess.map { $0.path }.joined(separator: "\n")
            let formatString = previewDir.path + "/%f.jpg"

            _ = try await runProcess(
                executablePath: "/opt/homebrew/bin/exiftool",
                arguments: ["-b", "-JpgFromRaw", "-W", formatString, "-@", "-"],
                stdinData: pathsList.data(using: .utf8)
            )

            // Orientation is already correct in embedded JPEG previews from NEF files,
            // so no separate orientation copy step is needed.
        }

        // Count actual results
        let finalPreviews = (try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }.count ?? 0

        state.currentFileIndex = finalPreviews
        state.progress = 1.0
        state.appendLog("Preview-generering klar: \(finalPreviews) bilder.", type: .success)
        state.appendStepLog(.generatePreviews, "\(finalPreviews) previews genererade", type: .success)
        audio.playStepComplete()
    }

    // MARK: - Step 3.5: AI Tagging

    /// Cached AI tags: filename -> PhotoTags
    private var aiTagResults: [String: VisionTaggingService.PhotoTags] = [:]

    private func runAITagging() async throws {
        guard let outputDir = state.outputDirectory else { return }
        let previewDir = outputDir.appendingPathComponent("previews")
        let fm = FileManager.default

        state.currentStep = .taggingPhotos

        // Check if ai_tags.json already exists with matching file count
        let tagsJSON = outputDir.appendingPathComponent("ai_tags.json")
        let previewFiles = (try? fm.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        let previewNames = Set(previewFiles.map { $0.deletingPathExtension().lastPathComponent })

        if fm.fileExists(atPath: tagsJSON.path),
           let existingData = try? Data(contentsOf: tagsJSON),
           let existingJSON = try? JSONSerialization.jsonObject(with: existingData) as? [String: [String: Any]],
           previewNames.isSubset(of: Set(existingJSON.keys)) {
            // Load from disk instead of re-running Vision
            aiTagResults = [:]
            for (filename, info) in existingJSON {
                let tags = (info["tags"] as? [String]) ?? []
                let desc = (info["description"] as? String) ?? ""
                let cat = (info["category"] as? String) ?? ""
                aiTagResults[filename] = VisionTaggingService.PhotoTags(
                    tags: tags, description: desc, primaryCategory: cat,
                    confidence: 1.0, rawLabels: []
                )
            }
            logDecision(step: "ai_tagging", decision: "skipped", details: [
                "reason": "json_exists",
                "tagCount": "\(existingJSON.count)"
            ])
            state.appendStepLog(.aiTagging, "AI-taggar redan sparade (\(existingJSON.count) bilder) — hoppar over", type: .info)
            state.appendLog("AI-taggning redan klar — laddar fran ai_tags.json.", type: .info)

            // Log loaded tags
            for (filename, tags) in aiTagResults.sorted(by: { $0.key < $1.key }) {
                let tagStr = tags.tags.joined(separator: ", ")
                let catStr = tags.primaryCategory.isEmpty ? "" : " [\(tags.primaryCategory)]"
                state.appendStepLog(.aiTagging, "\(filename): \(tagStr)\(catStr)")
            }
            state.progress = 1.0
            return
        }

        state.appendLog("AI-taggning av JPEG-previews med Apple Vision...", type: .info)

        guard !previewFiles.isEmpty else {
            state.appendLog("Inga preview-bilder att tagga.", type: .warning)
            return
        }

        state.totalFiles = previewFiles.count
        state.currentFileIndex = 0
        state.statusMessage = "AI-taggar \(previewFiles.count) bilder..."

        let urls = previewFiles.map { (filename: $0.deletingPathExtension().lastPathComponent, url: $0) }

        let tagger = VisionTaggingService.shared
        state.appendStepLog(.aiTagging, "Startar AI-klassificering av \(previewFiles.count) JPEG-previews (från previews/)...")
        aiTagResults = await tagger.tagPhotos(urls: urls) { [weak self] current, total, filename, tags in
            guard let self else { return }
            self.state.currentFileIndex = current
            self.state.progress = Double(current) / Double(total)
            self.state.updateStepProgress(.aiTagging, processed: current, total: total)
            if current % 10 == 0 || current == total {
                self.state.statusMessage = "AI-taggar bilder: \(current)/\(total)..."
            }
            // Log each photo as it's tagged
            if let tags {
                let tagStr = tags.tags.joined(separator: ", ")
                let catStr = tags.primaryCategory.isEmpty ? "" : " [\(tags.primaryCategory)]"
                self.state.appendStepLog(.aiTagging, "[\(current)/\(total)] \(filename): \(tagStr)\(catStr)")
            } else {
                self.state.appendStepLog(.aiTagging, "[\(current)/\(total)] \(filename): inga taggar", type: .warning)
            }
        }

        // Log summary
        var tagCounts: [String: Int] = [:]
        for (_, tags) in aiTagResults {
            for tag in tags.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        let sorted = tagCounts.sorted { $0.value > $1.value }
        let summary = sorted.prefix(10).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        state.appendStepLog(.aiTagging, "Vanligaste taggar: \(summary)", type: .success)
        state.appendLog("AI-taggning klar: \(aiTagResults.count) bilder. Vanligaste: \(summary)", type: .success)

        // Save tags to JSON for persistence
        var jsonDict: [String: [String: Any]] = [:]
        for (filename, tags) in aiTagResults {
            jsonDict[filename] = [
                "tags": tags.tags,
                "description": tags.description,
                "category": tags.primaryCategory
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted) {
            try? data.write(to: tagsJSON)
        }

        state.progress = 1.0
        audio.playStepComplete()
    }

    // MARK: - Step 4: HDR Merge (Mertens exposure fusion via OpenCV)

    private func runHDRMerge() async throws {
        guard let outputDir = state.outputDirectory else { return }

        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard FileManager.default.fileExists(atPath: groupsJSON.path) else { return }

        let data = try Data(contentsOf: groupsJSON)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let previewDir = outputDir.appendingPathComponent("previews")
        let hdrDir = outputDir.appendingPathComponent("hdr")
        try FileManager.default.createDirectory(at: hdrDir, withIntermediateDirectories: true)

        let bracketGroups = groups.filter { ($0["is_bracket"] as? Bool) == true }
        guard !bracketGroups.isEmpty else { return }

        state.currentStep = .mergingHDR
        state.statusMessage = "Slår ihop HDR-brackets (Mertens exposure fusion)..."
        state.totalFiles = bracketGroups.count
        state.currentFileIndex = 0
        state.progress = 0.0
        state.appendLog("Startar HDR-sammanslagning med Mertens exposure fusion (\(bracketGroups.count) bracket-grupper)...", type: .info)

        // Build list of groups to merge (skip already-done ones)
        var groupsToMerge: [(groupId: Int, previewPaths: [String])] = []
        for group in bracketGroups {
            let groupId = (group["group_id"] as? Int) ?? 0
            let files = (group["files"] as? [String]) ?? []
            let suggestedIndices = (group["suggested_hdr_indices"] as? [Int]) ?? Array(0..<files.count)

            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(groupId).tiff")
            if FileManager.default.fileExists(atPath: hdrTiff.path) { continue }

            // Use preview JPEGs for fusion (full resolution embedded previews from NEF)
            let previewPaths = suggestedIndices.compactMap { i -> String? in
                guard i < files.count else { return nil }
                let baseName = files[i].replacingOccurrences(of: ".NEF", with: "")
                let preview = previewDir.appendingPathComponent("\(baseName).jpg")
                return FileManager.default.fileExists(atPath: preview.path) ? preview.path : nil
            }

            guard previewPaths.count >= 2 else { continue }
            groupsToMerge.append((groupId: groupId, previewPaths: previewPaths))
        }

        if groupsToMerge.isEmpty {
            logDecision(step: "hdr_merge", decision: "skipped", details: [
                "reason": "all_complete"
            ])
            state.appendLog("Alla HDR-grupper redan klara.", type: .info)
            state.progress = 1.0
            return
        }

        // Write the Python fusion script
        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
        let pyScript = mertensFusionPython()
        try pyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptPath) }

        var successCount = 0
        var failCount = 0
        state.updateStepProgress(.createHDR, processed: 0, total: groupsToMerge.count)

        for (idx, group) in groupsToMerge.enumerated() {
            await waitIfPaused()
            state.statusMessage = "Exposure fusion: grupp \(group.groupId) (\(idx + 1)/\(groupsToMerge.count))..."
            state.currentFileIndex = idx
            state.progress = Double(idx) / Double(groupsToMerge.count)
            state.updateStepProgress(.createHDR, processed: idx, total: groupsToMerge.count)
            state.appendLog("HDR grupp \(group.groupId): \(group.previewPaths.count) bilder (Mertens fusion)...", type: .info)

            // Update detailed progress
            state.currentMergeGroupId = group.groupId
            state.currentMergeInputURLs = group.previewPaths.map { URL(fileURLWithPath: $0) }
            state.currentMergeOutputURL = nil

            let outputPath = hdrDir.appendingPathComponent("hdr_group_\(group.groupId).tiff").path
            let previewPath = hdrDir.appendingPathComponent("hdr_group_\(group.groupId).jpg").path

            let inputNames = group.previewPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): mergar \(group.previewPaths.count) bilder (\(inputNames))...")

            do {
                let output = try await runProcess(
                    executablePath: "/opt/homebrew/bin/python3",
                    arguments: [scriptPath.path, outputPath] + group.previewPaths
                )
                if FileManager.default.fileExists(atPath: outputPath) {
                    successCount += 1
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): klar → hdr_group_\(group.groupId).tiff (\(sizeMB) MB)", type: .success)
                    // Show JPEG preview in UI
                    let showURL = FileManager.default.fileExists(atPath: previewPath)
                        ? URL(fileURLWithPath: previewPath)
                        : URL(fileURLWithPath: outputPath)
                    state.currentMergeOutputURL = showURL
                    pipelineLog("  Grupp \(group.groupId): Mertens fusion klar (16-bit TIFF)")
                } else {
                    failCount += 1
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): ingen output skapad", type: .error)
                    pipelineLog("  Grupp \(group.groupId): Ingen output skapad. \(output)")
                }
            } catch {
                failCount += 1
                state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): misslyckades — \(error.localizedDescription)", type: .error)
                pipelineLog("  Grupp \(group.groupId): Fusion misslyckades: \(error.localizedDescription)")
            }

            state.currentFileIndex = idx + 1
            state.progress = Double(idx + 1) / Double(groupsToMerge.count)
        }

        // Clear detailed progress
        state.currentMergeInputURLs = []
        state.currentMergeOutputURL = nil
        state.currentMergeGroupId = nil

        state.progress = 1.0
        if failCount == 0 {
            state.appendLog("HDR-sammanslagning klar: \(successCount) grupper (Mertens fusion).", type: .success)
        } else {
            state.appendLog("HDR-sammanslagning: \(successCount) lyckades, \(failCount) misslyckades.", type: .warning)
        }
        audio.playStepComplete()
    }

    /// Runs Photoshop HDR merge for a single bracket group.
    private func runPhotoshopHDRSingleGroup(
        groupId: Int,
        files: [String],
        outputDir: String,
        scriptPath: String
    ) async -> Bool {
        // Build the file list as JS array literal
        let jsFiles = files.map { "\"\($0)\"" }.joined(separator: ",")
        let jsArgs = "var _groupId = \(groupId); var _files = [\(jsFiles)]; var _outputDir = \"\(outputDir)\";"

        let fullScript = "\(jsArgs)\n" + "$.evalFile(\"\(scriptPath)\");"

        // Write the invocation script
        let invokerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoflow_hdr_invoke_\(groupId).jsx")
        do {
            try fullScript.write(to: invokerPath, atomically: true, encoding: .utf8)
        } catch {
            pipelineLog("Kunde inte skriva invoker-script: \(error.localizedDescription)")
            return false
        }

        defer { try? FileManager.default.removeItem(at: invokerPath) }

        do {
            _ = try await runProcess(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Adobe Photoshop 2025\" to do javascript of file \"\(invokerPath.path)\""]
            )
        } catch {
            pipelineLog("Photoshop-fel grupp \(groupId): \(error.localizedDescription)")
            return false
        }

        // Check if TIFF was created (Photoshop always saves TIFF)
        let tiffPath = "\(outputDir)/hdr_group_\(groupId).tif"
        let jpegPath = "\(outputDir)/hdr_group_\(groupId).jpg"

        guard FileManager.default.fileExists(atPath: tiffPath) else {
            return false
        }

        // Generate JPEG preview from TIFF using sips (fast, reliable fallback)
        if !FileManager.default.fileExists(atPath: jpegPath) {
            do {
                _ = try await runProcess(
                    executablePath: "/usr/bin/sips",
                    arguments: ["-s", "format", "jpeg", "-s", "formatOptions", "80",
                                "--resampleWidth", "2048", tiffPath, "--out", jpegPath]
                )
                pipelineLog("  JPEG-preview skapad med sips för grupp \(groupId)")
            } catch {
                pipelineLog("  Kunde inte skapa JPEG-preview: \(error.localizedDescription)")
            }
        }

        return FileManager.default.fileExists(atPath: jpegPath)
    }

    /// Re-merge a single bracket group after user changes selection.
    /// Called from BracketReviewView when user modifies which photos are included.
    func reMergeHDR(group: BracketGroup) async {
        guard let outputDir = state.outputDirectory else { return }
        let hdrDir = outputDir.appendingPathComponent("hdr")

        let selectedPhotos = group.photos.filter { $0.accepted }
        guard selectedPhotos.count >= 2 else {
            state.appendLog("Grupp \(group.id): Minst 2 bilder krävs för HDR.", type: .warning)
            return
        }

        // Remove old HDR files
        let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(group.id).tiff")
        let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(group.id).jpg")
        let hdrTifOld = hdrDir.appendingPathComponent("hdr_group_\(group.id).tif")
        try? FileManager.default.removeItem(at: hdrTiff)
        try? FileManager.default.removeItem(at: hdrJpeg)
        try? FileManager.default.removeItem(at: hdrTifOld)

        // Use preview JPEGs for Mertens fusion
        let previewPaths = selectedPhotos.compactMap { photo -> String? in
            guard let url = photo.previewURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.path
        }

        guard previewPaths.count >= 2 else { return }

        state.appendLog("Gör om HDR för grupp \(group.id) med \(previewPaths.count) bilder (Mertens fusion)...", type: .info)

        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
        let pyScript = mertensFusionPython()
        try? pyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptPath) }

        do {
            _ = try await runProcess(
                executablePath: "/opt/homebrew/bin/python3",
                arguments: [scriptPath.path, hdrTiff.path] + previewPaths
            )
        } catch {
            state.appendLog("Fusion misslyckades: \(error.localizedDescription)", type: .error)
        }

        if FileManager.default.fileExists(atPath: hdrTiff.path) {
            // Use JPEG preview for UI if available, otherwise TIFF
            let previewURL = FileManager.default.fileExists(atPath: hdrJpeg.path) ? hdrJpeg : hdrTiff
            if let idx = state.bracketGroups.firstIndex(where: { $0.id == group.id }) {
                state.bracketGroups[idx].mergedHDRPreviewURL = previewURL
            }
            state.appendLog("HDR-ommerge klar för grupp \(group.id) (16-bit TIFF).", type: .success)
            audio.playStepComplete()
        } else {
            state.appendLog("HDR-ommerge misslyckades för grupp \(group.id).", type: .error)
            audio.playError()
        }
    }

    /// ExtendScript for Photoshop 2025 Merge to HDR Pro - single group.
    /// Expects _groupId (int), _files (array of path strings), _outputDir (string) to be set by the invoker script.
    private func photoshopHDRSingleGroupScript() -> String {
        return """
        // PhotoFlow HDR Merge - Single Group
        // Variables _groupId, _files, _outputDir are set by the invoker script

        var runMergeToHDRFromScript = true;

        // Load the Merge To HDR script (it loads its own dependencies)
        var basePath = decodeURI(app.path);
        $.evalFile(basePath + "/Presets/Scripts/Merge To HDR.jsx");

        var files = [];
        for (var f = 0; f < _files.length; f++) {
            files.push(new File(_files[f]));
        }

        try {
            // Run Photoshop Merge to HDR Pro (headless: align=true, deghost=best)
            mergeToHDR.mergeFilesToHDR(files, true, -2);

            if (app.documents.length > 0) {
                var doc = app.activeDocument;

                // Flatten if needed
                try { doc.flatten(); } catch(e) {}

                // Convert 32-bit HDR to 16-bit with Exposure/Gamma boost
                // Real estate HDR needs to be bright and airy
                if (doc.bitsPerChannel == BitsPerChannelType.THIRTYTWO) {
                    try {
                        var idCnvM = charIDToTypeID("CnvM");
                        var desc32 = new ActionDescriptor();
                        desc32.putClass(charIDToTypeID("T   "), charIDToTypeID("SxBt"));
                        // Use Exposure and Gamma method with +1.5 exposure boost
                        var egDesc = new ActionDescriptor();
                        egDesc.putDouble(stringIDToTypeID("exposure"), 1.5);
                        egDesc.putDouble(stringIDToTypeID("gamma"), 0.85);
                        desc32.putObject(stringIDToTypeID("using"), stringIDToTypeID("hdrToningExposureAndGamma"), egDesc);
                        executeAction(idCnvM, desc32, DialogModes.NO);
                    } catch(e) {
                        // Fallback: basic conversion
                        try {
                            var idCnvM2 = charIDToTypeID("CnvM");
                            var descFB = new ActionDescriptor();
                            descFB.putClass(charIDToTypeID("T   "), charIDToTypeID("SxBt"));
                            executeAction(idCnvM2, descFB, DialogModes.NO);
                        } catch(e2) {
                            doc.bitsPerChannel = BitsPerChannelType.SIXTEEN;
                        }
                    }
                }

                // Apply Auto Levels
                try {
                    var descLvls = new ActionDescriptor();
                    descLvls.putBoolean(charIDToTypeID("Auto"), true);
                    executeAction(charIDToTypeID("Lvls"), descLvls, DialogModes.NO);
                } catch(e) {}

                // Apply Shadow/Highlights - opens up dark areas, tames highlights
                // Perfect for real estate interior HDR
                try {
                    var shDesc = new ActionDescriptor();
                    shDesc.putInteger(stringIDToTypeID("shadowAmount"), 60);
                    shDesc.putInteger(stringIDToTypeID("shadowWidth"), 50);
                    shDesc.putInteger(stringIDToTypeID("shadowRadius"), 30);
                    shDesc.putInteger(stringIDToTypeID("highlightAmount"), 20);
                    shDesc.putInteger(stringIDToTypeID("highlightWidth"), 50);
                    shDesc.putInteger(stringIDToTypeID("highlightRadius"), 30);
                    shDesc.putInteger(stringIDToTypeID("colorCorrection"), 20);
                    shDesc.putInteger(stringIDToTypeID("midtoneBrightness"), 10);
                    shDesc.putBoolean(stringIDToTypeID("clipBlacks"), false);
                    shDesc.putBoolean(stringIDToTypeID("clipWhites"), false);
                    executeAction(stringIDToTypeID("shadowHighlight"), shDesc, DialogModes.NO);
                } catch(e) {}

                // Save as 16-bit TIFF (full quality)
                var tiffPath = _outputDir + "/hdr_group_" + _groupId + ".tif";
                var tiffFile = new File(tiffPath);
                var tiffOpts = new TiffSaveOptions();
                tiffOpts.imageCompression = TIFFEncoding.TIFFLZW;
                tiffOpts.byteOrder = ByteOrder.MACOS;
                doc.saveAs(tiffFile, tiffOpts, true);

                // Save JPEG preview
                if (doc.bitsPerChannel != BitsPerChannelType.EIGHT) {
                    doc.bitsPerChannel = BitsPerChannelType.EIGHT;
                }

                var jpegPath = _outputDir + "/hdr_group_" + _groupId + ".jpg";
                var jpegFile = new File(jpegPath);
                var jpegOpts = new JPEGSaveOptions();
                jpegOpts.quality = 10;
                jpegOpts.formatOptions = FormatOptions.PROGRESSIVE;
                doc.saveAs(jpegFile, jpegOpts, true);

                doc.close(SaveOptions.DONOTSAVECHANGES);
            }
        } catch (e) {
            // Close any open docs to avoid buildup
            try { if (app.documents.length > 0) app.activeDocument.close(SaveOptions.DONOTSAVECHANGES); } catch(e2) {}
        }

        "done"
        """
    }

    // MARK: - Lightroom HDR Integration

    /// Sends selected bracket groups to Lightroom Classic for HDR merge.
    /// Creates a staging folder with the selected files and opens Lightroom + Finder.
    func sendToLightroom(groups: [BracketGroup]) async {
        state.appendLog("Förbereder HDR-grupper för Lightroom...", type: .info)

        // Build trigger JSON for the Lightroom plugin
        var triggerGroups: [[String: Any]] = []
        var groupIndex = 0
        for group in groups where group.isBracket {
            let selectedPhotos = group.photos.filter { $0.accepted }
            guard selectedPhotos.count >= 2 else { continue }
            groupIndex += 1
            let files = selectedPhotos.map { $0.nefURL.path }
            triggerGroups.append([
                "group_id": groupIndex,
                "files": files,
                "output_dir": state.outputDirectory?.appendingPathComponent("hdr").path ?? ""
            ])
        }

        guard !triggerGroups.isEmpty else {
            state.appendLog("Inga bracket-grupper med valda bilder att skicka.", type: .warning)
            return
        }

        let totalFiles = triggerGroups.reduce(0) { $0 + (($1["files"] as? [String])?.count ?? 0) }
        state.appendLog("Skickar \(triggerGroups.count) bracket-grupper (\(totalFiles) filer) till Lightroom...", type: .info)

        // Write trigger file that the Lightroom plugin reads
        let triggerPath = NSTemporaryDirectory() + "photoflow_hdr_trigger.json"
        let triggerData: [String: Any] = ["groups": triggerGroups]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: triggerData, options: .prettyPrinted)
            try jsonData.write(to: URL(fileURLWithPath: triggerPath))
            state.appendLog("Trigger-fil skriven: \(triggerPath)", type: .info)
        } catch {
            state.appendLog("Kunde inte skriva trigger-fil: \(error.localizedDescription)", type: .error)
            return
        }

        // Remove any old completion marker
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "photoflow_hdr_done.json")
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "photoflow_hdr_status.json")

        // The Lightroom plugin auto-polls for the trigger file every 5 seconds.
        // Just make sure Lightroom is running.
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-b", "com.adobe.LightroomClassicCC7"]
        try? openProc.run()

        state.appendLog("Trigger-fil skriven med \(triggerGroups.count) grupper.", type: .success)
        state.appendLog("Kör nu i Lightroom: Library → Plug-in Extras → Kör HDR-sammanslagning från PhotoFlow", type: .warning)

        // Poll for completion
        Task {
            await waitForLightroomCompletion()
        }

        audio.playStepComplete()
    }

    /// Polls for the Lightroom plugin completion marker file.
    private func waitForLightroomCompletion() async {
        let donePath = NSTemporaryDirectory() + "photoflow_hdr_done.json"
        // Poll every 5 seconds for up to 10 minutes
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if FileManager.default.fileExists(atPath: donePath) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: donePath)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    await MainActor.run {
                        state.appendLog("Lightroom HDR klar! Status: \(status)", type: .success)
                        audio.playAllDone()
                    }
                }
                try? FileManager.default.removeItem(atPath: donePath)
                return
            }
        }
        await MainActor.run {
            state.appendLog("Timeout: fick inget svar från Lightroom-pluginet efter 10 min.", type: .warning)
        }
    }



    // MARK: - Load bracket groups for review

    private func loadBracketGroups() async throws {
        guard let outputDir = state.outputDirectory else { return }
        guard let inputDir = state.inputDirectory else { return }

        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        let data = try Data(contentsOf: groupsJSON)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let groups = json["groups"] as! [[String: Any]]

        let previewDir = outputDir.appendingPathComponent("previews")
        let dngStagingDir = outputDir.appendingPathComponent("dng")
        let hdrDir = outputDir.appendingPathComponent("hdr")

        // Build DNG lookup: search entire output dir (files may be in dng/ staging or address folders)
        var dngLookup: [String: URL] = [:]
        if let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "dng" {
                    dngLookup[fileURL.deletingPathExtension().lastPathComponent] = fileURL
                }
            }
        }

        // Build filename -> URL lookup for recursive input
        let allNEFs = findNEFFiles(in: inputDir)
        var nefLookup: [String: URL] = [:]
        for url in allNEFs {
            nefLookup[url.lastPathComponent] = url
        }

        // Load persisted AI tags if available
        var loadedAITags: [String: VisionTaggingService.PhotoTags] = [:]
        let aiTagsFile = outputDir.appendingPathComponent("ai_tags.json")
        if let aiData = try? Data(contentsOf: aiTagsFile),
           let aiJSON = try? JSONSerialization.jsonObject(with: aiData) as? [String: [String: Any]] {
            for (filename, info) in aiJSON {
                let tags = (info["tags"] as? [String]) ?? []
                let desc = (info["description"] as? String) ?? ""
                let cat = (info["category"] as? String) ?? ""
                loadedAITags[filename] = VisionTaggingService.PhotoTags(
                    tags: tags, description: desc, primaryCategory: cat,
                    confidence: 1.0, rawLabels: []
                )
            }
            pipelineLog("Laddade AI-taggar för \(loadedAITags.count) bilder")
        }

        // Load persisted cull decisions
        let cullDecisions = state.loadCullDecisions()
        if !cullDecisions.isEmpty {
            pipelineLog("Laddade gallringsbeslut for \(cullDecisions.count) bilder")
        }

        var bracketGroups: [BracketGroup] = []
        var allPhotos: [PhotoItem] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for groupData in groups {
            let groupId = (groupData["group_id"] as? Int) ?? 0
            let isBracket = (groupData["is_bracket"] as? Bool) ?? false
            let files = (groupData["files"] as? [String]) ?? []
            let exposures = (groupData["exposures"] as? [String]) ?? []
            let fNumber = (groupData["fnumber"] as? Double) ?? 0
            let iso = (groupData["iso"] as? Int) ?? Int((groupData["iso"] as? Double) ?? 0)
            let timeStart = (groupData["time_start"] as? String) ?? ""
            let timeEnd = (groupData["time_end"] as? String) ?? ""
            let dateStartStr = (groupData["date_start"] as? String) ?? ""
            let groupDate = dateFormatter.date(from: dateStartStr) ?? Date()
            let expRange = (groupData["exposure_range_stops"] as? Double) ?? 0
            let suggestedIndices = (groupData["suggested_hdr_indices"] as? [Int]) ?? []
            let suggestedSet = Set(suggestedIndices)

            var photos: [PhotoItem] = []
            for (i, filename) in files.enumerated() {
                let baseName = filename.replacingOccurrences(of: ".NEF", with: "")
                let nefURL = nefLookup[filename] ?? inputDir.appendingPathComponent(filename)
                let dngURL = dngLookup[baseName] ?? dngStagingDir.appendingPathComponent("\(baseName).dng")
                let previewURL = previewDir.appendingPathComponent("\(baseName).jpg")

                let expStr = i < exposures.count ? exposures[i] : ""
                var expSeconds: Double = 0
                if expStr.contains("/") {
                    let parts = expStr.split(separator: "/")
                    if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]) {
                        expSeconds = num / den
                    }
                } else {
                    expSeconds = Double(expStr) ?? 0
                }

                let previewExists = FileManager.default.fileExists(atPath: previewURL.path)
                let dngExists = FileManager.default.fileExists(atPath: dngURL.path)

                // Algorithm suggestion for HDR subset (stored for UI hint, not used for accept/reject)
                let autoSelect = isBracket && (suggestedSet.isEmpty ? true : suggestedSet.contains(i))

                // Look up AI tags
                let tagResult = aiTagResults[baseName] ?? loadedAITags[baseName]

                let photoId = "\(groupId)_\(filename)"

                // Apply saved cull decision only — photos start neutral (not accepted/rejected)
                // TODO: Consider re-adding auto-accept based on algorithm suggestion as opt-in setting
                let savedDecision = cullDecisions[photoId]
                let isAccepted = savedDecision == "accepted"
                let isRejected = savedDecision == "rejected"

                var photo = PhotoItem(
                    id: photoId,
                    filename: filename,
                    nefURL: nefURL,
                    dngURL: dngExists ? dngURL : nil,
                    previewURL: previewExists ? previewURL : nil,
                    exposureTime: expStr,
                    exposureSeconds: expSeconds,
                    fNumber: fNumber,
                    iso: iso,
                    dateTime: groupDate,
                    accepted: isAccepted,
                    algorithmSuggested: autoSelect
                )
                photo.rejected = isRejected
                if let tagResult {
                    photo.aiTags = tagResult.tags
                    photo.aiDescription = tagResult.description
                }
                photos.append(photo)
                allPhotos.append(photo)
            }

            let folderName = isBracket
                ? "bracket_\(String(format: "%03d", groupId))_HDR_\(photos.count)exp"
                : "single_\(String(format: "%03d", groupId))_\(photos.count)img"

            // Check for merged HDR output (TIFF is the real file, JPEG is preview for UI)
            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(groupId).tiff")
            let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(groupId).jpg")
            let hdrPreviewURL: URL?
            if FileManager.default.fileExists(atPath: hdrJpeg.path) {
                hdrPreviewURL = hdrJpeg
            } else if FileManager.default.fileExists(atPath: hdrTiff.path) {
                hdrPreviewURL = hdrTiff
            } else {
                hdrPreviewURL = nil
            }
            if hdrPreviewURL != nil {
                pipelineLog("  Grupp \(groupId): HDR finns (\(FileManager.default.fileExists(atPath: hdrTiff.path) ? "16-bit TIFF" : "JPEG"))")
            }

            let group = BracketGroup(
                id: groupId,
                isBracket: isBracket,
                folderName: folderName,
                photos: photos,
                fNumber: fNumber,
                iso: iso,
                timeStart: timeStart,
                timeEnd: timeEnd,
                exposureRangeStops: expRange,
                mergedHDRPreviewURL: hdrPreviewURL
            )
            bracketGroups.append(group)
        }

        state.bracketGroups = bracketGroups
        state.allPhotos = allPhotos
        state.appendLog("Laddade \(bracketGroups.count) grupper med \(allPhotos.count) bilder.", type: .success)
    }

    // MARK: - Process helpers

    private func runProcess(
        executablePath: String,
        arguments: [String],
        outputFile: URL? = nil,
        stdinData: Data? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tmpDir = NSTemporaryDirectory()
                let uid = UUID().uuidString

                // Use temp files instead of pipes to completely avoid pipe buffer deadlocks.
                // Pipes have limited kernel buffers (~64KB) and can cause Process/waitUntilExit
                // to hang when the parent holds write-end file descriptors.

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                // stdout → caller-specified file or temp file
                let stdoutFile: URL
                if let outputFile {
                    stdoutFile = outputFile
                } else {
                    stdoutFile = URL(fileURLWithPath: tmpDir + uid + ".stdout")
                }
                FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
                guard let stdoutHandle = FileHandle(forWritingAtPath: stdoutFile.path) else {
                    continuation.resume(throwing: PipelineError.processError("Kunde inte skapa stdout-fil"))
                    return
                }
                process.standardOutput = stdoutHandle

                // stderr → temp file
                let stderrFile = URL(fileURLWithPath: tmpDir + uid + ".stderr")
                FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
                guard let stderrHandle = FileHandle(forWritingAtPath: stderrFile.path) else {
                    continuation.resume(throwing: PipelineError.processError("Kunde inte skapa stderr-fil"))
                    return
                }
                process.standardError = stderrHandle

                // stdin → write data to temp file and use as stdin
                if let stdinData {
                    let stdinFile = URL(fileURLWithPath: tmpDir + uid + ".stdin")
                    try? stdinData.write(to: stdinFile)
                    if let stdinHandle = FileHandle(forReadingAtPath: stdinFile.path) {
                        process.standardInput = stdinHandle
                    }
                }

                Task { @MainActor in
                    self?.currentTask = process
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // No pipes → waitUntilExit cannot deadlock
                process.waitUntilExit()

                // Close file handles
                stdoutHandle.closeFile()
                stderrHandle.closeFile()

                // Read results from files
                let output: String
                if outputFile != nil {
                    output = "" // caller reads from outputFile directly
                } else {
                    output = (try? String(contentsOf: stdoutFile, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: stderrFile)
                    try? FileManager.default.removeItem(at: stdoutFile)
                }

                let stderrData = (try? Data(contentsOf: stderrFile)) ?? Data()
                try? FileManager.default.removeItem(at: stderrFile)

                // Clean up stdin temp file
                let stdinFile = URL(fileURLWithPath: tmpDir + uid + ".stdin")
                try? FileManager.default.removeItem(at: stdinFile)

                if process.terminationStatus != 0 {
                    let errorMsg = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: PipelineError.processError(
                        errorMsg.isEmpty ? "Process exited with code \(process.terminationStatus)" : errorMsg
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }

    // MARK: - Embedded Python scripts

    private func bracketAnalysisPython() -> String {
        """
        import csv, json, sys, math
        from datetime import datetime

        exif_csv, output_json = sys.argv[1], sys.argv[2]
        max_time_gap, min_bracket_size = int(sys.argv[3]), int(sys.argv[4])

        def parse_exposure(s):
            s = s.strip()
            if '/' in s:
                p = s.split('/')
                return float(p[0]) / float(p[1])
            return float(s)

        def parse_dt(s):
            try: return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S")
            except: return None

        def ev(exp):
            if exp <= 0: return 0
            return math.log2(exp)

        # Read EXIF data
        images = []
        with open(exif_csv, 'r') as f:
            for row in csv.DictReader(f):
                dt = parse_dt(row.get('DateTimeOriginal', ''))
                if not dt: continue
                try: exp = parse_exposure(row.get('ExposureTime', '0'))
                except: exp = 0
                try: fn = float(row.get('FNumber', '0'))
                except: fn = 0
                try: iso = int(row.get('ISO', '0'))
                except: iso = 0
                subsec = row.get('SubSecTimeOriginal', '0')
                try: subsec_val = int(subsec)
                except: subsec_val = 0
                precise_ts = dt.timestamp() + subsec_val / 100.0
                images.append({'filename': row['FileName'], 'datetime': dt, 'exposure': exp,
                    'fnumber': fn, 'iso': iso, 'exposure_str': row.get('ExposureTime', ''),
                    'precise_ts': precise_ts})

        images.sort(key=lambda x: x['filename'])

        # Phase 1: Group by time proximity + same aperture/ISO
        raw_groups, current = [], [images[0]] if images else []
        for i in range(1, len(images)):
            p, c = images[i-1], images[i]
            td = c['precise_ts'] - p['precise_ts']
            same = c['fnumber'] == p['fnumber'] and c['iso'] == p['iso']
            if td <= max_time_gap and same:
                current.append(c)
            else:
                raw_groups.append(current)
                current = [c]
        if current: raw_groups.append(current)

        # Phase 2: Split groups that contain multiple bracket sub-sequences
        def find_bracket_subsequences(group):
            if len(group) <= 3:
                return [group]
            exps = [img['exposure'] for img in group]
            evs = [ev(e) for e in exps]
            n = len(group)

            # Detect time gaps within the group - a gap >6s suggests new bracket take
            sub_seqs = []
            current_seq = [0]
            for i in range(1, n):
                gap = group[i]['precise_ts'] - group[i-1]['precise_ts']
                if gap > 6.0:
                    sub_seqs.append(current_seq)
                    current_seq = [i]
                else:
                    current_seq.append(i)
            sub_seqs.append(current_seq)

            if len(sub_seqs) > 1:
                return [[group[i] for i in seq] for seq in sub_seqs]

            # Look for repeating bracket patterns (e.g. 3+3 or 3+3+extra)
            # Check if exposures repeat a monotonic pattern
            for pat_len in [3, 4, 5]:
                if n >= pat_len * 2 and n <= pat_len * 2 + 2:
                    first_evs = sorted(evs[:pat_len])
                    second_evs = sorted(evs[pat_len:pat_len*2])
                    # Check if the two sets have similar EV spread
                    if len(second_evs) >= pat_len:
                        spread1 = first_evs[-1] - first_evs[0]
                        spread2 = second_evs[-1] - second_evs[0]
                        if spread1 > 1.0 and spread2 > 1.0 and abs(spread1 - spread2) < 2.0:
                            result = [group[:pat_len], group[pat_len:pat_len*2]]
                            if n > pat_len * 2:
                                result.append(group[pat_len*2:])
                            return result

            return [group]

        groups = []
        for rg in raw_groups:
            groups.extend(find_bracket_subsequences(rg))

        # Phase 3: Classify groups and find optimal HDR subsets
        def find_best_hdr_subset(group):
            exps = [(i, img['exposure']) for i, img in enumerate(group)]
            if len(exps) <= 1:
                return list(range(len(group)))

            # Remove duplicate exposures (keep first of each unique EV level)
            unique = []
            for idx, exp_val in exps:
                ev_val = ev(exp_val)
                is_dup = False
                for uidx, uexp in unique:
                    if abs(ev(uexp) - ev_val) < 0.3:
                        is_dup = True
                        break
                if not is_dup:
                    unique.append((idx, exp_val))

            # Sort by exposure value (dark to bright)
            unique.sort(key=lambda x: x[1])

            # For real estate HDR: drop the darkest exposure if it's much darker
            # than the median. Dark frames pull the HDR merge down too much.
            # Keep at least 2 exposures.
            if len(unique) >= 3:
                evs_sorted = [ev(u[1]) for u in unique]
                median_ev = evs_sorted[len(evs_sorted) // 2]
                darkest_ev = evs_sorted[0]
                # If darkest is >2.5 EV below median, skip it
                if (median_ev - darkest_ev) > 2.5:
                    unique = unique[1:]  # drop darkest
                    print(f"    Hoppar over morkaste exponering (EV-diff: {median_ev - darkest_ev:.1f})")

            indices = [u[0] for u in unique]

            if len(unique) < min_bracket_size:
                return indices

            return indices

        output = {'total_images': len(images), 'total_groups': len(groups), 'groups': []}
        for i, g in enumerate(groups):
            exps = [x['exposure'] for x in g]
            er = max(exps) / max(min(exps), 0.0001) if min(exps) > 0 else 0

            # Better bracket detection:
            # 1. Need min_bracket_size unique exposure levels
            unique_evs = set()
            for e in exps:
                ev_val = round(ev(e) * 3) / 3  # quantize to 1/3 EV
                unique_evs.add(ev_val)

            has_enough_unique = len(unique_evs) >= min_bracket_size
            has_range = er > 2.0
            is_bracket = has_enough_unique and has_range

            # Find suggested HDR subset
            hdr_indices = find_best_hdr_subset(g) if is_bracket else []

            files = [x['filename'].rsplit('.', 1)[0] + '.NEF' for x in g]
            group_info = {
                'group_id': i+1, 'is_bracket': is_bracket, 'image_count': len(g),
                'files': files, 'exposures': [x['exposure_str'] for x in g],
                'fnumber': g[0]['fnumber'], 'iso': g[0]['iso'],
                'time_start': g[0]['datetime'].strftime('%H:%M:%S'),
                'time_end': g[-1]['datetime'].strftime('%H:%M:%S'),
                'date_start': g[0]['datetime'].strftime('%Y-%m-%d %H:%M:%S'),
                'date_end': g[-1]['datetime'].strftime('%Y-%m-%d %H:%M:%S'),
                'exposure_range_stops': round(er, 1),
                'suggested_hdr_indices': hdr_indices,
                'unique_exposure_levels': len(unique_evs)}
            output['groups'].append(group_info)

        br = [x for x in output['groups'] if x['is_bracket']]
        output['bracket_groups_count'] = len(br)
        output['single_groups_count'] = len(output['groups']) - len(br)
        with open(output_json, 'w') as f: json.dump(output, f, indent=2)
        for g in output['groups']:
            tag = ' [HDR]' if g['is_bracket'] else ''
            sel = f" sel={g['suggested_hdr_indices']}" if g['suggested_hdr_indices'] else ''
            print(f"  Grupp {g['group_id']:3d}: {g['image_count']} imgs, {g['unique_exposure_levels']} unika EV, f/{g['fnumber']}{tag}{sel}")
        print(f"Grupper: {len(output['groups'])}, HDR: {len(br)}")
        """
    }

    private func organizeGroupsPython() -> String {
        """
        import json, os, sys
        groups_json, source_dir, dng_dir, groups_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
        with open(groups_json, 'r') as f: data = json.load(f)
        for g in data['groups']:
            gid, ib = g['group_id'], g['is_bracket']
            fn = f"bracket_{gid:03d}_HDR_{g['image_count']}exp" if ib else f"single_{gid:03d}_{g['image_count']}img"
            gf = os.path.join(groups_dir, fn)
            os.makedirs(gf, exist_ok=True)
            for f2 in g['files']:
                src = os.path.join(source_dir, f2)
                dst = os.path.join(gf, f2)
                if os.path.exists(src) and not os.path.exists(dst):
                    os.symlink(os.path.abspath(src), dst)
                dn = f2.rsplit('.', 1)[0] + '.dng'
                sd = os.path.join(dng_dir, dn)
                dd = os.path.join(gf, dn)
                if os.path.exists(sd) and not os.path.exists(dd):
                    os.symlink(os.path.abspath(sd), dd)
        """
    }

    /// Python script for Mertens exposure fusion via OpenCV.
    /// Usage: python3 script.py output.jpg input1.jpg input2.jpg input3.jpg
    private func mertensFusionPython() -> String {
        """
        import cv2, numpy as np, sys

        output_path = sys.argv[1]
        input_paths = sys.argv[2:]

        images = [cv2.imread(p) for p in input_paths]
        images = [img for img in images if img is not None]

        if len(images) < 2:
            print(f"Error: only {len(images)} valid images", file=sys.stderr)
            sys.exit(1)

        # Ensure all same size
        h, w = images[0].shape[:2]
        images = [cv2.resize(img, (w, h)) if img.shape[:2] != (h, w) else img for img in images]

        # Mertens exposure fusion - blends best-exposed regions from each image
        merge = cv2.createMergeMertens(
            contrast_weight=1.0,
            saturation_weight=1.0,
            exposure_weight=1.0
        )
        fusion = merge.process(images)

        # Clamp and convert to 16-bit for maximum quality
        result_16 = np.clip(fusion * 65535, 0, 65535).astype(np.uint16)

        # Save as 16-bit TIFF (lossless, raw-like quality)
        cv2.imwrite(output_path, result_16)

        # Also save a JPEG preview for the UI
        if output_path.lower().endswith('.tiff') or output_path.lower().endswith('.tif'):
            jpeg_path = output_path.rsplit('.', 1)[0] + '.jpg'
        else:
            jpeg_path = output_path + '.jpg'
        result_8 = np.clip(fusion * 255, 0, 255).astype(np.uint8)
        cv2.imwrite(jpeg_path, result_8, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"Mertens fusion: {len(images)} bilder -> {output_path} + preview")
        """
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
