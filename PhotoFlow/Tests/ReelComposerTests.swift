import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelComposer`: specen ska vara giltig, kodas runt och ha relativa sökvägar.
struct ReelComposerTests {
    private let base = URL(fileURLWithPath: "/Users/test/Objekt/Lindvägen 12", isDirectory: true)
    private var specDir: URL { base.appendingPathComponent("Lindvägen 12 FILM", isDirectory: true) }
    private var finishedDir: URL { base.appendingPathComponent("Lindvägen 12 FÄRDIGA", isDirectory: true) }

    private func item(_ n: Int, room: String?, category: String?, q: Double, s: Double = 0.4) -> ReelImageAnalyzer.Item {
        var v = [Float](repeating: 0, count: 16)
        v[n % 16] = 1
        let analysis = ReelImageAnalysis(
            sha256: String(format: "%064x", n), width: 6000, height: 4000, qualityScore: q, isUtility: false,
            horizonAngleDegrees: nil, sharpness: nil, featurePrint: v.withUnsafeBytes { Data($0) },
            saliencyBoxes: [], focus: .init(x: 0.5, y: 0.5), salientWidth: s, meanLuminance: 0.45, exifDate: nil,
            room: room, category: category, features: nil, caption: nil)
        return .init(url: finishedDir.appendingPathComponent("bild-\(n).jpg"), analysis: analysis)
    }

    private func items() -> [ReelImageAnalyzer.Item] {
        [item(0, room: "Fasad", category: "Exteriör", q: 0.9, s: 0.9),
         item(1, room: "Trädgård", category: "Exteriör", q: 0.8),
         item(2, room: "Vardagsrum", category: "Interiör", q: 0.85, s: 0.7),
         item(3, room: "Kök", category: "Interiör", q: 0.8),
         item(4, room: "Sovrum", category: "Interiör", q: 0.75),
         item(5, room: "Badrum", category: "Interiör", q: 0.7),
         item(6, room: "Hall", category: "Interiör", q: 0.6)]
    }

    @Test("Specen är giltig, har rätt antal klipp och kodas fram och tillbaka")
    func specIsValidAndRoundTrips() throws {
        let result = ReelComposer.compose(items: items(), specDirectory: specDir)
        let spec = result.spec
        #expect(spec.isReadable)
        #expect(spec.timeline.count == 5)
        #expect(spec.assets.count == 5)
        #expect(spec.property.kind == "house")
        #expect(spec.timeline.allSatisfy { clip in spec.assets.contains { $0.id == clip.asset } })
        #expect(spec.provenance.autoSelection?.count == 5)
        #expect(spec.provenance.generator.contains("ReelSelector"))
        #expect(spec.provenance.autoSelection?.first?.slot == "opening")
        let decoded = try ReelSpec.decode(from: try spec.jsonData())
        #expect(decoded == spec)
    }

    @Test("Total längd för 5 bilder i 9:16 ligger inom 10–16 s")
    func totalDurationInRange() {
        for format in ReelFormat.allCases {
            var options = ReelComposer.Options()
            options.format = format
            let spec = ReelComposer.compose(items: items(), specDirectory: specDir, options: options).spec
            let total = ReelTimeline.totalDuration(spec)
            #expect((10...16).contains(total), "\(format): \(total) s")
        }
    }

    @Test("Outputen följer formatet och kodningsprofilen")
    func outputProfile() {
        var options = ReelComposer.Options()
        options.format = .vertical
        let out = ReelComposer.compose(items: items(), specDirectory: specDir, options: options).spec.outputs[0]
        #expect(out.width == 1080 && out.height == 1920 && out.fps == 30 && out.aspect == "9:16")
        #expect(out.encoding?.codec == "h264")
        #expect(out.encoding?.audio == "aac-silent")
    }

    @Test("Sökvägarna är relativa spec-filens mapp")
    func relativePaths() {
        let spec = ReelComposer.compose(items: items(), specDirectory: specDir).spec
        for asset in spec.assets {
            let path = asset.sources.first?.path ?? ""
            #expect(path.hasPrefix("../Lindvägen 12 FÄRDIGA/bild-"))
            #expect(asset.sources.first?.kind == .local)
        }
        #expect(ReelComposer.relativePath(from: specDir, to: specDir.appendingPathComponent("a.jpg")) == "a.jpg")
        #expect(ReelComposer.relativePath(from: URL(fileURLWithPath: "/a/b/c"), to: URL(fileURLWithPath: "/a/x/y.jpg")) == "../../x/y.jpg")
    }

    @Test("Identiska filer (samma hash) räknas som en bild")
    func identicalFilesCollapse() {
        var list = items()
        var copy = list[2]
        copy.url = finishedDir.appendingPathComponent("kopia.jpg")
        list.append(copy)
        let result = ReelComposer.compose(items: list, specDirectory: specDir)
        #expect(result.candidates.count == 7)
    }

    @Test("Ombyggnad behåller användarens ordning och planerar om rörelsen")
    func rebuildKeepsOrder() throws {
        let original = ReelComposer.compose(items: items(), specDirectory: specDir).spec
        let order = original.assets.map(\.id).reversed().map { $0 }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let rebuilt = ReelComposer.rebuild(original, order: order, now: when)
        #expect(rebuilt.timeline.map(\.asset) == order)
        #expect(rebuilt.revision == original.revision + 1)
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.updatedBy.role == "photographer")
        #expect(rebuilt.provenance.edits?.last?.op == "reorder")
        #expect(rebuilt.timeline.first?.duration == ReelMotionPlanner.firstDuration)
        #expect(rebuilt.timeline.first?.transitionIn == nil)
        #expect(ReelTimeline.totalDuration(rebuilt) > 0)
        #expect(try ReelSpec.decode(from: try rebuilt.jsonData()) == rebuilt)
    }

    @Test("Ombyggnad: bytt bild (ny asset) och borttagen bild")
    func rebuildSwapsImage() {
        let result = ReelComposer.compose(items: items(), specDirectory: specDir)
        let original = result.spec
        let unusedItem = items().first { item in !original.assets.contains { $0.sha256 == item.analysis.sha256 } }!
        let newAsset = ReelComposer.asset(id: "a9", item: unusedItem, specDirectory: specDir)
        var order = original.assets.map(\.id)
        let removed = order.removeLast()
        order.insert("a9", at: 1)
        let rebuilt = ReelComposer.rebuild(original, order: order, newAssets: [newAsset], op: "swap")
        #expect(rebuilt.timeline.map(\.asset) == order)
        #expect(!rebuilt.assets.contains { $0.id == removed })
        #expect(rebuilt.assets.contains { $0.id == "a9" })
        #expect(rebuilt.provenance.autoSelection?.contains { $0.asset == removed } == false)
        #expect(rebuilt.provenance.edits?.last?.op == "swap")
    }

    @Test("Formatbyte vid ombyggnad ändrar outputen och planerar om")
    func rebuildChangesFormat() {
        let original = ReelComposer.compose(items: items(), specDirectory: specDir).spec
        let rebuilt = ReelComposer.rebuild(original, order: original.assets.map(\.id), format: .landscape)
        #expect(rebuilt.outputs.first?.aspect == "16:9")
        #expect(rebuilt.timeline.count == original.timeline.count)
    }
}
