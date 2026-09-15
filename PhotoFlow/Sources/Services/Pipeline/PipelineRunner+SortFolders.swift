import Foundation

extension PipelineRunner {
    /// Organize all files into address-named folders.
    func exportToAddressFolders() async {
        guard let outputDir = state.outputDirectory else { return }

        // Check if sorting has already been done
        let sortMarkerFile = outputDir.appendingPathComponent("files_sorted.json")
        if FileManager.default.fileExists(atPath: sortMarkerFile.path),
           let data = try? Data(contentsOf: sortMarkerFile),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let savedCount = saved["photos_sorted"] as? Int,
           savedCount == state.allPhotos.count {
            logDecision(step: "move_to_folders", decision: "skipped", details: [
                "reason": "marker_exists",
                "photosSorted": "\(savedCount)"
            ])
            state.appendStepLog(.moveToFolders, "Filer redan sorterade (\(savedCount) bilder) — hoppar över", type: .info)
            state.appendLog("Filsortering redan klar — hoppar över.", type: .info)
            return
        }

        state.currentStep = .sortingFiles
        state.statusMessage = "Sorterar filer i adressmappar..."

        let calendar = CalendarService.shared
        let fm = FileManager.default

        if calendarMappings.isEmpty {
            state.appendStepLog(.moveToFolders, "Inga kalendermatchningar — alla bilder sorteras till \"Osorterade\"", type: .warning)
        }

        state.appendLog("Organiserar filer i adressmappar...", type: .info)

        // Geocode all unique addresses and build metadata per address
        var addressMeta: [String: (lat: Double, lon: Double, bookingInfo: String?)] = [:]
        for mapping in calendarMappings {
            let address = calendar.addressFolder(for: mapping.photoDateRange.lowerBound, mappings: calendarMappings) ?? mapping.address
            if addressMeta[address] == nil {
                let bookingInfo = CalendarService.extractBookingInfo(from: mapping.eventTitle)
                // A manually corrected coordinate (PipelineState.correctAddress) must
                // win over automatic geocoding — that correction exists specifically
                // because geocoding got this address wrong.
                if let corrected = state.correctedCoordinates[mapping.address] {
                    addressMeta[address] = (lat: corrected.latitude, lon: corrected.longitude, bookingInfo: bookingInfo)
                    state.appendLog("Använder manuellt rättad GPS för \"\(mapping.address)\" → \(String(format: "%.6f", corrected.latitude)), \(String(format: "%.6f", corrected.longitude))", type: .success)
                    state.appendStepLog(.moveToFolders, "Manuellt rättad GPS: \"\(mapping.address)\" → \(String(format: "%.6f", corrected.latitude)), \(String(format: "%.6f", corrected.longitude))")
                    if let idx = state.allMatchedAddresses.firstIndex(where: { $0.address == mapping.address }) {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = corrected
                    }
                    continue
                }
                let coord = await calendar.geocodeAddress(mapping.address)
                if let coord {
                    addressMeta[address] = (lat: coord.latitude, lon: coord.longitude, bookingInfo: bookingInfo)
                    state.appendLog("Geokodade \"\(mapping.address)\" → \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))", type: .success)
                    state.appendStepLog(.moveToFolders, "Geokodad: \"\(mapping.address)\" → \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))")
                    // Update GPS status and coordinate in address banner
                    if let idx = state.allMatchedAddresses.firstIndex(where: { $0.address == mapping.address }) {
                        state.allMatchedAddresses[idx].hasGPS = true
                        state.allMatchedAddresses[idx].coordinate = coord
                    }
                } else {
                    addressMeta[address] = (lat: 0, lon: 0, bookingInfo: bookingInfo)
                    state.appendLog("Kunde inte geokoda \"\(mapping.address)\" — GPS-data utelämnas.", type: .warning)
                    state.appendStepLog(.moveToFolders, "Geokodning misslyckades: \"\(mapping.address)\"", type: .warning)
                }
            }
        }

        // Kopiera alla foton (sortering sker före gallring)
        let photosToOrganize = state.allPhotos
        var organized = 0
        var unmatched = 0
        var taggedFiles: [String] = []

        let maxConcurrentCopy = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        state.appendStepLog(.moveToFolders, "Sorterar \(photosToOrganize.count) bilder till adressmappar (\(maxConcurrentCopy) parallella)...")
        state.updateStepProgress(.moveToFolders, processed: 0, total: photosToOrganize.count)
        pipelineLog("exportToAddressFolders: \(photosToOrganize.count) bilder, outputDir=\(outputDir.path)")

        // Pre-create all needed directories (must be done before parallel copies)
        var photoFolders: [(photo: PhotoItem, folderName: String)] = []
        for photo in photosToOrganize {
            let folderName: String
            if let matched = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) {
                folderName = matched
            } else {
                folderName = "Osorterade"
                unmatched += 1
            }
            photoFolders.append((photo: photo, folderName: folderName))

            let previewDir = AddressFolderLayout.previewDir(in: outputDir, folderName: folderName)
            let dngDir = AddressFolderLayout.dngDir(in: outputDir, folderName: folderName)
            let extrasDir = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dngDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: extrasDir, withIntermediateDirectories: true)
        }

        // Create symlinks for all files into address folders (fast, no heavy I/O)
        for (index, (photo, folderName)) in photoFolders.enumerated() {
            let previewDestDir = AddressFolderLayout.previewDir(in: outputDir, folderName: folderName)
            let dngDestDir = AddressFolderLayout.dngDir(in: outputDir, folderName: folderName)
            let extrasDestDir = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
            var linkedFiles = 0

            // Symlink preview JPEG → TITTBILDER
            if let previewURL = photo.previewURL, fm.fileExists(atPath: previewURL.path) {
                let dest = previewDestDir.appendingPathComponent(previewURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: previewURL)
                }
                linkedFiles += 1
            }

            // Symlink DNG → address folder
            if let dngURL = photo.dngURL, fm.fileExists(atPath: dngURL.path) {
                let dest = dngDestDir.appendingPathComponent(dngURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: dngURL)
                }
                linkedFiles += 1
            }

            // Symlink original NEF → ÖVRIGA
            if fm.fileExists(atPath: photo.nefURL.path) {
                let dest = extrasDestDir.appendingPathComponent(photo.nefURL.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: photo.nefURL)
                }
                linkedFiles += 1
            }

            if linkedFiles > 0 {
                state.appendStepLog(.moveToFolders, "\(photo.filename) → \(folderName)/ (\(linkedFiles) symlinks)")
            } else {
                state.appendStepLog(.moveToFolders, "\(photo.filename) → \(folderName)/ — INGA filer länkades!", type: .error)
                pipelineLog("VARNING: Inga filer länkades för \(photo.filename)")
            }
            organized += 1

            // Update progress every 50 files so the UI step card shows activity, and
            // check for cancellation/pause at the same cadence rather than per-file
            // (this loop is pure fast symlink creation, not worth checking every file).
            if index % 50 == 0 || index == photoFolders.count - 1 {
                state.updateStepProgress(.moveToFolders, processed: organized, total: photosToOrganize.count)
                state.statusMessage = "Sorterar filer: \(organized)/\(photosToOrganize.count)..."
                if await shouldAbort() {
                    state.appendStepLog(.moveToFolders, "Avbrutet efter \(organized)/\(photosToOrganize.count) filer", type: .warning)
                    markActiveStepsCancelled()
                    return
                }
            }
        }

        // Staging folders (dng/, previews/) kept intact — address folders use symlinks

        // Copy HDR TIFF results into address folders (only if HDR merge is enabled)
        let hdrEnabled = AppSettings.shared.hdrMergeEnabled
        let hdrDir = outputDir.appendingPathComponent("hdr")
        for group in state.bracketGroups where group.isBracket && hdrEnabled {
            guard let firstPhoto = state.photos(in: group).first,
                  let folderName = calendar.addressFolder(for: firstPhoto.dateTime, mappings: calendarMappings) else { continue }
            let previewDir = AddressFolderLayout.previewDir(in: outputDir, folderName: folderName)
            let extrasDir = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
            try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: extrasDir, withIntermediateDirectories: true)

            // Move the 16-bit TIFF → ÖVRIGA
            let hdrTiff = hdrDir.appendingPathComponent("hdr_group_\(group.id).tiff")
            if fm.fileExists(atPath: hdrTiff.path) {
                let dest = extrasDir.appendingPathComponent(hdrTiff.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: hdrTiff, to: dest)
                } else {
                    try? fm.removeItem(at: hdrTiff)
                }
                taggedFiles.append(dest.path)
                state.appendStepLog(.moveToFolders, "HDR \(hdrTiff.lastPathComponent) → \(folderName) ÖVRIGA/")
            }

            // Move HDR JPEG preview → TITTBILDER
            let hdrJpeg = hdrDir.appendingPathComponent("hdr_group_\(group.id).jpg")
            if fm.fileExists(atPath: hdrJpeg.path) {
                let dest = previewDir.appendingPathComponent(hdrJpeg.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: hdrJpeg, to: dest)
                } else {
                    try? fm.removeItem(at: hdrJpeg)
                }
                taggedFiles.append(dest.path)
            }
        }

        if organized > 0 || unmatched > 0 {
            state.appendStepLog(.moveToFolders, "Sorterat: \(organized) bilder i adressmappar" + (unmatched > 0 ? ", \(unmatched) i Osorterade" : ""), type: .success)
            state.appendLog("Organiserade \(organized) bilder i adressmappar" + (unmatched > 0 ? " (\(unmatched) osorterade)" : "") + ".", type: .success)

            // Persist marker so we skip on re-run
            let sortMarker: [String: Any] = [
                "photos_sorted": organized + unmatched,
                "organized": organized,
                "unmatched": unmatched,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let markerData = try? JSONSerialization.data(withJSONObject: sortMarker, options: .prettyPrinted) {
                try? markerData.write(to: sortMarkerFile)
            }
        }
    }

    /// Delete rejected photos from address folders after culling is done
    func deleteRejectedFiles() async {
        guard let outputDir = state.outputDirectory else { return }

        let fm = FileManager.default
        let calendar = CalendarService.shared
        let rejectedPhotos = state.allPhotos.filter { $0.rejected }

        guard !rejectedPhotos.isEmpty else {
            state.appendLog("Inga gallrade bilder att ta bort.", type: .info)
            return
        }

        var deletedCount = 0
        let getBaseName = { (url: URL) in url.deletingPathExtension().lastPathComponent }

        for photo in rejectedPhotos {
            let folderName = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) ?? "Osorterade"
            let photoBase = getBaseName(photo.nefURL)

            // DNG files are in the address folder directly, previews and originals
            // (plus any XMP sidecar, same basename) in suffixed folders.
            let searchDirs = AddressFolderLayout.allDirs(in: outputDir, folderName: folderName)

            for dir in searchDirs {
                guard fm.fileExists(atPath: dir.path),
                      let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

                for file in files where getBaseName(file) == photoBase {
                    do {
                        try fm.removeItem(at: file)
                        deletedCount += 1
                        state.appendStepLog(.manualReview, "✗ Raderade \(file.lastPathComponent)")
                    } catch {
                        pipelineLog("Kunde inte radera \(file.lastPathComponent): \(error)")
                    }
                }
            }
        }

        logDecision(step: "cull_delete", decision: "deleted", details: [
            "rejectedPhotos": "\(rejectedPhotos.count)",
            "deletedFiles": "\(deletedCount)"
        ])
        state.appendLog("Raderade \(deletedCount) filer från gallrade bilder.", type: .success)
        state.appendStepLog(.manualReview, "Gallring klar: \(deletedCount) filer raderade", type: .success)
    }

    /// Creates the `bracket_NNN_HDR_Nexp` / `single_NNN_Nimg` folders under
    /// `bracket_groups/`, each containing symlinks to the group's NEF (via
    /// `nefLookup`, which — unlike the old Python version — resolves files
    /// recursively so subfolders under the input directory work) and DNG (from
    /// the `dng/` staging folder) files. Matches the old embedded Python
    /// organize script's behavior exactly, minus that bug.
    nonisolated static func organizeGroupsIntoFolders(groups: [BracketGroupResult], nefLookup: [String: URL], dngDir: URL, groupsDir: URL) {
        let fm = FileManager.default
        for group in groups {
            let folderName = group.isBracket
                ? "bracket_\(String(format: "%03d", group.groupId))_HDR_\(group.imageCount)exp"
                : "single_\(String(format: "%03d", group.groupId))_\(group.imageCount)img"
            let groupFolder = groupsDir.appendingPathComponent(folderName)
            try? fm.createDirectory(at: groupFolder, withIntermediateDirectories: true)

            for filename in group.files {
                if let nefURL = nefLookup[filename] {
                    let dst = groupFolder.appendingPathComponent(filename)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.createSymbolicLink(at: dst, withDestinationURL: nefURL)
                    }
                }

                let baseName = filename.contains(".") ? String(filename[..<filename.lastIndex(of: ".")!]) : filename
                let dngSrc = dngDir.appendingPathComponent("\(baseName).dng")
                let dngDst = groupFolder.appendingPathComponent("\(baseName).dng")
                if fm.fileExists(atPath: dngSrc.path) && !fm.fileExists(atPath: dngDst.path) {
                    try? fm.createSymbolicLink(at: dngDst, withDestinationURL: dngSrc)
                }
            }
        }
    }
}
