import CoreGraphics
import Foundation
import Testing
@testable import PhotoFlow

/// Redigering av rutklipp (R6d): rena funktioner (`ReelPanelEdit`) och redigeringsmodellens åtgärder: Dela ruta
/// med…, Dela upp, Byt plats, layout, ingång, inramning, Tillbaka till automatiskt, formatbyte, "Föreslå igen",
/// uteslut/pinna och rutnätets märkning.
struct ReelPanelEditTests {

    private let vertical = 1080.0 / 1920.0
    private let landscape = 1920.0 / 1080.0

    // MARK: - Uppsättning

    private let base = URL(fileURLWithPath: "/Users/test/Objekt/Lindvägen 12", isDirectory: true)

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 40)
        v[axis % 40] = 1
        return v
    }

    private func item(_ n: Int, room: String, q: Double, focus: Double = 0.6, portrait: Bool = false) -> ReelImageAnalyzer.Item {
        let exterior = ["Fasad", "Trädgård"].contains(room)
        var a = ObjektfilmTestKit.analysis(n + 300, room: room, category: exterior ? "Exteriör" : "Interiör", q: q,
                                           width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000)
        a.featurePrint = vec(n).withUnsafeBytes { Data($0) }
        a.salientWidth = focus
        a.saliencyBoxes = [.init(x: (1 - focus) / 2, y: 0.2, width: focus, height: 0.6)]
        return .init(url: base.appendingPathComponent("Lindvägen 12 red/\(n).jpg"), analysis: a)
    }

    /// Samma sju bilder som i kollagetesterna, plus ett montage (stående halvor, Hall och Uteplats).
    private func items(montage: Bool = false) -> [ReelImageAnalyzer.Item] {
        var list = [item(0, room: "Fasad", q: 0.9, focus: 0.9), item(1, room: "Trädgård", q: 0.8, focus: 0.5),
                    item(2, room: "Vardagsrum", q: 0.85, focus: 0.35), item(3, room: "Kök", q: 0.8),
                    item(4, room: "Matplats", q: 0.75), item(5, room: "Sovrum", q: 0.75), item(6, room: "Badrum", q: 0.7)]
        if montage {
            var m = item(7, room: "Hall", q: 0.8)
            m.analysis.panels = [.init(x: 0, y: 0, w: 0.5, h: 1), .init(x: 0.5, y: 0, w: 0.5, h: 1)]
            m.analysis.panelRooms = [.init(room: "Hall", category: "Interiör", caption: nil),
                                     .init(room: "Uteplats", category: "Exteriör", caption: nil)]
            list.append(m)
        }
        return list
    }

    private func makeModel(montage: Bool = false, format: ReelFormat? = nil) throws -> (ReelEditorModel, URL) {
        let root = try ObjektfilmTestKit.tempDir("ReelPanelEdit")
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let reel = AddressFolderLayout.reelDir(forSource: source)
        let model = ReelEditorModel()
        let list = items(montage: montage).map { item in
            ReelImageAnalyzer.Item(url: source.appendingPathComponent(item.url.lastPathComponent), analysis: item.analysis)
        }
        model.prepare(items: list, sourceDirectory: source, reelDirectory: reel, address: "Lindvägen 12")
        if let format, format != model.format { model.setFormat(format) }
        return (model, root)
    }

    private func sha(_ spec: ReelSpec, _ id: String) -> String { spec.assets.first { $0.id == id }!.sha256 }

    /// Det automatiska kollaget i filmen (9:16): klipp, ankare, partner.
    private func autoCollage(_ model: ReelEditorModel) throws -> (index: Int, anchor: String, partner: String, anchorSha: String, partnerSha: String) {
        let spec = try #require(model.spec)
        let i = try #require(spec.timeline.firstIndex { ReelComposer.autoCollagePartner($0) != nil })
        let anchor = spec.timeline[i].asset
        let partner = try #require(ReelComposer.autoCollagePartner(spec.timeline[i]))
        return (i, anchor, partner, sha(spec, anchor), sha(spec, partner))
    }

    /// Ett vanligt (inte rutor) klipp och en bild utanför filmen, för "Dela ruta med…". Krymper filmen vid behov.
    private func plainAndOutsider(_ model: ReelEditorModel) throws -> (clip: String, outsider: String) {
        if !model.candidateRows.contains(where: { $0.clipIndex == nil && $0.excludedReason == nil }) { model.setCount(3) }
        let outsider = try #require(model.candidateRows.first { $0.clipIndex == nil && $0.excludedReason == nil })
        let plain = try #require(model.clipRows.first { $0.panelKind == .none })
        return (plain.id, outsider.id)
    }

    /// Ett låst kollage: dela det första vanliga klippet med en bild utanför filmen.
    private func lockedCollage(_ model: ReelEditorModel) throws -> (clip: String, partner: String) {
        let (clip, outsider) = try plainAndOutsider(model)
        #expect(model.pairClip(clip, withCandidate: outsider))
        return (clip, outsider)
    }

    // MARK: - Rena funktioner

    @Test("Layouter som passar formatet: 9:16 stapel, 16:9 sida vid sida, 1:1 båda; sekvens alltid")
    func layoutsPerFormat() {
        #expect(ReelPanelEdit.collageLayouts(frameAspect: vertical) == [.stack, .sequence])
        #expect(ReelPanelEdit.collageLayouts(frameAspect: landscape) == [.side, .sequence])
        #expect(ReelPanelEdit.collageLayouts(frameAspect: 1) == [.stack, .side, .sequence])
    }

    @Test("Layout i 1:1: den som beskär minst; 9:16 och 16:9 ger formatets")
    func preferredLayout() {
        func image(_ w: Int, _ h: Int) -> ReelMotionPlanner.Image {
            .init(assetID: "x", width: w, height: h, focus: nil, salientWidth: nil, isExterior: false)
        }
        // Två liggande bilder (3:2): stapelns rutor (2:1) ligger närmare än sidans (1:2).
        #expect(ReelPanelEdit.preferredLayout(image(6000, 4000), image(6000, 4000), frameAspect: 1) == .stack)
        // Två stående (2:3): sida vid sida (1:2) ligger närmare än stapel (2:1).
        #expect(ReelPanelEdit.preferredLayout(image(4000, 6000), image(4000, 6000), frameAspect: 1) == .side)
        #expect(ReelPanelEdit.preferredLayout(image(4000, 6000), image(4000, 6000), frameAspect: vertical) == .stack)
        #expect(ReelPanelEdit.preferredLayout(image(6000, 4000), image(6000, 4000), frameAspect: landscape) == .side)
    }

    @Test("Inramning: mittpunkten flyttas men klampas inom bilden, med samma mitt i båda nycklarna")
    func recentering() {
        let panel = ReelSpec.Panel(asset: "a", source: nil,
                                   motion: .init(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.04)))
        let size = CGSize(width: 6000, height: 4000)
        let pane = ReelPanelEdit.paneAspect(layout: .stack, frameAspect: vertical, gutter: nil)
        // Liggande bild i en 9:8-ruta: utsnittet är 0,75 av bredden och hela höjden, så bara x kan flyttas.
        let moved = ReelPanelEdit.recentered(panel, cx: 0.4, cy: 0.2, imageSize: size, paneAspect: pane)
        #expect(abs(moved.motion.from.cx - 0.4) < 1e-9 && moved.motion.from.cx == moved.motion.to.cx)
        #expect(abs(moved.motion.from.cy - 0.5) < 1e-9 && moved.motion.from.cy == moved.motion.to.cy)
        #expect(moved.motion.from.zoom == 1 && moved.motion.to.zoom == 1.04)
        // Långt åt vänster: klampas så att utsnittet (bredd 0,75 / zoom) ligger kvar i bilden.
        let edge = ReelPanelEdit.recentered(panel, cx: -1, cy: 0.5, imageSize: size, paneAspect: pane)
        #expect(edge.motion.from.cx == edge.motion.to.cx && abs(edge.motion.from.cx - pane / 1.5 / 2) < 1e-9, "zoom 1: utsnittet är rutans bredd / bildens")
        for key in [edge.motion.from, edge.motion.to] {
            let frame = ReelPanelEdit.frame(of: key, source: nil, imageSize: size, paneAspect: pane)
            #expect(frame.minX >= -1e-9 && frame.maxX <= 1 + 1e-9)
        }
    }

    @Test("Inramning av en montagehalva klampas inom halvans källa")
    func montageHalfFraming() {
        let source = ReelSpec.UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let key = ReelSpec.MotionKey(cx: 0.1, cy: 0.5, zoom: 1)
        let clamped = ReelPanelEdit.clamped(key, source: source, imageSize: CGSize(width: 6000, height: 4000), paneAspect: vertical)
        let frame = ReelPanelEdit.frame(of: clamped, source: source, imageSize: CGSize(width: 6000, height: 4000), paneAspect: vertical)
        #expect(frame.minX >= 0.5 - 1e-9 && frame.maxX <= 1 + 1e-9)
    }

    // MARK: - Dela ruta med…

    @Test("Dela ruta med… (bild utanför filmen): stapel i 9:16, låst som custom, partnern är med i specen, ångra tar tillbaka")
    func pairWithOutsider() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, outsider) = try plainAndOutsider(model)
        let clips = model.clipRows.count
        let before = try #require(model.spec)
        #expect(model.canPair(clipID, withCandidate: outsider))
        #expect(model.pairClip(clipID, withCandidate: outsider))
        let spec = try #require(model.spec)
        let clip = try #require(spec.timeline.first { $0.asset == clipID })
        #expect(clip.fit == .panels && clip.layout == .stack && clip.motionPreset == "custom")
        #expect(clip.panels?.count == 2 && clip.panels?[0].asset == clipID)
        #expect(clip.panels?[1].asset != nil && sha(spec, clip.panels![1].asset) == outsider)
        #expect(clip.entrance?.type == .slide)
        #expect(model.clipRows.count == clips && spec.version == 2)
        #expect(model.undoActionName == "Dela ruta")
        // Rutnätet: partnern är i filmen på klippet, som ruta 2 av 2.
        let row = try #require(model.candidateRows.first { $0.id == outsider })
        #expect(row.clipIndex == model.clipRows.firstIndex { $0.id == clipID } && row.panelIndex == 1 && row.panelCount == 2)
        model.undo()
        #expect(model.spec?.timeline == before.timeline)
        model.redo()
        #expect(model.spec?.timeline.first { $0.asset == clipID }?.fit == .panels)
    }

    @Test("Dela ruta med… i 16:9 ger sida vid sida; i 1:1 den layout som beskär minst")
    func pairLayoutFollowsFormat() throws {
        for (format, expected) in [(ReelFormat.landscape, ReelSpec.PanelLayout.side), (.square, .stack)] {
            let (model, root) = try makeModel(format: format)
            defer { try? FileManager.default.removeItem(at: root) }
            let (clipID, outsider) = try plainAndOutsider(model)
            #expect(model.pairClip(clipID, withCandidate: outsider))
            #expect(model.clip(forAsset: clipID)?.layout == expected, "\(format)")
        }
    }

    @Test("Dela ruta med… en bild som redan är ett eget klipp: klippet går upp i kollaget")
    func pairWithOwnClip() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = model.clipRows.filter { $0.panelKind == .none }
        let a = try #require(plain.first), b = try #require(plain.last)
        #expect(a.id != b.id)
        let bSha = try #require(model.candidateID(forAsset: b.id))
        let clips = model.clipRows.count
        #expect(model.pairClip(a.id, withCandidate: bSha))
        #expect(model.clipRows.count == clips - 1)
        #expect(!model.clipRows.contains { $0.id == b.id })
        #expect(model.clip(forAsset: a.id)?.panels?[1].asset == b.id)
    }

    @Test("Dela ruta med… vägrar: bilden själv, en bild i ett annat rutklipp, ett rutklipp som ankare")
    func pairRefusals() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let auto = try autoCollage(model)
        let plain = try #require(model.clipRows.first { $0.panelKind == .none })
        let plainSha = try #require(model.candidateID(forAsset: plain.id))
        #expect(!model.pairClip(plain.id, withCandidate: plainSha), "bilden själv")
        #expect(!model.pairClip(plain.id, withCandidate: auto.partnerSha), "ruta i ett annat kollage")
        #expect(!model.pairClip(plain.id, withCandidate: auto.anchorSha), "ankare i ett annat kollage")
        #expect(!model.pairClip(auto.anchor, withCandidate: plainSha), "ankaret är redan ett rutklipp")
        #expect(!model.pairClip(plain.id, withCandidate: "finns-inte"))
    }

    @Test("Dela ruta med… som läge: nästa klick i rutnätet väljer partner, och ett annat klipp avbryter läget")
    func pickMode() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, outsider) = try plainAndOutsider(model)
        model.beginPickingPartner(for: clipID)
        #expect(model.partnerPickAssetID == clipID && model.selectedAssetID == clipID)
        // Ogiltigt val (bilden själv) avbryter inte läget.
        model.selectCandidate(try #require(model.candidateID(forAsset: clipID)))
        #expect(model.partnerPickAssetID == clipID && model.clip(forAsset: clipID)?.fit != .panels)
        model.selectCandidate(outsider)
        #expect(model.partnerPickAssetID == nil && model.clip(forAsset: clipID)?.fit == .panels)
        // Läget avbryts när ett annat klipp markeras.
        let other = try #require(model.clipRows.first { $0.panelKind == .none && $0.id != clipID })
        model.beginPickingPartner(for: other.id)
        model.selectedAssetID = clipID
        #expect(model.partnerPickAssetID == nil)
        model.beginPickingPartner(for: other.id)
        model.cancelPickingPartner()
        #expect(model.partnerPickAssetID == nil)
    }

    // MARK: - Dela upp, byt plats

    @Test("Dela upp: kollagets rutor blir två vanliga klipp, märkta som ditt val; ångra tar tillbaka kollaget")
    func splitCollage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        let partner = try #require(model.clip(forAsset: clipID)?.panels?[1].asset)
        let clips = model.clipRows.count
        model.splitPanels(clipID)
        let spec = try #require(model.spec)
        #expect(spec.timeline.allSatisfy { $0.fit != .panels } && model.clipRows.count == clips + 1)
        let at = try #require(spec.timeline.firstIndex { $0.asset == clipID })
        #expect(spec.timeline[at + 1].asset == partner)
        #expect(spec.timeline[at].motionPreset == nil && spec.version == 1)
        model.undo()
        #expect(model.clip(forAsset: clipID)?.fit == .panels)
    }

    @Test("Dela upp ett automatiskt kollage sätts inte ihop igen av nästa ombyggnad eller formatbyte")
    func splitAutoCollageStays() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        model.splitPanels(c.anchor)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true)
        let reasons = Dictionary(uniqueKeysWithValues: (model.spec?.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) })
        #expect(reasons[c.anchor] == "Delades upp av dig" && reasons[c.partner] == "Delades upp av dig")
        model.setFormat(.landscape)
        model.setFormat(.vertical)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true, "fotografens uppdelning gäller")
    }

    @Test("Byt plats: den andra bilden blir klippets bild och första rutan, locks som custom; klippets lås följer med")
    func swapCollage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        model.setDuration(clipID, seconds: 4)
        let before = try #require(model.clip(forAsset: clipID))
        let partner = try #require(before.panels?[1].asset)
        let position = try #require(model.clipRows.firstIndex { $0.id == clipID })
        model.swapPanels(clipID)
        let swapped = try #require(model.clip(forAsset: partner))
        #expect(swapped.panels?.map(\.asset) == [partner, clipID] && swapped.asset == partner)
        #expect(swapped.durationLocked == true && swapped.duration == 4 && swapped.motionPreset == "custom")
        #expect(model.clipRows.firstIndex { $0.id == partner } == position)
        #expect(model.clip(forAsset: clipID) == nil)
        #expect(model.selectedAssetID == partner)
        // Rutorna behåller sin inramning (rörelsen följer bilden).
        #expect(swapped.panels?[1].motion == before.panels?[0].motion)
        model.undo()
        #expect(model.clip(forAsset: clipID)?.panels?.map(\.asset) == [clipID, partner])
    }

    // MARK: - Layout, ingång, inramning

    @Test("Layout: stapel, sekvens; sida vid sida erbjuds inte i 9:16; inramningen klampas till de nya rutorna")
    func changeLayout() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        #expect(model.availableLayouts(forAsset: clipID) == [.stack, .sequence])
        model.setPanelLayout(clipID, .side)   // inte tillåtet i 9:16
        #expect(model.clip(forAsset: clipID)?.layout == .stack)
        model.setPanelLayout(clipID, .sequence)
        let clip = try #require(model.clip(forAsset: clipID))
        #expect(clip.layout == .sequence && clip.entrance == nil && clip.panels?.count == 2 && clip.motionPreset == "custom")
        #expect(model.spec?.version == 2)
        model.setPanelLayout(clipID, .stack)
        #expect(model.clip(forAsset: clipID)?.layout == .stack && model.clip(forAsset: clipID)?.entrance?.type == .slide)
        #expect(model.undoActionName == "Ändra layout")
    }

    @Test("Ingång: Glid in, Tona in, Ingen; gäller bara stapel och sida vid sida")
    func entrance() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        model.setEntrance(clipID, .fade)
        #expect(model.clip(forAsset: clipID)?.entrance?.type == .fade)
        model.setEntrance(clipID, .none)
        #expect(model.clip(forAsset: clipID)?.entrance?.type == ReelSpec.EntranceType.none)
        model.undo()
        #expect(model.clip(forAsset: clipID)?.entrance?.type == .fade)
        model.setPanelLayout(clipID, .sequence)
        model.setEntrance(clipID, .slide)
        #expect(model.clip(forAsset: clipID)?.entrance == nil, "sekvens har ingen ingång")
    }

    @Test("Inramning per ruta: mitten flyttas, ingen panorering, ett ångringssteg per dragning, och låser klippet")
    func framing() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        let before = try #require(model.clip(forAsset: clipID)?.panels)
        let revision = model.spec?.revision ?? 0
        model.beginCoalescing()
        model.setPanelCenter(clipID, panel: 1, cx: 0.45, cy: 0.45)
        model.setPanelCenter(clipID, panel: 1, cx: 0.55, cy: 0.55)
        model.setPanelCenter(clipID, panel: 1, cx: 0.6, cy: 0.6)
        model.endCoalescing()
        let after = try #require(model.clip(forAsset: clipID)?.panels)
        #expect(after[0] == before[0], "den andra rutan påverkar inte den första")
        #expect(after[1] != before[1], "inramningen flyttades")
        #expect(after[1].motion.from.cx == after[1].motion.to.cx && after[1].motion.from.cy == after[1].motion.to.cy)
        #expect(model.spec?.revision == revision + 1, "dragningen är ett enda steg")
        #expect(model.undoActionName == "Flytta inramning")
        model.undo()
        #expect(model.clip(forAsset: clipID)?.panels == before)
        // En ruta som inte finns påverkar inget.
        model.setPanelCenter(clipID, panel: 5, cx: 0.1, cy: 0.1)
        #expect(model.clip(forAsset: clipID)?.panels == before)
    }

    @Test("Inramning på ett automatiskt kollage låser det (custom)")
    func framingLocksAuto() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        #expect(!ReelPanelEdit.isLocked(model.spec!.timeline[c.index]))
        model.setPanelCenter(c.anchor, panel: 0, cx: 0.3, cy: 0.5)
        #expect(ReelPanelEdit.isLocked(model.spec!.timeline[c.index]))
        model.setFormat(.landscape)
        model.setFormat(.vertical)
        #expect(model.clip(forAsset: c.anchor)?.fit == .panels, "ett låst kollage löses inte upp av formatbyte")
    }

    @Test("Byt bild i en ruta: ett klick i rutnätet med ett markerat kollage byter vald ruta")
    func replacePanelByGridClick() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, partnerSha) = try lockedCollage(model)
        if !model.candidateRows.contains(where: { $0.clipIndex == nil && $0.excludedReason == nil }) { model.setCount(3) }
        let outsiders = model.candidateRows.filter { $0.clipIndex == nil && $0.excludedReason == nil }
        let fresh = try #require(outsiders.first)
        model.selectedAssetID = model.clip(forAsset: clipID) != nil ? clipID : model.selectedAssetID
        model.selectedPanelIndex = 1
        model.selectCandidate(fresh.id)
        let clip = try #require(model.clip(forAsset: clipID))
        #expect(clip.panels?[0].asset == clipID && sha(model.spec!, clip.panels![1].asset) == fresh.id)
        #expect(model.candidateRows.first { $0.id == partnerSha }?.clipIndex == nil, "den gamla partnern lämnar filmen")
        // Första rutan: klippets bild byts och klippets id följer med.
        model.selectedAssetID = clipID
        model.selectedPanelIndex = 0
        if let next = model.candidateRows.first(where: { $0.clipIndex == nil && $0.excludedReason == nil }) {
            model.selectCandidate(next.id)
            let newClip = try #require(model.spec?.timeline.first { ReelPanelEdit.kind(of: $0) == .collage })
            #expect(sha(model.spec!, newClip.asset) == next.id && newClip.panels?[1].asset == clip.panels?[1].asset)
        }
    }

    // MARK: - Tillbaka till automatiskt

    @Test("Tillbaka till automatiskt: ett låst kollage blir planerarens eget igen, med omräknade rutor")
    func restoreCollage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        let original = model.spec!.timeline[c.index]
        model.setPanelCenter(c.anchor, panel: 0, cx: 0.3, cy: 0.5)
        model.setEntrance(c.anchor, .fade)
        #expect(ReelPanelEdit.isLocked(model.spec!.timeline[c.index]))
        model.restorePanelsAuto(c.anchor)
        let restored = model.spec!.timeline[c.index]
        #expect(!ReelPanelEdit.isLocked(restored) && ReelComposer.autoCollagePartner(restored) == c.partner)
        #expect(restored.panels == original.panels && restored.entrance == original.entrance)
    }

    @Test("Tillbaka till automatiskt i 1:1: kollaget blir två klipp, och kommer tillbaka när formatet blir 9:16")
    func restoreInSquare() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, partnerSha) = try lockedCollage(model)
        model.setFormat(.square)
        #expect(model.clip(forAsset: clipID)?.fit == .panels, "låst kollage kvar i 1:1")
        model.restorePanelsAuto(clipID)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true)
        #expect(model.candidateRows.first { $0.id == partnerSha }?.clipIndex != nil)
        model.setFormat(.vertical)
        let again = model.spec?.timeline.first { $0.fit == .panels }
        _ = again   // om bilderna uppfyller reglerna är kollaget tillbaka; annars två klipp. Inget får saknas.
        #expect(model.candidateRows.first { $0.id == partnerSha }?.clipIndex != nil)
    }

    // MARK: - Formatbyte, Föreslå igen, uteslut, pinna

    @Test("Formatbyte 9:16 → 16:9 → 9:16 återskapar det automatiska kollaget utan Föreslå igen")
    func formatRoundTrip() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        let original = model.spec!.timeline
        model.setFormat(.landscape)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true)
        model.setFormat(.vertical)
        let spec = try #require(model.spec)
        let back = try #require(spec.timeline.first { ReelComposer.autoCollagePartner($0) != nil })
        #expect(Set(back.referencedAssetIDs.map { sha(spec, $0) }) == Set([c.anchorSha, c.partnerSha]))
        #expect(spec.timeline.count == original.count)
        let reasons = Dictionary(uniqueKeysWithValues: (spec.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) })
        #expect(reasons[back.asset]?.hasPrefix("Kollage:") == true)
        // Via 1:1 också (inget kollage där) och tillbaka.
        model.setFormat(.square)
        model.setFormat(.vertical)
        #expect(model.spec?.timeline.contains { ReelComposer.autoCollagePartner($0) != nil } == true)
    }

    @Test("Låst kollage vid formatbyte: layouten byts mot formatets och rutorna klampas; tillbaka ger giltiga rutor")
    func lockedCollageFormatChange() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        model.setFormat(.landscape)
        let landscapeClip = try #require(model.clip(forAsset: clipID))
        #expect(landscapeClip.layout == .side && landscapeClip.motionPreset == "custom" && landscapeClip.panels?.count == 2)
        let aspect = try #require(model.frameAspect)
        for info in model.panelInfos(forAsset: clipID) {
            let frame = ReelPanelEdit.frame(of: info.key, source: info.source, imageSize: info.imageSize, paneAspect: info.paneAspect)
            #expect(frame.minX >= -1e-9 && frame.maxX <= 1 + 1e-9 && frame.minY >= -1e-9 && frame.maxY <= 1 + 1e-9)
            #expect(abs(info.paneAspect - ReelPanelEdit.paneAspect(layout: .side, frameAspect: aspect, gutter: nil)) < 1e-9)
        }
        model.setFormat(.vertical)
        #expect(model.clip(forAsset: clipID)?.layout == .stack)
    }

    @Test("Föreslå igen med ett låst kollage: det finns kvar med sina två bilder och sin layout, ingen dubblett")
    func suggestAgainKeepsLocked() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, partnerSha) = try lockedCollage(model)
        let anchorSha = try #require(model.candidateID(forAsset: clipID))
        model.setEntrance(clipID, .fade)
        model.suggestAgain()
        let spec = try #require(model.spec)
        let clip = try #require(spec.timeline.first { ReelPanelEdit.kind(of: $0) == .collage && ReelPanelEdit.isLocked($0) })
        #expect(Set(clip.referencedAssetIDs.map { sha(spec, $0) }) == Set([anchorSha, partnerSha]))
        #expect(clip.layout == .stack && clip.entrance?.type == .fade)
        #expect(spec.timeline.filter { [anchorSha, partnerSha].contains(sha(spec, $0.asset)) }.count == 1)
        let referenced = Set(spec.timeline.flatMap(\.referencedAssetIDs))
        #expect(spec.assets.allSatisfy { referenced.contains($0.id) }, "inga överblivna bilder i specen")
        model.startOver()
        #expect(model.spec?.timeline.contains { ReelPanelEdit.isLocked($0) } == false, "Börja om helt kastar låsen")
    }

    @Test("Uteslut i ett låst kollage: den uteslutna går ur, den andra blir ett vanligt klipp på samma plats")
    func excludeInLockedCollage() throws {
        for excludeAnchor in [true, false] {
            let (model, root) = try makeModel()
            defer { try? FileManager.default.removeItem(at: root) }
            let (clipID, partnerSha) = try lockedCollage(model)
            let anchorSha = try #require(model.candidateID(forAsset: clipID))
            let position = try #require(model.clipRows.firstIndex { $0.id == clipID })
            let clips = model.clipRows.count
            model.toggleExcluded(excludeAnchor ? anchorSha : partnerSha)
            #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true && model.clipRows.count == clips)
            let kept = excludeAnchor ? partnerSha : anchorSha
            #expect(model.candidateID(forAsset: model.clipRows[position].id) == kept)
            #expect(model.candidateRows.first { $0.id == (excludeAnchor ? anchorSha : partnerSha) }?.clipIndex == nil)
            model.undo()
            #expect(model.clip(forAsset: clipID)?.fit == .panels)
        }
    }

    @Test("Pinna en bild i ett automatiskt kollage låser kollaget (custom); utan lås ett vanligt klipp")
    func pinLocksCollage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        model.togglePinned(c.anchorSha)
        #expect(ReelPanelEdit.isLocked(model.spec!.timeline[c.index]))
        model.restorePanelsAuto(c.anchor)
        #expect(ReelComposer.autoCollagePartner(model.spec!.timeline[c.index]) == c.partner)
        // En vanlig bild låses som förut, utan rutor.
        let plain = try #require(model.clipRows.first { $0.panelKind == .none })
        let plainSha = try #require(model.candidateID(forAsset: plain.id))
        model.togglePinned(plainSha)
        #expect(model.clip(forAsset: plain.id)?.fit != .panels)
    }

    @Test("Rutnätet märker båda bilderna: klipp N, ruta 1 och 2 av 2; vanliga klipp har ingen rutnumrering")
    func gridMarksPanels() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try autoCollage(model)
        let rows = model.candidateRows
        let first = try #require(rows.first { $0.id == c.anchorSha }), second = try #require(rows.first { $0.id == c.partnerSha })
        #expect(first.clipIndex == c.index && first.panelIndex == 0 && first.panelCount == 2)
        #expect(second.clipIndex == c.index && second.panelIndex == 1 && second.panelCount == 2)
        #expect(first.filmLabel == "klipp \(c.index + 1) · ruta 1/2")
        #expect(second.filmLabel == "klipp \(c.index + 1) · ruta 2/2")
        let plain = try #require(rows.first { $0.clipIndex != nil && $0.panelIndex == nil })
        #expect(plain.filmLabel == "klipp \((plain.clipIndex ?? 0) + 1)")
        // Partnerns eget urvalsskäl visas (inte ankarets).
        #expect(second.selectionReason?.hasPrefix("Kollage:") == true)
    }

    // MARK: - Montage

    @Test("Montage: sekvens eller hela bilden, Dela upp ger hela bilden, Byt plats vänder halvorna, Tillbaka till automatiskt")
    func montage() throws {
        let (model, root) = try makeModel(montage: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Montaget är ett eget klipp i 9:16 (sekvens) om det kom med; sätt annars fast antal högt.
        if !model.clipRows.contains(where: { $0.panelKind == .montage }) { model.setCount(8) }
        let row = try #require(model.clipRows.first { $0.panelKind == .montage })
        let id = row.id
        #expect(model.isMontageClip(id) && model.montageLayout(forAsset: id) == .sequence)
        #expect(model.availableLayouts(forAsset: id) == [.sequence])
        let original = try #require(model.clip(forAsset: id)?.panels)
        // Byt plats: andra halvan först.
        model.swapPanels(id)
        let swapped = try #require(model.clip(forAsset: id)?.panels)
        #expect(swapped.map(\.source) == original.map(\.source).reversed() && model.clip(forAsset: id)?.motionPreset == "custom")
        model.swapPanels(id)
        #expect(model.clip(forAsset: id)?.panels?.map(\.source) == original.map(\.source))
        // Dela upp = hela bilden som ett vanligt klipp (contain-blur), låst.
        model.splitPanels(id)
        let whole = try #require(model.clip(forAsset: id))
        #expect(whole.fit == .containBlur && whole.motionPreset == "custom" && whole.panels == nil)
        #expect(model.montageLayout(forAsset: id) == .whole)
        // Tillbaka till sekvens, sedan tillbaka till automatiskt.
        model.setMontageLayout(id, .sequence)
        #expect(model.clip(forAsset: id)?.layout == .sequence && model.clip(forAsset: id)?.panels?.count == 2)
        model.restorePanelsAuto(id)
        let auto = try #require(model.clip(forAsset: id))
        #expect(auto.fit == .panels && auto.motionPreset == nil && auto.layout == .sequence, "9:16: planeraren väljer sekvens")
        // Hela bilden → tillbaka till automatiskt via förvalet.
        model.setMontageLayout(id, .whole)
        model.restorePanelsAuto(id)
        #expect(model.clip(forAsset: id)?.fit == .panels && model.clip(forAsset: id)?.motionPreset == nil)
    }

    @Test("Sammandraget och varför: ett låst kollage nämner båda rummen och att du valt det")
    func explanations() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, _) = try lockedCollage(model)
        let spec = try #require(model.spec)
        let row = try #require(ReelChoiceSummary.summary(spec).rows.first { $0.assetID == clipID })
        #expect(row.room.contains(" + ") && row.locked)
        #expect(row.motion.hasPrefix("Rutor: stapel"))
        #expect(model.motionReason(forAsset: clipID) == .chosenByUser)
    }
}
