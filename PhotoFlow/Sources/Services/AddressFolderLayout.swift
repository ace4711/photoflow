import Foundation

/// Central definition of the address-folder naming scheme used when exporting
/// sorted photos into `outputDir`.
///
/// This exists because the folder-suffix scheme was previously duplicated (and
/// drifted out of sync) between `exportToAddressFolders`, `writeIPTCMetadata`
/// and `deleteRejectedFiles`: DNG symlinks live directly in `<address>` (no
/// suffix), while previews and originals live in suffixed sibling folders. A
/// bug had `writeIPTCMetadata` look for a non-existent `<address> DNG` folder,
/// silently skipping all DNG files for metadata writing. All three call sites
/// should go through this type so the layout can only change in one place.
nonisolated enum AddressFolderLayout {
    /// DNG symlinks live directly in the address-named folder — no suffix.
    static func dngDirName(_ folderName: String) -> String { folderName }
    static func previewDirName(_ folderName: String) -> String { "\(folderName) TITTBILDER" }
    static func extrasDirName(_ folderName: String) -> String { "\(folderName) ÖVRIGA" }
    /// Förbättrade versioner (steget "Förbättra bilder"): `hdr_group_<id>_enh.tiff/jpg`
    /// och `<DSC_xxxx>_enh.tiff/jpg`. Skrivs först till `enhanced/` och flyttas hit av sorteringen.
    static func enhancedDirName(_ folderName: String) -> String { "\(folderName)\(enhancedSuffix)" }
    /// Färdiga bilder exporterade från Lightroom (underlag för Objektfilm).
    static func finishedDirName(_ folderName: String) -> String { "\(folderName) FÄRDIGA" }
    /// Objektfilmens utmapp (`reel.json`, `reel_<format>.mp4`, `reel_analysis.json`).
    static func reelDirName(_ folderName: String) -> String { "\(folderName) FILM" }

    static let enhancedSuffix = " FÖRBÄTTRADE"
    /// Stagingmappen i outputmappen dit förbättringssteget skriver.
    static let enhancedStagingDirName = "enhanced"
    /// Filnamnsändelsen på förbättrade filer (före filändelsen).
    static let enhancedFileSuffix = "_enh"
    static let finishedSuffix = " FÄRDIGA"
    static let reelSuffix = " FILM"

    static func dngDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(dngDirName(folderName))
    }
    static func previewDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(previewDirName(folderName))
    }
    static func extrasDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(extrasDirName(folderName))
    }
    static func enhancedDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(enhancedDirName(folderName))
    }
    static func enhancedStagingDir(in outputDir: URL) -> URL {
        outputDir.appendingPathComponent(enhancedStagingDirName)
    }
    static func finishedDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(finishedDirName(folderName))
    }
    static func reelDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(reelDirName(folderName))
    }

    /// Adressen ur en `<adress> FÄRDIGA`-mapp (nil om namnet inte följer mönstret).
    static func addressName(fromFinishedDir name: String) -> String? {
        guard name.hasSuffix(finishedSuffix), name.count > finishedSuffix.count else { return nil }
        return String(name.dropLast(finishedSuffix.count))
    }

    /// Filmens utmapp för en källmapp med färdiga bilder: `<adress> FILM` bredvid
    /// `<adress> FÄRDIGA`, annars `<källmappens namn> FILM` bredvid källmappen.
    static func reelDir(forSource source: URL) -> URL {
        let name = source.lastPathComponent
        let base = addressName(fromFinishedDir: name) ?? name
        return source.deletingLastPathComponent().appendingPathComponent(reelDirName(base), isDirectory: true)
    }

    /// Var en grupps HDR-filer ligger just nu. Sorteringen flyttar TIFF:en till
    /// `<adress> ÖVRIGA/` och JPEG:en till `<adress> TITTBILDER/`, så den som
    /// bara letar i `hdr/` (som HDR-steget och granskningen gjorde) tror att en
    /// sorterad session saknar HDR — och gör om alla grupper.
    struct HDRFiles: Equatable {
        var tiff: URL?
        var jpeg: URL?
    }

    /// Alla grupper med HDR-filer i `hdr/` eller i en adressmapp, nyckel = grupp-id.
    /// `hdr/` vinner om samma grupp finns på båda ställena (den är nyast).
    static func locateHDRFiles(in outputDir: URL) -> [Int: HDRFiles] {
        let fm = FileManager.default
        var result: [Int: HDRFiles] = [:]
        func scan(_ dir: URL, overwrite: Bool) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where name.hasPrefix("hdr_group_") {
                let stem = (name as NSString).deletingPathExtension
                guard let id = Int(stem.dropFirst("hdr_group_".count)) else { continue }
                let url = dir.appendingPathComponent(name)
                var entry = result[id] ?? HDRFiles()
                switch (name as NSString).pathExtension.lowercased() {
                case "tiff", "tif": if overwrite || entry.tiff == nil { entry.tiff = url }
                case "jpg": if overwrite || entry.jpeg == nil { entry.jpeg = url }
                default: continue
                }
                result[id] = entry
            }
        }
        let topLevel = (try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? []
        for name in topLevel.sorted() where name.hasSuffix(" ÖVRIGA") || name.hasSuffix(" TITTBILDER") {
            scan(outputDir.appendingPathComponent(name), overwrite: false)
        }
        scan(outputDir.appendingPathComponent("hdr"), overwrite: true)
        return result
    }

    /// Förbättrade filer (nyckel = basnamnet utan `_enh`, t.ex. `hdr_group_3` eller
    /// `DSC_0012`) i `enhanced/` eller i någon `<adress> FÖRBÄTTRADE`-mapp.
    /// `enhanced/` vinner vid dubblett (den är nyast).
    static func locateEnhancedFiles(in outputDir: URL) -> [String: [URL]] {
        let fm = FileManager.default
        var result: [String: [URL]] = [:]
        func scan(_ dir: URL, overwrite: Bool) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            var local: [String: [URL]] = [:]
            for name in names.sorted() {
                let ext = (name as NSString).pathExtension.lowercased()
                guard ["tiff", "tif", "jpg"].contains(ext) else { continue }
                let stem = (name as NSString).deletingPathExtension
                guard stem.hasSuffix(enhancedFileSuffix), stem.count > enhancedFileSuffix.count else { continue }
                let key = String(stem.dropLast(enhancedFileSuffix.count))
                local[key, default: []].append(dir.appendingPathComponent(name))
            }
            for (key, urls) in local where overwrite || result[key] == nil { result[key] = urls }
        }
        let topLevel = (try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? []
        for name in topLevel.sorted() where name.hasSuffix(enhancedSuffix) {
            scan(outputDir.appendingPathComponent(name), overwrite: false)
        }
        scan(enhancedStagingDir(in: outputDir), overwrite: true)
        return result
    }

    /// All subfolders belonging to one address, in the order metadata writing
    /// and cull-deletion scan them: DNG, previews, originals/extras, then enhanced.
    static func allDirs(in outputDir: URL, folderName: String) -> [URL] {
        [dngDir(in: outputDir, folderName: folderName),
         previewDir(in: outputDir, folderName: folderName),
         extrasDir(in: outputDir, folderName: folderName),
         enhancedDir(in: outputDir, folderName: folderName)]
    }
}
