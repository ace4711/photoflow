import Foundation
import Testing
@testable import PhotoFlow

/// "Skicka till mäklare" och "Hämta ändringar" mot en låtsasserver. Bilderna är riktiga JPEG-filer med
/// GPS/EXIF, och låtsasservern nekar (som den riktiga) varje webbvariant som har metadata.
struct ReelShareModelTests {

    struct Rig {
        var root: URL
        var reel: URL
        var source: URL
        var editor: ReelEditorModel
        var share: ReelShareModel
        var server: FakeObjektfilmServer
        var indexURL: URL
    }

    private func rig(images: Int = 8) throws -> Rig {
        let root = try ObjektfilmTestKit.tempDir()
        let source = root.appendingPathComponent("Testgatan 1 FÄRDIGA")
        let reel = AddressFolderLayout.reelDir(forSource: source)
        let items = try ObjektfilmTestKit.realItems(count: images, in: source, gps: true)
        let editor = ReelEditorModel()
        editor.prepare(items: items, sourceDirectory: source, reelDirectory: reel, address: "Testgatan 1", sessionID: "S1")
        let server = FakeObjektfilmServer()
        let share = ReelShareModel()
        share.clientOverride = { _ in server.client() }
        let indexURL = root.appendingPathComponent("index.json")
        share.indexURL = indexURL
        share.load(reelDirectory: reel)
        return Rig(root: root, reel: reel, source: source, editor: editor, share: share, server: server, indexURL: indexURL)
    }

    @Test("Första skickningen: bilder utan metadata, If-Match 0, länk, tillstånd på disk och status")
    func firstSend() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.share.badge == .draft && !r.share.isLinked)
        await r.share.send(from: r.editor, label: "Maja Mäklare", days: 30)
        #expect(r.share.phase == .done)

        // Alla 8 bilder i poolen, båda varianterna, ingen med metadata (servern hade nekat).
        #expect(r.server.variants.count == 16)
        #expect(r.server.variants.values.allSatisfy { !ReelWebVariant.hasMetadata($0) })
        #expect(r.server.pool.count == 8)
        #expect(r.server.ifMatches == ["\"0\""])
        let sources = (r.server.specJSON?["assets"] as? [[String: Any]])?.compactMap { ($0["sources"] as? [[String: Any]])?.first }
        #expect(sources?.allSatisfy { $0["kind"] as? String == "store" && ($0["key"] as? String)?.hasPrefix("img/") == true } == true)
        #expect(!String(describing: r.server.specJSON as Any).contains("FÄRDIGA"))

        let link = try #require(r.share.createdLink)
        #expect(link.url.hasSuffix("#TOKEN1"))
        let saved = try #require(ReelRemoteState.load(from: r.reel))
        #expect(saved.objectId == r.server.objectId && saved.lastSyncedRevision == 1 && saved.lastSyncedLocalRevision == 1)
        #expect(saved.sourceRelativePath == "../Testgatan 1 FÄRDIGA")
        #expect(saved.links.map(\.label) == ["Maja Mäklare"])
        #expect(!(try String(contentsOf: ReelRemoteState.url(in: r.reel), encoding: .utf8)).contains("TOKEN"))
        #expect(ReelRemoteIndex.directory(for: r.server.objectId, at: r.indexURL)?.standardizedFileURL == r.reel.standardizedFileURL)
        #expect(r.share.badge == .withAgent(revision: 1))
        #expect(r.editor.spec?.revision == 1)
        #expect(!r.share.hasUnsentChanges(r.editor))
    }

    @Test("Skickar man igen laddas inga bilder upp på nytt, och If-Match är senast synkade revision")
    func resendSkipsUploadedImages() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.send(from: r.editor, label: "", days: 30)
        let uploadsBefore = r.server.requests.filter { $0.hasPrefix("PUT /api/v1/assets/") }.count
        r.editor.moveClip(r.editor.clipRows[0].id, to: 2)
        #expect(r.share.hasUnsentChanges(r.editor))
        await r.share.send(from: r.editor, label: "", days: 30, newLink: false)
        #expect(r.share.phase == .done)
        #expect(r.server.requests.filter { $0.hasPrefix("PUT /api/v1/assets/") }.count == uploadsBefore)
        #expect(r.server.ifMatches == ["\"0\"", "\"1\""])
        #expect(r.share.createdLink == nil)
        #expect(r.server.links.count == 1)
        #expect(r.server.specRevisionAsKnown == 2)
        #expect(!r.share.hasUnsentChanges(r.editor))
    }

    @Test("Hämta ändringar: mäklarens ordning hamnar i lokala reel.json med local-källor")
    func pullAdoptsAgentOrder() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.send(from: r.editor, label: "", days: 30)
        let before = r.editor.spec!.timeline.map(\.asset)
        let reordered = Array(before.reversed())
        r.server.agentReorders(reordered)

        await r.share.pull(into: r.editor)
        #expect(r.share.phase == .idle)
        #expect(r.editor.spec?.timeline.map(\.asset) == reordered)
        #expect(r.editor.spec?.revision == 2)
        #expect(r.share.notice?.contains("rev 2") == true)
        #expect(r.share.state?.lastSyncedRevision == 2)
        #expect(r.share.badge == .withAgent(revision: 2))

        let onDisk = try ReelSpec.decode(from: try Data(contentsOf: r.reel.appendingPathComponent("reel.json")))
        #expect(onDisk.timeline.map(\.asset) == reordered)
        #expect(onDisk.assets.allSatisfy { $0.sources.count == 1 && $0.sources[0].kind == .local })
        for asset in onDisk.assets {
            let file = URL(fileURLWithPath: asset.sources[0].path!, relativeTo: r.reel).standardizedFileURL
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        // Inga nya ändringar andra gången.
        await r.share.pull(into: r.editor)
        #expect(r.share.notice == "Inga nya ändringar från mäklaren.")
    }

    @Test("Osynkade lokala ändringar: Hämta ändringar frågar först, och Ladda om ersätter dem")
    func pullWithUnsentChangesAsks() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.send(from: r.editor, label: "", days: 30)
        let ids = r.editor.spec!.timeline.map(\.asset)
        r.editor.removeClip(ids[0])
        r.server.agentReorders(Array(ids.reversed()))

        await r.share.pull(into: r.editor)
        let conflict = try #require(r.share.conflict)
        #expect(conflict.kind == .localUnsent && conflict.currentRevision == 2)
        #expect(r.editor.spec?.timeline.count == ids.count - 1)    // orört
        #expect(r.share.pendingRemoteRevision == 2)

        r.share.resolveConflictByReloading(into: r.editor)
        #expect(r.share.conflict == nil)
        #expect(r.editor.spec?.timeline.map(\.asset) == Array(ids.reversed()))
        #expect(r.share.pendingRemoteRevision == nil)
    }

    @Test("412 vid skickning: dialogen erbjuder att ladda om, och efter det går skickning igenom")
    func send412() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.send(from: r.editor, label: "", days: 30)
        let ids = r.editor.spec!.timeline.map(\.asset)
        r.server.agentReorders(Array(ids.reversed()))      // mäklaren ändrar...
        r.editor.removeClip(ids[0])                          // ...och fotografen ändrar utan att hämta
        await r.share.send(from: r.editor, label: "", days: 30, newLink: false)
        let conflict = try #require(r.share.conflict)
        #expect(conflict.kind == .remoteChanged && conflict.currentRevision == 2)
        #expect(r.share.phase == .idle)
        #expect(r.server.specRevisionAsKnown == 2)          // inget skrevs över

        r.share.resolveConflictByReloading(into: r.editor)
        #expect(r.editor.spec?.timeline.map(\.asset) == Array(ids.reversed()))
        r.editor.removeClip(ids[1])
        await r.share.send(from: r.editor, label: "", days: 30, newLink: false)
        #expect(r.share.phase == .done)
        #expect(r.server.ifMatches.last == "\"2\"")
        #expect(r.server.specRevisionAsKnown == 3)
    }

    @Test("Automatisk hämtning när fönstret öppnas: tar emot mäklarens ändringar tyst, en gång")
    func autoRefresh() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.send(from: r.editor, label: "", days: 30)
        let ids = r.editor.spec!.timeline.map(\.asset)
        r.server.agentReorders(Array(ids.reversed()))

        // Fönstret öppnas på nytt: tillståndet läses från disk.
        r.share.load(reelDirectory: r.reel)
        #expect(r.share.isLinked && r.share.state?.lastSyncedRevision == 1)
        await r.share.autoRefresh(into: r.editor)
        #expect(r.editor.spec?.timeline.map(\.asset) == Array(ids.reversed()))
        #expect(r.share.conflict == nil)
        let getsBefore = r.server.requests.filter { $0 == "GET /api/v1/objects/\(r.server.objectId)" }.count
        await r.share.autoRefresh(into: r.editor)
        #expect(r.server.requests.filter { $0 == "GET /api/v1/objects/\(r.server.objectId)" }.count == getsBefore)
    }

    @Test("En film som aldrig skickats hämtar ingenting automatiskt")
    func autoRefreshWithoutLink() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        await r.share.autoRefresh(into: r.editor)
        #expect(r.server.requests.isEmpty)
        #expect(r.share.badge == .draft)
    }

    @Test("Fel nyckel: felet visas med serverns text och inget sparas")
    func wrongKey() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let bad = ReelServerClient(baseURL: r.server.baseURL, key: "pf_fel", session: r.server.session(), maxRetries: 0)
        r.share.clientOverride = { _ in bad }
        await r.share.send(from: r.editor, label: "", days: 30)
        #expect(r.share.phase == .failed("Ogiltig nyckel."))
        #expect(ReelRemoteState.load(from: r.reel) == nil)
    }

    @Test("Statusmärket följer serverns status")
    func badges() {
        #expect(ReelShareModel.Badge.draft.label == "Utkast")
        #expect(ReelShareModel.Badge.withAgent(revision: 4).label == "Hos mäklaren (rev 4)")
        #expect(ReelShareModel.Badge.approvedWaiting.label == "Godkänd – väntar på rendering")
        #expect(ReelShareModel.Badge.rendered.label == "Renderad")
    }
}
