import Foundation

extension PipelineRunner {
    /// Antal färdiga exiftool-kommandon (ett per fil i argfilen) i utdatan —
    /// varje kommando avslutas med en rad "N image files updated/unchanged/created"
    /// (created = ny XMP-sidecar för en NEF) eller "N files weren't updated due to errors".
    nonisolated static func completedExiftoolCommands(in output: String) -> Int {
        output.split(separator: "\n").filter { line in
            ["updated", "unchanged", "created"].contains { line.contains("image files \($0)") || line.contains("image file \($0)") }
                || line.contains("weren't updated due to errors")
        }.count
    }

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

        // Själva taggarna är delade med skrivningen när HDR-/förbättrade filer skapas (fas 1b).
        lines.append(contentsOf: ExiftoolMetadataArguments.tagLines(for: meta, isNEF: isNEF))

        if isNEF && !sidecarExists {
            lines.append("-o")
            lines.append(sidecarURL.path)
        }
        lines.append(isNEF && sidecarExists ? sidecarURL.path : file.path)
        lines.append("-execute")

        return lines
    }

    /// Filerna (exiftools målsökväg, alltså sista sökvägen före `-execute` i
    /// `exiftoolArguments`) som exiftool skrev utan fel, enligt `-progress`-utdatan: varje
    /// kommando börjar med "======== <fil> [i/n]" och slutar med "N image files
    /// updated/unchanged/created" eller "... weren't updated due to errors".
    nonisolated static func succeededExiftoolTargets(in output: String) -> Set<String> {
        var succeeded: Set<String> = []
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("======== ") {
                var name = line.dropFirst("======== ".count)
                if let bracket = name.range(of: " [", options: .backwards), name.hasSuffix("]") {
                    name = name[..<bracket.lowerBound]
                }
                current = String(name)
            } else if let file = current, let count = Self.exiftoolResultCount(line), count > 0 {
                // "0 image files updated" skrivs också när filen inte gick att skriva (före "... due to errors").
                succeeded.insert(file)
                current = nil
            } else if line.contains("weren't updated due to errors") {
                current = nil
            }
        }
        return succeeded
    }

    /// Antalet i en resultatrad "N image file(s) updated/unchanged/created", annars nil.
    nonisolated private static func exiftoolResultCount(_ line: Substring) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard ["updated", "unchanged", "created"].contains(where: { trimmed.hasSuffix("image files \($0)") || trimmed.hasSuffix("image file \($0)") }),
              let number = trimmed.split(separator: " ").first else { return nil }
        return Int(number)
    }

    // MARK: - Adressmetadata (fas 1b: beräknas efter kalendersteget, delas av alla steg)

    /// Bokningsinfo och koordinat för en adressmapp (nyckel = bokningens mappnamn,
    /// `CalendarService.sanitizeFolderName(adress)`), i bokningarnas ordning.
    nonisolated struct ResolvedAddress: Equatable, Sendable {
        enum Source: Equatable { case corrected, geocoded, failed }
        var key: String
        /// Bokningens adress (det som geokodades / rättades).
        var mappingAddress: String
        var bookingInfo: String?
        var latitude: Double?
        var longitude: Double?
        var source: Source
    }

    /// Signaturen som `addressMetadataCache` gäller för: bokningarna och de manuella rättningarna.
    private var addressMetadataSignature: String {
        let iso = ISO8601DateFormatter()
        let mappings = calendarMappings.map {
            "\($0.address)|\($0.eventTitle)|\(iso.string(from: $0.photoDateRange.lowerBound))|\(iso.string(from: $0.photoDateRange.upperBound))"
        }
        let corrections = state.correctedCoordinates
            .map { "\($0.key)=\($0.value.latitude),\($0.value.longitude)" }
            .sorted()
        return (mappings + ["#"] + corrections).joined(separator: ";")
    }

    /// Geokodar adresserna och tolkar bokningstitlarna — en gång, efter kalendersteget, i stället
    /// för (som före fas 1b) först i sorteringen och sedan igen i metadatasteget. En manuellt
    /// rättad koordinat (`correctedCoordinates`) vinner alltid över geokodningen. Resultatet
    /// återanvänds så länge bokningarna och rättningarna är desamma; en adress som inte gick att
    /// geokoda försöks igen vid nästa anrop (som förut, då sortering och metadata geokodade var för sig).
    func resolveAddressMetadata() async -> [ResolvedAddress] {
        let signature = addressMetadataSignature
        if let cache = addressMetadataCache, cache.signature == signature,
           !cache.entries.contains(where: { $0.source == .failed }) {
            return cache.entries
        }
        let calendar = CalendarService.shared
        var entries: [ResolvedAddress] = []
        var seen: Set<String> = []
        for mapping in calendarMappings {
            // Bokningens egen mapp (samma som sorteringen ger dess bilder) — inte mappen för dess
            // första fotodatum, som för en tätt följande bokning kunde bli grannens.
            let key = CalendarService.sanitizeFolderName(mapping.address)
            guard seen.insert(key).inserted else { continue }
            let titleInfo = await BookingTitleParser.shared.parse(title: mapping.eventTitle)
            let bookingInfo = BookingTitleParser.bookingInfoText(from: titleInfo)
            if let corrected = state.correctedCoordinates[mapping.address] {
                entries.append(ResolvedAddress(key: key, mappingAddress: mapping.address, bookingInfo: bookingInfo,
                                               latitude: corrected.latitude, longitude: corrected.longitude, source: .corrected))
            } else if let coord = await calendar.geocodeAddress(mapping.address) {
                entries.append(ResolvedAddress(key: key, mappingAddress: mapping.address, bookingInfo: bookingInfo,
                                               latitude: coord.latitude, longitude: coord.longitude, source: .geocoded))
            } else {
                entries.append(ResolvedAddress(key: key, mappingAddress: mapping.address, bookingInfo: bookingInfo,
                                               latitude: nil, longitude: nil, source: .failed))
            }
        }
        // Signaturen räknas om: rättningar kan ha kommit till medan vi väntade på geokodningen.
        if signature == addressMetadataSignature {
            addressMetadataCache = (signature, entries)
        }
        return entries
    }

    /// Metadatat per adressmapp (nyckel = mappnamnet) så som metadatasteget skriver det.
    func addressMetadataByFolder(_ entries: [ResolvedAddress]) -> [String: AddressMetadata] {
        var resolved: [String: (bookingInfo: String?, latitude: Double, longitude: Double)] = [:]
        for entry in entries {
            resolved[entry.key] = (entry.bookingInfo, entry.latitude ?? 0, entry.longitude ?? 0)
        }
        return MetadataPlan.addressMetadata(mappings: calendarMappings, resolved: resolved)
    }

    /// AI-taggar per basnamn (`DSC_0012`), bara när AI-taggning är på och bilden har taggar.
    func metadataAILookup() -> [String: AITagData] {
        guard AppSettings.shared.aiTaggingEnabled else { return [:] }
        var lookup: [String: AITagData] = [:]
        for photo in state.allPhotos where !photo.aiTags.isEmpty {
            let baseName = photo.filename.replacingOccurrences(of: ".NEF", with: "")
            lookup[baseName] = AITagData(tags: photo.aiTags, description: photo.aiDescription)
        }
        return lookup
    }

    // MARK: - Metadata när HDR-/förbättrade filer skapas (fas 1b, steg A)

    /// Det som behövs för att räkna fram metadatan för nya filer, utan att vänta på sorteringen.
    nonisolated struct CreationMetadataContext: Sendable {
        /// Adressmetadata per adressmapp; tom utan kalendermatchningar (allt blir "Osorterade").
        var addressMeta: [String: AddressMetadata]
        /// AI-uppslaget, eller nil om bilderna inte är inlästa än (HDR körs före `loadBracketGroups`).
        var aiLookup: [String: AITagData]?
        /// Basnamnen på sessionens bilder (från `bracket_groups.json`), för att avgöra att en fil
        /// INTE kan ha AI-taggar när `aiLookup` saknas.
        var photoBaseNames: Set<String>
        var aiTaggingEnabled: Bool
    }

    func creationMetadataContext(photoBaseNames: Set<String> = []) async -> CreationMetadataContext {
        let entries = calendarMappings.isEmpty ? [] : await resolveAddressMetadata()
        return CreationMetadataContext(
            addressMeta: addressMetadataByFolder(entries),
            aiLookup: state.allPhotos.isEmpty ? nil : metadataAILookup(),
            photoBaseNames: photoBaseNames,
            aiTaggingEnabled: AppSettings.shared.aiTaggingEnabled
        )
    }

    /// Metadatat som metadatasteget skulle skriva till `file` när den ligger i adressmappen
    /// `folderName`, eller nil om det inte är känt än eller om steget inte skulle skriva något
    /// (då skrivs bara EXIF, och metadatasteget tar resten som förut).
    nonisolated static func creationMetadata(for file: URL, folderName: String, context: CreationMetadataContext) -> IPTCFileMetadata? {
        let baseName = file.deletingPathExtension().lastPathComponent
        let folder: AddressMetadata?
        if folderName == MetadataPlan.unsortedFolderName {
            folder = nil
        } else {
            // En adressmapp som metadatasteget inte känner till skriver det inte heller till.
            guard let meta = context.addressMeta[folderName] else { return nil }
            folder = meta
        }
        let lookup: [String: AITagData]
        if let aiLookup = context.aiLookup {
            lookup = aiLookup
        } else if !context.photoBaseNames.contains(baseName) {
            lookup = [:]
        } else {
            return nil
        }
        return MetadataPlan.fileMetadata(baseName: baseName, folder: folder, aiLookup: lookup,
                                         aiTaggingEnabled: context.aiTaggingEnabled)
    }

    /// Adressmappen en fil redan ligger i (`<adress> ÖVRIGA`/`TITTBILDER`/`FÖRBÄTTRADE`), eller
    /// nil om den ligger i en stagingmapp (`hdr/`, `enhanced/`).
    nonisolated static func addressFolderName(containing file: URL) -> String? {
        let parent = file.deletingLastPathComponent().lastPathComponent
        for suffix in [" ÖVRIGA", " TITTBILDER", AddressFolderLayout.enhancedSuffix] {
            let nfcParent = parent.precomposedStringWithCanonicalMapping
            let nfcSuffix = suffix.precomposedStringWithCanonicalMapping
            if nfcParent.hasSuffix(nfcSuffix), nfcParent.count > nfcSuffix.count {
                return String(nfcParent.dropLast(nfcSuffix.count))
            }
        }
        return nil
    }

    /// Adressmappen för en bild med fotodatumet `date` ("Osorterade" utan kalendermatchning).
    func addressFolderName(forPhotoDate date: Date?) -> String {
        guard let date else { return MetadataPlan.unsortedFolderName }
        return CalendarService.shared.addressFolder(for: date, mappings: calendarMappings) ?? MetadataPlan.unsortedFolderName
    }

    /// Uppdaterar `metadata_stamps.json` efter att HDR/Förbättra skrivit `outputs`: stämpel för
    /// filer som fick IPTC/XMP/GPS, ingen stämpel (metadatasteget skriver dem) för övriga.
    func recordCreationStamps(_ outputs: [(url: URL, meta: IPTCFileMetadata?)], metadataWritten: Bool, outputDir: URL) {
        var stamps = MetadataStamps.load(from: outputDir)
        let before = stamps
        for output in outputs {
            if metadataWritten, let meta = output.meta {
                stamps.record(output.url, meta: meta, outputDir: outputDir)
            } else {
                stamps.remove(output.url, outputDir: outputDir)
            }
        }
        if stamps != before { stamps.save(to: outputDir) }
    }

    /// Write GPS + IPTC + AI tags to files in address folders
    func writeIPTCMetadata(outputDir: URL? = nil) async {
        let outputDir = outputDir ?? state.outputDirectory
        guard let outputDir else {
            state.appendLog("Ingen outputmapp — kan inte skriva metadata.", type: .error)
            return
        }

        state.currentStep = .writingMetadata
        state.statusMessage = "Skriver metadata (GPS, IPTC, AI-taggar)..."

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
           // En mapp per adress (två bokningar med samma adress delar mapp).
           savedFolderCount == Set(calendarMappings.map { CalendarService.sanitizeFolderName($0.address) }).count,
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

        // Adress, bokningsinfo och GPS per adressmapp: samma resultat som HDR/Förbättra använde
        // när filerna skapades (beräknat efter kalendersteget, se `resolveAddressMetadata`).
        let meta = addressMetadataByFolder(await resolveAddressMetadata())
        let aiTagLookup = metadataAILookup()
        let aiTaggingEnabled = AppSettings.shared.aiTaggingEnabled

        // Fas 1b: stämplar per fil. Filer vars stämpel visar att de redan har exakt den metadata
        // som skulle skrivas (HDR/förbättrade filer som fick den när de skapades, eller filer från
        // en tidigare körning) hoppas över. Utan stämpelfil (äldre sessioner) skrivs allt som förut.
        var stamps = MetadataStamps.load(from: outputDir)
        var skippedByStamp = 0

        // Collect ALL files and their combined metadata into a single argfile
        // Each file gets one entry with GPS + IPTC + AI tags combined
        var argfileLines: [String] = []
        var totalFiles = 0
        // Track per-file description for detailed logging
        var fileDescriptions: [String] = []
        // exiftools målsökväg (sista sökvägen före -execute) → filen och metadatan, för stämplarna.
        var plannedByTarget: [String: (file: URL, meta: IPTCFileMetadata)] = [:]

        func plan(_ file: URL, _ fileMeta: IPTCFileMetadata, description: String) {
            if stamps.matches(file, meta: fileMeta, outputDir: outputDir) {
                skippedByStamp += 1
                return
            }
            let lines = Self.exiftoolArguments(for: file, meta: fileMeta)
            argfileLines.append(contentsOf: lines)
            if lines.count >= 2 { plannedByTarget[lines[lines.count - 2]] = (file, fileMeta) }
            let sidecarNote = file.pathExtension.lowercased() == "nef" ? " (XMP-sidecar)" : ""
            fileDescriptions.append("✓ \(file.lastPathComponent)\(sidecarNote) ← \(description)")
            totalFiles += 1
        }

        for (folderName, folderMeta) in meta {
            // Build per-file log description
            var folderParts: [String] = []
            if let lat = folderMeta.latitude, let lon = folderMeta.longitude {
                folderParts.append("GPS \(String(format: "%.4f", lat)),\(String(format: "%.4f", lon))")
            }
            folderParts.append("adress=\"\(folderMeta.address)\"")

            for subDir in AddressFolderLayout.allDirs(in: outputDir, folderName: folderName) {
                guard fm.fileExists(atPath: subDir.path),
                      let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }

                for file in files {
                    // XMP sidecars aren't retaggable directly — they get written/updated
                    // as a side effect of processing their NEF (see exiftoolArguments).
                    if file.pathExtension.lowercased() == "xmp" { continue }
                    let baseName = file.deletingPathExtension().lastPathComponent
                    guard let fileMeta = MetadataPlan.fileMetadata(baseName: baseName, folder: folderMeta, aiLookup: aiTagLookup,
                                                                   aiTaggingEnabled: aiTaggingEnabled) else { continue }
                    var parts = folderParts
                    if let aiData = aiTagLookup[baseName] { parts.append("AI: \(aiData.tags.joined(separator: ", "))") }
                    plan(file, fileMeta, description: parts.joined(separator: ", "))
                }
            }
        }

        // Also handle AI-tagged files in "Osorterade" (no calendar match).
        // No outer directory-existence gate here — each of the three subfolders
        // (DNG has no suffix, same as address folders) is checked individually,
        // since a previous bug gated the whole block on a folder that wouldn't
        // exist unless there happened to be unmatched DNG files.
        if aiTaggingEnabled {
            for subDir in AddressFolderLayout.allDirs(in: outputDir, folderName: MetadataPlan.unsortedFolderName) {
                guard fm.fileExists(atPath: subDir.path),
                      let files = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) else { continue }
                for file in files {
                    if file.pathExtension.lowercased() == "xmp" { continue }
                    let baseName = file.deletingPathExtension().lastPathComponent
                    guard let fileMeta = MetadataPlan.fileMetadata(baseName: baseName, folder: nil, aiLookup: aiTagLookup,
                                                                   aiTaggingEnabled: aiTaggingEnabled) else { continue }
                    plan(file, fileMeta, description: "AI: \(aiTagLookup[baseName]?.tags.joined(separator: ", ") ?? "")")
                }
            }
        }

        // Persist marker so we skip on re-run
        func writeMarker(filesWritten: Int) {
            let marker: [String: Any] = [
                "version": Self.metadataMarkerVersion,
                "folders_written": meta.count,
                "files_written": filesWritten,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "addresses": Array(meta.keys),
                "stamps": MetadataStamps.fileName
            ]
            if let markerData = try? JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted) {
                try? markerData.write(to: metadataMarkerFile)
            }
        }

        if skippedByStamp > 0 {
            logDecision(step: "write_iptc", decision: "stamps", details: [
                "skippedByStamp": "\(skippedByStamp)", "toWrite": "\(totalFiles)"
            ])
            state.appendStepLog(.writeIPTCTags, "\(skippedByStamp) filer har redan rätt metadata (skrevs när de skapades eller vid en tidigare körning) — hoppas över", type: .info)
        }

        guard totalFiles > 0 else {
            if skippedByStamp > 0 {
                state.updateStepProgress(.writeIPTCTags, processed: skippedByStamp, total: skippedByStamp)
                state.appendLog("Metadata redan skriven till alla \(skippedByStamp) filer.", type: .success)
                writeMarker(filesWritten: skippedByStamp)
            } else {
                state.appendStepLog(.writeIPTCTags, "Inga filer att skriva metadata till", type: .warning)
            }
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

            // exiftool skriver "N image files updated" efter varje fil och tömmer
            // utdatan direkt (verifierat), så filen läses varje sekund medan den
            // kör: förloppet och loggen uppdateras fil för fil i stället för en
            // gång per omgång om 100 (~30 s tystnad per omgång).
            let stdoutURL = outputDir.appendingPathComponent(".exiftool_out_\(chunkIndex).txt")
            let chunkStart = processedSoFar
            let descriptions = fileDescriptions
            let total = totalFiles
            let state = self.state
            let logged = LoggedCount()
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let text = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                    let done = min(Self.completedExiftoolCommands(in: text), filesInChunk)
                    guard done > logged.value else { continue }
                    for i in (chunkStart + logged.value)..<min(chunkStart + done, descriptions.count) {
                        state.appendStepLog(.writeIPTCTags, descriptions[i])
                    }
                    logged.value = done
                    state.updateStepProgress(.writeIPTCTags, processed: chunkStart + done, total: total)
                    state.statusMessage = "Skriver metadata: \(chunkStart + done)/\(total) filer"
                }
            }
            defer { try? fm.removeItem(at: stdoutURL) }

            do {
                let chunkFiles = chunk.filter { !$0.hasPrefix("-") && !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
                try await PipelineMetrics.jobAsync(
                    step: "metadata", unit: "chunk:\(chunkIndex + 1)/\(chunks.count)",
                    bytesIn: PipelineMetrics.totalSize(of: chunkFiles),
                    bytesOut: { (_: Void) in PipelineMetrics.totalSize(of: chunkFiles) }
                ) {
                    _ = try await runProcess(
                        executablePath: exiftoolPath,
                        arguments: ["-@", argfileURL.path, "-common_args", "-progress"],
                        outputFile: stdoutURL
                    )
                }
                watcher.cancel()
                let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                pipelineLog("Exiftool chunk \(chunkIndex + 1)/\(chunks.count) output: \(output)")

                let updatedPattern = try? NSRegularExpression(pattern: "(\\d+) image files? updated")
                let matches = updatedPattern?.matches(in: output, range: NSRange(output.startIndex..., in: output)) ?? []
                for match in matches {
                    if let range = Range(match.range(at: 1), in: output), let count = Int(output[range]) {
                        totalUpdated += count
                    }
                }

                // Filer som bevakningen inte hann logga innan exiftool blev klar.
                let endIdx = min(chunkStart + filesInChunk, fileDescriptions.count)
                for i in min(chunkStart + logged.value, endIdx)..<endIdx {
                    state.appendStepLog(.writeIPTCTags, fileDescriptions[i])
                }
            } catch {
                watcher.cancel()
                state.appendStepLog(.writeIPTCTags, "Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .error)
                state.appendLog("Exiftool-fel i omgång \(chunkIndex + 1): \(error.localizedDescription)", type: .warning)
            }

            try? fm.removeItem(at: argfileURL)

            // Stämpla filerna som exiftool skrev utan fel (även när omgången som helhet felade).
            // Sparas efter varje omgång, så att ett avbrott inte gör att allt skrivs om nästa gång.
            let chunkOutput = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            let succeeded = Self.succeededExiftoolTargets(in: chunkOutput)
            var stamped = false
            for target in succeeded {
                guard let planned = plannedByTarget[target] else { continue }
                stamps.record(planned.file, meta: planned.meta, outputDir: outputDir)
                stamped = true
            }
            if stamped { stamps.save(to: outputDir) }

            processedSoFar += filesInChunk
            state.updateStepProgress(.writeIPTCTags, processed: processedSoFar, total: totalFiles)
        }

        state.appendStepLog(.writeIPTCTags, "Metadata skriven till \(totalUpdated) av \(totalFiles) filer", type: .success)
        state.updateStepProgress(.writeIPTCTags, processed: totalFiles, total: totalFiles)

        state.appendLog("Metadata skriven till \(totalFiles) filer.", type: .success)

        writeMarker(filesWritten: totalFiles + skippedByStamp)
    }
}

/// Hur många filer i en exiftool-omgång som redan loggats (delas mellan
/// bevakningen av utdatan och avslutningen av omgången).
@MainActor
final class LoggedCount {
    var value = 0
}
