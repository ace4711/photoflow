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
    nonisolated static func assertInsideOutput(_ url: URL, outputDir: URL) throws {
        guard isInside(url, of: outputDir) else {
            throw UnsafePathError(path: url.standardizedFileURL.path, outputDir: outputDir.standardizedFileURL.path)
        }
    }

    /// Same lexical containment test as `assertInsideOutput`, as a boolean
    /// instead of a thrown error — used by `createLink`/`SessionVerifier.
    /// repairBrokenLinks` to decide relative vs. absolute link destinations,
    /// never to guard a destructive operation (use `assertInsideOutput` for
    /// that).
    nonisolated static func isInside(_ url: URL, of outputDir: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let root = outputDir.standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        return target == root || target.hasPrefix(rootWithSlash)
    }

    /// True when `url` is a filesystem symlink (as opposed to a real file).
    /// Address folders should normally contain only symlinks (NEF/DNG/preview
    /// links created by `exportToAddressFolders`) plus a small set of real
    /// files the app writes itself (XMP sidecars, HDR TIFF/JPEG) — see
    /// `isCullManaged`.
    nonisolated static func isSymlink(_ url: URL) -> Bool {
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
    nonisolated static func isCullManaged(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "xmp" || isSymlink(url)
    }

    // MARK: - Flyttningssäkra symlänkar

    /// Creates a symlink at `linkURL` pointing at `targetURL`, choosing a
    /// RELATIVE destination (e.g. `../dng/DSC_0001.dng`) when `targetURL`
    /// lies inside `outputDir`, and an ABSOLUTE one when it doesn't (the
    /// original NEF on the user's input folder/SD card — a relative path
    /// there would just be more fragile, not less, since the card isn't part
    /// of the tree being archived).
    ///
    /// This is what makes an output session safe to move/archive as a whole:
    /// `FileManager.createSymbolicLink` always writes absolute paths, so a
    /// session moved from e.g. `Desktop/OUTPUT` to `Desktop/lint/OUTPUT` used
    /// to leave every DNG/preview symlink pointing at the OLD absolute
    /// location — even though the real file was sitting right next to it in
    /// the very same (moved) tree. See FORBATTRINGAR.md, "Relativa symlänkar
    /// och länkreparation", for the real session this was found against, and
    /// `SessionVerifier.repairBrokenLinks` for fixing links written before
    /// this existed.
    ///
    /// Idempotent: if a symlink with the correct destination already exists
    /// at `linkURL`, this does nothing. If something else already occupies
    /// that path (a real file, or a symlink with a different destination),
    /// it is left untouched — creating a link is never destructive here; use
    /// `SessionVerifier.repairBrokenLinks` to rewrite an existing wrong one.
    nonisolated static func createLink(at linkURL: URL, to targetURL: URL, outputDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let destination = linkDestination(for: targetURL, from: linkURL, outputDir: outputDir)

        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
            // Already a (possibly broken) symlink here — only a no-op if it's
            // already exactly what we'd write; never silently replace a
            // different one (that's `repairBrokenLinks`'s job, deliberately
            // separate from "create a new link").
            guard existing != destination else { return }
            return
        }
        guard !fm.fileExists(atPath: linkURL.path) else { return } // a real file already occupies this path.

        try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)
    }

    /// The destination string `createLink` would write: relative when
    /// `targetURL` is inside `outputDir`, absolute otherwise. Exposed
    /// separately (not just folded into `createLink`) so `SessionVerifier.
    /// repairBrokenLinks` can compute the same relative form when rewriting
    /// an existing broken link.
    nonisolated static func linkDestination(for targetURL: URL, from linkURL: URL, outputDir: URL) -> String {
        guard isInside(targetURL, of: outputDir) else {
            return targetURL.standardizedFileURL.path
        }
        return relativePath(from: linkURL.deletingLastPathComponent(), to: targetURL)
    }

    /// Relative path from `baseDir` to `target`, in symlink-destination form
    /// (e.g. `../dng/x.dng`) — computed lexically from standardized path
    /// components (a symlink resolves relative to ITS OWN directory, not the
    /// process's working directory, so `baseDir` must be the link's parent,
    /// not the link itself).
    nonisolated static func relativePath(from baseDir: URL, to target: URL) -> String {
        let baseComponents = baseDir.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < baseComponents.count, shared < targetComponents.count,
              baseComponents[shared] == targetComponents[shared] {
            shared += 1
        }
        let upCount = baseComponents.count - shared
        let downComponents = targetComponents[shared...]
        return (Array(repeating: "..", count: upCount) + downComponents).joined(separator: "/")
    }
}
