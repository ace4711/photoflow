import Foundation
import Testing
@testable import PhotoFlow

struct ReelSyncMergerTests {
    private let dir = URL(fileURLWithPath: "/Users/test/Objekt/Hus FILM", isDirectory: true)
    private let source = URL(fileURLWithPath: "/Users/test/Objekt/Hus FÄRDIGA", isDirectory: true)

    private func localSpec(count: Int = 4) -> (ReelSpec, [String: URL]) {
        let items = (0..<8).map { ReelImageAnalyzer.Item(url: source.appendingPathComponent("bild-\($0).jpg"),
                                                         analysis: ObjektfilmTestKit.analysis($0, q: 1 - Double($0) / 10)) }
        var options = ReelComposer.Options()
        options.count = count
        return (ReelComposer.compose(items: items, specDirectory: dir, options: options).spec, ReelFileIndex.index(from: items))
    }

    @Test("store → local via sha256-index, mäklarens ordning behålls")
    func mapsStoreToLocalKeepingOrder() throws {
        let (local, files) = localSpec()
        var remote = ReelUploadPlanner.storeSpec(local)
        remote.timeline.reverse()
        remote.revision = 7
        let result = ReelSyncMerger.merge(remote: remote, local: local, files: files, specDirectory: dir)
        #expect(result.isComplete)
        #expect(result.spec.timeline.map(\.asset) == local.timeline.map(\.asset).reversed())
        #expect(result.spec.revision == 7)
        for asset in result.spec.assets {
            let source = try #require(asset.sources.first)
            #expect(asset.sources.count == 1 && source.kind == .local)
            let url = URL(fileURLWithPath: try #require(source.path), relativeTo: dir).standardizedFileURL
            #expect(url == files[asset.sha256]?.standardizedFileURL)
        }
    }

    @Test("Mäklaren lägger till en bild ur poolen: den får fil, analys och ingen saknas")
    func agentAddsPoolImage() throws {
        let (local, files) = localSpec(count: 3)
        var remote = ReelUploadPlanner.storeSpec(local)
        let extra = ObjektfilmTestKit.analysis(7, room: "Bastu")
        remote.assets.append(.init(id: "pool-x", sha256: extra.sha256, width: 6000, height: 4000,
                                   sources: [.init(kind: .store, path: nil, url: nil, key: "img/\(extra.sha256)")], analysis: nil))
        var clip = remote.timeline[0]
        clip.asset = "pool-x"
        remote.timeline.append(clip)
        let result = ReelSyncMerger.merge(remote: remote, local: local, files: files, specDirectory: dir,
                                          analyses: [extra.sha256: extra])
        #expect(result.isComplete)
        let added = try #require(result.spec.assets.first { $0.id == "pool-x" })
        #expect(added.sources.first?.kind == .local)
        #expect(added.analysis?.room == "Bastu")
        #expect(result.spec.timeline.last?.asset == "pool-x")
    }

    @Test("Saknade bilder rapporteras och oanvända tillgångar tas bort")
    func reportsMissingAndPrunesUnused() {
        let (local, files) = localSpec(count: 3)
        var remote = ReelUploadPlanner.storeSpec(local)
        remote.assets.append(.init(id: "oanvand", sha256: ObjektfilmTestKit.sha(99), width: 10, height: 10, sources: [], analysis: nil))
        var partial = files
        partial[remote.assets[1].sha256] = nil
        let result = ReelSyncMerger.merge(remote: remote, local: nil, files: partial, specDirectory: dir)
        #expect(result.missing == [remote.assets[1].sha256])
        #expect(!result.isComplete)
        #expect(!result.spec.assets.contains { $0.id == "oanvand" })
        #expect(result.spec.assets.first { $0.sha256 == remote.assets[1].sha256 }?.sources.isEmpty == true)
    }

    @Test("Lokal källa som finns kvar används när indexet saknar bilden")
    func fallsBackToLocalSources() throws {
        let tmp = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reel = tmp.appendingPathComponent("FILM")
        let src = tmp.appendingPathComponent("FÄRDIGA")
        try FileManager.default.createDirectory(at: reel, withIntermediateDirectories: true)
        let items = try ObjektfilmTestKit.realItems(count: 4, in: src)
        var options = ReelComposer.Options()
        options.count = 3
        let local = ReelComposer.compose(items: items, specDirectory: reel, options: options).spec
        let result = ReelSyncMerger.merge(remote: ReelUploadPlanner.storeSpec(local), local: local, files: [:], specDirectory: reel)
        #expect(result.isComplete)
        #expect(result.spec.assets.allSatisfy { $0.sources.first?.kind == .local })
    }

    @Test("Filindex: hashar riktiga filer, omdöpt fil hittas ändå")
    func fileIndex() async throws {
        let tmp = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let items = try ObjektfilmTestKit.realItems(count: 3, in: tmp)
        try FileManager.default.moveItem(at: items[0].url, to: tmp.appendingPathComponent("omdopt.jpg"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("anteckning.txt"))
        let index = await ReelFileIndex.build(sourceDirectory: tmp)
        #expect(index.count == 3)
        #expect(index[items[0].analysis.sha256]?.lastPathComponent == "omdopt.jpg")
    }

    @Test("Specen från servern (millisekunder i datum) går att läsa; appens egna datum också")
    func decodesServerDates() throws {
        let (local, _) = localSpec()
        var json = String(decoding: try ReelUploadPlanner.storeSpec(local).jsonData(), as: UTF8.self)
        let updated = try #require(json.range(of: #""updatedAt" : "[^"]+""#, options: .regularExpression))
        json.replaceSubrange(updated, with: #""updatedAt" : "2026-10-03T12:00:00.123Z""#)
        let decoded = try ReelSpec.decode(from: Data(json.utf8))
        #expect(abs(decoded.updatedAt.timeIntervalSince1970 - 1_791_028_800.123) < 0.01)
        #expect(try ReelSpec.decode(from: try local.jsonData()) == local)
    }
}
