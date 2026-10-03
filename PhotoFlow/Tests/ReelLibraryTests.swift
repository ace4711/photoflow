import Foundation
import Testing
import AVFoundation
@testable import PhotoFlow

/// Filmindexet (`ReelLibrary`), miniatyrer, statusmappningen från serversvar och spelarens val av källa.
/// Videorna är små syntetiska MP4:or som renderas med `ReelRenderer.export`.
struct ReelLibraryTests {

    // MARK: Hjälp

    /// Renderar en liten MP4 (två bilder) i given storlek.
    @discardableResult
    private func makeVideo(at url: URL, width: Int, height: Int, workDir: URL) async throws -> ReelSpec {
        let items = try ObjektfilmTestKit.realItems(count: 2, in: workDir.appendingPathComponent("bilder-\(UUID().uuidString)"))
        var options = ReelComposer.Options()
        options.count = 3
        var spec = ReelComposer.compose(items: items, specDirectory: workDir, options: options).spec
        spec.timeline = spec.timeline.map { var clip = $0; clip.duration = 0.8; return clip }
        spec.outputs = [.init(id: "t", aspect: ReelLibrary.formatLabel(width: width, height: height),
                              width: width, height: height, fps: 10, encoding: nil)]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ReelRenderer.export(spec: spec, specDirectory: workDir, output: spec.outputs[0], to: url)
        return spec
    }

    private func session() throws -> URL { try ObjektfilmTestKit.tempDir("Filmer") }

    private func setDate(_ date: Date, _ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    }

    private func writeSpec(_ spec: ReelSpec, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try spec.jsonData().write(to: dir.appendingPathComponent("reel.json"))
    }

    // MARK: Filmindex

    @Test("Hittar filmer i FILM-mappar med format, upplösning och längd; ignorerar andra mappar")
    func findsFilms() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let film = root.appendingPathComponent("Lindvägen 12 FILM")
        try await makeVideo(at: film.appendingPathComponent("reel_9x16.mp4"), width: 180, height: 320, workDir: root)
        try await makeVideo(at: film.appendingPathComponent("reel_1x1.mp4"), width: 240, height: 240, workDir: root)
        try await makeVideo(at: root.appendingPathComponent("Storgatan 3 FILM/reel_16x9.mp4"), width: 320, height: 180, workDir: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Lindvägen 12 FÄRDIGA"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("hdr"), withIntermediateDirectories: true)

        let folders = await ReelLibrary.scan(outputDirectory: root)
        #expect(Set(folders.map(\.address)) == ["Lindvägen 12", "Storgatan 3"])
        let all = ReelLibrary.allFilms(folders)
        #expect(all.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.url.lastPathComponent, $0) })
        let vertical = try #require(byName["reel_9x16.mp4"])
        #expect(vertical.formatLabel == "9:16" && vertical.width == 180 && vertical.height == 320)
        #expect(vertical.duration > 0.5 && vertical.duration < 3)
        #expect(byName["reel_1x1.mp4"]?.formatLabel == "1:1")
        #expect(byName["reel_16x9.mp4"]?.formatLabel == "16:9")
        #expect(vertical.fileSize > 0)
        #expect(await ReelLibrary.countFilms(in: root) == 3)
    }

    @Test("Hittar även en mapp utan FILM-suffix om den har reel.json, och en FILM-mapp utan MP4")
    func findsOtherFoldersWithSpec() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try ObjektfilmTestKit.realItems(count: 2, in: root.appendingPathComponent("b"))
        let spec = ReelComposer.compose(items: items, specDirectory: root, options: .init()).spec
        try writeSpec(spec, to: root.appendingPathComponent("Egen film"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tom FILM"), withIntermediateDirectories: true)

        let folders = await ReelLibrary.scan(outputDirectory: root)
        #expect(Set(folders.map(\.directory.lastPathComponent)) == ["Egen film", "Tom FILM"])
        #expect(folders.allSatisfy { $0.films.isEmpty })
        #expect(folders.first { $0.directory.lastPathComponent == "Tom FILM" }?.address == "Tom")
        #expect(folders.first { $0.directory.lastPathComponent == "Egen film" }?.address == (spec.property.address.isEmpty ? "Egen film" : spec.property.address))
    }

    @Test("Kopplar reel.json (klipp, revision) och reel-remote.json (objekt, synkad revision, länkar)")
    func linksSpecAndRemote() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Lindvägen 12 FILM")
        var spec = try await makeVideo(at: dir.appendingPathComponent("reel_9x16.mp4"), width: 180, height: 320, workDir: root)
        spec.revision = 4
        spec.property.address = "Lindvägen 12"
        try writeSpec(spec, to: dir)
        let link = ReelRemoteState.Link(linkId: "l1", label: "Anna", createdAt: "2026-10-01T10:00:00Z", expiresAt: "2026-10-31T10:00:00Z")
        try ReelRemoteState(server: "https://film.example", objectId: "obj-1", reelId: spec.id, lastSyncedRevision: 3,
                            lastKnownStatus: "proposed", links: [link]).save(to: dir)

        let folder = try #require(await ReelLibrary.scan(outputDirectory: root).first)
        #expect(folder.clipCount == spec.timeline.count && folder.revision == 4)
        #expect(folder.specDuration == ReelTimeline.totalDuration(spec))
        #expect(folder.remote?.objectId == "obj-1" && folder.remote?.lastSyncedRevision == 3)
        #expect(folder.remote?.links == [link])
        #expect(folder.films.count == 1)
    }

    @Test("Sorterar nyast först: mapparna och filmerna i dem")
    func sortsNewestFirst() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Gammal FILM")
        let new = root.appendingPathComponent("Ny FILM")
        try await makeVideo(at: old.appendingPathComponent("reel_9x16.mp4"), width: 180, height: 320, workDir: root)
        try await makeVideo(at: new.appendingPathComponent("reel_9x16.mp4"), width: 180, height: 320, workDir: root)
        try await makeVideo(at: new.appendingPathComponent("reel_1x1.mp4"), width: 240, height: 240, workDir: root)
        try setDate(Date(timeIntervalSince1970: 1_000_000), old.appendingPathComponent("reel_9x16.mp4"))
        try setDate(Date(timeIntervalSince1970: 2_000_000), new.appendingPathComponent("reel_9x16.mp4"))
        try setDate(Date(timeIntervalSince1970: 3_000_000), new.appendingPathComponent("reel_1x1.mp4"))

        let folders = await ReelLibrary.scan(outputDirectory: root)
        #expect(folders.map(\.address) == ["Ny", "Gammal"])
        #expect(folders[0].films.map { $0.url.lastPathComponent } == ["reel_1x1.mp4", "reel_9x16.mp4"])
        #expect(ReelLibrary.allFilms(folders).map { $0.url.lastPathComponent } == ["reel_1x1.mp4", "reel_9x16.mp4", "reel_9x16.mp4"])
    }

    @Test("Tomt läge: ingen FILM-mapp, tom mapp och en fil som inte är en video")
    func emptyAndBroken() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await ReelLibrary.scan(outputDirectory: root).isEmpty)
        #expect(await ReelLibrary.countFilms(in: root) == 0)
        #expect(await ReelLibrary.scan(outputDirectory: root.appendingPathComponent("finns-inte")).isEmpty)

        let dir = root.appendingPathComponent("Trasig FILM")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("inte en video".utf8).write(to: dir.appendingPathComponent("reel_9x16.mp4"))
        let folders = await ReelLibrary.scan(outputDirectory: root)
        #expect(folders.count == 1 && folders[0].films.isEmpty)
    }

    @Test("Formatetiketter och längdtext")
    func labels() {
        #expect(ReelLibrary.formatLabel(width: 1080, height: 1920) == "9:16")
        #expect(ReelLibrary.formatLabel(width: 1080, height: 1080) == "1:1")
        #expect(ReelLibrary.formatLabel(width: 1920, height: 1080) == "16:9")
        #expect(ReelLibrary.formatLabel(width: 1000, height: 700) == "1000×700")
        #expect(ReelLibrary.durationText(42) == "0:42" && ReelLibrary.durationText(65) == "1:05")
    }

    @Test("Källmappen: reel-remote.json:s sökväg först, annars <adress> FÄRDIGA bredvid")
    func sourceDirectory() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let film = root.appendingPathComponent("Lindvägen 12 FILM")
        try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
        var folder = ReelFilmFolder(directory: film, address: "Lindvägen 12", clipCount: nil, revision: nil,
                                    specDuration: nil, remote: nil, films: [], updatedAt: .distantPast)
        #expect(folder.sourceDirectory() == nil)
        let finished = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        #expect(folder.sourceDirectory()?.standardizedFileURL.path == finished.standardizedFileURL.path)

        let other = root.appendingPathComponent("Annan källa")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        folder.remote = ReelRemoteState(server: "s", objectId: "o", reelId: "r", sourceRelativePath: "../Annan källa")
        #expect(folder.sourceDirectory()?.standardizedFileURL.path == other.standardizedFileURL.path)

        let request = ReelLaunchRequest.forFilmFolder(folder, outputDirectory: root, showShare: true)
        #expect(request.sourcePath == folder.sourceDirectory()?.path && request.showShare == true)
        #expect(request.outputPath == root.path && request.address == "Lindvägen 12")
    }

    // MARK: Miniatyr

    @Test("Miniatyrgenerering ger en bild i filmens proportioner (och cachar)")
    func thumbnail() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reel_9x16.mp4")
        try await makeVideo(at: url, width: 180, height: 320, workDir: root)
        let image = try #require(await ReelThumbnailer.thumbnail(for: url, maxSize: 160))
        #expect(image.height == 160 && image.width == 90)
        #expect(await ReelThumbnailer.thumbnail(for: url, maxSize: 160) != nil)
        #expect(await ReelThumbnailer.thumbnail(for: root.appendingPathComponent("saknas.mp4")) == nil)
    }

    // MARK: Serverstatus

    private nonisolated func detailJSON(status: String = "proposed", revision: Int = 2, renders: [[String: Any]] = [],
                            links: [[String: Any]] = []) -> [String: Any] {
        ["objectId": "obj-1", "reelId": "r", "address": "Lindvägen 12", "status": status, "currentRevision": revision,
         "approvedRevision": NSNull(), "links": links, "renders": renders]
    }

    private func service(host: String = "film-\(UUID().uuidString.prefix(8)).test", ttl: TimeInterval = 30,
                         handler: @escaping MockURLProtocol.Handler) -> ReelStatusService {
        MockURLProtocol.register(host: host, handler: handler)
        let baseURL = URL(string: "http://\(host)")!
        let client = ReelServerClient(baseURL: baseURL, key: "pf_abc", session: MockURLProtocol.session(),
                                      maxRetries: 0, backoff: { _ in .zero })
        return ReelStatusService(ttl: ttl) { id in ReelRemoteInfo(try await client.object(id), baseURL: baseURL) }
    }

    @Test("Statusmärket följer serverns status")
    func badges() {
        #expect(ReelFilmBadge(status: "draft", revision: 1).label == "Utkast")
        #expect(ReelFilmBadge(status: "proposed", revision: 3).label == "Hos mäklaren (rev 3)")
        #expect(ReelFilmBadge(status: "approved", revision: 3).label == "Godkänd – väntar på rendering")
        #expect(ReelFilmBadge(status: "rendered", revision: 3).label == "Renderad")
        #expect(ReelFilmBadge(status: nil, revision: 0) == .draft)
    }

    @Test("Serversvaret blir status, renderingar med absolut URL och länkar utan token")
    func mapsServerReply() async throws {
        nonisolated(unsafe) let reply = detailJSON(
            status: "rendered", revision: 5,
            renders: [["renderId": "rd1", "revision": 5, "outputId": "vertical", "current": true, "width": 1080, "height": 1920,
                       "duration": 21.5, "bytes": 1000, "url": "/media/123/sig/render/rd1"],
                      ["renderId": "rd0", "revision": 4, "outputId": "vertical", "current": false, "url": "/media/1/s/render/rd0"]],
            links: [["linkId": "l1", "label": "Anna", "createdAt": "2026-10-01T10:00:00.000Z",
                     "expiresAt": "2026-10-31T10:00:00.000Z", "revokedAt": NSNull(), "lastUsedAt": NSNull()],
                    ["linkId": "l2", "label": "Bo", "createdAt": "2026-09-01T10:00:00Z",
                     "expiresAt": "2026-09-30T10:00:00Z", "revokedAt": "2026-09-05T10:00:00Z"]])
        let host = "film-\(UUID().uuidString.prefix(8)).test"
        let svc = service(host: host) { req, _ in
            #expect(req.url?.path == "/api/v1/objects/obj-1")
            return .json(reply)
        }
        let info = try #require(await svc.lookup("obj-1").info)
        #expect(info.badge == .rendered && info.currentRevision == 5)
        #expect(info.renders.count == 2)
        let current = try #require(info.playableRender())
        #expect(current.renderId == "rd1" && current.formatLabel == "9:16")
        #expect(current.url?.absoluteString == "http://\(host)/media/123/sig/render/rd1")
        #expect(info.links.map(\.label) == ["Anna", "Bo"])
        #expect(info.links[1].revokedAt != nil && info.links[0].revokedAt == nil)
        // Token finns inte i svaret och inte i modellen.
        #expect(!String(describing: info).contains("token"))
    }

    @Test("Länktext: skickad, giltig till, återkallad och utgången")
    func linkSummary() {
        let created = ReelLinkInfo.parse("2026-10-01T10:00:00Z")
        let expires = ReelLinkInfo.parse("2026-10-31T10:00:00Z")
        let active = ReelLinkInfo(linkId: "a", label: "Anna", createdAt: created, expiresAt: expires, revokedAt: nil)
        let now = ReelLinkInfo.parse("2026-10-10T10:00:00Z")!
        let text = active.summary(now: now)
        #expect(text.hasPrefix("Länk skickad") && text.contains("till Anna") && text.contains(", giltig till"))
        #expect(active.summary(now: ReelLinkInfo.parse("2026-11-10T10:00:00Z")!).contains("gick ut"))
        var revoked = active
        revoked.revokedAt = created
        #expect(revoked.summary(now: now).hasSuffix("återkallad"))
        #expect(ReelLinkInfo(linkId: "b", label: nil, createdAt: nil, expiresAt: nil, revokedAt: nil).summary() == "Länk skickad till mäklare")
    }

    @Test("Lokala länkar slås ihop med serverns; servern vet om återkallning")
    func mergesLinks() {
        let local = [ReelRemoteState.Link(linkId: "l1", label: "Anna", createdAt: "2026-10-01T10:00:00Z", expiresAt: "2026-10-31T10:00:00Z"),
                     ReelRemoteState.Link(linkId: "l2", label: "Bo", createdAt: "2026-10-02T10:00:00Z", expiresAt: nil)]
        let revokedAt = ReelLinkInfo.parse("2026-10-03T10:00:00Z")
        let remote = [ReelLinkInfo(linkId: "l1", label: "Anna", createdAt: ReelLinkInfo.parse("2026-10-01T10:00:00Z"),
                                   expiresAt: ReelLinkInfo.parse("2026-10-31T10:00:00Z"), revokedAt: revokedAt)]
        let merged = mergedLinks(local: local, remote: remote)
        #expect(merged.map(\.linkId) == ["l2", "l1"])
        #expect(merged[1].revokedAt == revokedAt)
        #expect(mergedLinks(local: local, remote: nil).allSatisfy { $0.revokedAt == nil })
    }

    @Test("Cachen gäller kort: ett andra anrop går inte till servern, force gör det")
    func cachesBriefly() async {
        let counter = ReelServerClientTests.Counter()
        let svc = service { _, _ in counter.next(); return .json(detailJSON()) }
        _ = await svc.lookup("obj-1")
        _ = await svc.lookup("obj-1")
        #expect(counter.value == 1)
        _ = await svc.lookup("obj-1", force: true)
        #expect(counter.value == 2)
    }

    @Test("Servern svarar inte ger unreachable, 404 ger gone")
    func failures() async {
        let down = service { _, _ in .init(error: URLError(.notConnectedToInternet)) }
        #expect(await down.lookup("obj-1") == .unreachable)
        let gone = service { _, _ in .json(["error": ["code": "not_found", "message": "Finns inte."]], status: 404) }
        #expect(await gone.lookup("obj-1") == .gone)
        let broken = service { _, _ in .json(["error": ["code": "oops", "message": "Fel."]], status: 500) }
        #expect(await broken.lookup("obj-1") == .unreachable)
    }

    // MARK: Listmodellen

    private func folderWithRemote(in root: URL, status: String?) throws {
        let dir = root.appendingPathComponent("Lindvägen 12 FILM")
        let items = try ObjektfilmTestKit.realItems(count: 2, in: root.appendingPathComponent("b"))
        try writeSpec(ReelComposer.compose(items: items, specDirectory: root, options: .init()).spec, to: dir)
        try ReelRemoteState(server: "s", objectId: "obj-1", reelId: "r", lastSyncedRevision: 2, lastKnownStatus: status,
                            links: [.init(linkId: "l1", label: "Anna", createdAt: "2026-10-01T10:00:00Z", expiresAt: nil)])
            .save(to: dir)
    }

    @Test("Listmodellen visar serverns märke, och lokalt läge med förklaring när servern inte svarar")
    func listModelStatus() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        try folderWithRemote(in: root, status: "proposed")

        let model = ReelFilmListModel()
        model.serviceFactory = { self.service { _, _ in .json(self.detailJSON(status: "approved", revision: 2)) } }
        await model.load(outputDirectory: root)
        let folder = try #require(model.folders.first)
        #expect(model.badge(for: folder) == .approvedWaiting)
        #expect(model.statusNote(for: folder) == nil)
        #expect(model.links(for: folder).map(\.label) == ["Anna"])

        let offline = ReelFilmListModel()
        offline.serviceFactory = { self.service { _, _ in .init(error: URLError(.timedOut)) } }
        await offline.load(outputDirectory: root)
        let offlineFolder = try #require(offline.folders.first)
        #expect(offline.badge(for: offlineFolder) == .withAgent(revision: 2))
        #expect(offline.statusNote(for: offlineFolder) == "Servern svarar inte. Visar senast kända läge.")

        let unconfigured = ReelFilmListModel()
        unconfigured.serviceFactory = { nil }
        await unconfigured.load(outputDirectory: root)
        #expect(unconfigured.badge(for: try #require(unconfigured.folders.first)) == .withAgent(revision: 2))
        #expect(unconfigured.statusNote(for: try #require(unconfigured.folders.first)) == nil)
    }

    @Test("Renderingar som bara finns på servern listas; tomt läge märks")
    func listModelServerOnly() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = ReelFilmListModel()
        empty.serviceFactory = { nil }
        await empty.load(outputDirectory: root)
        #expect(empty.isEmpty && empty.films.isEmpty)

        try folderWithRemote(in: root, status: "rendered")
        let model = ReelFilmListModel()
        model.serviceFactory = {
            self.service { _, _ in
                .json(self.detailJSON(status: "rendered", renders: [
                    ["renderId": "rd1", "revision": 2, "outputId": "vertical", "current": true, "width": 1080, "height": 1920, "url": "/media/1/s/render/rd1"],
                    ["renderId": "rd0", "revision": 1, "outputId": "vertical", "current": false, "width": 1080, "height": 1920, "url": "/media/1/s/render/rd0"]]))
            }
        }
        await model.load(outputDirectory: root)
        #expect(!model.isEmpty)
        let folder = try #require(model.folders.first)
        #expect(model.serverOnlyRenders(for: folder).map(\.renderId) == ["rd1"])
    }

    // MARK: Spelaren

    @Test("Spelaren väljer lokal fil först, annars en ny signerad serverlänk, annars ett begripligt fel")
    func playerSource() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reel_9x16.mp4")
        try Data().write(to: file)
        nonisolated(unsafe) let reply = detailJSON(status: "rendered", renders: [
            ["renderId": "rd1", "revision": 2, "outputId": "vertical", "current": true, "url": "/media/1/s/render/rd1"]])
        let host = "film-\(UUID().uuidString.prefix(8)).test"
        let counter = ReelServerClientTests.Counter()
        let svc = service(host: host) { _, _ in counter.next(); return .json(reply) }
        let base = ReelPlayerRequest(filePath: file.path, objectId: "obj-1", renderId: "rd1", title: "t", width: 1080, height: 1920)

        let local = ReelPlayerModel()
        local.serviceFactory = { svc }
        await local.load(base)
        #expect(local.state == .ready(.local(file)) && counter.value == 0)

        var missing = base
        missing.filePath = root.appendingPathComponent("saknas.mp4").path
        let remote = ReelPlayerModel()
        remote.serviceFactory = { svc }
        await remote.load(missing)
        #expect(remote.state == .ready(.remote(URL(string: "http://\(host)/media/1/s/render/rd1")!)))

        let noServer = ReelPlayerModel()
        noServer.serviceFactory = { nil }
        await noServer.load(missing)
        guard case .failed = noServer.state else { Issue.record("förväntade fel"); return }

        var noObject = missing
        noObject.objectId = nil
        let none = ReelPlayerModel()
        await none.load(noObject)
        #expect(none.state == .failed("Filmfilen finns inte längre på disk."))

        let down = ReelPlayerModel()
        down.serviceFactory = { self.service { _, _ in .init(error: URLError(.notConnectedToInternet)) } }
        await down.load(missing)
        #expect(down.state == .failed("Servern svarar inte, och filmfilen saknas lokalt."))
    }

    @Test("Spelarfönstrets proportioner följer filmen")
    func playerAspect() {
        #expect(ReelPlayerRequest(filePath: nil, title: "", width: 1080, height: 1920).aspectRatio == 9.0 / 16)
        #expect(ReelPlayerRequest(filePath: nil, title: "", width: 0, height: 0).aspectRatio == 16.0 / 9)
    }
}
