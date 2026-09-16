import Foundation

/// Slutgranskning (see FORBATTRINGAR.md): a small, central guard that every
/// destructive filesystem call derived from user-influenced data (calendar
/// addresses, photo filenames) should pass through before it deletes, moves
/// or renames anything. On its own it is defense-in-depth — the real fix for
/// the path-traversal case is `CalendarService.sanitizeFolderName` refusing
/// to ever produce "", "." or ".." — but every call site listed in the task
/// (`deleteRejectedFiles`, `moveRejectedToFolder`, `resortAddressFolder`)
/// also asserts through here, so a future bug in an address/filename
/// computation throws and logs instead of silently deleting/moving something
/// outside the app's own output directory.
enum FileSafety {
    struct UnsafePathError: Error, CustomStringConvertible {
        let path: String
        let outputDir: String
        var description: String {
            "Säkerhetsspärr: \"\(path)\" ligger utanför outputmappen \"\(outputDir)\" — vägrar radera/flytta/döpa om."
        }
    }

    /// Throws unless `url` is `outputDir` itself or a descendant of it.
    ///
    /// Compares `standardizedFileURL` paths — a purely lexical normalization
    /// (collapses "." and resolves ".." against the string, without touching
    /// the filesystem or resolving symlinks; verified empirically against
    /// non-existent paths). Symlink resolution is deliberately NOT used here:
    /// address folders are full of symlinks that legitimately point outside
    /// outputDir (to the user's original NEF cards) by design — this guard
    /// protects the *path being acted on* (the symlink itself, a real file,
    /// a directory to rename), never where a symlink at that path points.
    static func assertInsideOutput(_ url: URL, outputDir: URL) throws {
        let target = url.standardizedFileURL.path
        let root = outputDir.standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard target == root || target.hasPrefix(rootWithSlash) else {
            throw UnsafePathError(path: target, outputDir: root)
        }
    }

    /// True when `url` is a filesystem symlink (as opposed to a real file).
    /// Address folders should normally contain only symlinks (NEF/DNG/preview
    /// links created by `exportToAddressFolders`) plus a small set of real
    /// files the app writes itself (XMP sidecars, HDR TIFF/JPEG) — see
    /// `isCullManaged`.
    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// True when `url` is safe for a per-photo culling delete/move step
    /// (`deleteRejectedFiles`, `moveRejectedToFolder`) to act on purely because
    /// its basename matches a rejected photo's basename: either a symlink
    /// (NEF/DNG/preview — everything `exportToAddressFolders` normally creates)
    /// or an `.xmp` sidecar the app itself wrote next to a NEF symlink.
    ///
    /// Guards against the "same basename, different extension" trap: a real,
    /// non-symlink file with a matching basename that the user placed in an
    /// address folder by hand (e.g. an edited `DSC_0001.psd` dropped into
    /// "<adress> ÖVRIGA") is left alone even though the basename matches,
    /// because it is neither a symlink nor a sidecar the app owns.
    static func isCullManaged(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "xmp" || isSymlink(url)
    }
}
