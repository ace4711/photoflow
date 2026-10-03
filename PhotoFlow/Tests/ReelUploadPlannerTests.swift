import Foundation
import Testing
@testable import PhotoFlow

struct ReelUploadPlannerTests {
    private let dir = URL(fileURLWithPath: "/Users/test/Objekt/Hus FILM", isDirectory: true)
    private let source = URL(fileURLWithPath: "/Users/test/Objekt/Hus FÄRDIGA", isDirectory: true)

    private func items(_ n: Int) -> [ReelImageAnalyzer.Item] {
        (0..<n).map { i in
            .init(url: source.appendingPathComponent("bild-\(i).jpg"),
                  analysis: ObjektfilmTestKit.analysis(i, room: "Rum \(i)", q: Double(i) / 100))
        }
    }

    private func spec(from items: [ReelImageAnalyzer.Item], count: Int = 3) -> ReelSpec {
        var options = ReelComposer.Options()
        options.count = count
        return ReelComposer.compose(items: items, specDirectory: dir, options: options).spec
    }

    @Test("Specen skrivs om local → store, och lokala sökvägar finns inte kvar")
    func storeSpec() {
        let spec = spec(from: items(8))
        let stored = ReelUploadPlanner.storeSpec(spec)
        #expect(stored.assets.count == spec.assets.count)
        for (a, b) in zip(spec.assets, stored.assets) {
            #expect(b.sources == [.init(kind: .store, path: nil, url: nil, key: "img/\(a.sha256)")])
        }
        let json = String(decoding: (try? stored.jsonData()) ?? Data(), as: UTF8.self)
        #expect(!json.contains("../") && !json.contains("\"local\""))
        #expect(stored.timeline == spec.timeline)
    }

    @Test("Poolen: filmens bilder först med sina id:n, sedan övriga med fil, aldrig fler än 40")
    func pool() {
        let all = items(50)
        let spec = spec(from: all, count: 5)
        let files = Dictionary(all.map { ($0.analysis.sha256, $0.url) }, uniquingKeysWith: { a, _ in a })
        let analyses = Dictionary(all.map { ($0.analysis.sha256, $0.analysis) }, uniquingKeysWith: { a, _ in a })
        let pool = ReelUploadPlanner.pool(spec: spec, analyses: analyses, files: files)
        #expect(pool.count == ReelUploadPlanner.poolLimit)
        #expect(pool.prefix(5).map(\.assetID) == spec.assets.map(\.id))
        #expect(Set(pool.map(\.sha256)).count == pool.count)
        #expect(Set(pool.map(\.assetID)).count == pool.count)
        #expect(pool.dropFirst(5).allSatisfy { $0.assetID.hasPrefix("pool-") })
        // Bästa kvalitet först bland de övriga.
        let extrasQuality = pool.dropFirst(5).compactMap { analyses[$0.sha256]?.qualityScore }
        #expect(extrasQuality == extrasQuality.sorted(by: >))
        #expect(pool.allSatisfy { $0.analysis != nil })
    }

    @Test("Bilder utan fil kommer inte med i poolen (utom de som redan ligger i specen)")
    func poolSkipsFileless() {
        let all = items(6)
        let spec = spec(from: all, count: 3)
        let analyses = Dictionary(all.map { ($0.analysis.sha256, $0.analysis) }, uniquingKeysWith: { a, _ in a })
        let pool = ReelUploadPlanner.pool(spec: spec, analyses: analyses, files: [:])
        #expect(pool.count == 3)
    }

    @Test("Vilka som ska laddas upp: bara de saknade, och de utan fil rapporteras")
    func uploads() {
        let files = [ObjektfilmTestKit.sha(1): source.appendingPathComponent("a.jpg"),
                     ObjektfilmTestKit.sha(2): source.appendingPathComponent("b.jpg")]
        let plan = ReelUploadPlanner.uploads(missing: [ObjektfilmTestKit.sha(2), ObjektfilmTestKit.sha(9)], files: files)
        #expect(plan.uploads.map(\.sha256) == [ObjektfilmTestKit.sha(2)])
        #expect(plan.unresolved == [ObjektfilmTestKit.sha(9)])
    }

    @Test("Poolbilden serialiseras med de fält servern kräver")
    func poolJSON() throws {
        let item = ReelUploadPlanner.PoolItem(assetID: "a1", sha256: ObjektfilmTestKit.sha(1), width: 6000, height: 4000,
                                              analysis: .init(room: "Kök", category: "Interiör", focus: .init(x: 0.5, y: 0.4),
                                                              salientWidth: 0.3, focusWidth: 0.2))
        let data = try JSONEncoder().encode(item.serverAsset)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["assetId"] as? String == "a1" && obj["width"] as? Int == 6000)
        #expect((obj["analysis"] as? [String: Any])?["room"] as? String == "Kök")
        #expect(data.count < 2000)
    }
}
