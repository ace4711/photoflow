import Foundation

extension PipelineRunner {
    // MARK: - Step 2: Bracket Analysis

    func runBracketAnalysis(inputDir: URL) async throws {
        state.currentStep = .analyzingBrackets
        state.statusMessage = "Analyserar EXIF-data och detekterar brackets..."
        state.progress = 0.0

        guard let outputDir = state.outputDirectory else { throw PipelineError.toolNotFound("Ingen outputmapp") }

        // Skip if bracket_groups.json already exists with matching file count AND
        // matching analysis params — otherwise a settings change would silently
        // keep using the old grouping.
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        let nefFiles = findNEFFiles(in: inputDir)
        let maxTimeGap = AppSettings.shared.maxTimeGap
        let minBracketSize = AppSettings.shared.minBracketSize
        if FileManager.default.fileExists(atPath: groupsJSON.path) {
            if let data = try? Data(contentsOf: groupsJSON),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let totalImages = json["total_images"] as? Int,
               totalImages == nefFiles.count,
               let params = json["params"] as? [String: Any],
               (params["max_time_gap"] as? Int) == maxTimeGap,
               (params["min_bracket_size"] as? Int) == minBracketSize {
                logDecision(step: "bracket_analysis", decision: "skipped", details: [
                    "reason": "json_exists_matching_count_and_params",
                    "totalImages": "\(totalImages)",
                    "nefCount": "\(nefFiles.count)",
                    "maxTimeGap": "\(maxTimeGap)",
                    "minBracketSize": "\(minBracketSize)"
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
        try await checkCancellationAndWaitIfPaused()

        let groupsDir = outputDir.appendingPathComponent("bracket_groups")
        try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

        // Read EXIF via ImageIO (ExifReader), falling back to exiftool only for
        // ExposureTime (verified unreliable via ImageIO on some real NEFs — see
        // ExifReader's doc comment). Replaces the old exiftool CSV dump + embedded
        // Python parsing.
        pipelineLog("  bracket: läser EXIF via ImageIO (\(nefFiles.count) filer)...")
        let records = try await ExifReader.readAll(nefFiles: nefFiles, exiftoolPath: try requireExiftool())
        pipelineLog("  bracket: EXIF-läsning klar (\(records.count)/\(nefFiles.count) filer gav giltig EXIF)")

        // Written for debugging only now (nothing downstream reads it) — same
        // idea as the old exiftool CSV dump, generated from what we actually read.
        let exifCSV = outputDir.appendingPathComponent("exif_data.csv")
        Self.writeExifDebugCSV(records: records, nefFiles: nefFiles, to: exifCSV)

        state.progress = 0.5
        try await checkCancellationAndWaitIfPaused()

        // Run bracket analysis (pure Swift port of the old Python script — see
        // BracketAnalyzer.swift)
        let params = BracketAnalysisParams(maxTimeGap: maxTimeGap, minBracketSize: minBracketSize)
        let analysis = BracketAnalyzer.analyze(records: records, params: params)
        pipelineLog("  bracket: analys klar (\(analysis.groups.count) grupper, \(analysis.bracketGroupsCount) brackets)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let jsonData = try encoder.encode(analysis)
        try jsonData.write(to: groupsJSON)

        // Create symlinked bracket group folders. The old Python version built
        // NEF paths as `source_dir/filename`, which silently produced no symlink
        // at all for NEFs in subfolders (findNEFFiles searches recursively) —
        // fixed here by reusing the same recursive lookup loadBracketGroups uses.
        try await checkCancellationAndWaitIfPaused()
        var nefLookup: [String: URL] = [:]
        for url in nefFiles { nefLookup[url.lastPathComponent] = url }
        Self.organizeGroupsIntoFolders(
            groups: analysis.groups,
            nefLookup: nefLookup,
            dngDir: outputDir.appendingPathComponent("dng"),
            groupsDir: groupsDir
        )
        pipelineLog("  bracket: grupperna organiserade i \(groupsDir.lastPathComponent)/")

        state.appendStepLog(.createHDR, "\(analysis.groups.count) grupper: \(analysis.bracketGroupsCount) brackets, \(analysis.singleGroupsCount) singlar", type: .success)

        state.progress = 1.0
        state.appendLog("Bracket-analys klar.", type: .success)
        audio.playStepComplete()
    }

    /// Writes a CSV of the EXIF fields `ExifReader` read, purely for manual
    /// debugging (nothing in the app reads this file back). Not a byte-for-byte
    /// replacement of the old exiftool CSV dump — columns match what
    /// `ExifRecord` actually carries.
    nonisolated static func writeExifDebugCSV(records: [ExifRecord], nefFiles: [URL], to url: URL) {
        var sourceByFilename: [String: String] = [:]
        for nef in nefFiles { sourceByFilename[nef.lastPathComponent] = nef.path }

        func csvField(_ value: String) -> String {
            guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        var lines = ["SourceFile,FileName,ExposureTime,FNumber,ISO,DateTimeOriginal,SubSecTimeOriginal,Orientation"]
        for record in records.sorted(by: { $0.filename < $1.filename }) {
            let source = sourceByFilename[record.filename] ?? record.filename
            // Original digit count (1-3) isn't preserved in the parsed Double —
            // this is a debug CSV, so a fixed 3-digit representation is fine.
            let subsecDigits = String(format: "%03.0f", record.subsec * 1000)
            lines.append([
                csvField(source),
                csvField(record.filename),
                csvField(record.exposureTime),
                csvField(String(record.fNumber)),
                csvField(String(record.iso)),
                csvField(dateFormatter.string(from: record.dateTimeOriginal)),
                csvField(subsecDigits),
                csvField(String(record.orientation))
            ].joined(separator: ","))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
