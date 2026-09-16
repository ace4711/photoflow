import Foundation

extension PipelineRunner {
    func loadExistingSession(inputDir: URL, outputDir: URL? = nil) async {
        state.reset()
        state.inputDirectory = inputDir
        state.outputDirectory = outputDir ?? inputDir.appendingPathComponent("processed")

        do {
            try await loadBracketGroups()
            state.currentStep = .reviewingBrackets
            state.statusMessage = "Granska bracket-grupper och välj bilder för HDR"
            audio.playNeedsAttention()
        } catch {
            state.errorMessage = error.localizedDescription
            state.appendLog(error.localizedDescription, type: .error)
            audio.playError()
        }
    }

    // MARK: - Load bracket groups for review

    func loadBracketGroups() async throws {
        guard let outputDir = state.outputDirectory else { return }
        guard let inputDir = state.inputDirectory else { return }

        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        let data = try Data(contentsOf: groupsJSON)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let groups = json["groups"] as! [[String: Any]]

        let previewDir = outputDir.appendingPathComponent("previews")
        let dngStagingDir = outputDir.appendingPathComponent("dng")
        let hdrDir = outputDir.appendingPathComponent("hdr")

        // Build DNG lookup: search entire output dir (files may be in dng/ staging or address folders)
        var dngLookup: [String: URL] = [:]
        for fileURL in Self.findFiles(withExtension: "dng", in: outputDir) {
            dngLookup[fileURL.deletingPathExtension().lastPathComponent] = fileURL
        }

        // Build filename -> URL lookup for recursive input
        let allNEFs = findNEFFiles(in: inputDir)
        var nefLookup: [String: URL] = [:]
        for url in allNEFs {
            nefLookup[url.lastPathComponent] = url
        }

        // Load persisted AI tags if available (Fas 3b Vision-taggar, Fas 3d
        // kompletterade med Foundation Models-bildbeskrivningar — se
        // `AITagsStore`. ML-särdrag/bildtext, när de finns, slås redan in i
        // `tags`/`description` här precis som i `PipelineRunner+AITagging.
        // mergeMLDescription`, så en återinladdad session visar samma
        // berikade taggar/beskrivning som precis efter en körning.)
        var loadedAITags: [String: VisionTaggingService.PhotoTags] = [:]
        if let entries = AITagsStore.load(from: outputDir) {
            for (filename, entry) in entries {
                var tags = entry.tags
                for feature in entry.mlFeatures ?? [] where !tags.contains(feature) {
                    tags.append(feature)
                }
                if let room = entry.mlRoom, !tags.contains(room) {
                    tags.insert(room, at: 0)
                }
                loadedAITags[filename] = VisionTaggingService.PhotoTags(
                    tags: tags,
                    description: entry.mlCaption ?? entry.description,
                    primaryCategory: entry.mlCategory ?? entry.category,
                    confidence: 1.0, rawLabels: []
                )
            }
            pipelineLog("Laddade AI-taggar för \(loadedAITags.count) bilder")
        }

        // Load persisted Vision quality analysis (Fas 3b), falling back to disk
        // when this run hasn't computed it in-memory yet (e.g. loading an
        // existing session without re-running the pipeline).
        let loadedQuality = PhotoQualityService.load(from: outputDir) ?? [:]
        if !loadedQuality.isEmpty {
            pipelineLog("Laddade Vision-kvalitetsanalys för \(loadedQuality.count) bilder")
        }

        // Load persisted cull decisions
        let cullDecisions = state.loadCullDecisions()
        if !cullDecisions.isEmpty {
            pipelineLog("Laddade gallringsbeslut for \(cullDecisions.count) bilder")
        }

        var bracketGroups: [BracketGroup] = []
        var allPhotos: [PhotoItem] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for groupData in groups {
            let groupId = (groupData["group_id"] as? Int) ?? 0
            let isBracket = (groupData["is_bracket"] as? Bool) ?? false
            let files = (groupData["files"] as? [String]) ?? []
            let exposures = (groupData["exposures"] as? [String]) ?? []
            let fNumber = (groupData["fnumber"] as? Double) ?? 0
            let iso = (groupData["iso"] as? Int) ?? Int((groupData["iso"] as? Double) ?? 0)
            let timeStart = (groupData["time_start"] as? String) ?? ""
            let timeEnd = (groupData["time_end"] as? String) ?? ""
            let dateStartStr = (groupData["date_start"] as? String) ?? ""
            let groupDate = dateFormatter.date(from: dateStartStr) ?? Date()
            // Per-file capture times, when available — old bracket_groups.json files
            // (written before this field existed) fall back to the group's start date
            // for every photo, same as before.
            let perFileDateStrings = (groupData["datetimes"] as? [String]) ?? []
            let perFileDates = perFileDateStrings.map { dateFormatter.date(from: $0) }
            let expRange = (groupData["exposure_range_stops"] as? Double) ?? 0
            let suggestedIndices = (groupData["suggested_hdr_indices"] as? [Int]) ?? []
            let suggestedSet = Set(suggestedIndices)

            var photos: [PhotoItem] = []
            for (i, filename) in files.enumerated() {
                let baseName = filename.replacingOccurrences(of: ".NEF", with: "")
                let nefURL = nefLookup[filename] ?? inputDir.appendingPathComponent(filename)
                let dngURL = dngLookup[baseName] ?? dngStagingDir.appendingPathComponent("\(baseName).dng")
                let previewURL = previewDir.appendingPathComponent("\(baseName).jpg")

                let expStr = i < exposures.count ? exposures[i] : ""
                var expSeconds: Double = 0
                if expStr.contains("/") {
                    let parts = expStr.split(separator: "/")
                    if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]) {
                        expSeconds = num / den
                    }
                } else {
                    expSeconds = Double(expStr) ?? 0
                }

                let previewExists = FileManager.default.fileExists(atPath: previewURL.path)
                let dngExists = FileManager.default.fileExists(atPath: dngURL.path)

                // Algorithm suggestion for HDR subset (stored for UI hint, not used for accept/reject)
                let autoSelect = isBracket && (suggestedSet.isEmpty ? true : suggestedSet.contains(i))

                // Look up AI tags
                let tagResult = aiTagResults[baseName] ?? loadedAITags[baseName]

                let photoId = "\(groupId)_\(filename)"

                // Apply saved cull decision only — photos start neutral (not accepted/rejected)
                // TODO: Consider re-adding auto-accept based on algorithm suggestion as opt-in setting
                let savedDecision = cullDecisions[photoId]
                let isAccepted = savedDecision == "accepted"
                let isRejected = savedDecision == "rejected"

                // Prefer this photo's own capture time over the group's start time —
                // a bracket/single group can span several minutes, and using the
                // group start for every photo made calendar matching pick the wrong
                // address for photos taken near a booking boundary.
                let photoDate = (i < perFileDates.count ? perFileDates[i] : nil) ?? groupDate

                var photo = PhotoItem(
                    id: photoId,
                    filename: filename,
                    nefURL: nefURL,
                    dngURL: dngExists ? dngURL : nil,
                    previewURL: previewExists ? previewURL : nil,
                    exposureTime: expStr,
                    exposureSeconds: expSeconds,
                    fNumber: fNumber,
                    iso: iso,
                    dateTime: photoDate,
                    accepted: isAccepted,
                    algorithmSuggested: autoSelect
                )
                photo.rejected = isRejected
                if let tagResult {
                    photo.aiTags = tagResult.tags
                    photo.aiDescription = tagResult.description
                }
                if let quality = photoQualityResults[baseName] ?? loadedQuality[baseName] {
                    photo.qualityScore = quality.qualityScore
                    photo.isUtility = quality.isUtility
                    photo.horizonAngle = quality.horizonAngleDegrees
                    photo.sharpness = quality.sharpness
                    photo.duplicateGroupID = quality.duplicateGroupID
                }
                photos.append(photo)
                allPhotos.append(photo)
            }

            let folderName = isBracket
                ? "bracket_\(String(format: "%03d", groupId))_HDR_\(photos.count)exp"
                : "single_\(String(format: "%03d", groupId))_\(photos.count)img"

            // Check for merged HDR output (TIFF is the real file, JPEG is preview for UI)
            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(groupId).tiff")
            let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(groupId).jpg")
            let hdrPreviewURL: URL?
            if FileManager.default.fileExists(atPath: hdrJpeg.path) {
                hdrPreviewURL = hdrJpeg
            } else if FileManager.default.fileExists(atPath: hdrTiff.path) {
                hdrPreviewURL = hdrTiff
            } else {
                hdrPreviewURL = nil
            }
            if hdrPreviewURL != nil {
                pipelineLog("  Grupp \(groupId): HDR finns (\(FileManager.default.fileExists(atPath: hdrTiff.path) ? "16-bit TIFF" : "JPEG"))")
            }

            let group = BracketGroup(
                id: groupId,
                isBracket: isBracket,
                folderName: folderName,
                photoIDs: photos.map(\.id),
                fNumber: fNumber,
                iso: iso,
                timeStart: timeStart,
                timeEnd: timeEnd,
                exposureRangeStops: expRange,
                mergedHDRPreviewURL: hdrPreviewURL
            )
            bracketGroups.append(group)
        }

        state.bracketGroups = bracketGroups
        state.allPhotos = allPhotos
        state.appendLog("Laddade \(bracketGroups.count) grupper med \(allPhotos.count) bilder.", type: .success)
    }
}
