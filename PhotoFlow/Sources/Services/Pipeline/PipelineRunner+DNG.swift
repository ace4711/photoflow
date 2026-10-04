import Foundation

extension PipelineRunner {
    // MARK: - Atomisk DNG-utdata (fas 1a, #7)
    //
    // Adobe DNG Converter skriver sina filer fortlöpande medan ett parti pågår. Skrev den
    // direkt i `dng/` räknades en halvskriven fil (appen avslutad, processen dödad, disken
    // full) som färdig av hoppa-över-logiken. Nu skrivs varje parti till `dng/.partial/` och
    // filerna flyttas till `dng/` (en omdöpning på samma volym, alltså atomisk per fil) först
    // när processen avslutats utan fel. `.partial` städas vid start och efter varje parti.

    /// Undermappen i `dng/` där ett pågående parti skrivs.
    nonisolated static let dngPartialDirName = ".partial"

    /// Namn (utan ändelse, gemener) på de riktiga DNG-filerna direkt i `dngDir`. Räknar inte
    /// symlänkar, dolda filer eller något i `.partial/`.
    nonisolated static func completedDNGNames(in dngDir: URL) -> Set<String> {
        var names = Set<String>()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dngDir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return names }
        for fileURL in entries where fileURL.pathExtension.lowercased() == "dng" {
            let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { continue }
            names.insert(fileURL.deletingPathExtension().lastPathComponent.lowercased())
        }
        return names
    }

    /// Tar bort `dng/.partial/` (rester av ett avbrutet parti).
    nonisolated static func cleanDNGPartial(in dngDir: URL) {
        try? FileManager.default.removeItem(at: dngDir.appendingPathComponent(dngPartialDirName))
    }

    /// Flyttar färdiga `.dng`-filer från `partialDir` till `dngDir` (ersätter en befintlig fil
    /// med samma namn). Returnerar de flyttade filernas nya sökvägar.
    @discardableResult
    nonisolated static func promotePartialDNGs(from partialDir: URL, to dngDir: URL) throws -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: partialDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var moved: [URL] = []
        for file in entries where file.pathExtension.lowercased() == "dng" {
            let destination = dngDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: file)
            } else {
                try fm.moveItem(at: file, to: destination)
            }
            moved.append(destination)
        }
        return moved
    }

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
        // Rester av ett avbrutet parti städas först; bara färdiga filer direkt i dng/ räknas.
        Self.cleanDNGPartial(in: dngDir)
        let existingDNGNames = Self.completedDNGNames(in: dngDir)
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
        if !existingDNGNames.isEmpty { state.markStepUntimed(.convertToDNG) }

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

        let partialDir = dngDir.appendingPathComponent(Self.dngPartialDirName)
        defer { Self.cleanDNGPartial(in: dngDir) }

        var convertedSoFar = existingDNGNames.count
        for (chunkIndex, chunk) in chunks.enumerated() {
            try await checkCancellationAndWaitIfPaused()
            // Nytt tomt `.partial` per parti: en död process kan inte lämna filer som nästa parti flyttar.
            Self.cleanDNGPartial(in: dngDir)
            try FileManager.default.createDirectory(at: partialDir, withIntermediateDirectories: true)
            let batchUnit = "batch:\(chunkIndex + 1)/\(chunks.count)"
            try await PipelineMetrics.jobAsync(
                step: "dng", unit: batchUnit,
                bytesIn: PipelineMetrics.totalSize(of: chunk.map { URL(fileURLWithPath: $0) }),
                bytesOut: { (moved: [URL]) in PipelineMetrics.totalSize(of: moved) }
            ) { () async throws -> [URL] in
                _ = try await runProcess(
                    executablePath: converterPath,
                    // `-mp`: konverteraren delar partiet på flera processer. Mätt på 150 NEF (intern disk):
                    // 13,1 s utan, 8,8 s med (−33 %); fyra egna samtidiga processer gav samma 8,8 s och två
                    // 9,7 s, så ett parti med `-mp` räcker. DNG-filerna har identisk metadata (inkl.
                    // RawImageDigest) som utan flaggan. På T5 begränsas steget av disken, där gör den ~0.
                    arguments: ["-c", "-mp", "-d", partialDir.path] + chunk
                ) { _ in }
                // Processen gick bra: först nu räknas filerna som färdiga.
                return try PipelineMetrics.phase("promote") { try Self.promotePartialDNGs(from: partialDir, to: dngDir) }
            }

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
