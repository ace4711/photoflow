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

    /// All subfolders belonging to one address, in the order metadata writing
    /// and cull-deletion scan them: DNG, previews, then originals/extras.
    static func allDirs(in outputDir: URL, folderName: String) -> [URL] {
        [dngDir(in: outputDir, folderName: folderName),
         previewDir(in: outputDir, folderName: folderName),
         extrasDir(in: outputDir, folderName: folderName)]
    }
}
