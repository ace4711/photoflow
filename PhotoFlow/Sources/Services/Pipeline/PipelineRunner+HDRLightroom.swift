import Foundation
import AppKit

extension PipelineRunner {
    // MARK: - HDR-motorn "Lightroom Classic"
    //
    // Gruppernas ramar kopieras till `<output>/lr_staging/group_<id>/`, ETT trigger skickas till
    // pluginet (`mode = "render"`) och Lightroom slår ihop, framkallar (Auto) och exporterar en
    // 16-bitars sRGB-TIFF exakt dit den inbyggda motorn skulle lagt den (`HDRMergeJob.tiffURL`).
    // Efteråt görs JPEG-förhandsvisningen, EXIF/IPTC skrivs och `hdr.json` får sin post med
    // `engine = "lightroom"` — därefter är gruppen som vilken HDR-grupp som helst för resten av
    // kedjan. Grupper som misslyckas, eller som Lightroom inte hinner med, returneras som `fallback`
    // och görs av den inbyggda Core Image-motorn: steget hänger sig aldrig och tappar ingen grupp.

    struct LightroomHDRResult {
        var succeeded: [Int] = []
        var fallback: [HDRMergeJob] = []
    }

    func renderHDRGroupsWithLightroom(
        jobs: [HDRMergeJob], outputDir: URL, exiftoolPath: String?, metadataContext: CreationMetadataContext,
        hdrLog: inout HDRLog, baseOptions: HDREngine.Options
    ) async throws -> LightroomHDRResult {
        var result = LightroomHDRResult()
        func failAll(_ reason: String) -> LightroomHDRResult {
            state.appendStepLog(.createHDR, "Lightroom: \(reason) — alla grupper görs med Core Image", type: .warning)
            return LightroomHDRResult(succeeded: [], fallback: jobs)
        }

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: LightroomRender.bundleIdentifier) != nil else {
            return failAll("Lightroom Classic är inte installerat")
        }
        guard FileManager.default.fileExists(atPath: PreflightModel.lightroomPluginLink.path) else {
            return failAll("PhotoFlowLR-pluginet är inte installerat i Lightroom")
        }

        let fm = FileManager.default
        let stagingRoot = outputDir.appendingPathComponent(LightroomRender.stagingRootName)
        let triggerURL = Self.triggerFileURL, statusURL = Self.statusFileURL, doneURL = Self.doneFileURL
        defer {
            // Mellanlagringen och en eventuell outhämtad trigger städas alltid.
            try? fm.removeItem(at: stagingRoot)
            try? fm.removeItem(at: triggerURL)
        }

        // 1. Mellanlagra ramarna (APFS-kloner på samma volym, annars vanliga kopior).
        state.statusMessage = "Lightroom: förbereder \(jobs.count) grupper..."
        try? fm.removeItem(at: stagingRoot)
        var lrJobs: [LightroomRender.Job] = []
        var stagingFailed: [Int] = []
        for job in jobs {
            try await checkCancellationAndWaitIfPaused()
            let dir = LightroomRender.stagingDirectory(outputDir: outputDir, groupId: job.groupId)
            let sources = job.lightroomFiles
            let staged: [String]? = await Task.detached {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    return try sources.map { src in
                        let dest = dir.appendingPathComponent(src.lastPathComponent)
                        try FileManager.default.copyItem(at: src, to: dest)
                        return dest.path
                    }
                } catch { return nil }
            }.value
            if let staged, staged.count >= 2 {
                lrJobs.append(.init(groupId: job.groupId, files: staged, outputPath: job.tiffURL.path))
            } else {
                stagingFailed.append(job.groupId)
            }
        }
        for id in stagingFailed {
            state.appendStepLog(.createHDR, "HDR grupp \(id): kunde inte kopiera ramarna till Lightroom — Core Image tar den", type: .warning)
        }
        guard !lrJobs.isEmpty else { return LightroomHDRResult(succeeded: [], fallback: jobs) }
        for job in jobs { try? fm.createDirectory(at: job.tiffURL.deletingLastPathComponent(), withIntermediateDirectories: true) }

        // 2. Skriv triggern och starta/aktivera Lightroom.
        try? fm.removeItem(at: doneURL)
        try? fm.removeItem(at: statusURL)
        do {
            let data = try JSONSerialization.data(withJSONObject: LightroomRender.triggerPayload(jobs: lrJobs),
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: triggerURL, options: .atomic)
        } catch {
            return failAll("kunde inte skriva triggern (\(error.localizedDescription))")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", LightroomRender.bundleIdentifier]
        try? open.run()
        state.appendStepLog(.createHDR, "Lightroom: skickar \(lrJobs.count) grupper. Använd inte datorn under körningen — pluginet styr Lightrooms fönster med tangenttryckningar.", type: .info)
        state.appendLog("Lightroom renderar \(lrJobs.count) HDR-grupper — rör inte tangentbord/mus.", type: .info)

        // 3. Vänta: framsteg från lr_status.json, med tidsgränser så att steget aldrig hänger sig.
        let started = Date()
        let overall = LightroomRender.overallTimeoutSeconds(groupCount: lrJobs.count)
        var lastProgress = Date()
        var lastResultCount = 0
        var lastCurrent: Int?
        var status: LightroomRender.Status?
        var timedOut: String?
        while true {
            do { try await checkCancellationAndWaitIfPaused() } catch {
                try? fm.removeItem(at: triggerURL)
                state.appendStepLog(.createHDR, "Avbrutet — Lightroom kan fortsätta med gruppen den håller på med (avbryt i dess förloppsruta).", type: .warning)
                throw error
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let latest = (try? Data(contentsOf: statusURL)).flatMap(LightroomRender.parseStatus(data:))
            if let latest { status = latest }
            let done = LightroomRender.isDone(doneData: try? Data(contentsOf: doneURL)) || (latest?.isComplete ?? false)

            if let latest {
                if latest.results.count > lastResultCount {
                    for r in latest.results.dropFirst(lastResultCount) {
                        let took = r.seconds.map { StepTiming.formatExact($0) } ?? "?"
                        state.appendStepLog(.createHDR, r.status == "ok"
                            ? "HDR grupp \(r.groupId): Lightroom klar på \(took)"
                            : "HDR grupp \(r.groupId): Lightroom misslyckades — \(r.message)",
                            type: r.status == "ok" ? .success : .warning)
                    }
                    lastResultCount = latest.results.count
                    lastProgress = Date()
                    state.currentFileIndex = lastResultCount
                    state.progress = Double(lastResultCount) / Double(max(jobs.count, 1))
                    state.updateStepProgress(.createHDR, processed: lastResultCount, total: jobs.count)
                }
                if let current = latest.currentGroupId, current != lastCurrent {
                    lastCurrent = current
                    lastProgress = Date()
                    state.currentMergeGroupId = current
                    let position = "\(latest.currentIndex ?? 0)/\(latest.total ?? lrJobs.count)"
                    state.statusMessage = "Lightroom: grupp \(current) (\(position))..."
                    state.appendStepLog(.createHDR, "Lightroom: grupp \(current) (\(position))...")
                }
            }
            if done { break }

            let elapsed = Date().timeIntervalSince(started)
            if status == nil, elapsed > LightroomRender.pickupTimeoutSeconds {
                timedOut = "Lightroom-pluginet plockade inte upp triggern på \(Int(LightroomRender.pickupTimeoutSeconds)) s (körs Lightroom med PhotoFlowLR?)"
                break
            }
            if status != nil, Date().timeIntervalSince(lastProgress) > LightroomRender.stallTimeoutSeconds {
                timedOut = "inga framsteg på \(Int(LightroomRender.stallTimeoutSeconds)) s"
                break
            }
            if elapsed > overall {
                timedOut = "tidsgränsen på \(Int(overall / 60)) min nåddes"
                break
            }
        }
        if let timedOut {
            try? fm.removeItem(at: triggerURL)
            state.appendStepLog(.createHDR, "Lightroom: \(timedOut) — de grupper som inte hunnit klart görs med Core Image", type: .warning)
        }
        state.currentMergeGroupId = nil

        // 4. Verifiera filerna och efterarbeta de lyckade; resten är reserv.
        let outcomes = LightroomRender.outcomes(jobs: lrJobs, status: status) { LightroomRender.isValidImage(atPath: $0) }
        for job in jobs {
            try await checkCancellationAndWaitIfPaused()
            guard let outcome = outcomes[job.groupId] else { result.fallback.append(job); continue }
            if case .failed(let reason) = outcome {
                state.appendStepLog(.createHDR, "HDR grupp \(job.groupId): Lightroom gav ingen bild (\(reason)) — Core Image tar den", type: .warning)
                result.fallback.append(job)
                continue
            }
            if await finalizeLightroomGroup(job, outputDir: outputDir, exiftoolPath: exiftoolPath,
                                            metadataContext: metadataContext, options: baseOptions, hdrLog: &hdrLog) {
                result.succeeded.append(job.groupId)
            } else {
                result.fallback.append(job)
            }
        }
        hdrLog.updatedAt = Date()
        hdrLog.save(to: outputDir)
        return result
    }

    /// JPEG-förhandsvisning, EXIF/IPTC och `hdr.json`-post för en grupp vars TIFF Lightroom skrivit.
    private func finalizeLightroomGroup(
        _ job: HDRMergeJob, outputDir: URL, exiftoolPath: String?, metadataContext: CreationMetadataContext,
        options: HDREngine.Options, hdrLog: inout HDRLog
    ) async -> Bool {
        let tiffURL = job.tiffURL, jpegURL = job.jpegURL
        try? FileManager.default.createDirectory(at: jpegURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let groupFolder = job.firstPhotoDate.map { addressFolderName(forPhotoDate: $0) }
        func fileMetadata(for url: URL) -> IPTCFileMetadata? {
            guard let folder = Self.addressFolderName(containing: url) ?? groupFolder else { return nil }
            return Self.creationMetadata(for: url, folderName: folder, context: metadataContext)
        }
        let metadata = (tiff: fileMetadata(for: tiffURL), jpeg: fileMetadata(for: jpegURL))
        // EXIF-källan: bracketens mittexponering, som den inbyggda motorn.
        let byExposure = job.frames.sorted { $0.exposureSeconds < $1.exposureSeconds }
        let reference = byExposure.isEmpty ? job.lightroomFiles.first : byExposure[byExposure.count / 2].url
        let maxDimension = options.jpegMaxDimension, quality = options.jpegQuality

        let metadataWritten: Bool? = await Task.detached {
            do {
                try HDRWriter.writeJPEG(fromImageAt: tiffURL, to: jpegURL, maxDimension: maxDimension, quality: quality)
            } catch { return nil }
            guard let exiftoolPath, let reference else { return false }
            return HDRWriter.writeMetadata(from: reference, outputs: [(tiffURL, metadata.tiff), (jpegURL, metadata.jpeg)],
                                           exiftoolPath: exiftoolPath)
        }.value
        guard let metadataWritten else {
            state.appendStepLog(.createHDR, "HDR grupp \(job.groupId): kunde inte göra JPEG av Lightroom-bilden", type: .warning)
            return false
        }

        recordCreationStamps([(tiffURL, metadata.tiff), (jpegURL, metadata.jpeg)], metadataWritten: metadataWritten, outputDir: outputDir)
        let rewroteSorted = Self.addressFolderName(containing: tiffURL) != nil || Self.addressFolderName(containing: jpegURL) != nil
        if rewroteSorted && (metadata.tiff == nil || metadata.jpeg == nil || !metadataWritten) {
            try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
        }
        hdrLog.entries[HDRLog.key(groupId: job.groupId)] = HDRLog.Entry(
            engineVersion: HDREngine.version, fingerprint: job.fingerprint, frames: job.frameNames,
            manualSelection: job.manualSelection, mergedAt: Date(), engine: HDRLog.lightroomEngine)
        hdrLog.updatedAt = Date()
        hdrLog.save(to: outputDir)

        let size = (try? FileManager.default.attributesOfItem(atPath: tiffURL.path)[.size] as? Int) ?? 0
        state.appendStepLog(.createHDR, String(format: "HDR grupp %d: klar via Lightroom → %@ (%.1f MB)", job.groupId,
                                               tiffURL.lastPathComponent, Double(size) / 1_048_576.0), type: .success)
        state.currentMergeOutputURL = jpegURL
        return true
    }
}
