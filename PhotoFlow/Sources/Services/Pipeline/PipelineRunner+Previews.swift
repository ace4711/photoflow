import Foundation

extension PipelineRunner {
    // MARK: - Step 3: Preview Generation

    func runPreviewGeneration(inputDir: URL) async throws {
        state.currentStep = .generatingPreviews

        guard let outputDir = state.outputDirectory else { throw PipelineError.toolNotFound("Ingen outputmapp") }
        let previewDir = outputDir.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let nefFiles = findNEFFiles(in: inputDir)

        // Fas 8: manifest-fingerprint satt HÄR (innan något skip-beslut), av
        // samma skäl som bracket-analysen/AI-taggningen i Fas 6 — så
        // manifestet alltid får rätt värde när steget markeras klart nedanför
        // i PipelineRunner.swift, oavsett vilken gren nedan tar. Preview-
        // extraktion har inga egna inställningar som påverkar resultatet
        // (samma exiftool-kommando oavsett), så fingerprintet är bara
        // filnamn+storlek — den faktiska skip-kontrollen är fortfarande den
        // per-fil-baserade jämförelsen nedanför (starkare än ett fingerprint
        // ensamt: den upptäcker exakt VILKA NEF-filer som saknar en preview).
        let fingerprint = SessionManifestStore.fingerprint(fileURLs: nefFiles)
        state.setPendingFingerprint(fingerprint, for: .generatePreviews)

        // Check if all previews already exist — compare basenames, not counts.
        // A raw count comparison ("existingPreviews >= nefFiles.count") can pass
        // even when the previews on disk don't actually match the current NEF set
        // (e.g. leftover previews from a differently-named batch), which then
        // skipped generation for NEFs that had no preview at all.
        let existingPreviewNames = Set((try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { $0.deletingPathExtension().lastPathComponent } ?? [])
        let nefBaseNames = Set(nefFiles.map { $0.deletingPathExtension().lastPathComponent })
        if nefBaseNames.isSubset(of: existingPreviewNames) {
            logDecision(step: "preview_generation", decision: "skipped", details: [
                "reason": "all_exist",
                "existingCount": "\(existingPreviewNames.count)",
                "nefCount": "\(nefFiles.count)",
                "fingerprint": fingerprint
            ])
            state.appendLog("Alla \(nefFiles.count) previews finns redan — hoppar over.", type: .info)
            state.appendStepLog(.generatePreviews, "Alla \(nefFiles.count) previews finns redan — hoppar over", type: .info)
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
                executablePath: try requireExiftool(),
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
}
