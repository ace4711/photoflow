import Foundation

/// Omsortering av en redan sorterad session: filer som ligger i fel adressmapp (efter en ändrad
/// tilldelningsregel eller ny kalendermatchning) flyttas till rätt mapp.
///
/// Sorteringen skapade förut bara länkar i den mapp bilden hör till nu — den rörde aldrig det som
/// redan låg i en annan adressmapp. En bild som bytt adress fanns då kvar i den gamla mappen (med
/// den gamla adressens metadata) och fick en ny länk i den nya. Här flyttas i stället allt som
/// appen själv skapat i adressmapparna:
/// - symlänkar till NEF/DNG/förhandsbild (`<adress>`, `<adress> TITTBILDER`, `<adress> ÖVRIGA`),
/// - XMP-sidecars bredvid NEF-länkarna (bär gallringsbeslut och metadata),
/// - HDR-filer (`hdr_group_<id>.tiff|jpg`) och förbättrade filer (`<nyckel>_enh.*` i FÖRBÄTTRADE),
/// - samma sak i `Gallrade/`-undermapparna ("flytta"-läget i gallringen), till rätt mapps `Gallrade/`.
///
/// Original raderas aldrig (en NEF i adressmappen är alltid en länk; att ta bort en länk rör inte
/// originalet). En felplacerad länk tas bort bara när rätt mapp redan har en länk med samma namn.
/// Unika filer (HDR, förbättrade, sidecars) raderas bara när rätt mapp redan har en byte-identisk
/// kopia; annars flyttas de, eller lämnas kvar med en varning om rätt mapp har en annan fil med
/// samma namn. Filer som användaren lagt dit själv (riktiga filer med en bilds basnamn), FÄRDIGA
/// och FILM rörs aldrig.
extension PipelineRunner {
    /// Vad omsorteringen gjorde med en fil.
    nonisolated struct Relocation: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            /// Flyttad till `destination`.
            case moved
            /// Felplacerad länk (eller identisk kopia) borttagen — rätt mapp hade redan samma fil.
            case removedDuplicate
            /// Lämnad kvar: rätt mapp har en annan fil med samma namn.
            case keptConflict
        }
        var source: URL
        var destination: URL
        var action: Action
    }

    /// Adressmapparna som finns på disk (inklusive "Osorterade"), utlästa ur mappnamnen.
    nonisolated static func addressFoldersOnDisk(in outputDir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        var folders: Set<String> = []
        for name in names {
            for suffix in [" ÖVRIGA", " TITTBILDER", AddressFolderLayout.enhancedSuffix] {
                let nfc = name.precomposedStringWithCanonicalMapping
                let nfcSuffix = suffix.precomposedStringWithCanonicalMapping
                if nfc.hasSuffix(nfcSuffix), nfc.count > nfcSuffix.count {
                    // Behåll diskens stavning (NFC/NFD) så att sökvägarna går att öppna.
                    folders.insert(String(name.dropLast(suffix.count)))
                }
            }
        }
        return folders.sorted()
    }

    /// Flyttar felplacerade filer till rätt adressmapp. Ren mot appens tillstånd: rätt mapp ges av
    /// uppslagen (`photoFolders`: bildens basnamn `DSC_0012` → mapp; `hdrGroupFolders`: grupp-id →
    /// mapp; `enhancedFolder`: nyckel `hdr_group_3`/`DSC_0012` → mapp). En fil vars rätta mapp inte
    /// är känd lämnas där den är.
    nonisolated static func relocateMisplacedFiles(
        outputDir: URL,
        photoFolders: [String: String],
        hdrGroupFolders: [Int: String],
        enhancedFolder: (String) -> String?
    ) -> [Relocation] {
        let fm = FileManager.default
        var result: [Relocation] = []
        let nfc = { (s: String) in s.precomposedStringWithCanonicalMapping }

        enum Kind: CaseIterable { case dng, preview, extras, enhanced }
        func dir(_ kind: Kind, _ folder: String) -> URL {
            switch kind {
            case .dng: return AddressFolderLayout.dngDir(in: outputDir, folderName: folder)
            case .preview: return AddressFolderLayout.previewDir(in: outputDir, folderName: folder)
            case .extras: return AddressFolderLayout.extrasDir(in: outputDir, folderName: folder)
            case .enhanced: return AddressFolderLayout.enhancedDir(in: outputDir, folderName: folder)
            }
        }
        func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
        func occupied(_ url: URL) -> Bool { isLink(url) || fm.fileExists(atPath: url.path) }

        for folder in addressFoldersOnDisk(in: outputDir) {
            for kind in Kind.allCases {
                let base = dir(kind, folder)
                for subdir in [base, base.appendingPathComponent("Gallrade")] {
                    guard let names = try? fm.contentsOfDirectory(atPath: subdir.path) else { continue }
                    for name in names.sorted() {
                        let source = subdir.appendingPathComponent(name)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue, !isLink(source) { continue }
                        let ext = (name as NSString).pathExtension.lowercased()
                        let stem = (name as NSString).deletingPathExtension

                        // Vem äger filen, och är den unik (raderas aldrig utan identisk kopia)?
                        var target: String?
                        var unique = true
                        if kind == .enhanced {
                            guard ["tiff", "tif", "jpg"].contains(ext), stem.hasSuffix(AddressFolderLayout.enhancedFileSuffix),
                                  stem.count > AddressFolderLayout.enhancedFileSuffix.count else { continue }
                            target = enhancedFolder(String(stem.dropLast(AddressFolderLayout.enhancedFileSuffix.count)))
                        } else if stem.hasPrefix("hdr_group_"), ["tiff", "tif", "jpg"].contains(ext),
                                  let id = Int(stem.dropFirst("hdr_group_".count)) {
                            target = hdrGroupFolders[id]
                        } else if let photoFolder = photoFolders[stem] {
                            if ext == "xmp" {
                                target = photoFolder
                            } else if isLink(source) {
                                target = photoFolder
                                unique = false
                            } else {
                                continue // en riktig fil med bildens basnamn: användarens, rörs inte
                            }
                        }
                        guard let target, nfc(target) != nfc(folder) else { continue }

                        let targetBase = dir(kind, target)
                        let destDir = subdir == base ? targetBase : targetBase.appendingPathComponent("Gallrade")
                        let destination = destDir.appendingPathComponent(name)
                        guard (try? FileSafety.assertInsideOutput(source, outputDir: outputDir)) != nil,
                              (try? FileSafety.assertInsideOutput(destination, outputDir: outputDir)) != nil else { continue }

                        if occupied(destination) {
                            let identical = !unique || fm.contentsEqual(atPath: source.path, andPath: destination.path)
                            if identical, (try? fm.removeItem(at: source)) != nil {
                                result.append(Relocation(source: source, destination: destination, action: .removedDuplicate))
                            } else {
                                result.append(Relocation(source: source, destination: destination, action: .keptConflict))
                            }
                            continue
                        }
                        do {
                            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                            try fm.moveItem(at: source, to: destination)
                            result.append(Relocation(source: source, destination: destination, action: .moved))
                        } catch {
                            result.append(Relocation(source: source, destination: destination, action: .keptConflict))
                        }
                    }
                }
            }
        }
        return result
    }

    /// Omsorteringen i sorteringssteget: bygger uppslagen ur sessionens bilder/grupper, flyttar,
    /// loggar varje flytt och tar bort stämplarna för flyttade filer (de får ny metadata).
    func relocateMisplacedFiles(outputDir: URL) -> [Relocation] {
        var photoFolders: [String: String] = [:]
        for photo in state.allPhotos {
            photoFolders[photo.nefURL.deletingPathExtension().lastPathComponent] = addressFolderName(forPhotoDate: photo.dateTime)
        }
        var hdrGroupFolders: [Int: String] = [:]
        for group in state.bracketGroups where group.isBracket {
            guard let first = state.photos(in: group).first else { continue }
            hdrGroupFolders[group.id] = addressFolderName(forPhotoDate: first.dateTime)
        }
        let relocations = Self.relocateMisplacedFiles(
            outputDir: outputDir, photoFolders: photoFolders, hdrGroupFolders: hdrGroupFolders,
            enhancedFolder: { key in
                // Okända nycklar (ingen sådan grupp/bild) flyttas inte.
                if key.hasPrefix("hdr_group_") {
                    return Int(key.dropFirst("hdr_group_".count)).flatMap { hdrGroupFolders[$0] }
                }
                return photoFolders[key]
            }
        )
        guard !relocations.isEmpty else { return [] }

        var stamps = MetadataStamps.load(from: outputDir)
        func short(_ url: URL) -> String {
            "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        }
        for relocation in relocations {
            stamps.remove(relocation.source, outputDir: outputDir)
            switch relocation.action {
            case .moved:
                stamps.remove(relocation.destination, outputDir: outputDir)
                state.appendStepLog(.moveToFolders, "Flyttad: \(short(relocation.source)) → \(short(relocation.destination))")
                pipelineLog("Omsortering: flyttade \(relocation.source.path) → \(relocation.destination.path)")
            case .removedDuplicate:
                state.appendStepLog(.moveToFolders, "Felplacerad dubblett borttagen: \(short(relocation.source)) (finns redan i \(short(relocation.destination)))")
                pipelineLog("Omsortering: tog bort dubblett \(relocation.source.path) (finns i \(relocation.destination.path))")
            case .keptConflict:
                state.appendStepLog(.moveToFolders, "Lämnad kvar: \(short(relocation.source)) — \(short(relocation.destination)) finns redan och är en annan fil", type: .warning)
                pipelineLog("Omsortering: lämnade \(relocation.source.path) (konflikt med \(relocation.destination.path))")
            }
        }
        stamps.save(to: outputDir)
        let moved = relocations.filter { $0.action == .moved }.count
        let removed = relocations.filter { $0.action == .removedDuplicate }.count
        let kept = relocations.filter { $0.action == .keptConflict }.count
        logDecision(step: "move_to_folders", decision: "relocated", details: [
            "moved": "\(moved)", "removedDuplicates": "\(removed)", "keptConflicts": "\(kept)"
        ])
        state.appendStepLog(.moveToFolders,
            "Omsortering: \(moved) filer flyttade till rätt adressmapp" + (removed > 0 ? ", \(removed) dubbletter borttagna" : "")
            + (kept > 0 ? ", \(kept) lämnade kvar (konflikt)" : ""), type: kept > 0 ? .warning : .success)
        state.appendLog("Omsortering: \(moved) filer flyttade till rätt adressmapp.", type: .success)
        // Metadata för de flyttade filerna måste skrivas om (stämplarna ovan är borta; markören också).
        try? FileManager.default.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
        return relocations
    }
}
