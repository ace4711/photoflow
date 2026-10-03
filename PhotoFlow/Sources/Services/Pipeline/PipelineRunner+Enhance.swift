import Foundation

extension PipelineRunner {
    // MARK: - Steg: Förbättra bilder
    //
    // Körs efter HDR-sammanslagningen och bracket-grupperna är inlästa, före
    // "Sortera filer". En färdig bild per motiv:
    //  - HDR-TIFF för varje bracket-grupp (ligger i `hdr/` eller redan i en adressmapp),
    //  - DNG-rendering (annars förhandsbilden) för varje bild i en singelgrupp.
    // Resultatet (16-bitars TIFF + JPEG) skrivs till `enhanced/<nyckel>_enh.*`;
    // sorteringen flyttar det sedan till `<adress> FÖRBÄTTRADE/`
    // (`moveUnsortedEnhanced`). Originalen, DNG och HDR-filerna rörs aldrig.

    /// En bild som ska förbättras.
    struct EnhanceJob: Equatable {
        enum Kind: String { case hdr, dng, preview }
        /// `hdr_group_<id>` eller bildens basnamn.
        var key: String
        var kind: Kind
        var source: URL
        var label: String
    }

    /// Vilka bilder som ska förbättras, och hur många som hoppas över (avvisade
    /// i gallringen, eller bracket-grupper utan HDR-fil).
    func enhanceJobs(outputDir: URL) -> (jobs: [EnhanceJob], skippedRejected: Int, skippedNoSource: Int) {
        let fm = FileManager.default
        let hdrFiles = AddressFolderLayout.locateHDRFiles(in: outputDir)
        var jobs: [EnhanceJob] = []
        var rejected = 0, noSource = 0
        for group in state.bracketGroups {
            let photos = state.photos(in: group)
            if group.isBracket {
                if !photos.isEmpty, photos.allSatisfy(\.rejected) { rejected += 1; continue }
                guard let tiff = hdrFiles[group.id]?.tiff, fm.fileExists(atPath: tiff.path) else { noSource += 1; continue }
                jobs.append(EnhanceJob(key: "hdr_group_\(group.id)", kind: .hdr, source: tiff, label: "HDR grupp \(group.id)"))
            } else {
                for photo in photos {
                    if photo.rejected { rejected += 1; continue }
                    if let dng = photo.dngURL, fm.fileExists(atPath: dng.path) {
                        jobs.append(EnhanceJob(key: photo.displayName, kind: .dng, source: dng, label: photo.displayName))
                    } else if let preview = photo.previewURL, fm.fileExists(atPath: preview.path) {
                        jobs.append(EnhanceJob(key: photo.displayName, kind: .preview, source: preview, label: photo.displayName))
                    } else {
                        noSource += 1
                    }
                }
            }
        }
        return (jobs, rejected, noSource)
    }

    /// Per-bild-fingerprint: källfilens namn, storlek och ändringstid + profilens
    /// innehåll + motorns version (+ det som ändrar renderingen av källan).
    func enhanceFingerprint(job: EnhanceJob, profile: EnhancementProfile) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: job.source.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let settings = AppSettings.shared
        return SessionManifestStore.fingerprint(fileURLs: [job.source], settings: [
            "profile": profile.canonicalJSON,
            "engine": "\(EnhancementEngine.version)",
            "mtime": "\(Int(mtime))",
            "kind": job.kind.rawValue,
            "maxDimension": job.kind == .dng ? "\(settings.hdrMaxDimension)" : "-",
            "hdrSharpen": job.kind == .hdr ? "\(settings.hdrSharpenEnabled)" : "-"
        ])
    }

    /// Kör steget. Returnerar antalet bilder som nu är förbättrade (gjorda + redan klara).
    @discardableResult
    func runEnhancePhotos() async throws -> Int {
        guard let outputDir = state.outputDirectory else { return 0 }
        let fm = FileManager.default
        let settings = AppSettings.shared
        let profile = EnhancementProfileStore.shared.profile(id: settings.enhanceProfileID)
        let stagingDir = AddressFolderLayout.enhancedStagingDir(in: outputDir)
        state.recordEnhancementProfile(profile.id)

        let (jobs, skippedRejected, skippedNoSource) = enhanceJobs(outputDir: outputDir)
        state.currentStep = .enhancingPhotos

        var log = EnhancementLog.load(from: outputDir) ?? EnhancementLog(engineVersion: EnhancementEngine.version, profileID: profile.id)
        log.engineVersion = EnhancementEngine.version
        log.profileID = profile.id

        let existing = AddressFolderLayout.locateEnhancedFiles(in: outputDir)
        var fingerprints: [String: String] = [:]
        var pending: [EnhanceJob] = []
        for job in jobs {
            let fingerprint = enhanceFingerprint(job: job, profile: profile)
            fingerprints[job.key] = fingerprint
            let files = existing[job.key] ?? []
            let hasTiff = files.contains { ["tiff", "tif"].contains($0.pathExtension.lowercased()) }
            let hasJpeg = files.contains { $0.pathExtension.lowercased() == "jpg" }
            if hasTiff, hasJpeg, log.entries[job.key]?.fingerprint == fingerprint { continue }
            pending.append(job)
        }
        let alreadyDone = jobs.count - pending.count

        state.setPendingFingerprint(
            SessionManifestStore.fingerprint(fileURLs: jobs.map(\.source), settings: [
                "profile": profile.canonicalJSON, "engine": "\(EnhancementEngine.version)"
            ]),
            for: .enhancePhotos
        )

        if skippedRejected > 0 {
            state.appendStepLog(.enhancePhotos, "\(skippedRejected) avvisade bilder/grupper hoppas över", type: .info)
        }
        if skippedNoSource > 0 {
            state.appendStepLog(.enhancePhotos, "\(skippedNoSource) motiv saknar HDR-fil/DNG/förhandsbild och hoppas över", type: .warning)
        }

        if pending.isEmpty {
            state.markStepUntimed(.enhancePhotos)
            logDecision(step: "enhance", decision: "skipped", details: [
                "reason": jobs.isEmpty ? "no_images" : "all_complete",
                "images": "\(jobs.count)", "profile": profile.id
            ])
            state.appendStepLog(.enhancePhotos,
                jobs.isEmpty ? "Inga bilder att förbättra" : "Alla \(jobs.count) bilder redan förbättrade (\(profile.name)) — hoppar över",
                type: .info)
            state.appendLog("Förbättra bilder: inget att göra.", type: .info)
            return jobs.count
        }
        if alreadyDone > 0 { state.markStepUntimed(.enhancePhotos) }

        let exiftoolPath = try? requireExiftool()
        state.statusMessage = "Förbättrar bilder (\(profile.name))..."
        state.totalFiles = pending.count
        state.currentFileIndex = 0
        state.progress = 0
        state.appendStepLog(.enhancePhotos, "Förbättrar \(pending.count) bilder med profilen \"\(profile.name)\"" + (alreadyDone > 0 ? " (\(alreadyDone) redan klara)" : ""))
        state.appendLog("Förbättrar \(pending.count) bilder (profil \(profile.name))...", type: .info)
        state.updateStepProgress(.enhancePhotos, processed: 0, total: pending.count)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var done = 0, failed = 0
        for (idx, job) in pending.enumerated() {
            try await checkCancellationAndWaitIfPaused()
            state.statusMessage = "Förbättrar \(job.label) (\(idx + 1)/\(pending.count))..."
            state.currentFileIndex = idx
            state.progress = Double(idx) / Double(pending.count)
            state.updateStepProgress(.enhancePhotos, processed: idx, total: pending.count)

            let tiff = stagingDir.appendingPathComponent("\(job.key)\(AddressFolderLayout.enhancedFileSuffix).tiff")
            let jpeg = stagingDir.appendingPathComponent("\(job.key)\(AddressFolderLayout.enhancedFileSuffix).jpg")
            let source: EnhancementEngine.Source = job.kind == .dng
                ? .raw(job.source, maxDimension: settings.hdrMaxDimension)
                : .image(job.source)
            let request = EnhancementEngine.Request(
                source: source, tiffURL: tiff, jpegURL: jpeg, profile: profile,
                alreadySharpened: job.kind == .hdr && settings.hdrSharpenEnabled,
                exifSource: job.source, exiftoolPath: exiftoolPath
            )
            let started = Date()
            do {
                let outcome = try await EnhancementEngine.enhance(request)
                let seconds = Date().timeIntervalSince(started)
                log.entries[job.key] = EnhancementLog.Entry(
                    kind: job.kind.rawValue, source: job.source.lastPathComponent,
                    fingerprint: fingerprints[job.key] ?? "", profileID: profile.id, profile: profile,
                    analysis: outcome.analysis, autoParameters: outcome.autoParameters, parameters: outcome.parameters,
                    outputs: [tiff.lastPathComponent, jpeg.lastPathComponent],
                    width: outcome.width, height: outcome.height, seconds: seconds, date: Date()
                )
                log.updatedAt = Date()
                log.save(to: outputDir)
                done += 1
                state.appendStepLog(.enhancePhotos,
                    "\(job.label) [\(profile.name)]: \(outcome.parameters.summary) — \(StepTiming.formatExact(seconds))",
                    type: .success)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                state.appendStepLog(.enhancePhotos, "\(job.label): misslyckades — \(error.localizedDescription)", type: .error)
                pipelineLog("  Förbättring \(job.label) misslyckades: \(error.localizedDescription)")
            }
            state.currentFileIndex = idx + 1
            state.progress = Double(idx + 1) / Double(pending.count)
        }

        state.progress = 1.0
        logDecision(step: "enhance", decision: "done", details: [
            "enhanced": "\(done)", "failed": "\(failed)", "alreadyDone": "\(alreadyDone)", "profile": profile.id
        ])
        if failed == 0 {
            state.appendLog("Förbättra bilder klart: \(done) bilder (\(profile.name)).", type: .success)
        } else {
            state.appendLog("Förbättra bilder: \(done) lyckades, \(failed) misslyckades.", type: .warning)
        }
        return done + alreadyDone
    }
}
