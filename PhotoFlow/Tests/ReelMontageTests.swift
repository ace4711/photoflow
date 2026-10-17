import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Montage (R6b): analysen sparar och räknar i efterhand `panels`, rum per halva, urvalet räknar ett
/// montage som en plats som täcker båda rumstyperna, och planeringen gör det till ett rutklipp
/// (`sequence`) i 9:16 och 1:1 men ett vanligt klipp i 16:9. Formatbyte fram och tillbaka (rebuild),
/// och skillnaden mellan automatiska och låsta rutklipp.
struct ReelMontageTests {

    private let vertical = 1080.0 / 1920.0
    private let square = 1.0
    private let landscape = 1920.0 / 1080.0

    // MARK: - Analys (fil, cache, rum per halva)

    private func tempDir() throws -> URL { try ObjektfilmTestKit.tempDir("ReelMontage") }

    /// Två olika rutmönster (stående, 590 px var av 1200 × 800) med en vit ränna på 20 px emellan.
    private func writeMontageJPEG(to url: URL, gutter: Bool = true) throws {
        let w = 1200, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let gutterWidth = gutter ? 20 : 0
        let half = (w - gutterWidth) / 2
        for (side, seed) in [(0, 3), (1, 11)] {
            let x0 = side == 0 ? 0 : half + gutterWidth
            for y in stride(from: 0, to: h, by: 16) {
                for x in stride(from: 0, to: half, by: 16) {
                    let v = CGFloat((x * (seed + 3) + y * (seed + 5) + x * y / 7) % 200 + 30) / 255
                    ctx.setFillColor(CGColor(red: v, green: CGFloat((y * seed) % 200 + 30) / 255, blue: 1 - v * 0.8, alpha: 1))
                    ctx.fill(CGRect(x: x0 + x, y: y, width: min(16, half - x), height: 16))
                }
            }
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("Analysen hittar ett montage och lämnar en vanlig bild med en tom lista")
    func analysisFindsMontage() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let montage = dir.appendingPathComponent("1.jpg")
        try writeMontageJPEG(to: montage)
        let plain = ObjektfilmTestKit.writeJPEG(to: dir.appendingPathComponent("vanlig.jpg"), width: 900, height: 600, seed: 4)
        let items = try await ReelImageAnalyzer.analyze(urls: [montage, plain], cacheDirectory: nil, describe: false,
                                                        qualityMeasurer: { _ in nil })
        #expect(items[0].analysis.panels?.count == 2)
        #expect(items[1].analysis.panels?.isEmpty == true)
        let halves = try #require(items[0].analysis.panels)
        #expect(halves[0].x == 0 && halves[1].x > 0.5 && halves[0].w < 0.5 && halves[1].w < 0.5)
    }

    @Test("Cachad analys utan panels får fältet beräknat i efterhand, utan att övriga mätningar görs om")
    func panelsBackfilledInCache() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let montage = dir.appendingPathComponent("1.jpg")
        try writeMontageJPEG(to: montage)
        let cacheDir = dir.appendingPathComponent("FILM")
        let first = try await ReelImageAnalyzer.analyze(urls: [montage], cacheDirectory: cacheDir, describe: false,
                                                        qualityMeasurer: { _ in nil })
        let sha = first[0].analysis.sha256
        // En cache skriven före R6b: inget panels-fält alls (inte ens en tom lista) och en markör.
        var cache = ReelImageAnalyzer.loadCache(from: cacheDir)
        cache[sha]?.panels = nil
        cache[sha]?.panelRooms = nil
        cache[sha]?.sharpness = 12345
        ReelImageAnalyzer.saveCache(cache, to: cacheDir)
        let json = try String(contentsOf: cacheDir.appendingPathComponent("reel_analysis.json"), encoding: .utf8)
        #expect(!json.contains("\"panels\""))

        let second = try await ReelImageAnalyzer.analyze(urls: [montage], cacheDirectory: cacheDir, describe: false,
                                                         qualityMeasurer: { _ in nil })
        #expect(second[0].analysis.panels?.count == 2)
        #expect(second[0].analysis.sharpness == 12345)       // ingen ommätning
        #expect(ReelImageAnalyzer.loadCache(from: cacheDir)[sha]?.panels?.count == 2)
        #expect(ReelImageAnalyzer.loadCache(from: cacheDir)[sha]?.sharpness == 12345)
    }

    @Test("Rum per halva: den viktigaste halvans rum blir montagets, bildtexten båda, och det gäller om och om igen")
    func panelRoomsApplied() {
        var a = ObjektfilmTestKit.analysis(1, room: "Kök", category: "Interiör")   // modellens svar för hela montaget
        a.panels = [.init(x: 0, y: 0, w: 0.49, h: 1), .init(x: 0.51, y: 0, w: 0.49, h: 1)]
        a.panelRooms = [.init(room: "Hall", category: "Interiör", caption: "Ljus hall med köksö"),
                        .init(room: "Uteplats", category: "Exteriör", caption: "Altan med utsikt")]
        ReelImageAnalyzer.applyPanelRooms(to: &a)
        #expect(a.room == "Uteplats" && a.category == "Exteriör")
        #expect(a.caption == "Ljus hall med köksö | Altan med utsikt")
        let once = a
        ReelImageAnalyzer.applyPanelRooms(to: &a)
        #expect(a == once)
        // Okänt rum på den första halvan: den andra vinner. Inga rum alls: analysen orörd.
        var b = ObjektfilmTestKit.analysis(2, room: "Kök")
        b.panelRooms = [.init(room: nil, category: nil, caption: nil), .init(room: "Sovrum", category: "Interiör", caption: nil)]
        ReelImageAnalyzer.applyPanelRooms(to: &b)
        #expect(b.room == "Sovrum")
        var c = ObjektfilmTestKit.analysis(3, room: "Kök")
        c.panelRooms = [.init(room: nil, category: nil, caption: nil), .init(room: nil, category: nil, caption: nil)]
        ReelImageAnalyzer.applyPanelRooms(to: &c)
        #expect(c.room == "Kök")
    }

    @Test("Montageanalysen kodas fram och tillbaka (panels, panelRooms), och äldre cache utan fälten läses")
    func analysisCoding() throws {
        var a = ObjektfilmTestKit.analysis(1, room: "Hall")
        a.panels = [.init(x: 0, y: 0, w: 0.49, h: 1), .init(x: 0.51, y: 0, w: 0.49, h: 1)]
        a.panelRooms = [.init(room: "Hall", category: "Interiör", caption: "a"), .init(room: "Altan", category: "Exteriör", caption: nil)]
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(ReelImageAnalysis.self, from: try encoder.encode(a))
        #expect(decoded == a)
        var old = a; old.panels = nil; old.panelRooms = nil
        let oldDecoded = try JSONDecoder().decode(ReelImageAnalysis.self, from: try encoder.encode(old))
        #expect(oldDecoded.panels == nil && oldDecoded.panelRooms == nil)
    }

    // MARK: - Urval

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 40)
        v[axis % 40] = 1
        return v
    }

    private func cand(_ id: String, room: String?, category: String? = nil, q: Double = 0.7, axis: Int,
                      horizon: Double? = nil, panelRooms: [String] = []) -> ReelCandidate {
        let exterior = ["Fasad", "Trädgård", "Altan", "Uteplats", "Balkong"].contains(room ?? "")
        return ReelCandidate(id: id, filename: "\(id).jpg", quality: q, horizonDegrees: horizon, featureVector: vec(axis),
                             salientWidth: 0.4, meanLuminance: 0.45, room: room,
                             category: category ?? (exterior ? "Exteriör" : "Interiör"), panelRooms: panelRooms)
    }

    private func villa() -> [ReelCandidate] {
        [cand("fasad", room: "Fasad", q: 0.9, axis: 0),
         cand("trad", room: "Trädgård", q: 0.8, axis: 1),
         cand("vard", room: "Vardagsrum", q: 0.85, axis: 2),
         cand("kok", room: "Kök", q: 0.8, axis: 3),
         cand("sov", room: "Sovrum", q: 0.75, axis: 4),
         cand("bad", room: "Badrum", q: 0.7, axis: 5),
         cand("hall", room: "Hall", q: 0.6, axis: 6)]
    }

    @Test("Den viktigaste halvans rum enligt roomPriority: kök före sovrum före hall, okänt sist, lika = första")
    func primaryPanelIndex() {
        #expect(ReelSelector.primaryPanelIndex(["Hall", "Uteplats"]) == 1)
        #expect(ReelSelector.primaryPanelIndex(["Sovrum", "Kök"]) == 1)
        #expect(ReelSelector.primaryPanelIndex(["Kök", "Sovrum"]) == 0)
        #expect(ReelSelector.primaryPanelIndex(["Badrum", "Hall"]) == 0)       // badrum (klass 2) före nyttorum (3)
        #expect(ReelSelector.primaryPanelIndex(["Bastu", "Badrum"]) == 0)       // särskilt rum före badrum
        #expect(ReelSelector.primaryPanelIndex([nil, "Hall"]) == 1)
        #expect(ReelSelector.primaryPanelIndex(["Hall", "Entré"]) == 0)         // lika: den första
        #expect(ReelSelector.primaryPanelIndex([]) == nil)
    }

    @Test("Montage: rumstyp = viktigaste halvans, täckta typer och text")
    func montageHelpers() {
        let m = cand("m", room: "Uteplats", axis: 9, panelRooms: ["Hall", "Uteplats"])
        #expect(ReelSelector.isMontage(m) && !ReelSelector.isMontage(villa()[0]))
        #expect(ReelSelector.montageRooms(m) == "Hall och Uteplats")
        let same = cand("s", room: "Badrum", axis: 9, panelRooms: ["Badrum", "badrum"])
        #expect(ReelSelector.montageRooms(same) == "Badrum (två bilder)")
    }

    @Test("Ett montage täcker ingen rumstyp: den fristående köks- och sovrumsbilden går före, montaget är extra")
    func montageIsExtraNotCoverage() throws {
        var list = villa()
        list.append(cand("m", room: "Kök", q: 0.95, axis: 9, panelRooms: ["Hall", "Kök"]))
        // Automatiskt: fem viktiga typer, alla får en fristående bild; montaget (högst poäng) tas inte i runda 0.
        let ids = ReelSelector.select(list).picks.map(\.candidateID)
        #expect(ids.contains("kok") && ids.contains("sov") && ids.contains("vard") && ids.contains("fasad"))
        #expect(!ids.contains("m"), "montaget ska inte ta ett kökets plats: \(ids)")
        // Med plats över (exakt antal 7 av 8 kandidater) kommer montaget med som extra, efter de fristående.
        let seven = ReelSelector.select(list, count: 7).picks
        #expect(seven.count == 7 && seven.contains { $0.candidateID == "m" } && seven.contains { $0.candidateID == "kok" })
        let pick = try #require(seven.first { $0.candidateID == "m" })
        #expect(pick.reason.hasPrefix("Montage: Hall och Kök, poäng "), "\(pick.reason)")
    }

    @Test("Saknas en fristående bild av montagets rumstyp tar montaget typens plats")
    func montageWhenNoStandalone() {
        var list = villa().filter { $0.id != "kok" }
        list.append(cand("m", room: "Kök", q: 0.8, axis: 9, panelRooms: ["Kök", "Sovrum"]))
        let ids = ReelSelector.select(list).picks.map(\.candidateID)
        #expect(ids.contains("m") && ids.contains("sov"))        // sovrummet är fortfarande en egen plats
    }

    @Test("Dubblett: en fristående bild vinner över ett montage och montaget förklaras")
    func standaloneBeatsMontageDuplicate() throws {
        var list = villa()
        var m = cand("m", room: "Uteplats", q: 0.99, axis: 3, panelRooms: ["Kök", "Uteplats"])   // samma feature print som "kok"
        m.filename = "1.jpg"
        list.append(m)
        let sel = ReelSelector.select(list)
        #expect(!sel.picks.contains { $0.candidateID == "m" })
        let ex = try #require(sel.excluded.first { $0.candidateID == "m" })
        #expect(ex.kind == .duplicate && ex.reason == "Visar samma som kok.jpg")
    }

    @Test("Exakt antal: montaget är en plats")
    func montageWithFixedCount() {
        var list = villa()
        list.append(cand("m", room: "Kök", q: 0.95, axis: 9, panelRooms: ["Kök", "Sovrum"]))
        let sel = ReelSelector.select(list, count: 8)
        #expect(sel.picks.count == 8 && sel.picks.contains { $0.candidateID == "m" })
    }

    @Test("Ett montage öppnar inte filmen när en enskild hjältebild finns, och horisonten räknas inte för det")
    func montageNotOpening() {
        var list = [cand("vard", room: "Vardagsrum", q: 0.6, axis: 2),
                    cand("kok", room: "Kök", q: 0.6, axis: 3),
                    cand("sov", room: "Sovrum", q: 0.6, axis: 4)]
        list.append(cand("m", room: "Vardagsrum", q: 0.99, axis: 9, panelRooms: ["Vardagsrum", "Hall"]))
        let sel = ReelSelector.select(list)
        #expect(sel.picks.first?.candidateID != "m")
        #expect(sel.picks.contains { $0.candidateID == "m" })
        // Horisonten lutar 8°, men ett montage med exteriör huvudhalva filtreras inte bort på den.
        let ext = cand("mx", room: "Uteplats", q: 0.8, axis: 12, horizon: 8, panelRooms: ["Hall", "Uteplats"])
        #expect(ReelSelector.select(villa() + [ext]).excluded.contains { $0.candidateID == "mx" } == false)
        let plainExt = cand("px", room: "Uteplats", q: 0.8, axis: 13, horizon: 8)
        #expect(ReelSelector.select(villa() + [plainExt]).excluded.contains { $0.candidateID == "px" && $0.kind == .horizon })
    }

    // MARK: - Planering

    private func montageImage(_ id: String = "m", aspect: (w: Int, h: Int) = (5315, 3543)) -> ReelMotionPlanner.Image {
        var image = ReelMotionPlanner.Image(assetID: id, width: aspect.w, height: aspect.h, focus: .init(x: 0.5, y: 0.5),
                                            salientWidth: 0.9, isExterior: false)
        image.panels = [.init(x: 0, y: 0, w: 0.4935, h: 1), .init(x: 0.5065, y: 0, w: 0.4935, h: 1)]
        return image
    }

    private func plain(_ id: String) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: 6000, height: 4000, focus: .init(x: 0.5, y: 0.5), salientWidth: 0.3, isExterior: false)
    }

    @Test("9:16: montaget blir ett rutklipp (sequence) med två halvor som fyller ramen")
    func verticalSequence() throws {
        let clips = ReelMotionPlanner.plan([plain("a"), montageImage(), plain("b")], frameAspect: vertical)
        let clip = clips[1]
        #expect(clip.fit == .panels && clip.layout == .sequence && clip.asset == "m")
        #expect(clip.motionPreset == nil)               // automatiskt, inte låst
        let panels = try #require(clip.panels)
        #expect(panels.count == 2 && panels.allSatisfy { $0.asset == "m" })
        #expect(panels[0].source == montageImage().panels[0] && panels[1].source == montageImage().panels[1])
        #expect(clip.motion == panels[0].motion)
        #expect(clip.gutter == nil && clip.entrance == nil)
        // Rörelsen ligger inom varje halva (mittpunkt och utsnitt), zoom in på första, ut på andra.
        for panel in panels {
            let s = try #require(panel.source)
            for key in [panel.motion.from, panel.motion.to] {
                #expect(key.cx >= s.x && key.cx <= s.x + s.w && key.cy >= s.y && key.cy <= s.y + s.h)
                let crop = ReelTimeline.panelCrop(imageSize: CGSize(width: 5315, height: 3543), source: s, destAspect: vertical,
                                                  center: CGPoint(x: key.cx, y: key.cy), zoom: key.zoom)
                #expect(crop.minX >= s.x - 1e-9 && crop.maxX <= s.x + s.w + 1e-9 && crop.minY >= s.y - 1e-9 && crop.maxY <= s.y + s.h + 1e-9)
            }
        }
        #expect(panels[0].motion.to.zoom > panels[0].motion.from.zoom)
        #expect(panels[1].motion.to.zoom < panels[1].motion.from.zoom)
        #expect(abs(panels[0].motion.to.zoom - panels[1].motion.from.zoom) < 1e-9)   // skjutningen går mellan lika inzoomade bilder
        // Längd: 2 × 1,8 s.
        #expect(abs(clip.duration - 3.6) < 1e-9)
        // Grannarna är vanliga klipp, och övergången in till montaget är automatisk.
        #expect(clips[0].fit != .panels && clips[2].fit != .panels)
        #expect(clip.transitionIn != nil)
    }

    @Test("1:1: också ett rutklipp, och halvan beskärs bara i höjd (ramen är bredare än halvan)")
    func squareSequence() throws {
        let clip = ReelMotionPlanner.plan([montageImage()], frameAspect: square)[0]
        #expect(clip.fit == .panels && clip.layout == .sequence)
        let panel = try #require(clip.panels?.first)
        let s = try #require(panel.source)
        let crop = ReelTimeline.panelCrop(imageSize: CGSize(width: 5315, height: 3543), source: s, destAspect: square,
                                          center: CGPoint(x: panel.motion.from.cx, y: panel.motion.from.cy), zoom: panel.motion.from.zoom)
        #expect(abs(crop.width - s.w) < 1e-9 && crop.height < s.h)
    }

    @Test("16:9: ett vanligt klipp utan rutor")
    func landscapePlain() {
        let clip = ReelMotionPlanner.plan([montageImage()], frameAspect: landscape)[0]
        #expect(clip.fit != .panels && clip.panels == nil && clip.layout == nil)
        #expect(clip.asset == "m")
        // En montagebild i liggande ram är en vanlig bild: ramen är bredare än halvorna tillsammans.
        #expect(!ReelMotionPlanner.isMontageSequence(montageImage(), frameAspect: landscape, override: nil))
        #expect(ReelMotionPlanner.isMontageSequence(montageImage(), frameAspect: vertical, override: nil))
        #expect(ReelMotionPlanner.isMontageSequence(montageImage(), frameAspect: square, override: nil))
    }

    @Test("Längd: skalas med tempo, och en låst längd gäller hela klippet")
    func duration() {
        for (tempo, expected) in [(ReelMotionPlanner.Tempo.calm, 4.32), (.normal, 3.6), (.fast, 3.06)] {
            let clip = ReelMotionPlanner.plan([montageImage()], frameAspect: vertical, tempo: tempo)[0]
            #expect(abs(clip.duration - expected) < 1e-9)
        }
        var o = ReelMotionPlanner.ClipOverride()
        o.duration = 5
        let locked = ReelMotionPlanner.plan([montageImage()], frameAspect: vertical, overrides: ["m": o], tempo: .fast)[0]
        #expect(locked.duration == 5 && locked.durationLocked == true && locked.fit == .panels)
    }

    @Test("Ett eget förval på bilden (zooma in, hela bilden, egen rörelse) gäller hela bilden: inget rutklipp")
    func presetWins() {
        for preset in [ReelMotionPlanner.Preset.zoomIn, .zoomOut, .panRight, .contain] {
            var o = ReelMotionPlanner.ClipOverride()
            o.preset = preset
            let clip = ReelMotionPlanner.plan([montageImage()], frameAspect: vertical, overrides: ["m": o])[0]
            #expect(clip.fit != .panels, "\(preset)")
        }
        // Ett låst rutklipp (custom) behålls som det är, också i 16:9.
        let planned = ReelMotionPlanner.plan([montageImage()], frameAspect: vertical)[0]
        var o = ReelMotionPlanner.ClipOverride()
        o.panels = .init(layout: .sequence, panels: planned.panels ?? [], gutter: nil, entrance: nil)
        let kept = ReelMotionPlanner.plan([montageImage()], frameAspect: landscape, overrides: ["m": o])[0]
        #expect(kept.fit == .panels && kept.panels == planned.panels && kept.motionPreset == "custom")
    }

    @Test("Ett montage med bara en halva eller trasiga rutor är aldrig ett rutklipp")
    func invalidPanels() {
        var one = montageImage()
        one.panels = [one.panels[0]]
        #expect(ReelMotionPlanner.plan([one], frameAspect: vertical)[0].fit != .panels)
        var bad = montageImage()
        bad.panels[1].w = 0
        #expect(ReelMotionPlanner.plan([bad], frameAspect: vertical)[0].fit != .panels)
    }

    @Test("Tidslinjen visar halvorna efter varandra: vänster, intern skjutning, höger")
    func timelineShowsHalves() throws {
        let result = composeWithMontage(format: .vertical)
        let spec = result.spec
        let index = try #require(spec.timeline.firstIndex { $0.fit == .panels })
        let start = ReelTimeline.clipStarts(spec)[index]
        let clip = spec.timeline[index]
        let size = CGSize(width: 270, height: 480)
        func layers(_ t: Double) -> [ReelTimeline.LayerState] {
            ReelTimeline.state(at: t, spec: spec, outputSize: size).filter { $0.panel != nil }
        }
        // Klippets mitt (inom den interna skjutningen): två lager. Början: bara vänster halva. Slutet: bara höger.
        // (Övergången in till klippet ligger i dess första 0,5 s; mät efter den.)
        let first = layers(start + 0.6)
        #expect(first.count == 1 && first[0].panel?.index == 0)
        let mid = layers(start + clip.duration / 2)
        #expect(mid.count == 2)
        let last = layers(start + clip.duration - 0.05)
        #expect(last.count == 1 && last[0].panel?.index == 1)
        let left = try #require(clip.panels?[0].source), right = try #require(clip.panels?[1].source)
        #expect(first[0].crop.maxX <= left.x + left.w + 1e-9)
        #expect(last[0].crop.minX >= right.x - 1e-9)
    }

    // MARK: - Komposition, formatbyte, lås

    private let base = URL(fileURLWithPath: "/Users/test/Objekt/Chronas väg 7", isDirectory: true)
    private var specDir: URL { base.appendingPathComponent("Chronas väg 7 FILM", isDirectory: true) }

    private func item(_ n: Int, room: String, category: String = "Interiör", q: Double, montage: Bool = false) -> ReelImageAnalyzer.Item {
        var a = ObjektfilmTestKit.analysis(n + 100, room: room, category: category, q: q,
                                           width: montage ? 5315 : 6000, height: montage ? 3543 : 4000)
        a.featurePrint = vec(n).withUnsafeBytes { Data($0) }
        a.salientWidth = 0.4
        if montage {
            a.panels = [.init(x: 0, y: 0, w: 0.4935, h: 1), .init(x: 0.5065, y: 0, w: 0.4935, h: 1)]
            a.panelRooms = [.init(room: "Hall", category: "Interiör", caption: "Hall"),
                            .init(room: "Uteplats", category: "Exteriör", caption: "Altan")]
            ReelImageAnalyzer.applyPanelRooms(to: &a)
        }
        return .init(url: base.appendingPathComponent("Chronas väg 7 red/\(n).jpg"), analysis: a)
    }

    private func items() -> [ReelImageAnalyzer.Item] {
        [item(0, room: "Vardagsrum", q: 0.85),
         item(1, room: "Kök", q: 0.8),
         item(2, room: "Hall", category: "Interiör", q: 0.9, montage: true),
         item(3, room: "Sovrum", q: 0.75),
         item(4, room: "Badrum", q: 0.7)]
    }

    private func composeWithMontage(format: ReelFormat, count: Int? = 5) -> ReelComposer.Result {
        var options = ReelComposer.Options()
        options.format = format
        options.count = count
        options.curated = true
        return ReelComposer.compose(items: items(), specDirectory: specDir, options: options)
    }

    @Test("compose i 9:16: montaget blir ett rutklipp, asseten bär panels och rum, specen är v2")
    func composeVertical() throws {
        let result = composeWithMontage(format: .vertical)
        let spec = result.spec
        let montage = try #require(spec.assets.first { $0.analysis?.panels != nil })
        #expect(montage.analysis?.panels?.count == 2)
        #expect(montage.analysis?.panelRooms == ["Hall", "Uteplats"])
        #expect(montage.analysis?.room == "Uteplats")        // viktigaste halvans rum
        let clip = try #require(spec.timeline.first { $0.asset == montage.id })
        #expect(clip.fit == .panels && clip.layout == .sequence && clip.panels?.count == 2)
        #expect(spec.version == 2 && spec.minReaderVersion == 2)
        #expect(spec.timeline.filter { $0.fit == .panels }.count == 1)
        #expect(try ReelSpec.decode(from: try spec.jsonData()) == spec)
        // Motiveringen i urvalet.
        let reason = try #require(spec.provenance.autoSelection?.first { $0.asset == montage.id }?.reason)
        #expect(reason.contains("Hall och Uteplats"), "\(reason)")
    }

    @Test("compose i 16:9: samma urval, men montaget är ett vanligt klipp och specen v1")
    func composeLandscape() throws {
        let spec = composeWithMontage(format: .landscape).spec
        #expect(spec.timeline.allSatisfy { $0.fit != .panels })
        #expect(spec.version == 1 && spec.minReaderVersion == 1)
        #expect(spec.assets.contains { $0.analysis?.panels != nil })          // analysen följer med för nästa formatbyte
    }

    @Test("Formatbyte fram och tillbaka: automatiska rutklipp följer formatet, specversionen följer med")
    func formatRoundTrip() throws {
        let vertical = composeWithMontage(format: .vertical).spec
        let order = vertical.timeline.map(\.asset)
        let landscape = ReelComposer.rebuild(vertical, order: order, format: .landscape)
        #expect(landscape.timeline.allSatisfy { $0.fit != .panels })
        #expect(landscape.version == 1 && landscape.minReaderVersion == 1)
        let square = ReelComposer.rebuild(landscape, order: order, format: .square)
        #expect(square.timeline.filter { $0.fit == .panels }.count == 1 && square.version == 2)
        let back = ReelComposer.rebuild(square, order: order, format: .vertical)
        #expect(back.timeline == vertical.timeline)
        #expect(back.assets == vertical.assets)
    }

    @Test("Automatiskt rutklipp läses inte som lås, men ett custom-rutklipp är fotografens och står kvar")
    func autoVersusLocked() throws {
        let vertical = composeWithMontage(format: .vertical).spec
        #expect(ReelComposer.overrides(in: vertical).isEmpty)
        #expect(ReelChoiceSummary.summary(vertical).lockedChoices == 0)
        // Fotografen har ändrat något (custom): klippet blir ett lås som överlever formatbyte.
        var edited = vertical
        let i = try #require(edited.timeline.firstIndex { $0.fit == .panels })
        edited.timeline[i].motionPreset = ReelMotionPlanner.Preset.custom.rawValue
        let o = ReelComposer.overrides(in: edited)
        #expect(o[edited.timeline[i].asset]?.panels?.layout == .sequence)
        let landscape = ReelComposer.rebuild(edited, order: edited.timeline.map(\.asset), format: .landscape)
        #expect(landscape.timeline[i].fit == .panels && landscape.timeline[i].panels == edited.timeline[i].panels)
        // En längd som fotografen låst gäller även när klippet planeras om i ett annat format.
        var longer = vertical
        longer.timeline[i].duration = 6
        longer.timeline[i].durationLocked = true
        let square = ReelComposer.rebuild(longer, order: longer.timeline.map(\.asset), format: .square)
        #expect(square.timeline[i].fit == .panels && square.timeline[i].duration == 6 && square.timeline[i].durationLocked == true)
        // Låst övergång på det automatiska montageklippet följer med.
        var fadeLocked = vertical
        fadeLocked.timeline[i].transitionIn = .init(type: .cut, direction: nil, duration: 0)
        fadeLocked.timeline[i].transitionLocked = true
        let rebuilt = ReelComposer.rebuild(fadeLocked, order: fadeLocked.timeline.map(\.asset), format: .square)
        #expect(rebuilt.timeline[i].transitionIn?.type == .cut && rebuilt.timeline[i].transitionLocked == true)
    }

    @Test("Förklaringar: motionReasons, sammandrag och rumsrad nämner montaget")
    func explanations() throws {
        let vertical = composeWithMontage(format: .vertical).spec
        let landscape = composeWithMontage(format: .landscape).spec
        func reasons(_ spec: ReelSpec) -> [ReelMotionPlanner.MotionReason] { ReelEditorModel.motionReasons(spec) }
        let i = try #require(vertical.timeline.firstIndex { $0.fit == .panels })
        let v = reasons(vertical)[i]
        guard case .montageSequence(let frame, let whole) = v else { Issue.record("fel skäl: \(v)"); return }
        #expect(abs(frame - vertical.outputs[0].aspectRatio) < 1e-6 && whole > frame)
        #expect(v.text.hasPrefix("Montage:") && v.text.contains("efter varandra") && v.kind == .zoom)
        let montageID = try #require(landscape.assets.first { $0.analysis?.panels != nil }).id
        let j = try #require(landscape.timeline.firstIndex { $0.asset == montageID })
        let l = reasons(landscape)[j]
        guard case .montageWhole = l else { Issue.record("fel skäl: \(l)"); return }
        #expect(l.text.contains("hela montaget") && l.text.hasPrefix("Montage:"))
        // Sammandraget.
        let summary = ReelChoiceSummary.summary(vertical)
        #expect(summary.rows[i].room == "Montage: Hall och Uteplats")
        #expect(summary.rows[i].motion == "Montage: halvorna efter varandra")
        #expect(summary.rows[i].locked == false)
        #expect(ReelChoiceSummary.summary(landscape).rows[j].room == "Montage: Hall och Uteplats")
    }

    @Test("Ett förval på montagebilden (zooma in) i det smala formatet ger ett vanligt klipp och ett eget skäl")
    func presetReason() throws {
        let vertical = composeWithMontage(format: .vertical).spec
        let i = try #require(vertical.timeline.firstIndex { $0.fit == .panels })
        var o = ReelMotionPlanner.ClipOverride()
        o.preset = .zoomIn
        let rebuilt = ReelComposer.rebuild(vertical, order: vertical.timeline.map(\.asset), overrides: [vertical.timeline[i].asset: o])
        #expect(rebuilt.timeline[i].fit == .cover && rebuilt.timeline[i].motionPreset == "zoomIn")
        #expect(rebuilt.version == 1)
        #expect(ReelEditorModel.motionReasons(rebuilt)[i] == .chosenByUser)
    }
}

private extension ReelSpec.Output {
    var aspectRatio: Double { Double(width) / Double(height) }
}
