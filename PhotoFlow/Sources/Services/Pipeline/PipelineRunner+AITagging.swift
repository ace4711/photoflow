import Foundation

extension PipelineRunner {
    // MARK: - Step 3.5: AI Tagging + Vision-baserad kvalitetsanalys (Fas 3b)

    func runAITagging() async throws {
        guard let outputDir = state.outputDirectory else { return }
        let previewDir = outputDir.appendingPathComponent("previews")
        let fm = FileManager.default

        state.currentStep = .taggingPhotos

        let previewFiles = (try? fm.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        try await runVisionTagging(outputDir: outputDir, previewFiles: previewFiles)
        try await checkCancellationAndWaitIfPaused()
        try await runPhotoDescriptions(outputDir: outputDir, previewFiles: previewFiles)
        try await checkCancellationAndWaitIfPaused()
        try await runVisionQualityAnalysis(outputDir: outputDir, previewFiles: previewFiles)

        state.progress = 1.0
        audio.playStepComplete()
    }

    // MARK: - AI-taggning (Vision-klassificering + svensk taggmappning)

    private func runVisionTagging(outputDir: URL, previewFiles: [URL]) async throws {
        // Check if ai_tags.json already exists with matching file count
        let previewNames = Set(previewFiles.map { $0.deletingPathExtension().lastPathComponent })

        if let existingEntries = AITagsStore.load(from: outputDir),
           previewNames.isSubset(of: Set(existingEntries.keys)) {
            // Load from disk instead of re-running Vision
            aiTagResults = [:]
            for (filename, entry) in existingEntries {
                aiTagResults[filename] = VisionTaggingService.PhotoTags(
                    tags: entry.tags, description: entry.description, primaryCategory: entry.category,
                    confidence: 1.0, rawLabels: []
                )
            }
            logDecision(step: "ai_tagging", decision: "skipped", details: [
                "reason": "json_exists",
                "tagCount": "\(existingEntries.count)"
            ])
            state.appendStepLog(.aiTagging, "AI-taggar redan sparade (\(existingEntries.count) bilder) — hoppar over", type: .info)
            state.appendLog("AI-taggning redan klar — laddar fran ai_tags.json.", type: .info)

            // Log loaded tags
            for (filename, tags) in aiTagResults.sorted(by: { $0.key < $1.key }) {
                let tagStr = tags.tags.joined(separator: ", ")
                let catStr = tags.primaryCategory.isEmpty ? "" : " [\(tags.primaryCategory)]"
                state.appendStepLog(.aiTagging, "\(filename): \(tagStr)\(catStr)")
            }
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
        var entries: [String: AITagsStore.Entry] = [:]
        for (filename, tags) in aiTagResults {
            entries[filename] = AITagsStore.Entry(tags: tags.tags, description: tags.description, category: tags.primaryCategory)
        }
        AITagsStore.save(entries, to: outputDir)
    }

    // MARK: - AI-bildbeskrivningar (Foundation Models, Fas 3d)

    /// Genererar en svensk bildtext + särdrag för ett urval bilder (en per
    /// bracket-/singelgrupp) via `PhotoDescriptionService`, efter den snabba
    /// Vision-klassificeringen ovan. Berikar `aiTagResults` (samma dict som
    /// `writeIPTCMetadata` läser via `photo.aiTags`/`photo.aiDescription`) i
    /// stället för att kräva ändringar nedströms: Vision-taggarna + ML-
    /// särdragen slås ihop till en enda taggmängd, och ML-bildtexten
    /// ersätter Vision's mall-genererade beskrivning när den finns.
    private func runPhotoDescriptions(outputDir: URL, previewFiles: [URL]) async throws {
        guard AppSettings.shared.aiDescriptionsEnabled else {
            state.appendStepLog(.aiTagging, "AI-bildbeskrivningar avstängda i inställningar — hoppar över", type: .info)
            return
        }
        guard PhotoDescriptionService.isAvailable else {
            state.appendStepLog(.aiTagging, "Foundation Models bildbeskrivning inte tillgänglig på den här enheten (kräver Apple Intelligence, macOS 27+) — hoppar över, Vision-taggar används som tidigare", type: .info)
            return
        }
        guard !previewFiles.isEmpty else { return }

        var stored = AITagsStore.load(from: outputDir) ?? [:]

        // Slå in redan sparade ML-beskrivningar (från en tidigare körning) i
        // aiTagResults direkt, så att en omkörning av pipelinen (t.ex. efter
        // att ha laddat en sparad session) fortfarande skriver den berikade
        // taggmängden till IPTC utan att anropa modellen igen.
        for (filename, entry) in stored where entry.mlCaption != nil {
            mergeMLDescription(filename: filename, entry: entry)
        }

        let bracketGroupByFilename = loadBracketGroupIDs(outputDir: outputDir)

        // En representativ bild per bracket-/singelgrupp (första filen i
        // varje grupp, i preview-filnamnsordning) + alla ogrupperade bilder —
        // håller modellanropen nere. Se FORBATTRINGAR.md för uppmätt tid/bild
        // och varför ett fullständigt urval inte gjordes.
        var seenGroups: Set<Int> = []
        var sampleFiles: [URL] = []
        for file in previewFiles {
            let base = file.deletingPathExtension().lastPathComponent
            if stored[base]?.mlCaption != nil { continue }
            if let groupID = bracketGroupByFilename[base] {
                if seenGroups.contains(groupID) { continue }
                seenGroups.insert(groupID)
            }
            sampleFiles.append(file)
        }

        guard !sampleFiles.isEmpty else {
            state.appendStepLog(.aiTagging, "Alla urvalsbilder har redan AI-bildbeskrivningar — hoppar över", type: .info)
            return
        }

        state.appendStepLog(.aiTagging, "Genererar svenska bildbeskrivningar med Foundation Models för \(sampleFiles.count) av \(previewFiles.count) bilder (ett urval per bracket-/singelgrupp)...")
        state.statusMessage = "AI-bildbeskrivningar: \(sampleFiles.count) bilder..."

        let service = PhotoDescriptionService.shared
        var durations: [TimeInterval] = []

        for (index, file) in sampleFiles.enumerated() {
            if await shouldAbort() {
                state.appendStepLog(.aiTagging, "Avbrutet efter \(index)/\(sampleFiles.count) bildbeskrivningar", type: .warning)
                markActiveStepsCancelled()
                break
            }

            let base = file.deletingPathExtension().lastPathComponent
            let start = Date()
            let result = await service.describe(imageAt: file)
            let elapsed = Date().timeIntervalSince(start)
            durations.append(elapsed)

            var entry = stored[base] ?? AITagsStore.Entry(
                tags: aiTagResults[base]?.tags ?? [],
                description: aiTagResults[base]?.description ?? "",
                category: aiTagResults[base]?.primaryCategory ?? ""
            )

            if let result {
                entry.mlRoom = result.room
                entry.mlCategory = result.category
                entry.mlFeatures = result.features
                entry.mlCaption = result.caption
                stored[base] = entry
                mergeMLDescription(filename: base, entry: entry)
                state.appendStepLog(.aiTagging, "[\(index + 1)/\(sampleFiles.count)] \(base): \(result.caption) (\(String(format: "%.1f", elapsed))s)")
            } else {
                stored[base] = entry
                state.appendStepLog(.aiTagging, "[\(index + 1)/\(sampleFiles.count)] \(base): ingen ML-beskrivning (\(String(format: "%.1f", elapsed))s)", type: .warning)
            }

            state.updateStepProgress(.aiTagging, processed: index + 1, total: sampleFiles.count)
            if (index + 1) % 5 == 0 || index + 1 == sampleFiles.count {
                state.statusMessage = "AI-bildbeskrivningar: \(index + 1)/\(sampleFiles.count)..."
            }
        }

        // Fyll på med oförändrade Vision-only-poster för bilder som inte
        // ingick i urvalet, så ai_tags.json fortsätter täcka alla previews.
        for file in previewFiles {
            let base = file.deletingPathExtension().lastPathComponent
            if stored[base] == nil, let tags = aiTagResults[base] {
                stored[base] = AITagsStore.Entry(tags: tags.tags, description: tags.description, category: tags.primaryCategory)
            }
        }
        AITagsStore.save(stored, to: outputDir)

        if !durations.isEmpty {
            let avg = durations.reduce(0, +) / Double(durations.count)
            state.appendStepLog(.aiTagging, "AI-bildbeskrivningar klart: \(durations.count) bilder, snitt \(String(format: "%.2f", avg))s/bild", type: .success)
            state.appendLog("AI-bildbeskrivningar klara (\(durations.count) bilder, snitt \(String(format: "%.2f", avg))s/bild).", type: .success)
        }
    }

    /// Slår ihop Vision-taggarna för `filename` med Foundation Models
    /// särdrag/rum (unika, rummet först) och ersätter beskrivningen med
    /// ML-bildtexten, direkt i `aiTagResults` — samma dict `writeIPTCMetadata`
    /// och `photo.aiTags`/`photo.aiDescription` (via `PipelineRunner+LoadSession`)
    /// läser, så resten av pipelinen inte behöver veta varifrån taggarna kom.
    private func mergeMLDescription(filename: String, entry: AITagsStore.Entry) {
        guard let caption = entry.mlCaption else { return }
        var mergedTags = aiTagResults[filename]?.tags ?? entry.tags
        for feature in entry.mlFeatures ?? [] where !mergedTags.contains(feature) {
            mergedTags.append(feature)
        }
        if let room = entry.mlRoom, !mergedTags.contains(room) {
            mergedTags.insert(room, at: 0)
        }
        aiTagResults[filename] = VisionTaggingService.PhotoTags(
            tags: mergedTags,
            description: caption,
            primaryCategory: entry.mlCategory ?? aiTagResults[filename]?.primaryCategory ?? entry.category,
            confidence: aiTagResults[filename]?.confidence ?? 1.0,
            rawLabels: aiTagResults[filename]?.rawLabels ?? []
        )
    }

    // MARK: - Vision-kvalitetsanalys (estetik, horisont, skärpa, dubbletter)

    private func runVisionQualityAnalysis(outputDir: URL, previewFiles: [URL]) async throws {
        let previewNames = Set(previewFiles.map { $0.deletingPathExtension().lastPathComponent })

        if let existing = PhotoQualityService.load(from: outputDir),
           previewNames.isSubset(of: Set(existing.keys)) {
            photoQualityResults = existing
            logDecision(step: "photo_quality", decision: "skipped", details: [
                "reason": "json_exists",
                "count": "\(existing.count)"
            ])
            state.appendStepLog(.aiTagging, "Vision-kvalitetsanalys redan sparad (\(existing.count) bilder) — hoppar over", type: .info)
            return
        }

        guard !previewFiles.isEmpty else { return }

        state.appendStepLog(.aiTagging, "Startar Vision-kvalitetsanalys (estetik, horisont, skärpa, dubbletter) av \(previewFiles.count) bilder...")
        state.statusMessage = "Vision-analys: \(previewFiles.count) bilder..."

        let bracketGroupByFilename = loadBracketGroupIDs(outputDir: outputDir)

        let items = previewFiles.map { url -> PhotoQualityService.SessionInput in
            let base = url.deletingPathExtension().lastPathComponent
            return PhotoQualityService.SessionInput(filename: base, url: url, bracketGroupID: bracketGroupByFilename[base])
        }

        let total = items.count
        photoQualityResults = try await PhotoQualityService.analyzeSession(items: items) { [weak self] current, total in
            guard let self else { return }
            self.state.progress = Double(current) / Double(total)
            self.state.updateStepProgress(.aiTagging, processed: current, total: total)
            if current % 10 == 0 || current == total {
                self.state.statusMessage = "Vision-analys: \(current)/\(total)..."
            }
        }

        let duplicateCount = photoQualityResults.values.compactMap(\.duplicateGroupID).count
        let utilityCount = photoQualityResults.values.filter(\.isUtility).count
        let skewedCount = photoQualityResults.values.filter { ($0.horizonAngleDegrees.map { abs($0) } ?? 0) > 1.0 }.count
        state.appendStepLog(.aiTagging, "Vision-kvalitetsanalys klar: \(total) bilder, \(duplicateCount) i dubblettgrupper, \(utilityCount) nyttobilder, \(skewedCount) med skev horisont (>1°)", type: .success)
        state.appendLog("Vision-kvalitetsanalys klar: \(duplicateCount) mojliga dubbletter, \(skewedCount) skeva horisonter.", type: .success)

        PhotoQualityService.save(photoQualityResults, to: outputDir)
    }

    /// Reads `bracket_groups.json` (already written by the earlier bracket-analysis
    /// step) to build a filename (no extension) -> group_id map, so
    /// `PhotoQualityService.analyzeSession` can exclude same-bracket-group pairs
    /// from duplicate clustering (they're deliberate different exposures of one
    /// shot, not accidental repeats).
    private func loadBracketGroupIDs(outputDir: URL) -> [String: Int] {
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        guard let data = try? Data(contentsOf: groupsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return [:] }

        var result: [String: Int] = [:]
        for groupData in groups {
            let groupId = (groupData["group_id"] as? Int) ?? 0
            let files = (groupData["files"] as? [String]) ?? []
            for filename in files {
                let base = filename.replacingOccurrences(of: ".NEF", with: "")
                result[base] = groupId
            }
        }
        return result
    }
}
