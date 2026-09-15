import Foundation

extension PipelineRunner {
    // MARK: - Step 3.5: AI Tagging

    func runAITagging() async throws {
        guard let outputDir = state.outputDirectory else { return }
        let previewDir = outputDir.appendingPathComponent("previews")
        let fm = FileManager.default

        state.currentStep = .taggingPhotos

        // Check if ai_tags.json already exists with matching file count
        let tagsJSON = outputDir.appendingPathComponent("ai_tags.json")
        let previewFiles = (try? fm.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

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
            state.progress = 1.0
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

        state.progress = 1.0
        audio.playStepComplete()
    }
}
