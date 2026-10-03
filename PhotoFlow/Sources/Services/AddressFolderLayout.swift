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
enum AddressFolderLayout {
    /// DNG symlinks live directly in the address-named folder — no suffix.
    static func dngDirName(_ folderName: String) -> String { folderName }
    static func previewDirName(_ folderName: String) -> String { "\(folderName) TITTBILDER" }
    static func extrasDirName(_ folderName: String) -> String { "\(folderName) ÖVRIGA" }

    static func dngDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(dngDirName(folderName))
    }
    static func previewDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(previewDirName(folderName))
    }
    static func extrasDir(in outputDir: URL, folderName: String) -> URL {
        outputDir.appendingPathComponent(extrasDirName(folderName))
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

    /// All subfolders belonging to one address, in the order metadata writing
    /// and cull-deletion scan them: DNG, previews, then originals/extras.
    static func allDirs(in outputDir: URL, folderName: String) -> [URL] {
        [dngDir(in: outputDir, folderName: folderName),
         previewDir(in: outputDir, folderName: folderName),
         extrasDir(in: outputDir, folderName: folderName)]
    }
}
