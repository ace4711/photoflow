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
            state.appendLog("Alla \(nefFiles.count) previews finns redan — hoppar över.", type: .info)
            state.appendStepLog(.generatePreviews, "Alla \(nefFiles.count) previews finns redan — hoppar över", type: .info)
            // Äldre sessioner: rotationen skrevs inte förut — rätta en gång.
            if !FileManager.default.fileExists(atPath: previewDir.appendingPathComponent(Self.orientationMarker).path) {
                try await applyPreviewOrientation(nefFiles: nefFiles, previewDir: previewDir)
            }
            state.progress = 1.0
            return
        }

        state.appendLog("Genererar JPEG-previews...", type: .info)
        state.appendStepLog(.generatePreviews, "Genererar previews för \(nefFiles.count) NEF-filer...")

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
        if alreadyDone > 0 { state.markStepUntimed(.generatePreviews) }

        state.currentFileIndex = alreadyDone
        state.progress = Double(alreadyDone) / Double(nefFiles.count)

        if !filesToProcess.isEmpty {
            // Use a single exiftool call to extract all embedded JPEG previews at once.
            // -W creates output files using the format string: %d = source dir, %f = filename
            // We write to previewDir/%f.jpg for each input NEF.
            let pathsList = filesToProcess.map { $0.path }.joined(separator: "\n")
            let formatString = previewDir.path + "/%f.jpg"

            let exiftoolPath = try requireExiftool()
            let previewDirURL = previewDir
            try await PipelineMetrics.jobAsync(
                step: "previews", unit: "batch:\(filesToProcess.count) filer",
                bytesIn: PipelineMetrics.totalSize(of: filesToProcess),
                bytesOut: { (_: Void) in
                    PipelineMetrics.totalSize(of: filesToProcess.map { previewDirURL.appendingPathComponent("\($0.deletingPathExtension().lastPathComponent).jpg") })
                }
            ) {
                _ = try await runProcess(
                    executablePath: exiftoolPath,
                    arguments: ["-b", "-JpgFromRaw", "-W", formatString, "-@", "-"],
                    stdinData: pathsList.data(using: .utf8)
                )
            }

        }

        // Rotationen skrivs för de nya förhandsbilderna — eller för alla, om
        // mappen kommer från en körning innan detta fanns.
        let markerExists = FileManager.default.fileExists(atPath: previewDir.appendingPathComponent(Self.orientationMarker).path)
        if !markerExists || !filesToProcess.isEmpty {
            try await applyPreviewOrientation(nefFiles: markerExists ? filesToProcess : nefFiles, previewDir: previewDir)
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

    // MARK: - Rotation

    /// Markerfil i previews/: rotationen är skriven för mappens förhandsbilder.
    static let orientationMarker = ".orientation_v1"

    /// Den inbäddade JPEG:en (JpgFromRaw) i en Z 8-NEF är alltid liggande och
    /// saknar rotationsflagga — porträttbilder visades därför på sidan i
    /// granskningen tills RAW-renderingen (som roterar) tog över. Läser
    /// NEF-filernas Orientation i ett exiftool-anrop och skriver den till
    /// förhandsbilderna som behöver den. Pixlarna rörs inte; bildladdarna läser
    /// flaggan (`kCGImageSourceCreateThumbnailWithTransform`).
    func applyPreviewOrientation(nefFiles: [URL], previewDir: URL) async throws {
        guard !nefFiles.isEmpty else { return }
        let exiftool = try requireExiftool()
        let listing = try await PipelineMetrics.jobAsync(step: "previews", unit: "orientation:\(nefFiles.count) filer") {
            try await runProcess(
                executablePath: exiftool,
                arguments: ["-q", "-T", "-n", "-FileName", "-Orientation", "-@", "-"],
                stdinData: nefFiles.map(\.path).joined(separator: "\n").data(using: .utf8)
            )
        }
        let rotated = Self.parseOrientations(listing).filter { $0.value != 1 }
        var lines: [String] = []
        for (base, orientation) in rotated.sorted(by: { $0.key < $1.key }) {
            let preview = previewDir.appendingPathComponent("\(base).jpg")
            guard FileManager.default.fileExists(atPath: preview.path) else { continue }
            lines += ["-overwrite_original", "-Orientation#=\(orientation)", preview.path, "-execute"]
        }
        if !lines.isEmpty {
            _ = try await runProcess(
                executablePath: exiftool,
                arguments: ["-q", "-@", "-"],
                stdinData: lines.joined(separator: "\n").data(using: .utf8)
            )
            state.appendStepLog(.generatePreviews, "Rotation satt på \(lines.count / 4) porträttbilder", type: .info)
        }
        FileManager.default.createFile(atPath: previewDir.appendingPathComponent(Self.orientationMarker).path, contents: Data())
    }

    /// `exiftool -T -n -FileName -Orientation` → [filnamn utan ändelse: orientering].
    /// Rader utan siffra (t.ex. "-" när taggen saknas) hoppas över.
    nonisolated static func parseOrientations(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            result[(String(parts[0]) as NSString).deletingPathExtension] = value
        }
        return result
    }
}
