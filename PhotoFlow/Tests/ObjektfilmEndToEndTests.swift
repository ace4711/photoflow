import Foundation
import Testing
@testable import PhotoFlow

/// Hela kedjan mot en riktig Objektfilm-server (lokalt, `server/`), i tre steg som körs efter varandra med
/// mäklarens ändringar (curl) emellan. Hoppas över om inte `OBJEKTFILM_E2E_DIR` och `OBJEKTFILM_E2E_PHASE`
/// är satta (`xcodebuild test` med `TEST_RUNNER_`-prefix). Arbetsmappen innehåller `config.json`
/// (`baseURL`, `photographerKey`, `renderKey`), kopian av `in/` och `reel-out-1d/`.
///
/// Appens riktiga Application Support-index och Keychain rörs inte: indexet ligger i arbetsmappen och
/// nycklarna kommer ur `config.json`.
struct ObjektfilmEndToEndTests {

    nonisolated private static let env = ProcessInfo.processInfo.environment
    nonisolated private static let enabled = env["OBJEKTFILM_E2E_DIR"] != nil
    nonisolated private static func phase(_ name: String) -> Bool { env["OBJEKTFILM_E2E_PHASE"] == name }

    private struct Config: Decodable {
        var baseURL: URL
        var photographerKey: String
        var renderKey: String
    }

    private struct Rig {
        var work: URL
        var source: URL
        var reel: URL
        var config: Config
        var indexURL: URL
    }

    private func rig() throws -> Rig {
        let work = URL(fileURLWithPath: Self.env["OBJEKTFILM_E2E_DIR"]!, isDirectory: true)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: work.appendingPathComponent("config.json")))
        return Rig(work: work, source: work.appendingPathComponent("in", isDirectory: true),
                   reel: work.appendingPathComponent("reel-out-1d", isDirectory: true), config: config,
                   indexURL: work.appendingPathComponent("index.json"))
    }

    /// Öppnar filmen som fönstret gör: analyser ur cachen, bildfiler i källmappen, `reel.json` återställs.
    private func openEditor(_ r: Rig) async -> ReelEditorModel {
        let cache = ReelImageAnalyzer.loadCache(from: r.reel)
        let index = await ReelFileIndex.build(sourceDirectory: r.source)
        let items = index.compactMap { sha, url in cache[sha].map { ReelImageAnalyzer.Item(url: url, analysis: $0) } }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        let editor = ReelEditorModel()
        editor.prepare(items: items, sourceDirectory: r.source, reelDirectory: r.reel, address: "Provgatan 1")
        return editor
    }

    private func makeShare(_ r: Rig) -> ReelShareModel {
        let share = ReelShareModel()
        share.indexURL = r.indexURL
        let client = ReelServerClient(baseURL: r.config.baseURL, key: r.config.photographerKey)
        share.clientOverride = { _ in client }
        share.load(reelDirectory: r.reel)
        return share
    }

    @Test("Steg 1: skicka filmen och skapa länk", .enabled(if: enabled && phase("send")))
    func send() async throws {
        let r = try rig()
        let editor = await openEditor(r)
        #expect(editor.hasFilm)
        let share = makeShare(r)
        await share.send(from: editor, label: "E2E-mäklare", days: 30)
        #expect(share.phase == .done, "\(share.phase)")
        let link = try #require(share.createdLink)
        let state = try #require(ReelRemoteState.load(from: r.reel))
        let out: [String: Any] = ["objectId": state.objectId, "link": link.url, "revision": state.lastSyncedRevision,
                                  "order": editor.spec!.timeline.map(\.asset), "status": state.lastKnownStatus ?? ""]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
            .write(to: r.work.appendingPathComponent("send-out.json"))
    }

    @Test("Steg 2: hämta mäklarens ändringar", .enabled(if: enabled && phase("pull")))
    func pull() async throws {
        let r = try rig()
        let expected = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: r.work.appendingPathComponent("agent-order.json"))) as? [String])
        // Fönstret öppnas igen: tillståndet läses från reel-remote.json och ändringar hämtas automatiskt.
        let editor = await openEditor(r)
        let before = editor.spec!.timeline.map(\.asset)
        #expect(before != expected)
        let share = makeShare(r)
        #expect(share.isLinked)
        await share.autoRefresh(into: editor)
        #expect(editor.spec?.timeline.map(\.asset) == expected)
        let onDisk = try ReelSpec.decode(from: Data(contentsOf: r.reel.appendingPathComponent("reel.json")))
        #expect(onDisk.timeline.map(\.asset) == expected)
        #expect(onDisk.assets.allSatisfy { $0.sources.count == 1 && $0.sources[0].kind == .local })
        for asset in onDisk.assets {
            let file = URL(fileURLWithPath: asset.sources[0].path!, relativeTo: r.reel).standardizedFileURL
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.path)")
        }
        #expect(onDisk.revision == share.state?.lastSyncedRevision)
        try JSONSerialization.data(withJSONObject: ["revision": onDisk.revision, "order": onDisk.timeline.map(\.asset),
                                                    "badge": share.badge.label, "status": share.state?.lastKnownStatus ?? ""])
            .write(to: r.work.appendingPathComponent("pull-out.json"))
    }

    @Test("Steg 3: workern renderar det godkända jobbet", .enabled(if: enabled && phase("render")))
    func render() async throws {
        let r = try rig()
        let client = ReelServerClient(baseURL: r.config.baseURL, key: r.config.renderKey)
        let events = ReelRenderWorkerTests.Events()
        let worker = ReelRenderWorker(api: client, indexURL: r.indexURL, heartbeatInterval: .seconds(60), pollWait: 5,
                                      onEvent: { events.add($0) })
        let outcome = await worker.runOnce()
        guard case .rendered(let file) = outcome else { Issue.record("väntade rendered, fick \(outcome), \(events.all)"); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        #expect(size > 10_000)
        #expect(file.deletingLastPathComponent().standardizedFileURL == r.reel.standardizedFileURL)
        // Inget mer jobb.
        #expect(await worker.runOnce() == .idle)
        try JSONSerialization.data(withJSONObject: ["file": file.path, "bytes": size, "events": events.all.map { "\($0)" }.count])
            .write(to: r.work.appendingPathComponent("render-out.json"))
    }
}
