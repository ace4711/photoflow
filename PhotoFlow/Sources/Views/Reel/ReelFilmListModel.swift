import Foundation
import Observation

enum ReelFilmsWindow {
    static let id = "reel-films"
}

enum ReelPlayerWindow {
    static let id = "reel-player"
}

/// Vad som öppnar filmlistan: sessionens outputmapp.
struct ReelFilmsRequest: Codable, Hashable {
    var outputPath: String
}

/// Vad som öppnar spelaren. Bara värden (identitet för fönstret); den signerade serverlänken hämtas
/// först när spelaren öppnas, eftersom den bara gäller en timme.
struct ReelPlayerRequest: Codable, Hashable {
    /// Lokala MP4:n (om den finns).
    var filePath: String?
    /// Serverns objekt och rendering, för att spela utan lokal kopia.
    var objectId: String?
    var renderId: String?
    var title: String
    var width: Int
    var height: Int
    /// FILM-mappen och sessionens outputmapp, för "Öppna i Bildspel".
    var folderPath: String?
    var outputPath: String?

    init(filePath: String?, objectId: String? = nil, renderId: String? = nil, title: String, width: Int, height: Int,
         folderPath: String? = nil, outputPath: String? = nil) {
        self.filePath = filePath
        self.objectId = objectId
        self.renderId = renderId
        self.title = title
        self.width = width
        self.height = height
        self.folderPath = folderPath
        self.outputPath = outputPath
    }

    var aspectRatio: Double { width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9 }

    static func local(film: ReelFilm, in folder: ReelFilmFolder, outputDirectory: URL?) -> ReelPlayerRequest {
        ReelPlayerRequest(filePath: film.url.path, objectId: folder.remote?.objectId, renderId: nil,
                          title: "\(folder.address) · \(film.formatLabel)", width: film.width, height: film.height,
                          folderPath: folder.directory.path, outputPath: outputDirectory?.path)
    }

    static func remote(render: ReelRemoteRender, in folder: ReelFilmFolder, outputDirectory: URL?) -> ReelPlayerRequest {
        ReelPlayerRequest(filePath: nil, objectId: folder.remote?.objectId, renderId: render.renderId,
                          title: "\(folder.address) · \(render.formatLabel ?? render.outputId)",
                          width: render.width ?? 0, height: render.height ?? 0,
                          folderPath: folder.directory.path, outputPath: outputDirectory?.path)
    }
}

extension ReelLaunchRequest {
    /// Bildspelsfönstret för en FILM-mapp: källmappen (färdiga bilder) om den finns, annars mappväljaren
    /// i outputmappen. `showShare` öppnar "Skicka till mäklare" så fort filmen är laddad.
    static func forFilmFolder(_ folder: ReelFilmFolder, outputDirectory: URL?, showShare: Bool = false) -> ReelLaunchRequest {
        let output = outputDirectory ?? folder.directory.deletingLastPathComponent()
        var request = ReelLaunchRequest(startPath: output.path, outputPath: output.path, address: folder.address)
        request.sourcePath = folder.sourceDirectory()?.path
        request.showShare = showShare ? true : nil
        return request
    }
}

/// Vymodellen för filmlistan: skannar sessionens outputmapp och lägger serverns status ovanpå.
/// Skanningen och nätverket körs utanför huvudtråden (se `ReelLibrary`, `ReelStatusService`).
@Observable
final class ReelFilmListModel {

    private(set) var outputDirectory: URL?
    private(set) var folders: [ReelFilmFolder] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Serverns svar per FILM-mapp (bara mappar med `reel-remote.json` frågas).
    private(set) var remote: [String: ReelRemoteLookup] = [:]

    /// Byts i tester.
    @ObservationIgnored var serviceFactory: () -> ReelStatusService? = { ReelStatusService.live() }
    @ObservationIgnored var now: () -> Date = { Date() }

    var films: [ReelFilm] { ReelLibrary.allFilms(folders) }
    var isEmpty: Bool { hasLoaded && folders.isEmpty }

    func load(outputDirectory: URL, force: Bool = false) async {
        self.outputDirectory = outputDirectory
        isLoading = true
        let scanned = await ReelLibrary.scan(outputDirectory: outputDirectory)
        folders = scanned
        hasLoaded = true
        isLoading = false
        await refreshRemote(force: force)
    }

    /// Frågar servern om varje kopplad film (parallellt), och uppdaterar listan allt eftersom.
    func refreshRemote(force: Bool = false) async {
        guard let service = serviceFactory() else { remote = [:]; return }
        let targets = folders.compactMap { folder in folder.remote.map { (folder.id, $0.objectId) } }
        await withTaskGroup(of: (String, ReelRemoteLookup).self) { group in
            for (folderID, objectId) in targets {
                group.addTask { (folderID, await service.lookup(objectId, force: force)) }
            }
            for await (folderID, lookup) in group { remote[folderID] = lookup }
        }
    }

    // MARK: Härlett per mapp

    func lookup(_ folder: ReelFilmFolder) -> ReelRemoteLookup? { remote[folder.id] }

    /// Serverns märke när det finns, annars det senast kända lokalt (nil när filmen aldrig skickats).
    func badge(for folder: ReelFilmFolder) -> ReelFilmBadge? {
        guard let state = folder.remote else { return nil }
        if let info = remote[folder.id]?.info { return info.badge }
        return ReelFilmBadge(status: state.lastKnownStatus, revision: state.lastSyncedRevision)
    }

    /// Kort förklaring när serverstatusen inte kunde hämtas.
    func statusNote(for folder: ReelFilmFolder) -> String? {
        switch remote[folder.id] {
        case .unreachable: return "Servern svarar inte. Visar senast kända läge."
        case .gone: return "Filmen finns inte längre på servern."
        default: return nil
        }
    }

    func links(for folder: ReelFilmFolder) -> [ReelLinkInfo] {
        guard let state = folder.remote else { return [] }
        return mergedLinks(local: state.links, remote: remote[folder.id]?.info?.links)
    }

    /// Renderingar som bara finns på servern (ingen lokal MP4 i samma format) och går att spela.
    func serverOnlyRenders(for folder: ReelFilmFolder) -> [ReelRemoteRender] {
        guard let info = remote[folder.id]?.info else { return [] }
        let local = Set(folder.films.map(\.formatLabel))
        return info.renders.filter { render in
            guard render.current, render.url != nil else { return false }
            if let label = render.formatLabel { return !local.contains(label) }
            return folder.films.isEmpty
        }
    }
}
