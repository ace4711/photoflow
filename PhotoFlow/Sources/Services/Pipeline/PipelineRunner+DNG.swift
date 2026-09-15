import Foundation

extension PipelineRunner {
    // MARK: - Step 1: DNG Conversion
    // internal: called from PipelineRunner.swift (startPipeline/rerunStep).

    func runDNGConversion(inputDir: URL) async throws {
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

        // Check which DNG files already exist in the dng/ staging folder only.
        // Address folders also contain DNG entries, but those are symlinks back into
        // this same staging folder — scanning outputDir recursively double-counted
        // them (harmless for the count itself, but meant a fresh dng/ folder with
        // stale address-folder symlinks pointing at now-deleted files could still
        // report "all exist"). Regular files only, so a symlink can never masquerade
        // as a real conversion result.
        var existingDNGNames = Set<String>()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dngDir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) {
            for fileURL in entries where fileURL.pathExtension.lowercased() == "dng" {
                let isSymlink = (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                guard !isSymlink else { continue }
                existingDNGNames.insert(fileURL.deletingPathExtension().lastPathComponent.lowercased())
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
            try await checkCancellationAndWaitIfPaused()
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
            .filter { $0.pathExtension.lowercased() == "dng" }
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
}
