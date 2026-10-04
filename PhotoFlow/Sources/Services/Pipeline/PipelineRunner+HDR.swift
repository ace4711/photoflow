import Foundation

extension PipelineRunner {
    // MARK: - Step 4: HDR Merge
    //
    // Two engines, selectable via `AppSettings.hdrEngine` (Fas 3a):
    // - "coreImage" (default): real exposure fusion on RAW data (DNG/NEF) via
    //   `Services/HDR/` (CIRAWFilter + a from-scratch Mertens implementation
    //   on Accelerate). Preserves RAW dynamic range instead of fusing 8-bit
    //   embedded JPEG previews.
    // - "opencv": the original path — Mertens fusion via python3/OpenCV on
    //   the 8-bit embedded JPEG previews. Kept as a fallback/comparison engine.

    /// Felsökningsläge (`photoflow-cli --hdr-debug`): varje sammanslagning skriver mask,
    /// exponeringsmatchad mörk ram, fusion utan window pull och `hdr_metrics.json` till
    /// `<output>/hdr_debug/hdr_group_<id>/`.
    nonisolated(unsafe) static var hdrDebugEnabled = false

    /// En grupps HDR-jobb.
    struct HDRMergeJob {
        var groupId: Int
        var previewPaths: [String]
        var frames: [HDREngine.Frame]
        var windowSource: HDREngine.Frame?
        /// NEF-filnamnen för fusionsramarna och fönsterkällan (till `hdr.json`).
        var frameNames: [String]
        var windowSourceName: String?
        var manualSelection: Bool
        var firstPhotoDate: Date?
        var fingerprint: String
        var tiffURL: URL
        var jpegURL: URL
        var reason: String
    }

    /// HDR-motorns inställningar som `HDREngine.Options` (mask/felsökning läggs till per grupp).
    func currentHDROptions() -> HDREngine.Options {
        HDREngine.Options(
            maxDimension: AppSettings.shared.hdrMaxDimension,
            alignEnabled: AppSettings.shared.hdrAlignEnabled,
            sharpenEnabled: AppSettings.shared.hdrSharpenEnabled,
            windowPull: AppSettings.shared.hdrEngine == "opencv" ? WindowPull.Options(enabled: false) : AppSettings.shared.windowPullOptions
        )
    }

    /// Fingerprint för en grupps HDR med de nuvarande inställningarna (se `HDRLog.fingerprint`).
    func currentHDRFingerprint(identity: [URL]) -> String {
        let settings = AppSettings.shared
        return HDRLog.fingerprint(identity: identity, engine: settings.hdrEngine, maxDimension: settings.hdrMaxDimension,
                                  align: settings.hdrAlignEnabled, sharpen: settings.hdrSharpenEnabled,
                                  windowPull: settings.hdrEngine == "opencv" ? WindowPull.Options(enabled: false) : settings.windowPullOptions)
    }

    /// Fönstermasken för en grupp (`hdr_masks/hdr_group_<id>.png` i outputroten).
    static func hdrMaskURL(outputDir: URL, groupId: Int) -> URL {
        outputDir.appendingPathComponent("hdr_masks").appendingPathComponent("hdr_group_\(groupId).png")
    }

    /// - Parameter forceAll: "Kör om steget" — gör om alla grupper, även aktuella, och skriv
    ///   där filerna redan ligger (även i en sorterad adressmapp).
    func runHDRMerge(forceAll: Bool = false) async throws {
        guard let outputDir = state.outputDirectory else { return }

        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard FileManager.default.fileExists(atPath: groupsJSON.path) else { return }

        let data = try Data(contentsOf: groupsJSON)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return }

        let previewDir = outputDir.appendingPathComponent("previews")
        let dngDir = outputDir.appendingPathComponent("dng")
        let hdrDir = outputDir.appendingPathComponent("hdr")
        try FileManager.default.createDirectory(at: hdrDir, withIntermediateDirectories: true)

        let bracketGroups = groups.filter { ($0["is_bracket"] as? Bool) == true }
        guard !bracketGroups.isEmpty else { return }

        let engine = AppSettings.shared.hdrEngine
        let engineLabel = engine == "opencv" ? "Mertens exposure fusion (OpenCV)" : "Exposure fusion (Core Image RAW)"

        state.currentStep = .mergingHDR
        state.statusMessage = "Slår ihop HDR-brackets (\(engineLabel))..."
        state.totalFiles = bracketGroups.count
        state.currentFileIndex = 0
        state.progress = 0.0
        state.appendLog("Startar HDR-sammanslagning med \(engineLabel) (\(bracketGroups.count) bracket-grupper)...", type: .info)

        // Recursive NEF lookup, used to resolve the RAW fallback when a file
        // hasn't been converted to DNG yet (same pattern as loadBracketGroups).
        var nefLookup: [String: URL] = [:]
        if let inputDir = state.inputDirectory {
            for url in findNEFFiles(in: inputDir) {
                nefLookup[url.lastPathComponent] = url
            }
        }

        // Vilka grupper som ska slås ihop: saknad fil, ändrat fingerprint (andra exponeringar
        // eller HDR-inställningar), eller äldre motorversion om inställningen säger det.
        // Befintliga filer utan post i hdr.json adopteras (migrering) i stället för att göras om.
        // Filer som sorteringen redan flyttat till en adressmapp skrivs om där de ligger.
        let existingHDR = AddressFolderLayout.locateHDRFiles(in: outputDir)
        var hdrLog = (forceAll ? nil : HDRLog.load(from: outputDir)) ?? HDRLog()
        let policy = HDRLog.RedoPolicy(setting: AppSettings.shared.hdrRedoOnEngineUpdate)
        let windowPullOn = engine != "opencv" && AppSettings.shared.hdrWindowPullEnabled
        var adopted = 0
        var groupsToMerge: [HDRMergeJob] = []
        for group in bracketGroups {
            let groupId = (group["group_id"] as? Int) ?? 0
            let key = HDRLog.key(groupId: groupId)
            let files = (group["files"] as? [String]) ?? []
            let exposures = ((group["exposures"] as? [String]) ?? []).map { (try? ExifReader.parseExposureString($0)) ?? 0 }
            let suggestedIndices = (group["suggested_hdr_indices"] as? [Int]) ?? Array(0..<files.count)
            let entry = hdrLog.entries[key]

            func exposure(of index: Int) -> Double { index < exposures.count ? exposures[index] : 0 }
            // Urvalet: granskningens om gruppen gjorts om manuellt (sparat i hdr.json), annars förslaget.
            var selectedIndices = suggestedIndices.filter { $0 < files.count }
            if let entry, entry.manualSelection {
                let manual = entry.frames.compactMap { files.firstIndex(of: $0) }
                if manual.count >= 2 { selectedIndices = manual }
            }
            let selectedFiles = selectedIndices.map { files[$0] }

            // Preview JPEGs (full-resolution embedded previews from NEF) — used by the OpenCV engine.
            let previewPaths = selectedFiles.compactMap { filename -> String? in
                let baseName = filename.replacingOccurrences(of: ".NEF", with: "")
                let preview = previewDir.appendingPathComponent("\(baseName).jpg")
                return FileManager.default.fileExists(atPath: preview.path) ? preview.path : nil
            }

            // RAW files (DNG preferred, NEF fallback) — used by the Core Image engine.
            func rawURL(_ filename: String) -> URL? {
                let baseName = filename.replacingOccurrences(of: ".NEF", with: "")
                let dngURL = dngDir.appendingPathComponent("\(baseName).dng")
                if FileManager.default.fileExists(atPath: dngURL.path) { return dngURL }
                return nefLookup[filename]
            }
            let frames = selectedIndices.compactMap { i in rawURL(files[i]).map { HDREngine.Frame(url: $0, exposureSeconds: exposure(of: i)) } }

            // Fönsterkällan: gruppens mörkaste exponering, även om förslaget sorterat bort den.
            var windowSource: HDREngine.Frame?
            var windowSourceName: String?
            if windowPullOn, !files.isEmpty {
                let darkestIndex = exposures.count == files.count && exposures.allSatisfy({ $0 > 0 })
                    ? exposures.indices.min(by: { exposures[$0] < exposures[$1] })!
                    : (selectedIndices.first ?? 0)
                if let url = rawURL(files[darkestIndex]) {
                    windowSource = HDREngine.Frame(url: url, exposureSeconds: exposure(of: darkestIndex))
                    windowSourceName = files[darkestIndex]
                }
            }

            let usable = engine == "opencv" ? previewPaths.count : frames.count
            guard usable >= 2 else { continue }

            // Identitet: original-NEF:erna (skrivs aldrig till).
            let identityNames = selectedFiles + (windowSourceName.map { selectedFiles.contains($0) ? [] : [$0] } ?? [])
            let identity = identityNames.compactMap { nefLookup[$0] }
            let fingerprint = currentHDRFingerprint(identity: identity)
            let existing = existingHDR[groupId]
            let decision = HDRLog.decide(fileExists: existing?.tiff != nil, entry: entry, fingerprint: fingerprint,
                                         currentVersion: HDREngine.version, policy: policy, force: forceAll,
                                         identityComplete: identity.count == identityNames.count)
            switch decision {
            case .skip:
                continue
            case .adopt:
                hdrLog.entries[key] = HDRLog.Entry(engineVersion: HDRLog.legacyEngineVersion, fingerprint: fingerprint, adopted: true,
                                                   frames: selectedFiles)
                adopted += 1
                continue
            case .merge(let reason):
                groupsToMerge.append(HDRMergeJob(
                    groupId: groupId, previewPaths: previewPaths, frames: frames, windowSource: windowSource,
                    frameNames: selectedFiles, windowSourceName: windowSourceName,
                    manualSelection: entry?.manualSelection ?? false,
                    firstPhotoDate: Self.firstPhotoDate(ofGroup: group), fingerprint: fingerprint,
                    tiffURL: existing?.tiff ?? hdrDir.appendingPathComponent("hdr_group_\(groupId).tiff"),
                    jpegURL: existing?.jpeg ?? hdrDir.appendingPathComponent("hdr_group_\(groupId).jpg"),
                    reason: reason))
            }
        }
        if adopted > 0 || forceAll {
            hdrLog.updatedAt = Date()
            hdrLog.save(to: outputDir)
            if adopted > 0 {
                state.appendStepLog(.createHDR, "\(adopted) befintliga HDR-filer registrerade i hdr.json (görs inte om)", type: .info)
            }
        }

        if groupsToMerge.isEmpty {
            logDecision(step: "hdr_merge", decision: "skipped", details: [
                "reason": "all_complete"
            ])
            state.appendLog("Alla HDR-grupper redan klara.", type: .info)
            state.progress = 1.0
            return
        }

        // Resolve the chosen engine's tool dependency once up front — failing
        // per-group would produce "N misslyckades" instead of one clear message.
        let python3Path = engine == "opencv" ? try requirePython3WithOpenCV() : nil
        let exiftoolPath = try? requireExiftool()

        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
        if engine == "opencv" {
            try mertensFusionPython().write(to: scriptPath, atomically: true, encoding: .utf8)
        }
        defer { if engine == "opencv" { try? FileManager.default.removeItem(at: scriptPath) } }

        let baseOptions = currentHDROptions()
        let debugDir = Self.hdrDebugEnabled ? outputDir.appendingPathComponent("hdr_debug") : nil

        // Fas 1b: adress, GPS och bokningsinfo är kända efter kalendersteget, så metadatan skrivs
        // direkt i samma exiftool-anrop som EXIF-kopian (i stället för en omskrivning till i
        // metadatasteget). Bilderna är inte inlästa än (`loadBracketGroups` körs efter HDR), så
        // AI-uppslaget saknas — men en HDR-fil heter aldrig som en bild och får därför inga AI-taggar.
        let photoBaseNames = Set(groups.flatMap { ($0["files"] as? [String]) ?? [] }
            .map { $0.replacingOccurrences(of: ".NEF", with: "") })
        let metadataContext = await creationMetadataContext(photoBaseNames: photoBaseNames)

        var successCount = 0
        var failCount = 0
        state.updateStepProgress(.createHDR, processed: 0, total: groupsToMerge.count)
        if groupsToMerge.count < bracketGroups.count { state.markStepUntimed(.createHDR) }

        for (idx, group) in groupsToMerge.enumerated() {
            try await checkCancellationAndWaitIfPaused()
            state.statusMessage = "\(engineLabel): grupp \(group.groupId) (\(idx + 1)/\(groupsToMerge.count))..."
            state.currentFileIndex = idx
            state.progress = Double(idx) / Double(groupsToMerge.count)
            state.updateStepProgress(.createHDR, processed: idx, total: groupsToMerge.count)

            let inputCount = engine == "opencv" ? group.previewPaths.count : group.frames.count
            state.appendLog("HDR grupp \(group.groupId): \(inputCount) bilder (\(engineLabel))...", type: .info)

            // Update detailed progress
            state.currentMergeGroupId = group.groupId
            state.currentMergeInputURLs = engine == "opencv"
                ? group.previewPaths.map { URL(fileURLWithPath: $0) }
                : group.frames.map(\.url)
            state.currentMergeOutputURL = nil

            let outputPath = group.tiffURL.path
            let previewPath = group.jpegURL.path
            // TIFF:en byts in först när den är färdigskriven, så en misslyckad omgörning lämnar den gamla.
            try? FileManager.default.createDirectory(at: group.tiffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: group.jpegURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let inputNames = (engine == "opencv" ? group.previewPaths.map { URL(fileURLWithPath: $0).lastPathComponent } : group.frames.map(\.url.lastPathComponent)).joined(separator: ", ")
            let windowNote = group.windowSourceName.map { group.frameNames.contains($0) ? "" : ", fönster från \($0)" } ?? ""
            state.appendStepLog(.createHDR, "HDR grupp \(group.groupId) (\(group.reason)): mergar \(inputCount) bilder (\(inputNames)\(windowNote))...")
            var mergeResult: HDREngine.MergeResult?

            let groupStarted = Date()
            do {
                if engine == "opencv" {
                    guard let python3Path else { throw PipelineError.toolNotFound("python3 med OpenCV saknas") }
                    _ = try await runProcess(
                        executablePath: python3Path,
                        arguments: [scriptPath.path, outputPath] + group.previewPaths
                    )
                } else {
                    let groupLabel = "Grupp \(idx + 1)/\(groupsToMerge.count)"
                    let imageCount = group.frames.count + (group.windowSourceName.map { group.frameNames.contains($0) ? 0 : 1 } ?? 0)
                    let state = self.state
                    let reporter = HDRProgressReporter()
                    let rawURLs = group.frames.map(\.url)
                    let tiffURL = group.tiffURL
                    let jpegURL = group.jpegURL
                    // Sorteringen flyttar filerna till gruppens adressmapp (första bildens fotodatum);
                    // ligger filen redan i en adressmapp gäller den. Okänt datum → okänd mapp: bara
                    // EXIF nu, metadatasteget tar resten.
                    let groupFolder = group.firstPhotoDate.map { addressFolderName(forPhotoDate: $0) }
                    func fileMetadata(for url: URL) -> IPTCFileMetadata? {
                        guard let folder = Self.addressFolderName(containing: url) ?? groupFolder else { return nil }
                        return Self.creationMetadata(for: url, folderName: folder, context: metadataContext)
                    }
                    let metadata = (tiff: fileMetadata(for: tiffURL), jpeg: fileMetadata(for: jpegURL))
                    var hdrOptions = baseOptions
                    hdrOptions.maskURL = Self.hdrMaskURL(outputDir: outputDir, groupId: group.groupId)
                    hdrOptions.debugDir = debugDir
                    let frames = group.frames
                    let windowSource = group.windowSource
                    let result = try await PipelineMetrics.jobAsync(
                        step: "hdr", unit: "group:\(group.groupId)",
                        bytesIn: PipelineMetrics.totalSize(of: rawURLs),
                        bytesOut: { (_: HDREngine.MergeResult) in
                            PipelineMetrics.totalSize(of: [URL(fileURLWithPath: outputPath), URL(fileURLWithPath: previewPath)])
                        }
                    ) {
                        try await HDREngine.merge(
                            frames: frames,
                            windowSource: windowSource,
                            options: hdrOptions,
                            tiffURL: tiffURL,
                            jpegURL: jpegURL,
                            exiftoolPath: exiftoolPath,
                            metadata: metadata,
                            progress: { fraction in
                                guard let phase = reporter.newPhase(for: fraction, imageCount: imageCount) else { return }
                                Task { @MainActor in
                                    state.statusMessage = "\(engineLabel): \(groupLabel) — \(phase)"
                                    state.appendStepLog(.createHDR, "\(groupLabel): \(phase)")
                                }
                            }
                        )
                    }
                    recordCreationStamps([(tiffURL, metadata.tiff), (jpegURL, metadata.jpeg)],
                                         metadataWritten: result.metadataWritten, outputDir: outputDir)
                    let rewroteSorted = Self.addressFolderName(containing: tiffURL) != nil || Self.addressFolderName(containing: jpegURL) != nil
                    if rewroteSorted && (metadata.tiff == nil || metadata.jpeg == nil || !result.metadataWritten) {
                        // En levererad fil skrevs om utan full metadata: metadatasteget måste köras igen.
                        try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
                    }
                    mergeResult = result
                }

                if FileManager.default.fileExists(atPath: outputPath) {
                    hdrLog.entries[HDRLog.key(groupId: group.groupId)] = HDRLog.Entry(
                        engineVersion: HDREngine.version, fingerprint: group.fingerprint, frames: group.frameNames,
                        manualSelection: group.manualSelection,
                        reference: mergeResult.map { $0.referenceFrame.deletingPathExtension().lastPathComponent + ".NEF" },
                        windowSource: mergeResult?.windowSource == nil ? nil : group.windowSourceName,
                        window: mergeResult?.window, mergedAt: Date(), seconds: Date().timeIntervalSince(groupStarted))
                    hdrLog.updatedAt = Date()
                    hdrLog.save(to: outputDir)
                    if let window = mergeResult?.window {
                        state.appendStepLog(.createHDR, window.applied
                            ? String(format: "HDR grupp %d: fönster från mörkaste exponeringen (%.1f %% av bilden, gain %+.1f EV)", group.groupId, window.maskFraction * 100, window.gainEV)
                            : "HDR grupp \(group.groupId): ingen window pull — \(window.reason ?? "inget att hämta")")
                    }
                    successCount += 1
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
                    let took = StepTiming.formatExact(Date().timeIntervalSince(groupStarted))
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): klar på \(took) → hdr_group_\(group.groupId).tiff (\(sizeMB) MB)", type: .success)
                    state.appendLog("HDR \(idx + 1)/\(groupsToMerge.count) klar på \(took)", type: .success)
                    // Show JPEG preview in UI
                    let showURL = FileManager.default.fileExists(atPath: previewPath)
                        ? URL(fileURLWithPath: previewPath)
                        : URL(fileURLWithPath: outputPath)
                    state.currentMergeOutputURL = showURL
                    pipelineLog("  Grupp \(group.groupId): \(engineLabel) klar (16-bit TIFF)")
                } else {
                    failCount += 1
                    state.appendStepLog(.createHDR, "HDR grupp \(group.groupId): ingen output skapad", type: .error)
                    pipelineLog("  Grupp \(group.groupId): Ingen output skapad.")
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
            state.appendLog("HDR-sammanslagning klar: \(successCount) grupper (\(engineLabel)).", type: .success)
        } else {
            state.appendLog("HDR-sammanslagning: \(successCount) lyckades, \(failCount) misslyckades.", type: .warning)
        }
        audio.playStepComplete()
        NotificationService.shared.notifyHDRComplete(successCount: successCount, failCount: failCount)
    }

    /// Re-merge a single bracket group after user changes selection.
    /// Called from BracketReviewView when user modifies which photos are included.
    /// Returnerar URL:erna som skrevs om (TIFF + JPEG) när det lyckades, så att
    /// appen kan tömma bildcachen för dem — filnamnen är desamma som förut.
    @discardableResult
    func reMergeHDR(group: BracketGroup) async -> [URL] {
        guard let outputDir = state.outputDirectory else { return [] }
        let hdrDir = outputDir.appendingPathComponent("hdr")

        let selectedPhotos = state.photos(in: group).filter { $0.accepted }
        guard selectedPhotos.count >= 2 else {
            state.appendLog("Grupp \(group.id): Minst 2 bilder krävs för HDR.", type: .warning)
            return []
        }

        // Den gamla HDR:en får ligga kvar tills den nya är klar — TIFF:en byts
        // in först när den är färdigskriven (HDRWriter), så ett misslyckat
        // försök lämnar den föregående sammanslagningen orörd.
        // Skriv där gruppens HDR redan ligger: efter sorteringen i adressmappen,
        // så att den levererade filen byts ut och inte en kopia i hdr/.
        let existing = AddressFolderLayout.locateHDRFiles(in: outputDir)[group.id]
        let hdrTiff = existing?.tiff ?? hdrDir.appendingPathComponent("hdr_group_\(group.id).tiff")
        let hdrJpeg = existing?.jpeg ?? hdrDir.appendingPathComponent("hdr_group_\(group.id).jpg")
        try? FileManager.default.createDirectory(at: hdrDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: hdrDir.appendingPathComponent("hdr_group_\(group.id).tif"))

        state.reMergingGroups.insert(group.id)
        defer { state.reMergingGroups.remove(group.id) }
        var mergeSucceeded = false
        var mergeResult: HDREngine.MergeResult?
        let started = Date()
        // Fönsterkällan: gruppens mörkaste exponering, även om den inte är vald.
        let groupPhotos = state.photos(in: group)
        let darkest = groupPhotos.allSatisfy({ $0.exposureSeconds > 0 })
            ? groupPhotos.min(by: { $0.exposureSeconds < $1.exposureSeconds }) : nil
        let windowPhoto = AppSettings.shared.hdrWindowPullEnabled && AppSettings.shared.hdrEngine != "opencv" ? darkest : nil

        let engine = AppSettings.shared.hdrEngine
        let engineLabel = engine == "opencv" ? "Mertens exposure fusion (OpenCV)" : "Exposure fusion (Core Image RAW)"
        state.appendLog("Gör om HDR för grupp \(group.id) med \(selectedPhotos.count) bilder (\(engineLabel))...", type: .info)

        do {
            if engine == "opencv" {
                let previewPaths = selectedPhotos.compactMap { photo -> String? in
                    guard let url = photo.previewURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url.path
                }
                guard previewPaths.count >= 2 else {
                    state.appendLog("Grupp \(group.id): för få förhandsbilder för OpenCV-fusion.", type: .warning)
                    return []
                }
                guard let python3Path = ToolLocator.python3WithOpenCV else {
                    state.appendLog("python3 med OpenCV (cv2) och numpy saknas — installera med: pip3 install opencv-python numpy", type: .error)
                    return []
                }
                let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow_mertens.py")
                try mertensFusionPython().write(to: scriptPath, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: scriptPath) }
                _ = try await runProcess(
                    executablePath: python3Path,
                    arguments: [scriptPath.path, hdrTiff.path] + previewPaths
                )
                mergeSucceeded = true
            } else {
                let frames = selectedPhotos.map { HDREngine.Frame(url: $0.dngURL ?? $0.nefURL, exposureSeconds: $0.exposureSeconds) }
                guard frames.count >= 2 else {
                    state.appendLog("Grupp \(group.id): för få RAW-filer (DNG/NEF) för HDR.", type: .warning)
                    return []
                }
                var hdrOptions = currentHDROptions()
                hdrOptions.maskURL = Self.hdrMaskURL(outputDir: outputDir, groupId: group.id)
                // Samma metadata som metadatasteget skulle skriva (fas 1b): mappen filen redan ligger
                // i, annars den sorteringen flyttar den till. Saknar adressen GPS ännu, eller är
                // metadatan okänd, skrivs bara EXIF och stämpeln tas bort så att metadatasteget skriver resten.
                let metadataContext = await creationMetadataContext()
                let groupFolder = addressFolderName(forPhotoDate: state.photos(in: group).first?.dateTime)
                func fileMetadata(for url: URL) -> IPTCFileMetadata? {
                    Self.creationMetadata(for: url, folderName: Self.addressFolderName(containing: url) ?? groupFolder,
                                          context: metadataContext)
                }
                let metadata = (tiff: fileMetadata(for: hdrTiff), jpeg: fileMetadata(for: hdrJpeg))
                let result = try await HDREngine.merge(
                    frames: frames,
                    windowSource: windowPhoto.map { HDREngine.Frame(url: $0.dngURL ?? $0.nefURL, exposureSeconds: $0.exposureSeconds) },
                    options: hdrOptions,
                    tiffURL: hdrTiff,
                    jpegURL: hdrJpeg,
                    exiftoolPath: try? requireExiftool(),
                    metadata: metadata
                )
                mergeResult = result
                let metadataWritten = result.metadataWritten
                recordCreationStamps([(hdrTiff, metadata.tiff), (hdrJpeg, metadata.jpeg)],
                                     metadataWritten: metadataWritten, outputDir: outputDir)
                if metadata.tiff == nil || metadata.jpeg == nil || !metadataWritten {
                    // Metadatasteget måste köras igen för den här gruppens filer.
                    try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
                }
                mergeSucceeded = true
            }
        } catch {
            state.appendLog("Fusion misslyckades: \(error.localizedDescription)", type: .error)
        }

        if mergeSucceeded, FileManager.default.fileExists(atPath: hdrTiff.path) {
            // Granskningens urval sparas i hdr.json, så att HDR-steget inte går tillbaka till
            // bracket-analysens förslag (och gör om gruppen) vid nästa körning.
            let frameNames = selectedPhotos.map(\.filename)
            let windowName = mergeResult?.windowSource == nil ? nil : windowPhoto?.filename
            let identityNames = frameNames + (windowName.map { frameNames.contains($0) ? [] : [$0] } ?? [])
            let nefByName = Dictionary(groupPhotos.map { ($0.filename, $0.nefURL) }, uniquingKeysWith: { a, _ in a })
            var hdrLog = HDRLog.load(from: outputDir) ?? HDRLog()
            hdrLog.entries[HDRLog.key(groupId: group.id)] = HDRLog.Entry(
                engineVersion: HDREngine.version,
                fingerprint: currentHDRFingerprint(identity: identityNames.compactMap { nefByName[$0] }),
                frames: frameNames, manualSelection: true,
                reference: mergeResult.map { $0.referenceFrame.deletingPathExtension().lastPathComponent + ".NEF" },
                windowSource: windowName, window: mergeResult?.window, mergedAt: Date(),
                seconds: Date().timeIntervalSince(started))
            hdrLog.updatedAt = Date()
            hdrLog.save(to: outputDir)

            // Use JPEG preview for UI if available, otherwise TIFF
            let previewURL = FileManager.default.fileExists(atPath: hdrJpeg.path) ? hdrJpeg : hdrTiff
            if let idx = state.bracketGroups.firstIndex(where: { $0.id == group.id }) {
                state.bracketGroups[idx].mergedHDRPreviewURL = previewURL
                state.bracketGroups[idx].enhancedPreviewURL = nil // gammal förbättring hör till den förra sammanslagningen
            }
            state.appendLog("HDR-ommerge klar för grupp \(group.id) (16-bit TIFF).", type: .success)
            // Förbättra gruppen direkt, annars visar granskningen (och levererar sorteringen)
            // den förbättrade versionen av den förra sammanslagningen.
            let enhanced = await reEnhanceHDRGroup(group.id)
            audio.playStepComplete()
            return [hdrTiff, hdrJpeg] + enhanced
        } else {
            state.appendLog("HDR-ommerge misslyckades för grupp \(group.id) — den tidigare sammanslagningen ligger kvar.", type: .error)
            audio.playError()
            return []
        }
    }

    /// Fotodatumet för gruppens första bild, räknat som `loadBracketGroups` gör (bildens egen
    /// tid i `datetimes`, annars gruppens `date_start`) — det avgör vilken adressmapp gruppens
    /// HDR-filer sorteras till (`moveUnsortedHDR`). nil om inget av dem går att tolka
    /// (`loadBracketGroups` tar då dagens datum, alltså i praktiken "Osorterade").
    nonisolated static func firstPhotoDate(ofGroup group: [String: Any]) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let first = (group["datetimes"] as? [String])?.first, let date = formatter.date(from: first) {
            return date
        }
        return (group["date_start"] as? String).flatMap { formatter.date(from: $0) }
    }

    /// Python script for Mertens exposure fusion via OpenCV (the "opencv" engine).
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

/// Gör `HDREngine.merge`s täta förloppsanrop (0…1) till några få läsbara
/// faser för loggen, och rapporterar bara när fasen byts.
nonisolated final class HDRProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    func newPhase(for fraction: Double, imageCount: Int) -> String? {
        let phase = Self.phase(for: fraction, imageCount: imageCount)
        lock.lock(); defer { lock.unlock() }
        guard phase != last else { return nil }
        last = phase
        return phase
    }

    /// Faserna följer `HDREngine.merge`: 5–50 % RAW-rendering per bild,
    /// 55 % justering klar, 55–90 % exposure fusion, 95 % TIFF/JPEG skrivna.
    static func phase(for fraction: Double, imageCount: Int) -> String {
        switch fraction {
        case ..<0.5:
            let done = Int(((fraction - 0.05) / 0.45 * Double(imageCount)).rounded(.down))
            return "renderar RAW \(min(max(done + 1, 1), imageCount))/\(imageCount)"
        case ..<0.55: return "justerar bilderna mot varandra"
        case ..<0.9: return "slår ihop exponeringarna"
        default: return "sparar TIFF och JPEG"
        }
    }
}
