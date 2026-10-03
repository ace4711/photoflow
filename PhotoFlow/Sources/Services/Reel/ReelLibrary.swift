import Foundation
import AVFoundation
import CoreGraphics

/// En renderad film (en MP4) i en FILM-mapp.
nonisolated struct ReelFilm: Sendable, Equatable, Identifiable {
    var url: URL
    var width: Int
    var height: Int
    var duration: Double
    var createdAt: Date
    var modifiedAt: Date
    var fileSize: Int64

    var id: String { url.path }

    /// "9:16", "1:1" eller "16:9" när proportionerna ligger nära, annars "bredd×höjd".
    var formatLabel: String { ReelLibrary.formatLabel(width: width, height: height) }
}

/// En FILM-mapp (`<adress> FILM`, eller annan mapp med `reel.json`) med det som hör till den.
nonisolated struct ReelFilmFolder: Sendable, Equatable, Identifiable {
    var directory: URL
    var address: String
    /// Antal klipp i `reel.json` (nil om filen saknas eller inte går att läsa).
    var clipCount: Int?
    /// `reel.json`s lokala revision.
    var revision: Int?
    /// Filmens beräknade längd enligt `reel.json`.
    var specDuration: Double?
    var remote: ReelRemoteState?
    /// Nyast först.
    var films: [ReelFilm]
    /// Senaste aktivitet i mappen (nyaste film, annars `reel.json`s ändringstid).
    var updatedAt: Date

    var id: String { directory.path }

    /// Mappen med de färdiga bilderna: den som `reel-remote.json` pekar på, annars
    /// `<adress> FÄRDIGA` bredvid FILM-mappen. Nil om ingen av dem finns kvar.
    func sourceDirectory() -> URL? {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if let source = remote?.sourceDirectory(relativeTo: directory), exists(source) { return source }
        let parent = directory.deletingLastPathComponent()
        let folderName = directory.lastPathComponent
        var bases: [String] = []
        if !address.isEmpty { bases.append(address) }
        if folderName.hasSuffix(AddressFolderLayout.reelSuffix), folderName.count > AddressFolderLayout.reelSuffix.count {
            bases.append(String(folderName.dropLast(AddressFolderLayout.reelSuffix.count)))
        }
        for base in bases {
            let finished = AddressFolderLayout.finishedDir(in: parent, folderName: base)
            if exists(finished) { return finished }
        }
        return nil
    }
}

/// Filmindex för en session: hittar alla filmer i sessionens outputmapp. Ren logik utan UI; allt
/// diskarbete och AVFoundation körs utanför huvudtråden (`@concurrent`).
nonisolated enum ReelLibrary {

    static let specFileName = "reel.json"

    /// FILM-mappar: `<adress> FILM` och andra mappar direkt under outputmappen som har en `reel.json`.
    static func filmFolderURLs(in outputDirectory: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: outputDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
            if url.lastPathComponent.hasSuffix(AddressFolderLayout.reelSuffix) { return true }
            return fm.fileExists(atPath: url.appendingPathComponent(ReelLibrary.specFileName).path)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// MP4-filerna i en FILM-mapp (inte de dolda temporärfilerna som renderingen skriver).
    static func videoURLs(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Billigt antal filmer (bara kataloglistning, ingen AVFoundation), för "Filmer (n)" i historiken.
    @concurrent
    static func countFilms(in outputDirectory: URL) async -> Int {
        filmFolderURLs(in: outputDirectory).reduce(0) { $0 + videoURLs(in: $1).count }
    }

    /// Alla FILM-mappar med filmer och koppling till `reel.json`/`reel-remote.json`. Nyast först.
    @concurrent
    static func scan(outputDirectory: URL) async -> [ReelFilmFolder] {
        var folders: [ReelFilmFolder] = []
        for dir in filmFolderURLs(in: outputDirectory) {
            if Task.isCancelled { break }
            folders.append(await folder(at: dir))
        }
        return sorted(folders)
    }

    static func sorted(_ folders: [ReelFilmFolder]) -> [ReelFilmFolder] {
        folders.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.directory.lastPathComponent.localizedStandardCompare($1.directory.lastPathComponent) == .orderedAscending
        }
    }

    /// Alla filmer i alla mappar, nyast först.
    static func allFilms(_ folders: [ReelFilmFolder]) -> [ReelFilm] {
        folders.flatMap(\.films).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @concurrent
    static func folder(at dir: URL) async -> ReelFilmFolder {
        let specData = try? Data(contentsOf: dir.appendingPathComponent(ReelLibrary.specFileName))
        let spec = specData.flatMap { try? ReelSpec.decode(from: $0) }
        let remote = ReelRemoteState.load(from: dir)
        var films: [ReelFilm] = []
        for url in videoURLs(in: dir) {
            if let film = await film(at: url) { films.append(film) }
        }
        films.sort { $0.modifiedAt > $1.modifiedAt }

        let name = dir.lastPathComponent
        var address = spec?.property.address ?? ""
        if address.isEmpty {
            address = name.hasSuffix(AddressFolderLayout.reelSuffix) && name.count > AddressFolderLayout.reelSuffix.count
                ? String(name.dropLast(AddressFolderLayout.reelSuffix.count)) : name
        }
        let specModified = (try? dir.appendingPathComponent(ReelLibrary.specFileName)
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let dirModified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ReelFilmFolder(
            directory: dir, address: address,
            clipCount: spec?.timeline.count, revision: spec?.revision,
            specDuration: spec.map(ReelTimeline.totalDuration),
            remote: remote, films: films,
            updatedAt: films.first?.modifiedAt ?? specModified ?? dirModified ?? .distantPast)
    }

    /// Längd, upplösning och datum för en MP4 (nil om filen inte går att läsa som video).
    @concurrent
    static func film(at url: URL) async -> ReelFilm? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let size = natural.applying(transform)
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        return ReelFilm(
            url: url, width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()),
            duration: duration, createdAt: values?.creationDate ?? modified, modifiedAt: modified,
            fileSize: Int64(values?.fileSize ?? 0))
    }

    static func formatLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "okänt format" }
        let ratio = Double(width) / Double(height)
        for (label, value) in [("9:16", 9.0 / 16), ("1:1", 1.0), ("16:9", 16.0 / 9), ("4:5", 0.8)]
        where abs(ratio - value) / value < 0.03 { return label }
        return "\(width)×\(height)"
    }

    /// "0:42" eller "1:05".
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Miniatyrer

/// En bildruta ur en MP4 som miniatyr, cachad per fil och ändringstid.
nonisolated enum ReelThumbnailer {

    private final class Cache: @unchecked Sendable {
        let storage = NSCache<NSString, CGImage>()
    }
    private static let cache = Cache()

    /// Bildrutan vid 1 s (eller mitt i en kortare film), högst `maxSize` pixlar på långsidan.
    @concurrent
    static func thumbnail(for url: URL, maxSize: CGFloat = 320) async -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(Int(maxSize))" as NSString
        if let hit = cache.storage.object(forKey: key) { return hit }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        cache.storage.setObject(image, forKey: key)
        return image
    }
}
