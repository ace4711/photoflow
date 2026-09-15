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
        try await runVisionQualityAnalysis(outputDir: outputDir, previewFiles: previewFiles)

        state.progress = 1.0
        audio.playStepComplete()
    }

    // MARK: - AI-taggning (Vision-klassificering + svensk taggmappning)

    private func runVisionTagging(outputDir: URL, previewFiles: [URL]) async throws {
        let fm = FileManager.default

        // Check if ai_tags.json already exists with matching file count
        let tagsJSON = outputDir.appendingPathComponent("ai_tags.json")
        let previewNames = Set(previewFiles.map { $0.deletingPathExtension().lastPathComponent })

        if fm.fileExists(atPath: tagsJSON.path),
           let existingData = try? Data(contentsOf: tagsJSON),
           let existingJSON = try? JSONSerialization.jsonObject(with: existingData) as? [String: [String: Any]],
           previewNames.isSubset(of: Set(existingJSON.keys)) {
            // Load from disk instead of re-running Vision
            aiTagResults = [:]
            for (filename, info) in existingJSON {
                let tags = (info["tags"] as? [String]) ?? []
                let desc = (info["description"] as? String) ?? ""
                let cat = (info["category"] as? String) ?? ""
                aiTagResults[filename] = VisionTaggingService.PhotoTags(
                    tags: tags, description: desc, primaryCategory: cat,
                    confidence: 1.0, rawLabels: []
                )
            }
            logDecision(step: "ai_tagging", decision: "skipped", details: [
                "reason": "json_exists",
                "tagCount": "\(existingJSON.count)"
            ])
            state.appendStepLog(.aiTagging, "AI-taggar redan sparade (\(existingJSON.count) bilder) — hoppar over", type: .info)
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
        var jsonDict: [String: [String: Any]] = [:]
        for (filename, tags) in aiTagResults {
            jsonDict[filename] = [
                "tags": tags.tags,
                "description": tags.description,
                "category": tags.primaryCategory
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted) {
            try? data.write(to: tagsJSON)
        }
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
