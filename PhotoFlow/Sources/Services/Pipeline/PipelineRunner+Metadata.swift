import Foundation

extension PipelineRunner {
    /// Builds the exiftool argfile lines (one file's block, ending with "-execute")
    /// for writing address/GPS/IPTC/AI metadata to a single output file.
    ///
    /// NEF files in address folders are symlinks to the user's original card/input
    /// files — we must never modify them. Plain `-overwrite_original` on a symlink
    /// makes exiftool replace the link with a full copy of its target (verified),
    /// which both duplicates disk usage and silently drops the metadata write (it
    /// lands on the new copy's inode, but the "staging" file the rest of the
    /// pipeline references is unaffected). So:
    ///   - DNG / preview JPEG / HDR TIFF-JPEG (regular files we own): write with
    ///     `-overwrite_original_in_place`, which preserves the symlink and writes
    ///     through to the target (verified).
    ///   - NEF (symlink to the original): never touch the file at all. Instead
    ///     write (or update) an XMP sidecar next to the symlink, using the
    ///     XMP-tag equivalents of the IPTC fields.
    static func exiftoolArguments(for file: URL, meta: IPTCFileMetadata) -> [String] {
        let isNEF = file.pathExtension.lowercased() == "nef"
        let sidecarURL = file.deletingPathExtension().appendingPathExtension("xmp")
        let sidecarExists = isNEF && FileManager.default.fileExists(atPath: sidecarURL.path)

        var lines: [String] = []

        if isNEF {
            if sidecarExists {
                // Sidecar is a plain file — safe to overwrite directly.
                lines.append("-overwrite_original")
            }
            // else: -o creates a brand new sidecar file, nothing to overwrite.
        } else {
            lines.append("-overwrite_original_in_place")
        }
        lines.append("-charset")
        lines.append("iptc=UTF8")

        if let lat = meta.latitude, let lon = meta.longitude {
            let latRef = lat >= 0 ? "N" : "S"
            let lonRef = lon >= 0 ? "E" : "W"
            if isNEF {
                // XMP:GPSLatitudeRef/GPSLongitudeRef don't exist as separate tags
                // (verified with exiftool 13.50 — "doesn't exist or isn't writable").
                // exiftool accepts a signed "value N/S/E/W" string directly on the
                // XMP:GPSLatitude/GPSLongitude tags instead.
                lines.append("-XMP:GPSLatitude=\(abs(lat)) \(latRef)")
                lines.append("-XMP:GPSLongitude=\(abs(lon)) \(lonRef)")
            } else {
                lines.append("-GPSLatitude=\(abs(lat))")
                lines.append("-GPSLatitudeRef=\(latRef)")
                lines.append("-GPSLongitude=\(abs(lon))")
                lines.append("-GPSLongitudeRef=\(lonRef)")
            }
        }

        if let address = meta.address, !address.isEmpty {
            if isNEF {
                lines.append("-XMP:Title=\(address)")
                lines.append("-XMP-iptcCore:Location=\(address)")
                lines.append("-XMP-iptcCore:Sublocation=\(address)")
            } else {
                lines.append("-IPTC:Headline=\(address)")
                lines.append("-IPTC:ObjectName=\(address)")
                lines.append("-XMP:Title=\(address)")
                lines.append("-IPTC:Sub-location=\(address)")
            }
        }

        if let eventTitle = meta.eventTitle, !eventTitle.isEmpty {
            lines.append(isNEF ? "-XMP:Instructions=\(eventTitle)" : "-IPTC:SpecialInstructions=\(eventTitle)")
        }

        for tag in meta.aiTags {
            // -=/+= idiom: removes the tag first if present, then re-adds it, so
            // re-running this step doesn't pile up duplicate keywords (verified
            // with exiftool 13.50 — plain += duplicates on every re-run).
            if isNEF {
                lines.append("-XMP:Subject-=\(tag)")
                lines.append("-XMP:Subject+=\(tag)")
            } else {
                lines.append("-IPTC:Keywords-=\(tag)")
                lines.append("-IPTC:Keywords+=\(tag)")
                lines.append("-XMP:Subject-=\(tag)")
                lines.append("-XMP:Subject+=\(tag)")
            }
        }

        if let description = meta.description, !description.isEmpty {
            if isNEF {
                lines.append("-XMP:Description=\(description)")
            } else {
                lines.append("-IPTC:Caption-Abstract=\(description)")
                lines.append("-XMP:Description=\(description)")
            }
        }

        if isNEF && !sidecarExists {
            lines.append("-o")
            lines.append(sidecarURL.path)
        }
        lines.append(isNEF && sidecarExists ? sidecarURL.path : file.path)
        lines.append("-execute")

        return lines
    }

    /// Write GPS + IPTC + AI tags to files in address folders
    func writeIPTCMetadata(outputDir: URL? = nil, addressMeta: [String: (lat: Double, lon: Double, bookingInfo: String?)]? = nil) async {
        let outputDir = outputDir ?? state.outputDirectory
        guard let outputDir else {
            state.appendLog("Ingen outputmapp — kan inte skriva metadata.", type: .error)
            return
        }

        state.currentStep = .writingMetadata
        state.statusMessage = "Skriver metadata (GPS, IPTC, AI-taggar)..."

        let calendar = CalendarService.shared
        let fm = FileManager.default

        // Fas 8: manifest-fingerprint av bildlistan + AI-taggar/beskrivning
        // per bild + adress-/rättningssignaturen (samma som moveToFolders) +
        // om AI-taggning är av/på. Fångar t.ex. en omkörd AI-taggning eller
        // adressrättning som inte ändrar antalet adressmappar/filer, vilket
        // den gamla ren-antals-markörfilen (nedan, kvar som fallback för
        // sessioner utan manifest-record) missade.
        let aiTagsSignature = state.allPhotos
            .filter { !$0.aiTags.isEmpty || !$0.aiDescription.isEmpty }
            .map { "\($0.filename):\($0.aiTags.joined(separator: ",")):\($0.aiDescription)" }
            .sorted()
            .joined(separator: ";")
        let addressSignature = calendarMappings
            .map { "\($0.address)|\($0.eventTitle)" }
            .sorted()
            .joined(separator: ";")
        let correctionSignature = state.correctedCoordinates
            .map { "\($0.key)=\($0.value.latitude),\($0.value.longitude)" }
            .sorted()
            .joined(separator: ";")
        let metadataFingerprint = SessionManifestStore.fingerprint(
            fileURLs: state.allPhotos.map(\.nefURL),
            settings: [
                "aiTaggingEnabled": "\(AppSettings.shared.aiTaggingEnabled)",
                "aiTags": aiTagsSignature,
                "addresses": addressSignature,
                "corrections": correctionSignature
            ]
        )
        state.setPendingFingerprint(metadataFingerprint, for: .writeIPTCTags)

        // Check if metadata has already been written (skip if so).
        // Markers without "version": Self.metadataMarkerVersion are from before the
        // DNG-folder-suffix fix / NEF-sidecar fix and must NOT be trusted — otherwise
        // existing sessions would never get corrected metadata on next run.
        let metadataMarkerFile = outputDir.appendingPathComponent("metadata_written.json")
        let metadataManifestRecord = state.sessionManifest?.steps[DashboardStep.writeIPTCTags.manifestKey]
        if fm.fileExists(atPath: metadataMarkerFile.path),
           let data = try? Data(contentsOf: metadataMarkerFile),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedVersion = saved["version"] as? Int, savedVersion == Self.metadataMarkerVersion,
           let savedFolderCount = saved["folders_written"] as? Int,
           let savedFileCount = saved["files_written"] as? Int,
           savedFolderCount == calendarMappings.count,
           // Manifestet matchar, eller (bakåtkompatibilitet) sessionen har
           // inget fingerprint-record för det här steget än.
           (metadataManifestRecord == nil || metadataManifestRecord?.inputFingerprint == metadataFingerprint) {
            logDecision(step: "write_iptc", decision: "skipped", details: [
                "reason": metadataManifestRecord == nil ? "marker_exists_no_manifest_record" : "manifest_fingerprint_match",
                "filesWritten": "\(savedFileCount)",
                "foldersWritten": "\(savedFolderCount)",
                "fingerprint": metadataFingerprint
            ])
            state.appendStepLog(.writeIPTCTags, "Metadata redan skriven (\(savedFileCount) filer, \(savedFolderCount) adresser) — hoppar över", type: .info)
            state.appendLog("Metadata redan skriven — hoppar över.", type: .info)
            return
        }

        // If no addressMeta provided, rebuild it from calendarMappings
        var meta = addressMeta ?? [:]
        if meta.isEmpty && !calendarMappings.isEmpty {
            for mapping in calendarMappings {
                let address = calendar.addressFolder(for: mapping.photoDateRange.lowerBound, mappings: calendarMappings) ?? mapping.address
                if meta[address] == nil {
                    let titleInfo = await BookingTitleParser.shared.parse(title: mapping.eventTitle)
                    let bookingInfo = BookingTitleParser.bookingInfoText(from: titleInfo)
                    // Same reasoning as exportToAddressFolders: a manual correction
                    // must win over re-geocoding the (known-wrong) original address.
                    if let corrected = state.correctedCoordinates[mapping.address] {
                        meta[address] = (lat: corrected.latitude, lon: corrected.longitude, bookingInfo: bookingInfo)
                        continue
                    }
                    let coord = await calendar.geocodeAddress(mapping.address)
                    if let coord {
                        meta[address] = (lat: coord.latitude, lon: coord.longitude, bookingInfo: bookingInfo)
                    } else {
                        meta[address] = (lat: 0, lon: 0, bookingInfo: bookingInfo)
                    }
                }
            }
        }

        // Build AI tag lookup: baseName -> (tags, description)
        var aiTagLookup: [String: (tags: [String], description: String)] = [:]
        if AppSettings.shared.aiTaggingEnabled {
            for photo in state.allPhotos where !photo.aiTags.isEmpty {
                let baseName = photo.filename.replacingOccurrences(of: ".NEF", with: "")
                aiTagLookup[baseName] = (tags: photo.aiTags, description: photo.aiDescription)
            }
        }

        // Collect ALL files and their combined metadata into a single argfile
        // Each file gets one entry with GPS + IPTC + AI tags combined
        var argfileLines: [String] = []
        var totalFiles = 0
        // Track per-file description for detailed logging
        var fileDescriptions: [String] = []

        for (folderName, folderMeta) in meta {
            // Find the matching address/title for IPTC
            let mapping = calendarMappings.first(where: {
                calendar.addressFolder(for: $0.photoDateRange.lowerBound, mappings: calendarMappings) == folderName
            })

            // NFC-normalize all strings
            let address = (mapping?.address ?? folderName).precomposedStringWithCanonicalMapping
            let eventTitle = (mapping?.eventTitle ?? "").precomposedStringWithCanonicalMapping
            let bookingInfo = (folderMeta.bookingInfo ?? "").precomposedStringWithCanonicalMapping
            let description = [address, bookingInfo].filter { !$0.isEmpty }.joined(separator: " — ")

            let hasGPS = folderMeta.lat != 0 || folderMeta.lon != 0

            for subDir in AddressFolderLayout.allDirs(in: outputDir, folderName: folderName) {
                guard fm.fileExists(atPath: subDir.path),
                      let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }

                for file in files {
                    // XMP sidecars aren't retaggable directly — they get written/updated
                    // as a side effect of processing their NEF (see exiftoolArguments).
                    if file.pathExtension.lowercased() == "xmp" { continue }

                    // Build per-file log description
                    var parts: [String] = []
                    if hasGPS {
                        parts.append("GPS \(String(format: "%.4f", folderMeta.lat)),\(String(format: "%.4f", folderMeta.lon))")
                    }
                    parts.append("adress=\"\(address)\"")

                    // Per-file AI tags (merged into the same exiftool call)
                    let baseName = file.deletingPathExtension().lastPathComponent
                    let aiData = aiTagLookup[baseName]
                    let nfcTags = (aiData?.tags ?? []).map { $0.precomposedStringWithCanonicalMapping }
                    let combinedDesc: String
                    if let aiData {
                        combinedDesc = [description, aiData.description.precomposedStringWithCanonicalMapping]
                            .filter { !$0.isEmpty }.joined(separator: " — ")
                        parts.append("AI: \(aiData.tags.joined(separator: ", "))")
                    } else {
                        combinedDesc = description
                    }

                    let fileMeta = IPTCFileMetadata(
                        address: address,
                        eventTitle: eventTitle,
                        description: combinedDesc,
                        latitude: hasGPS ? folderMeta.lat : nil,
                        longitude: hasGPS ? folderMeta.lon : nil,
                        aiTags: nfcTags
                    )
                    argfileLines.append(contentsOf: Self.exiftoolArguments(for: file, meta: fileMeta))

                    let sidecarNote = file.pathExtension.lowercased() == "nef" ? " (XMP-sidecar)" : ""
                    fileDescriptions.append("✓ \(file.lastPathComponent)\(sidecarNote) ← \(parts.joined(separator: ", "))")
                    totalFiles += 1
                }
            }
        }

        // Also handle AI-tagged files in "Osorterade" (no calendar match).
        // No outer directory-existence gate here — each of the three subfolders
        // (DNG has no suffix, same as address folders) is checked individually,
        // since a previous bug gated the whole block on a folder that wouldn't
        // exist unless there happened to be unmatched DNG files.
        if AppSettings.shared.aiTaggingEnabled {
            for subDir in AddressFolderLayout.allDirs(in: outputDir, folderName: "Osorterade") {
                guard fm.fileExists(atPath: subDir.path),
                      let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }
                for file in files {
                    if file.pathExtension.lowercased() == "xmp" { continue }
                    let baseName = file.deletingPathExtension().lastPathComponent
                    guard let aiData = aiTagLookup[baseName] else { continue }

                    let nfcTags = aiData.tags.map { $0.precomposedStringWithCanonicalMapping }
                    let nfcDesc = aiData.description.precomposedStringWithCanonicalMapping
                    let fileMeta = IPTCFileMetadata(
                        address: nil,
                        eventTitle: nil,
                        description: nfcDesc.isEmpty ? nil : nfcDesc,
                        latitude: nil,
                        longitude: nil,
                        aiTags: nfcTags
                    )
                    argfileLines.append(contentsOf: Self.exiftoolArguments(for: file, meta: fileMeta))

                    let sidecarNote = file.pathExtension.lowercased() == "nef" ? " (XMP-sidecar)" : ""
                    fileDescriptions.append("✓ \(file.lastPathComponent)\(sidecarNote) ← AI: \(aiData.tags.joined(separator: ", "))")
                    totalFiles += 1
                }
            }
        }

        guard totalFiles > 0 else {
            state.appendStepLog(.writeIPTCTags, "Inga filer att skriva metadata till", type: .warning)
            return
        }

        guard let exiftoolPath = ToolLocator.exiftool else {
            state.appendStepLog(.writeIPTCTags, "exiftool saknas. Installera med: brew install exiftool", type: .error)
            state.appendLog("Metadata kunde inte skrivas — exiftool saknas.", type: .error)
            return
        }

        state.updateStepProgress(.writeIPTCTags, processed: 0, total: totalFiles)

        // Split argfile lines into chunks of ~100 files for continuous progress
        // Each file's block ends with "-execute", so split on those boundaries
        let chunkSize = 100
        var chunks: [[String]] = []
        var currentChunk: [String] = []
        var filesInCurrentChunk = 0

        for line in argfileLines {
            currentChunk.append(line)
            if line == "-execute" {
                filesInCurrentChunk += 1
                if filesInCurrentChunk >= chunkSize {
                    chunks.append(currentChunk)
                    currentChunk = []
                    filesInCurrentChunk = 0
                }
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        state.appendStepLog(.writeIPTCTags, "Skriver metadata till \(totalFiles) filer...")

        var totalUpdated = 0
        var processedSoFar = 0

        for (chunkIndex, chunk) in chunks.enumerated() {
            if await shouldAbort() {
                state.appendStepLog(.writeIPTCTags, "Avbrutet efter \(processedSoFar)/\(totalFiles) filer", type: .warning)
                markActiveStepsCancelled()
                return
            }
            let argfileURL = outputDir.appendingPathComponent(".exiftool_argfile_\(chunkIndex).txt")
            let argfileContent = chunk.joined(separator: "\n")
            try? argfileContent.write(to: argfileURL, atomically: true, encoding: .utf8)

            let filesInChunk = chunk.filter { $0 == "-execute" }.count

            do {
                let output = try await runProcess(
                    executablePath: exiftoolPath,
                    arguments: ["-@", argfileURL.path]
                )
                pipelineLog("Exiftool chunk \(chunkIndex + 1)/\(chunks.count) output: \(output)")

                let updatedPattern = try? NSRegularExpression(pattern: "(\\d+) image files? updated")
                let matches = updatedPattern?.matches(in: output, range: NSRange(output.startIndex..., in: output)) ?? []
                for match in matches {
                    if let range = Range(match.range(at: 1), in: output), let count = Int(output[range]) {
                        totalUpdated += count
                    }
                }

                // Log per-file details for this chunk
                let startIdx = processedSoFar
                let endIdx = min(startIdx + filesInChunk, fileDescriptions.count)
                for i in startIdx..<endIdx {
                    state.appendStepLog(.writeIPTCTags, fileDescriptions[i])
                }
            } catch {
                state.appendStepLog(.writeIPTCTags, "Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .error)
                state.appendLog("Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .warning)
            }

            try? fm.removeItem(at: argfileURL)

            processedSoFar += filesInChunk
            state.updateStepProgress(.writeIPTCTags, processed: processedSoFar, total: totalFiles)
        }

        state.appendStepLog(.writeIPTCTags, "Metadata skriven till \(totalUpdated) av \(totalFiles) filer", type: .success)
        state.updateStepProgress(.writeIPTCTags, processed: totalFiles, total: totalFiles)

        state.appendLog("Metadata skriven till \(totalFiles) filer.", type: .success)

        // Persist marker so we skip on re-run
        let marker: [String: Any] = [
            "version": Self.metadataMarkerVersion,
            "folders_written": meta.count,
            "files_written": totalFiles,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "addresses": Array(meta.keys)
        ]
        if let markerData = try? JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted) {
            try? markerData.write(to: metadataMarkerFile)
        }
    }
}

/// Metadata to write to one output file via `PipelineRunner.exiftoolArguments`.
/// `address`/`eventTitle`/`description` are `nil` when the field should not be
/// touched at all (e.g. AI-only files in "Osorterade" that have no calendar match).
/// All strings are expected to already be NFC-normalized by the caller.
struct IPTCFileMetadata {
    var address: String?
    var eventTitle: String?
    var description: String?
    var latitude: Double?
    var longitude: Double?
    var aiTags: [String] = []
}

