import Foundation

/// Fas 4: vad som händer med gallringsbeslut när `PreviewCullView.finishCulling`
/// avslutas — styrs av `AppSettings.cullAction` ("markera" default, "radera",
/// "flytta"). Tidigare fanns bara `deleteRejectedFiles` (permanent radering);
/// nu är den bara ETT av tre lägen, se `finishCullingAction`.
extension PipelineRunner {
    /// Dispatcher som `PreviewCullView.finishCulling` anropar i stället för
    /// att gå direkt på `deleteRejectedFiles` — väljer beteende efter
    /// `AppSettings.cullAction`.
    func finishCullingAction() async {
        switch AppSettings.shared.cullAction {
        case "radera":
            await deleteRejectedFiles()
        case "flytta":
            await moveRejectedToFolder()
        default: // "markera" — även okänt/framtida värde faller tillbaka hit, säkrast (rör inga filer)
            await writeCullRatings()
        }
    }

    /// Builds the exiftool argfile lines for one file's gallringsbeslut, using
    /// the same NEF-symlink-vs-real-file distinction as
    /// `PipelineRunner.exiftoolArguments` (see that function's doc comment for
    /// why NEF never gets touched directly): DNG/JPEG/HDR-TIFF get
    /// `-overwrite_original_in_place`, NEF gets an XMP sidecar.
    ///
    /// `XMP:Rating` is what Lightroom Classic reads for both star ratings
    /// (0-5) AND the "Rejected" flag: verified against Adobe's XMP
    /// specification/Lightroom's own behavior — Lightroom shows a photo as
    /// "Rejected" (black flag) exactly when `xmp:Rating == -1`, and as
    /// unflagged/unrated at `0`. Accepted photos get a plain 3-star rating
    /// (a reasonable "good, keep" default — the user can always refine further
    /// inside Lightroom); rejected photos get `-1` so Lightroom's own
    /// Attribute/Flag filters pick them up immediately without any import
    /// step. `XMP-photoshop:Urgency=8` (lowest of IPTC's 1-8 scale) is added
    /// on rejects too, so the decision is still visible in tools that don't
    /// understand the rating/flag convention.
    static func cullExiftoolArguments(for file: URL, accepted: Bool) -> [String] {
        let isNEF = file.pathExtension.lowercased() == "nef"
        let sidecarURL = file.deletingPathExtension().appendingPathExtension("xmp")
        let sidecarExists = isNEF && FileManager.default.fileExists(atPath: sidecarURL.path)

        var lines: [String] = []
        if isNEF {
            if sidecarExists {
                lines.append("-overwrite_original")
            }
        } else {
            lines.append("-overwrite_original_in_place")
        }

        let rating = accepted ? 3 : -1
        lines.append("-XMP:Rating=\(rating)")
        if !accepted {
            lines.append("-XMP-photoshop:Urgency=8")
        }

        if isNEF && !sidecarExists {
            lines.append("-o")
            lines.append(sidecarURL.path)
        }
        lines.append(isNEF && sidecarExists ? sidecarURL.path : file.path)
        lines.append("-execute")
        return lines
    }

    /// "markera"-läget: skriver `XMP:Rating` (+`Urgency` för avvisade) till
    /// alla filer för varje BESLUTAD bild (accepterad eller avvisad) — rör
    /// aldrig oreviderade bilder. Tar aldrig bort eller flyttar något.
    func writeCullRatings() async {
        guard let outputDir = state.outputDirectory else { return }
        let fm = FileManager.default
        let calendar = CalendarService.shared
        let decidedPhotos = state.allPhotos.filter { $0.accepted || $0.rejected }

        guard !decidedPhotos.isEmpty else {
            state.appendLog("Inga gallringsbeslut att skriva till Lightroom.", type: .info)
            return
        }
        guard let exiftoolPath = ToolLocator.exiftool else {
            state.appendStepLog(.manualReview, "exiftool saknas — kan inte skriva gallringsbeslut som XMP-betyg. Installera med: brew install exiftool", type: .error)
            state.appendLog("Gallringsbeslut kunde inte skrivas — exiftool saknas.", type: .error)
            return
        }

        let getBaseName = { (url: URL) in url.deletingPathExtension().lastPathComponent }
        var argfileLines: [String] = []
        var fileDescriptions: [String] = []

        for photo in decidedPhotos {
            let folderName = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) ?? "Osorterade"
            let photoBase = getBaseName(photo.nefURL)

            for dir in AddressFolderLayout.allDirs(in: outputDir, folderName: folderName) {
                guard fm.fileExists(atPath: dir.path),
                      let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

                for file in files where getBaseName(file) == photoBase {
                    // XMP sidecars are written as a side effect of tagging their NEF,
                    // never re-tagged directly (same reasoning as writeIPTCMetadata).
                    if file.pathExtension.lowercased() == "xmp" { continue }
                    argfileLines.append(contentsOf: Self.cullExiftoolArguments(for: file, accepted: photo.accepted))
                    let symbol = photo.accepted ? "★" : "✗"
                    fileDescriptions.append("\(symbol) \(file.lastPathComponent) ← Rating=\(photo.accepted ? 3 : -1)")
                }
            }
        }

        guard !argfileLines.isEmpty else {
            state.appendStepLog(.manualReview, "Inga filer hittades för gallringsbeslut — hoppar över XMP-skrivning", type: .warning)
            return
        }

        let argfileURL = outputDir.appendingPathComponent(".exiftool_cull_argfile.txt")
        try? argfileLines.joined(separator: "\n").write(to: argfileURL, atomically: true, encoding: .utf8)

        do {
            let output = try await runProcess(executablePath: exiftoolPath, arguments: ["-@", argfileURL.path])
            pipelineLog("Cull-rating exiftool output: \(output)")
            for desc in fileDescriptions {
                state.appendStepLog(.manualReview, desc)
            }
            state.appendStepLog(.manualReview, "Gallringsbeslut skrivna som XMP-betyg till \(fileDescriptions.count) filer — synliga direkt i Lightroom (Rejected-flagga/stjärnor)", type: .success)
            state.appendLog("Gallringsbeslut skrivna som XMP-betyg (Lightroom) till \(fileDescriptions.count) filer — inga filer rörda.", type: .success)
            logDecision(step: "cull_mark", decision: "xmp_written", details: ["files": "\(fileDescriptions.count)"])
        } catch {
            state.appendStepLog(.manualReview, "Fel vid skrivning av gallringsbeslut: \(error.localizedDescription)", type: .error)
            state.appendLog("Kunde inte skriva gallringsbeslut: \(error.localizedDescription)", type: .error)
        }
        try? fm.removeItem(at: argfileURL)
    }

    /// "flytta"-läget: flyttar (inte kopierar) avvisade bilders filer till en
    /// "Gallrade"-undermapp under respektive DNG-/TITTBILDER-/ÖVRIGA-mapp.
    /// De flesta filer där är redan symlänkar (se `exportToAddressFolders`) —
    /// att flytta en symlänk flyttar bara länken, aldrig originalfilen den
    /// pekar på.
    func moveRejectedToFolder() async {
        guard let outputDir = state.outputDirectory else { return }
        let fm = FileManager.default
        let calendar = CalendarService.shared
        let rejectedPhotos = state.allPhotos.filter { $0.rejected }

        guard !rejectedPhotos.isEmpty else {
            state.appendLog("Inga gallrade bilder att flytta.", type: .info)
            return
        }

        var movedCount = 0
        let getBaseName = { (url: URL) in url.deletingPathExtension().lastPathComponent }

        for photo in rejectedPhotos {
            let folderName = calendar.addressFolder(for: photo.dateTime, mappings: calendarMappings) ?? "Osorterade"
            let photoBase = getBaseName(photo.nefURL)

            for dir in AddressFolderLayout.allDirs(in: outputDir, folderName: folderName) {
                guard fm.fileExists(atPath: dir.path),
                      let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

                let culledDir = dir.appendingPathComponent("Gallrade")
                for file in files where getBaseName(file) == photoBase {
                    try? fm.createDirectory(at: culledDir, withIntermediateDirectories: true)
                    let dest = culledDir.appendingPathComponent(file.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: dest.path) {
                            try fm.removeItem(at: dest)
                        }
                        try fm.moveItem(at: file, to: dest)
                        movedCount += 1
                        state.appendStepLog(.manualReview, "→ Flyttade \(file.lastPathComponent) till \(dir.lastPathComponent)/Gallrade/")
                    } catch {
                        pipelineLog("Kunde inte flytta \(file.lastPathComponent) till Gallrade/: \(error)")
                    }
                }
            }
        }

        logDecision(step: "cull_move", decision: "moved", details: [
            "rejectedPhotos": "\(rejectedPhotos.count)",
            "movedFiles": "\(movedCount)"
        ])
        state.appendLog("Flyttade \(movedCount) filer till Gallrade-mappar (inget raderat).", type: .success)
        state.appendStepLog(.manualReview, "Gallring klar: \(movedCount) filer flyttade till Gallrade/", type: .success)
    }
}
