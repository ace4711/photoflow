import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Datamodellen tål rutklipp (spec v2) utan redigerings-UI: en spec byggd för hand (montagehalvor av
/// samma bild i `sequence` och ett kollage av två bilder i `stack`) går genom ombyggnad, JSON,
/// redigeringsmodellen, synk, uppladdningsplanering och export utan att krascha eller tappa rutor.
struct ReelPanelsDataModelTests {

    // MARK: - Uppsättning

    private struct Fixture {
        var root: URL
        var source: URL
        var reel: URL
        var items: [ReelImageAnalyzer.Item]
        var spec: ReelSpec
        var files: [String: URL]
    }

    private static let still = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.04))

    private func writePNG(_ url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// bild-0: montage (röd vänster halva, blå höger), bild-1..3 enfärgade liggande bilder, bild-4 oanvänd.
    private func makeFixture() throws -> Fixture {
        let root = try ObjektfilmTestKit.tempDir("PanelsData")
        let source = root.appendingPathComponent("Test FÄRDIGA", isDirectory: true)
        let reel = root.appendingPathComponent("Test FILM", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reel, withIntermediateDirectories: true)
        let dims = [(800, 600), (600, 400), (600, 400), (600, 400), (600, 400)]
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 0.8, 0), (1, 0.5, 0), (0, 0.4, 1), (0.5, 0.5, 0.5)]
        var items: [ReelImageAnalyzer.Item] = []
        for n in 0..<5 {
            let url = source.appendingPathComponent("bild-\(n).png")
            let (w, h) = dims[n]
            try writePNG(url, width: w, height: h) { ctx in
                if n == 0 {
                    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
                    ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
                } else {
                    ctx.setFillColor(red: colors[n].0, green: colors[n].1, blue: colors[n].2, alpha: 1)
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            items.append(.init(url: url, analysis: ObjektfilmTestKit.analysis(n, room: ["Hall", "Kök", "Matplats", "Sovrum", "Badrum"][n],
                                                                               width: w, height: h)))
        }
        func asset(_ id: String, _ n: Int) -> ReelSpec.Asset {
            .init(id: id, sha256: items[n].analysis.sha256, width: dims[n].0, height: dims[n].1,
                  sources: [.init(kind: .local, path: ReelComposer.relativePath(from: reel, to: items[n].url))],
                  analysis: .init(room: items[n].analysis.room, category: "Interiör"))
        }
        let left = ReelSpec.UnitRect(x: 0, y: 0, w: 0.5, h: 1), right = ReelSpec.UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let plain = ReelSpec.Clip(asset: "a4", duration: 2, fit: .cover, motion: Self.still)
        let montage = ReelSpec.Clip(
            asset: "a1", duration: 3, fit: .panels, motion: Self.still,
            transitionIn: .init(type: .crossfade, direction: nil, duration: 0.5), motionPreset: "custom",
            layout: .sequence, panels: [.init(asset: "a1", source: left, motion: Self.still),
                                        .init(asset: "a1", source: right, motion: Self.still)])
        let collage = ReelSpec.Clip(
            asset: "a2", duration: 3, fit: .panels, motion: Self.still,
            transitionIn: .init(type: .crossfade, direction: nil, duration: 0.5), motionPreset: "custom",
            layout: .stack, panels: [.init(asset: "a2", source: nil, motion: Self.still), .init(asset: "a3", source: nil, motion: Self.still)],
            gutter: 0.02, entrance: .init(type: .slide, stagger: 0.3, duration: 0.6))
        let spec = ReelSpec(
            schema: ReelSpec.schemaName, version: 1, minReaderVersion: 1, id: "panels-test", revision: 1, status: "draft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedBy: .init(role: "photographer", name: nil), property: .init(address: "Test", sessionID: nil, kind: "apartment"),
            assets: [asset("a1", 0), asset("a2", 1), asset("a3", 2), asset("a4", 3)], style: ReelComposer.defaultStyle,
            timeline: [plain, montage, collage], audio: nil, overlays: [], brand: nil,
            outputs: [ReelSpec.Output(id: "vertical", aspect: "9:16", width: 270, height: 480, fps: 10,
                                      encoding: .init(codec: "h264", bitrateMbps: 2, audio: "aac-silent"))],
            provenance: .init(generator: "test", autoSelection: nil, edits: nil)).updatingVersions()
        return Fixture(root: root, source: source, reel: reel, items: items, spec: spec, files: ReelFileIndex.index(from: items))
    }

    private func panelsClips(_ spec: ReelSpec) -> [ReelSpec.Clip] { spec.timeline.filter { $0.fit == .panels } }

    // MARK: - Version och JSON

    @Test("Versioner: rutor ger minReaderVersion 2, en film utan rutor skrivs som version 1")
    func versioning() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.spec.version == 2 && f.spec.minReaderVersion == 2 && f.spec.isReadable)
        let json = String(decoding: try f.spec.jsonData(), as: UTF8.self)
        #expect(json.contains("\"minReaderVersion\" : 2") && json.contains("\"fit\" : \"panels\""))

        // Ett v1-skrivet värde som ändå har rutor höjs vid kodning (aldrig en trasig fil).
        var stale = f.spec
        stale.version = 1; stale.minReaderVersion = 1
        let decoded = try ReelSpec.decode(from: try stale.jsonData())
        #expect(decoded.minReaderVersion == 2)

        var plain = f.spec
        plain.timeline = [plain.timeline[0]]
        plain.assets = [plain.assets[3]]
        let plainJSON = String(decoding: try plain.updatingVersions().jsonData(), as: UTF8.self)
        #expect(plainJSON.contains("\"minReaderVersion\" : 1") && !plainJSON.contains("\"panels\" :") && !plainJSON.contains("\"layout\""))
        // En läsare med version 1 skulle vägra filen: minReaderVersion > 1.
        #expect(f.spec.minReaderVersion > 1)
    }

    @Test("JSON-rundtur bevarar alla rutor, källor, gutter och ingång")
    func jsonRoundTrip() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let data = try f.spec.jsonData()
        let back = try ReelSpec.decode(from: data)
        #expect(back == f.spec)
        #expect(try back.jsonData() == data)
        let montage = try #require(back.timeline.first { $0.layout == .sequence })
        #expect(montage.panels?.count == 2 && montage.panels?[1].source == .init(x: 0.5, y: 0, w: 0.5, h: 1))
        let collage = try #require(back.timeline.first { $0.layout == .stack })
        #expect(collage.gutter == 0.02 && collage.entrance == .init(type: .slide, stagger: 0.3, duration: 0.6))
        #expect(back.usedAssetIDs == ["a1", "a2", "a3", "a4"])
    }

    // MARK: - Ombyggnad

    @Test("rebuild: omordning och formatbyte behåller rutklippen och deras bilder")
    func rebuildKeepsPanels() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalPanels = Dictionary(uniqueKeysWithValues: panelsClips(f.spec).map { ($0.asset, $0) })

        let moved = ReelComposer.rebuild(f.spec, order: ["a2", "a4", "a1"])
        #expect(moved.timeline.map(\.asset) == ["a2", "a4", "a1"])
        #expect(Set(moved.assets.map(\.id)) == ["a1", "a2", "a3", "a4"], "a3 är bara ruta i kollaget men får inte tappas")
        for clip in panelsClips(moved) {
            let old = try #require(originalPanels[clip.asset])
            #expect(clip.fit == .panels && clip.layout == old.layout && clip.panels == old.panels
                    && clip.gutter == old.gutter && clip.entrance == old.entrance && clip.motion == old.motion)
            #expect(clip.motionPreset == "custom")
        }
        #expect(moved.version == 2 && moved.minReaderVersion == 2)
        #expect(moved.usedAssetIDs == ["a1", "a2", "a3", "a4"])

        let landscape = ReelComposer.rebuild(moved, order: moved.timeline.map(\.asset), format: .landscape)
        #expect(landscape.outputs[0].id == "landscape")
        // R6d: ett låst rutklipps layout följer formatet (stapel passar inte 16:9: sida vid sida) och nycklarna klampas
        // mot de nya rutorna (fixturens halvor har mittpunkten på skarven, så de flyttas in i halvan); rutornas
        // bilder och källor är oförändrade. Sekvensen behåller sin layout.
        #expect(panelsClips(landscape).map { $0.panels?.map(\.asset) } == panelsClips(moved).map { $0.panels?.map(\.asset) })
        #expect(panelsClips(landscape).map { $0.panels?.map(\.source) } == panelsClips(moved).map { $0.panels?.map(\.source) })
        #expect(panelsClips(landscape).map(\.layout) == [.side, .sequence])
        // Och tillbaka igen.
        let back = ReelComposer.rebuild(landscape, order: landscape.timeline.map(\.asset), format: .vertical)
        #expect(panelsClips(back).map { $0.panels?.map(\.asset) } == panelsClips(f.spec).reversed().map { $0.panels?.map(\.asset) })
        #expect(panelsClips(back).map(\.layout) == panelsClips(f.spec).reversed().map(\.layout))

        // Ett rutklipp längd följer reglerna men kan låsas: låst längd behålls.
        var locked = moved
        let i = try #require(locked.timeline.firstIndex { $0.layout == .stack })
        locked.timeline[i].duration = 5.5
        locked.timeline[i].durationLocked = true
        let again = ReelComposer.rebuild(locked, order: locked.timeline.map(\.asset))
        #expect(again.timeline[i].duration == 5.5 && again.timeline[i].panels == locked.timeline[i].panels)

        // Utan klippet tappas bara dess egna partner; utan alla rutklipp blir filmen version 1 igen.
        let noCollage = ReelComposer.rebuild(f.spec, order: ["a1", "a4"])
        #expect(Set(noCollage.assets.map(\.id)) == ["a1", "a4"] && noCollage.version == 2)
        let plainOnly = ReelComposer.rebuild(f.spec, order: ["a4"])
        #expect(plainOnly.assets.map(\.id) == ["a4"] && plainOnly.version == 1 && plainOnly.minReaderVersion == 1)
        #expect(!String(decoding: try plainOnly.jsonData(), as: UTF8.self).contains("\"fit\" : \"panels\""))
    }

    @Test("overrides(in:): rutklipp läses som fotografens låsta val med bilderna i rutorna")
    func overridesReadPanels() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let o = ReelComposer.overrides(in: f.spec)
        #expect(o["a1"]?.panels?.layout == .sequence && o["a2"]?.panels?.panels.map(\.asset) == ["a2", "a3"])
        #expect(o["a4"] == nil)
        // Planeraren skriver inte över layout, rutor och rörelse, även om fotografen ber om ett förval.
        var forced = o
        forced["a2"]?.preset = .panLeft
        let planned = ReelMotionPlanner.plan(ReelComposer.plannerImages(f.spec.assets.filter { ["a4", "a1", "a2"].contains($0.id) }),
                                             frameAspect: 9.0 / 16.0, overrides: forced)
        let collage = try #require(planned.first { $0.asset == "a2" })
        #expect(collage.fit == .panels && collage.layout == .stack && collage.panels?.count == 2 && collage.motion == Self.still)
    }

    @Test("compose med preserving: rutklippen följer med 'Föreslå igen', bilderna numreras om på sha256")
    func composePreservesPanels() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var options = ReelComposer.Options()
        options.count = 4
        let result = ReelComposer.compose(items: f.items, specDirectory: f.reel, options: options, preserving: f.spec)
        let spec = result.spec
        let clips = panelsClips(spec)
        #expect(clips.count == 2, "båda rutklippen finns kvar")
        let shaOf = Dictionary(spec.assets.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        let shas = clips.map { ($0.panels ?? []).map { shaOf[$0.asset] ?? "?" } }
        #expect(shas.contains([f.items[0].analysis.sha256, f.items[0].analysis.sha256]))
        #expect(shas.contains([f.items[1].analysis.sha256, f.items[2].analysis.sha256]))
        #expect(spec.usedAssetIDs.isSubset(of: Set(spec.assets.map(\.id))))
        #expect(spec.version == 2)
        // Utan rutor är en nykomponerad film version 1.
        #expect(ReelComposer.compose(items: f.items, specDirectory: f.reel, options: options).spec.version == 1)
    }

    // MARK: - Redigeringsmodellen

    @Test("ReelEditorModel: prepare, clipRows, candidateRows och redigering med rutklipp")
    func editorModel() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.spec.jsonData().write(to: f.reel.appendingPathComponent("reel.json"))

        let model = ReelEditorModel()
        model.prepare(items: f.items, sourceDirectory: f.source, reelDirectory: f.reel, address: "Test")
        let spec = try #require(model.spec)
        #expect(spec.timeline.map(\.fit) == [.cover, .panels, .panels], "den sparade filmen återställs")
        #expect(model.clipRows.map(\.id) == ["a4", "a1", "a2"])
        let rows = model.candidateRows
        #expect(rows.count == 5)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[f.items[2].analysis.sha256]?.clipIndex == 2, "kollagets andra bild visas som med i klipp 3")
        #expect(byID[f.items[0].analysis.sha256]?.clipIndex == 1)
        #expect(byID[f.items[4].analysis.sha256]?.clipIndex == nil)
        #expect(model.assetID(forCandidate: f.items[2].analysis.sha256) == "a2")

        // Redigera: omordning, längd, format, förval på rutklipp (ignoreras), borttagning.
        model.moveClip("a2", to: 0)
        #expect(model.clipRows.map(\.id) == ["a2", "a4", "a1"])
        #expect(panelsClips(try #require(model.spec)).count == 2)
        let revision = model.spec?.revision
        model.setPreset("a2", .zoomIn)
        model.setCustomMotion("a2", fit: .cover, motion: Self.still)
        #expect(model.spec?.revision == revision, "rörelse på rutklipp ignoreras tills R6d")
        model.setDuration("a2", seconds: 4.2)
        #expect(model.spec?.timeline[0].duration == 4.2 && model.spec?.timeline[0].durationLocked == true)
        model.setFormat(.square)
        #expect(model.spec?.timeline[0].panels?.map(\.asset) == ["a2", "a3"])
        #expect(model.spec?.assets.contains { $0.id == "a3" } == true)
        _ = model.motionReason(forAsset: "a2")
        let summary = ReelChoiceSummary.summary(try #require(model.spec))
        #expect(summary.rows.count == 3 && summary.rows[0].motion.hasPrefix("Rutor: stapel"))
        #expect(summary.rows[2].motion.hasPrefix("Rutor: efter varandra"))

        // Sparad på disk som version 2 och läsbar igen.
        let saved = try ReelSpec.decode(from: Data(contentsOf: f.reel.appendingPathComponent("reel.json")))
        #expect(saved.minReaderVersion == 2 && panelsClips(saved).count == 2 && saved.assets.count == 4)

        model.removeClip("a2")
        #expect(model.spec?.assets.contains { $0.id == "a3" } == false)
        model.removeClip("a1")
        #expect(model.spec?.version == 1, "utan rutor skrivs filmen som version 1")
    }

    @Test("candidateRows kraschar inte när samma bild finns i flera klipp (rutklipp och vanligt klipp)")
    func duplicateImagesDoNotCrash() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var spec = f.spec
        // Montagebilden a1 visas både i sequence-klippet och som vanligt klipp; a2 både som kollage och vanligt klipp.
        spec.timeline.append(.init(asset: "a1", duration: 2, fit: .cover, motion: Self.still))
        spec.timeline.append(.init(asset: "a3", duration: 2, fit: .cover, motion: Self.still))
        try spec.jsonData().write(to: f.reel.appendingPathComponent("reel.json"))
        let model = ReelEditorModel()
        model.prepare(items: f.items, sourceDirectory: f.source, reelDirectory: f.reel, address: "Test")
        #expect(model.spec?.timeline.count == 5)
        #expect(model.candidateRows.count == 5)
        #expect(model.clipRows.count == 5)
        // Första klippet som visar bilden gäller.
        let byID = Dictionary(uniqueKeysWithValues: model.candidateRows.map { ($0.id, $0) })
        #expect(byID[f.items[0].analysis.sha256]?.clipIndex == 1 && byID[f.items[2].analysis.sha256]?.clipIndex == 2)
    }

    // MARK: - Synk och uppladdning

    @Test("Synk och uppladdning: rutornas bilder hittas, laddas upp och pruneras inte")
    func syncAndUpload() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let remote = ReelUploadPlanner.storeSpec(f.spec)
        #expect(remote.minReaderVersion == 2 && remote.assets.allSatisfy { $0.sources.first?.kind == .store })
        #expect(remote.timeline == f.spec.timeline, "rutorna följer med oförändrade")
        #expect(remote.assets.contains { $0.id == "a3" })

        // Poolen innehåller alla filmens bilder, även den som bara är ruta.
        let analyses = Dictionary(f.items.map { ($0.analysis.sha256, $0.analysis) }, uniquingKeysWith: { a, _ in a })
        let pool = ReelUploadPlanner.pool(spec: f.spec, analyses: analyses, files: f.files)
        #expect(pool.prefix(4).map(\.assetID) == ["a1", "a2", "a3", "a4"])
        #expect(pool.map(\.sha256).contains(f.items[2].analysis.sha256))

        // Mäklarens spec kommer tillbaka: a3 används bara av en ruta och ska behållas och få sin fil.
        let merged = ReelSyncMerger.merge(remote: remote, local: nil, files: f.files, specDirectory: f.reel)
        #expect(merged.isComplete)
        #expect(Set(merged.spec.assets.map(\.id)) == ["a1", "a2", "a3", "a4"])
        #expect(merged.spec.assets.allSatisfy { $0.sources.first?.kind == .local })
        #expect(merged.spec.timeline == f.spec.timeline)

        // Saknas rutans bild på den här Macen rapporteras den.
        var partial = f.files
        partial[f.items[2].analysis.sha256] = nil
        let incomplete = ReelSyncMerger.merge(remote: remote, local: nil, files: partial, specDirectory: f.reel)
        #expect(incomplete.missing == [f.items[2].analysis.sha256])
        let plan = ReelUploadPlanner.uploads(missing: [f.items[2].analysis.sha256], files: f.files)
        #expect(plan.uploads.map(\.sha256) == [f.items[2].analysis.sha256] && plan.unresolved.isEmpty)
    }

    // MARK: - Export

    @Test("Export av en film med rutklipp: mp4 med rätt längd, och alla rutor syns i bildrutorna")
    func exportWithPanels() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let spec = f.spec
        let output = spec.outputs[0]
        let total = ReelTimeline.totalDuration(spec)
        let out = f.reel.appendingPathComponent("film.mp4")
        try await ReelRenderer.export(spec: spec, specDirectory: f.reel, output: output, to: out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - total) <= 0.15, "längd \(duration) mot \(total)")

        // Bildrutor: kollagets båda bilder (orange uppe, grön... a2 grön, a3 orange) och montagehalvorna.
        let renderer = ReelRenderer(spec: spec, specDirectory: f.reel, maxOutputSize: CGSize(width: 270, height: 480))
        try renderer.preload()
        func px(_ t: Double, _ x: Int, _ y: Int) -> [Int] {
            let image = renderer.renderFrame(at: t, size: CGSize(width: 270, height: 480))
            var buf = [UInt8](repeating: 0, count: 4)
            renderer.context.render(image, toBitmap: &buf, rowBytes: 4,
                                    bounds: CGRect(x: CGFloat(x), y: 480 - CGFloat(y) - 1, width: 1, height: 1),
                                    format: .RGBA8, colorSpace: ReelRenderer.sRGB)
            return buf.map(Int.init)
        }
        let starts = ReelTimeline.clipStarts(spec)
        // Montage (klipp 2): första halvan röd, sedan blå.
        let m = starts[1]
        #expect(px(m + 0.6, 135, 240)[0] > 240 && px(m + 0.6, 135, 240)[2] < 15)
        #expect(px(m + 2.4, 135, 240)[2] > 240 && px(m + 2.4, 135, 240)[0] < 15)
        // Kollage (klipp 3), efter ingången: a2 (grön) uppe, a3 (orange) nere.
        let c = starts[2] + 1.5
        let top = px(c, 135, 100), bottom = px(c, 135, 380)
        #expect(top[1] > 190 && top[0] < 15, "uppe \(top)")
        #expect(bottom[0] > 240 && bottom[2] < 15, "nere \(bottom)")
    }

    @Test("requiredLongEdge tar hänsyn till rutornas bilder (partnerbilden laddas inte som oanvänd)")
    func requiredLongEdgeForPanels() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let renderer = ReelRenderer(spec: f.spec, specDirectory: f.reel, maxOutputSize: CGSize(width: 1080, height: 1920))
        let a3 = try #require(f.spec.assets.first { $0.id == "a3" })
        // a3 är bara ruta i kollaget (stack i 9:16): ruta 1080 × ~957 px ur 600 × 400 → hela bildens långsida behövs.
        #expect(renderer.requiredLongEdge(for: a3) == 600)
        #expect(f.spec.usedAssetIDs.contains("a3"))
    }
}
