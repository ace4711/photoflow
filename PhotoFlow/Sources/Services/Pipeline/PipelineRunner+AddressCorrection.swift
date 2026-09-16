import Foundation

/// Fas 4 (kvarstående från Fas 1b, se FORBATTRINGAR.md): when the user
/// corrects a mismatched address via `AddressBanner`/`PipelineState.
/// correctAddress`, the folder-naming source of truth — `PipelineRunner.
/// calendarMappings` — previously wasn't updated at all, so every later call
/// to `CalendarService.addressFolder(for:mappings:)` (metadata writing,
/// cull-file lookups, re-sorting) kept resolving to the OLD address until the
/// calendar step was re-run from scratch. These two functions close that gap:
/// `updateCalendarMappingAddress` fixes the in-memory mapping immediately,
/// and `resortAddressFolder` renames the already-created on-disk folders (if
/// any) to match.
extension PipelineRunner {
    /// Updates every `calendarMappings` entry matching `oldAddress` in place,
    /// so folder-name lookups reflect the correction immediately — without
    /// this, `calendarMappings` would keep pointing at the pre-correction
    /// address until `findCalendarInfo` is re-run from scratch (which throws
    /// away calendar_matches.json and re-geocodes everything).
    func updateCalendarMappingAddress(from oldAddress: String, to newAddress: String) {
        guard oldAddress != newAddress else { return }
        var changed = false
        for i in calendarMappings.indices where calendarMappings[i].address == oldAddress {
            calendarMappings[i].address = newAddress
            changed = true
        }
        if changed {
            pipelineLog("Adressmappning uppdaterad i minnet: \"\(oldAddress)\" → \"\(newAddress)\"")
        }
    }

    /// True when files have already been organized into an address folder for
    /// `address` — i.e. `exportToAddressFolders` has run AND the on-disk
    /// folder for it actually exists. Used to decide whether `AddressBanner`
    /// should offer "Sortera om filerna till den nya adressmappen" after a
    /// correction.
    func addressFolderAlreadySorted(_ address: String) -> Bool {
        guard let outputDir = state.outputDirectory else { return false }
        let marker = outputDir.appendingPathComponent("files_sorted.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        let folderName = CalendarService.sanitizeFolderName(address)
        return FileManager.default.fileExists(atPath: AddressFolderLayout.dngDir(in: outputDir, folderName: folderName).path)
            || FileManager.default.fileExists(atPath: AddressFolderLayout.previewDir(in: outputDir, folderName: folderName).path)
            || FileManager.default.fileExists(atPath: AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName).path)
    }

    /// Renames the on-disk address folders (DNG / TITTBILDER / ÖVRIGA) from
    /// `oldAddress`'s sanitized name to `newAddress`'s, when files were
    /// already sorted under the old name. Only ever touches the three exact
    /// folder names `AddressFolderLayout` defines, directly under
    /// `outputDir` — never the input/original directories, and never any
    /// other folder. Also updates `calendarMappings` (via
    /// `updateCalendarMappingAddress`) so subsequent lookups agree with the
    /// new folder names. Returns `true` if anything was actually moved.
    @discardableResult
    func resortAddressFolder(from oldAddress: String, to newAddress: String) -> Bool {
        guard let outputDir = state.outputDirectory else { return false }
        let fm = FileManager.default
        let oldName = CalendarService.sanitizeFolderName(oldAddress)
        let newName = CalendarService.sanitizeFolderName(newAddress)
        guard oldName != newName else {
            // Names sanitize to the same thing (e.g. only whitespace differs) —
            // still fix the in-memory mapping, nothing to move on disk.
            updateCalendarMappingAddress(from: oldAddress, to: newAddress)
            return false
        }

        let renamePairs = [
            (AddressFolderLayout.dngDirName(oldName), AddressFolderLayout.dngDirName(newName)),
            (AddressFolderLayout.previewDirName(oldName), AddressFolderLayout.previewDirName(newName)),
            (AddressFolderLayout.extrasDirName(oldName), AddressFolderLayout.extrasDirName(newName))
        ]

        var movedAny = false
        for (oldSub, newSub) in renamePairs {
            let oldURL = outputDir.appendingPathComponent(oldSub)
            let newURL = outputDir.appendingPathComponent(newSub)
            // Both are always built from AddressFolderLayout's fixed dir-name
            // helpers directly under outputDir, so this should never throw —
            // it's defense-in-depth against a future bug in an address string
            // ever escaping outputDir via rename, matching FileSafety's use in
            // the culling delete/move paths.
            guard (try? FileSafety.assertInsideOutput(oldURL, outputDir: outputDir)) != nil,
                  (try? FileSafety.assertInsideOutput(newURL, outputDir: outputDir)) != nil else {
                pipelineLog("Säkerhetsspärr: vägrade döpa om \(oldSub) → \(newSub) (utanför outputDir)")
                continue
            }
            guard fm.fileExists(atPath: oldURL.path) else { continue }

            if fm.fileExists(atPath: newURL.path) {
                // Target already exists (e.g. correcting twice, or a previous
                // partial run) — merge file-by-file instead of letting
                // moveItem fail outright on a non-empty destination.
                if let files = try? fm.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil) {
                    for file in files {
                        let dest = newURL.appendingPathComponent(file.lastPathComponent)
                        if !fm.fileExists(atPath: dest.path), (try? FileSafety.assertInsideOutput(dest, outputDir: outputDir)) != nil {
                            try? fm.moveItem(at: file, to: dest)
                        }
                    }
                }
                try? fm.removeItem(at: oldURL)
                movedAny = true
                state.appendLog("Slog ihop \"\(oldSub)\" i \"\(newSub)\" (adressrättning).", type: .success)
            } else {
                do {
                    try fm.moveItem(at: oldURL, to: newURL)
                    movedAny = true
                    state.appendLog("Döpte om mapp \"\(oldSub)\" → \"\(newSub)\" (adressrättning).", type: .success)
                } catch {
                    pipelineLog("Kunde inte flytta \(oldSub) → \(newSub): \(error)")
                    state.appendLog("Kunde inte flytta \"\(oldSub)\" → \"\(newSub)\": \(error.localizedDescription)", type: .error)
                }
            }
        }

        updateCalendarMappingAddress(from: oldAddress, to: newAddress)

        if movedAny {
            logDecision(step: "address_correction", decision: "resorted_folders", details: [
                "from": oldAddress, "to": newAddress
            ])
            state.appendLog("Sorterade om filerna för \"\(oldAddress)\" till \"\(newAddress)\".", type: .success)
        }
        return movedAny
    }
}
