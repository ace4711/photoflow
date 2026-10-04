import Foundation
import CryptoKit

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
        /// Bilden är taggad som exteriör: bara då rätas horisonten (se `EnhancementEngine`).
        var isExterior: Bool = false
        /// Filer som identifierar källans innehåll i fingerprintet: original-NEF:erna,
        /// som aldrig skrivs till. Källan själv (HDR-TIFF, DNG, förhandsbild) duger inte —
        /// metadatasteget skriver EXIF/GPS i den efteråt, så storlek och ändringstid byts
        /// och varje omkörning såg alla bilder som ändrade.
        var identity: [URL] = []
        /// Fönstermasken från window pull (bara HDR; filen behöver inte finnas).
        var windowMask: URL? = nil
    }

    /// Exteriör enligt AI-taggarna (Vision): taggen "Exteriör" och ingen "Interiör".
    static func isExterior(_ photos: [PhotoItem]) -> Bool {
        let tags = Set(photos.flatMap(\.aiTags))
        return tags.contains("Exteriör") && !tags.contains("Interiör")
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
                // Exponeringarna som ingick: de godkända om urvalet ändrats i granskningen
                // (en ny sammanslagning görs då med dem), annars alla i gruppen.
                let merged = photos.contains(where: \.accepted) ? photos.filter(\.accepted) : photos
                jobs.append(EnhanceJob(key: "hdr_group_\(group.id)", kind: .hdr, source: tiff, label: "HDR grupp \(group.id)",
                                      isExterior: Self.isExterior(photos), identity: merged.map(\.nefURL),
                                      windowMask: Self.hdrMaskURL(outputDir: outputDir, groupId: group.id)))
            } else {
                for photo in photos {
                    if photo.rejected { rejected += 1; continue }
                    if let dng = photo.dngURL, fm.fileExists(atPath: dng.path) {
                        jobs.append(EnhanceJob(key: photo.displayName, kind: .dng, source: dng, label: photo.displayName,
                                          isExterior: Self.isExterior([photo]), identity: [photo.nefURL]))
                    } else if let preview = photo.previewURL, fm.fileExists(atPath: preview.path) {
                        jobs.append(EnhanceJob(key: photo.displayName, kind: .preview, source: preview, label: photo.displayName,
                                          isExterior: Self.isExterior([photo]), identity: [photo.nefURL]))
                    } else {
                        noSource += 1
                    }
                }
            }
        }
        return (jobs, rejected, noSource)
    }

    /// Engångsövergången från det gamla fingerprintet: samma motor, samma profil och
    /// samma källa. `enhancement.json` sparar källans filnamn (inte hela sökvägen),
    /// så jämförelsen görs på namnet — förut jämfördes hela sökvägen och ingen bild
    /// godkändes.
    static func canAdoptPreviousEnhancement(entry: EnhancementLog.Entry, job: EnhanceJob, profile: EnhancementProfile,
                                            previousEngineVersion: Int) -> Bool {
        previousEngineVersion == EnhancementEngine.version
            && entry.profile == profile
            && entry.kind == job.kind.rawValue
            && (entry.source == job.source.lastPathComponent || entry.source == job.source.path)
    }

    /// Per-bild-fingerprint: original-NEF:ernas namn och storlek (de skrivs aldrig
    /// till — se `EnhanceJob.identity`) + profilens innehåll + motorns version + det
    /// som ändrar källan (HDR-motorns version och inställningar, DNG-renderingens storlek).
    func enhanceFingerprint(job: EnhanceJob, profile: EnhancementProfile) -> String {
        let settings = AppSettings.shared
        return SessionManifestStore.fingerprint(fileURLs: job.identity.isEmpty ? [job.source] : job.identity, settings: [
            "profile": profile.canonicalJSON,
            "engine": "\(EnhancementEngine.version)",
            "kind": job.kind.rawValue,
            "straighten": "\(job.isExterior)",
            "maxDimension": "\(settings.hdrMaxDimension)",
            "hdr": job.kind == .hdr ? "v\(HDREngine.version) align=\(settings.hdrAlignEnabled) sharpen=\(settings.hdrSharpenEnabled)" : "-",
            "windowMask": Self.windowMaskDigest(job.windowMask)
        ])
    }

    /// Fönstermaskens innehåll (SHA-256, förkortad) för fingerprintet; "-" utan mask.
    nonisolated static func windowMaskDigest(_ url: URL?) -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "-" }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Förfrågan till `EnhancementEngine` för ett jobb. Metadatan följer mappen filen ligger
    /// i (en `<adress> FÖRBÄTTRADE`-mapp), annars den sorteringen flyttar den till.
    func enhanceRequest(job: EnhanceJob, profile: EnhancementProfile, tiffURL: URL, jpegURL: URL,
                        exiftoolPath: String?, metadataContext: CreationMetadataContext) -> EnhancementEngine.Request {
        let settings = AppSettings.shared
        let source: EnhancementEngine.Source = job.kind == .dng
            ? .raw(job.source, maxDimension: settings.hdrMaxDimension)
            : .image(job.source)
        // Sorteringen flyttar filerna till `<adress> FÖRBÄTTRADE/` (`moveUnsortedEnhanced`).
        let folderName = Self.addressFolderName(containing: tiffURL) ?? enhancedFolderName(forKey: job.key)
        return EnhancementEngine.Request(
            source: source, tiffURL: tiffURL, jpegURL: jpegURL, profile: profile,
            alreadySharpened: job.kind == .hdr && settings.hdrSharpenEnabled,
            exifSource: job.source, exiftoolPath: exiftoolPath,
            tiffMetadata: Self.creationMetadata(for: tiffURL, folderName: folderName, context: metadataContext),
            jpegMetadata: Self.creationMetadata(for: jpegURL, folderName: folderName, context: metadataContext),
            allowStraighten: job.isExterior,
            windowMaskURL: job.windowMask
        )
    }

    /// En förbättring av en HDR-grupp är inaktuell när HDR-filen skrevs om efter den
    /// (`hdr.json`s `mergedAt`). Fingerprintet räcker inte: det bygger på original-NEF:erna,
    /// som är desamma när bara HDR-motorn eller fönsterinställningarna ändrats.
    nonisolated static func enhancementIsStale(enhancedAt: Date, hdrMergedAt: Date?) -> Bool {
        guard let hdrMergedAt else { return false }
        return hdrMergedAt > enhancedAt
    }

    /// Gör om förbättringen av en HDR-grupp direkt efter en omsammanslagning i granskningen,
    /// så att den förbättrade bilden (som granskningen visar och sorteringen levererar) inte
    /// blir kvar från den förra sammanslagningen. Skriver där den förbättrade filen redan
    /// ligger (`<adress> FÖRBÄTTRADE/` efter sorteringen). Finns ingen förbättring än görs
    /// inget — steget "Förbättra bilder" tar den när det körs.
    /// Returnerar de omskrivna filerna (för bildcachen).
    @discardableResult
    func reEnhanceHDRGroup(_ groupId: Int) async -> [URL] {
        let settings = AppSettings.shared
        guard settings.enhanceEnabled, let outputDir = state.outputDirectory else { return [] }
        let key = "hdr_group_\(groupId)"
        let existing = AddressFolderLayout.locateEnhancedFiles(in: outputDir)[key] ?? []
        var log = EnhancementLog.load(from: outputDir)
        guard !existing.isEmpty || log?.entries[key] != nil else { return [] }
        guard let job = enhanceJobs(outputDir: outputDir).jobs.first(where: { $0.key == key }) else { return [] }

        let profile = EnhancementProfileStore.shared.profile(id: settings.enhanceProfileID)
        let stagingDir = AddressFolderLayout.enhancedStagingDir(in: outputDir)
        let tiff = existing.first { ["tiff", "tif"].contains($0.pathExtension.lowercased()) }
            ?? stagingDir.appendingPathComponent("\(key)\(AddressFolderLayout.enhancedFileSuffix).tiff")
        let jpeg = existing.first { $0.pathExtension.lowercased() == "jpg" }
            ?? stagingDir.appendingPathComponent("\(key)\(AddressFolderLayout.enhancedFileSuffix).jpg")
        try? FileManager.default.createDirectory(at: tiff.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: jpeg.deletingLastPathComponent(), withIntermediateDirectories: true)

        let req = enhanceRequest(job: job, profile: profile, tiffURL: tiff, jpegURL: jpeg,
                                 exiftoolPath: try? requireExiftool(), metadataContext: await creationMetadataContext())
        state.appendLog("Förbättrar om HDR grupp \(groupId) efter omsammanslagningen...", type: .info)
        let started = Date()
        do {
            let outcome = try await EnhancementEngine.enhance(req)
            recordCreationStamps([(req.tiffURL, req.tiffMetadata), (req.jpegURL, req.jpegMetadata)],
                                 metadataWritten: outcome.metadataWritten, outputDir: outputDir)
            if Self.addressFolderName(containing: tiff) != nil,
               req.tiffMetadata == nil || req.jpegMetadata == nil || !outcome.metadataWritten {
                try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
            }
            var updated = log ?? EnhancementLog(engineVersion: EnhancementEngine.version, profileID: profile.id)
            updated.entries[key] = EnhancementLog.Entry(
                kind: job.kind.rawValue, source: job.source.lastPathComponent,
                fingerprint: enhanceFingerprint(job: job, profile: profile), profileID: profile.id, profile: profile,
                analysis: outcome.analysis, autoParameters: outcome.autoParameters, parameters: outcome.parameters,
                outputs: [tiff.lastPathComponent, jpeg.lastPathComponent],
                width: outcome.width, height: outcome.height, seconds: Date().timeIntervalSince(started), date: Date()
            )
            updated.updatedAt = Date()
            updated.save(to: outputDir)
            log = updated
            if let idx = state.bracketGroups.firstIndex(where: { $0.id == groupId }) {
                state.bracketGroups[idx].enhancedPreviewURL = jpeg
            }
            state.appendLog("HDR grupp \(groupId) förbättrad igen (\(profile.name)).", type: .success)
            return [tiff, jpeg]
        } catch {
            state.appendLog("Förbättringen av HDR grupp \(groupId) misslyckades: \(error.localizedDescription)", type: .error)
            return []
        }
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
        let previousEngineVersion = log.engineVersion
        log.engineVersion = EnhancementEngine.version
        log.profileID = profile.id

        let existing = AddressFolderLayout.locateEnhancedFiles(in: outputDir)
        let hdrLog = HDRLog.load(from: outputDir)
        var fingerprints: [String: String] = [:]
        var pending: [EnhanceJob] = []
        var migrated = 0
        for job in jobs {
            let fingerprint = enhanceFingerprint(job: job, profile: profile)
            fingerprints[job.key] = fingerprint
            let files = existing[job.key] ?? []
            let hasTiff = files.contains { ["tiff", "tif"].contains($0.pathExtension.lowercased()) }
            let hasJpeg = files.contains { $0.pathExtension.lowercased() == "jpg" }
            if hasTiff, hasJpeg, let entry = log.entries[job.key] {
                // HDR-filen omgjord efter förbättringen (ny motor, fönsterinställningar, omsammanslagning).
                if job.kind == .hdr, Self.enhancementIsStale(enhancedAt: entry.date, hdrMergedAt: hdrLog?.entries[job.key]?.mergedAt) {
                    pending.append(job)
                    continue
                }
                if entry.fingerprint == fingerprint { continue }
                // Engångsövergång från det gamla fingerprintet (källans storlek/tid, som
                // metadatasteget ändrar): samma motor, samma profil och samma källfil →
                // resultatet är detsamma; uppdatera fingerprintet i stället för att göra om.
                if Self.canAdoptPreviousEnhancement(entry: entry, job: job, profile: profile,
                                                    previousEngineVersion: previousEngineVersion) {
                    log.entries[job.key]?.fingerprint = fingerprint
                    migrated += 1
                    continue
                }
            }
            pending.append(job)
        }
        if migrated > 0 {
            log.save(to: outputDir)
            state.appendStepLog(.enhancePhotos, "\(migrated) redan förbättrade bilder godkända med nytt fingerprint (ingen omräkning)", type: .info)
        }
        let alreadyDone = jobs.count - pending.count

        state.setPendingFingerprint(
            SessionManifestStore.fingerprint(fileURLs: jobs.flatMap { $0.identity.isEmpty ? [$0.source] : $0.identity }, settings: [
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
        var finished = 0

        // Fas 1b: adress, GPS och AI-taggar är kända, så metadatan skrivs i samma exiftool-anrop
        // som EXIF-kopian i stället för att metadatasteget skriver om filen en gång till.
        let metadataContext = await creationMetadataContext()

        func request(for job: EnhanceJob) -> EnhancementEngine.Request {
            enhanceRequest(job: job, profile: profile,
                           tiffURL: stagingDir.appendingPathComponent("\(job.key)\(AddressFolderLayout.enhancedFileSuffix).tiff"),
                           jpegURL: stagingDir.appendingPathComponent("\(job.key)\(AddressFolderLayout.enhancedFileSuffix).jpg"),
                           exiftoolPath: exiftoolPath, metadataContext: metadataContext)
        }

        // RAW-rendering/Core Image-kedjan per bild är till stor del enkeltrådad, så några bilder körs
        // samtidigt. Tre räcker: minnet är ~0,5 GB per bild. (HDR-TIFF:erna är okomprimerade sedan
        // fas 1a, så avkodningen är försumbar; tidigare LZW kostade ~0,3 s per bild.)
        let maxConcurrent = min(3, max(1, ProcessInfo.processInfo.activeProcessorCount / 3))
        try await withThrowingTaskGroup(of: (Int, Result<EnhancementEngine.Outcome, Error>, Double).self) { @MainActor group in
            var next = 0
            var running = 0
            @MainActor func launchNext() async throws {
                try await checkCancellationAndWaitIfPaused()
                let idx = next
                next += 1
                running += 1
                let job = pending[idx]
                let req = request(for: job)
                state.statusMessage = "Förbättrar \(job.label) (\(idx + 1)/\(pending.count))..."
                state.currentFileIndex = idx
                group.addTask {
                    let started = Date()
                    do {
                        let outcome = try await PipelineMetrics.jobAsync(
                            step: "enhance", unit: job.key,
                            bytesIn: PipelineMetrics.totalSize(of: [job.source]),
                            bytesOut: { (_: EnhancementEngine.Outcome) in PipelineMetrics.totalSize(of: [req.tiffURL, req.jpegURL]) }
                        ) {
                            try await EnhancementEngine.enhance(req)
                        }
                        return (idx, .success(outcome), Date().timeIntervalSince(started))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (idx, .failure(error), Date().timeIntervalSince(started))
                    }
                }
            }
            while next < pending.count && running < maxConcurrent { try await launchNext() }
            while let (idx, result, seconds) = try await group.next() {
                running -= 1
                finished += 1
                let job = pending[idx]
                switch result {
                case .success(let outcome):
                    let req = request(for: job)
                    recordCreationStamps([(req.tiffURL, req.tiffMetadata), (req.jpegURL, req.jpegMetadata)],
                                         metadataWritten: outcome.metadataWritten, outputDir: outputDir)
                    log.entries[job.key] = EnhancementLog.Entry(
                        kind: job.kind.rawValue, source: job.source.lastPathComponent,
                        fingerprint: fingerprints[job.key] ?? "", profileID: profile.id, profile: profile,
                        analysis: outcome.analysis, autoParameters: outcome.autoParameters, parameters: outcome.parameters,
                        outputs: [req.tiffURL.lastPathComponent, req.jpegURL.lastPathComponent],
                        width: outcome.width, height: outcome.height, seconds: seconds, date: Date()
                    )
                    log.updatedAt = Date()
                    log.save(to: outputDir)
                    done += 1
                    state.appendStepLog(.enhancePhotos,
                        "\(job.label) [\(profile.name)]: \(outcome.parameters.summary) — \(StepTiming.formatExact(seconds))",
                        type: .success)
                case .failure(let error):
                    failed += 1
                    state.appendStepLog(.enhancePhotos, "\(job.label): misslyckades — \(error.localizedDescription)", type: .error)
                    pipelineLog("  Förbättring \(job.label) misslyckades: \(error.localizedDescription)")
                }
                state.progress = Double(finished) / Double(pending.count)
                state.updateStepProgress(.enhancePhotos, processed: finished, total: pending.count)
                if next < pending.count { try await launchNext() }
            }
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
