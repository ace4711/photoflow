import Foundation
import Testing
@testable import PhotoFlow

/// Tester för Regi R0: lås i datamodellen. Varje låst val (förval, längd, övergång, egen rörelse)
/// ska överleva ombyggnad och nytt förslag; pinnade/uteslutna bilder, ordningslås, tempo och
/// de nya spec-fälten kodas runt.
struct ReelLockTests {

    // MARK: Hjälp

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha(_ n: Int) -> String { String(format: "%064x", n) }

    private func item(_ n: Int, room: String, category: String, q: Double, in dir: URL, s: Double = 0.4) -> ReelImageAnalyzer.Item {
        var v = [Float](repeating: 0, count: 16)
        v[n % 16] = 1
        let a = ReelImageAnalysis(
            sha256: sha(n), width: 6000, height: 4000, qualityScore: q, isUtility: false,
            horizonAngleDegrees: nil, sharpness: nil, featurePrint: v.withUnsafeBytes { Data($0) },
            saliencyBoxes: [], focus: .init(x: 0.5, y: 0.5), salientWidth: s, meanLuminance: 0.45, exifDate: nil,
            room: room, category: category, features: nil, caption: nil)
        return .init(url: dir.appendingPathComponent("bild-\(n).jpg"), analysis: a)
    }

    private func items(in dir: URL) -> [ReelImageAnalyzer.Item] {
        [item(0, room: "Fasad", category: "Exteriör", q: 0.9, in: dir, s: 0.9),
         item(1, room: "Trädgård", category: "Exteriör", q: 0.8, in: dir),
         item(2, room: "Vardagsrum", category: "Interiör", q: 0.85, in: dir, s: 0.7),
         item(3, room: "Kök", category: "Interiör", q: 0.8, in: dir),
         item(4, room: "Sovrum", category: "Interiör", q: 0.75, in: dir),
         item(5, room: "Badrum", category: "Interiör", q: 0.7, in: dir),
         item(6, room: "Hall", category: "Interiör", q: 0.6, in: dir)]
    }

    private func makeModel() throws -> (ReelEditorModel, URL) {
        let root = try tempDir()
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let model = ReelEditorModel()
        model.prepare(items: items(in: source), sourceDirectory: source,
                      reelDirectory: AddressFolderLayout.reelDir(forSource: source), address: "Lindvägen 12")
        return (model, root)
    }

    private let customMotion = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 2.0),
                                               to: .init(cx: 0.3, cy: 0.5, zoom: 1.5))

    private func clip(_ model: ReelEditorModel, _ id: String) -> ReelSpec.Clip? {
        model.spec?.timeline.first { $0.asset == id }
    }

    /// Sätter alla fyra sorters lås på fyra olika klipp och returnerar deras asset-id:n.
    private func lockEverything(_ model: ReelEditorModel) -> (preset: String, duration: String, cut: String, custom: String) {
        let ids = model.clipRows.map(\.id)
        model.setPreset(ids[1], .panLeft)
        model.setDuration(ids[2], seconds: 4.2)
        model.setTransition(ids[3], .init(type: .cut, direction: nil, duration: 0))
        model.setCustomMotion(ids[4], fit: .cover, motion: customMotion)
        return (ids[1], ids[2], ids[3], ids[4])
    }

    private func expectLocks(_ model: ReelEditorModel, _ l: (preset: String, duration: String, cut: String, custom: String),
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(clip(model, l.preset)?.motionPreset == "panLeft", sourceLocation: sourceLocation)
        #expect(clip(model, l.duration)?.duration == 4.2, sourceLocation: sourceLocation)
        #expect(clip(model, l.duration)?.durationLocked == true, sourceLocation: sourceLocation)
        #expect(clip(model, l.cut)?.transitionLocked == true, sourceLocation: sourceLocation)
        #expect(clip(model, l.cut)?.transitionIn?.type == .cut, sourceLocation: sourceLocation)
        let c = clip(model, l.custom)
        #expect(c?.motionPreset == "custom", sourceLocation: sourceLocation)
        #expect(c?.motion == customMotion, sourceLocation: sourceLocation)
        #expect(c?.fit == .cover, sourceLocation: sourceLocation)
    }

    private func candidates(_ n: Int, quality: (Int) -> Double = { 0.9 - Double($0) * 0.05 }) -> [ReelCandidate] {
        (0..<n).map { i in
            var v = [Float](repeating: 0, count: 16)
            v[i % 16] = 1
            return ReelCandidate(id: sha(i), filename: "bild-\(i).jpg", quality: quality(i), featureVector: v,
                                 salientWidth: 0.4, meanLuminance: 0.45,
                                 room: ["Fasad", "Vardagsrum", "Kök", "Sovrum", "Badrum", "Hall", "Kontor"][i % 7],
                                 category: i % 7 == 0 ? "Exteriör" : "Interiör")
        }
    }

    // MARK: Lås överlever ombyggnad

    @Test("Låsta val är oförändrade efter omordning")
    func locksSurviveReorder() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = lockEverything(model)
        expectLocks(model, l)
        model.moveClip(l.custom, to: 0)
        model.moveClip(l.cut, to: 4)
        expectLocks(model, l)
        #expect(model.clipRows.map(\.id).first == l.custom)
    }

    @Test("Låsta val är oförändrade när en bild på annan plats byts")
    func locksSurviveReplaceElsewhere() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let l = lockEverything(model)
        let target = model.clipRows.map(\.id)[0]
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        model.replaceClip(target, withCandidate: spare.id)
        expectLocks(model, l)
    }

    @Test("Låst övergång följer med klippet även till plats 0 och tillbaka, och låst utan värde betyder standard")
    func transitionLockAtFirstPosition() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows.map(\.id)[2]
        let push = ReelSpec.Transition(type: .push, direction: .up, duration: 0.8)
        model.setTransition(id, push)
        model.moveClip(id, to: 0)
        #expect(clip(model, id)?.transitionIn == push)
        model.moveClip(id, to: 3)
        #expect(clip(model, id)?.transitionIn == push)
        model.setTransition(id, nil)
        #expect(clip(model, id)?.transitionLocked == true)
        #expect(clip(model, id)?.transitionIn == nil)
        model.clearTransition(id)
        #expect(clip(model, id)?.transitionLocked == nil)
        #expect(clip(model, id)?.transitionIn != nil)
    }

    @Test("Formatbyte: egen rörelse klampas om men cx/cy/zoom behålls när de ryms")
    func formatChangeClampsCustom() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows.map(\.id)[1]
        // Startnyckeln ryms i alla format; slutnyckeln (zoom 1, cx 0,2) ryms i 9:16 men inte i 16:9.
        let motion = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 2), to: .init(cx: 0.2, cy: 0.5, zoom: 1))
        model.setCustomMotion(id, fit: .cover, motion: motion)
        #expect(clip(model, id)?.motion == motion)
        #expect(model.adaptedCustomMotions == 0)
        model.setFormat(.landscape)
        let c = try #require(clip(model, id))
        #expect(c.motionPreset == "custom")
        #expect(c.motion.from == motion.from)
        #expect(abs(c.motion.to.cx - 0.5) < 1e-9)
        #expect(c.motion.to.zoom == 1)
        #expect(model.adaptedCustomMotions == 1)
    }

    @Test("Egen rörelse: zoom under 1 höjs till 1")
    func customZoomClampedToOne() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows.map(\.id)[1]
        model.setCustomMotion(id, fit: .cover, motion: .init(from: .init(cx: 0.5, cy: 0.5, zoom: 0.5),
                                                              to: .init(cx: 0.5, cy: 0.5, zoom: 1.4)))
        #expect(clip(model, id)?.motion.from.zoom == 1)
        #expect(clip(model, id)?.motion.to.zoom == 1.4)
    }

    @Test("Förval släpper egen rörelse; custom utan rörelse utgår från klippets nuvarande")
    func presetReleasesCustom() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows.map(\.id)[1]
        let before = try #require(clip(model, id))
        model.setPreset(id, .custom)
        #expect(clip(model, id)?.motionPreset == "custom")
        #expect(clip(model, id)?.motion == before.motion)
        model.setPreset(id, .auto)
        #expect(clip(model, id)?.motionPreset == nil)
        #expect(ReelMotionPlanner.Preset.selectableCases.contains(.custom) == false)
    }

    // MARK: Föreslå igen / börja om

    @Test("suggestAgain behåller per-bild-lås, tempo, pinnade, uteslutna och format; startOver kastar allt")
    func suggestAgainKeepsLocksStartOverDrops() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setFormat(.square)
        let l = lockEverything(model)
        let shaOf = { (id: String) in model.spec!.assets.first { $0.id == id }!.sha256 }
        let locked = [l.preset, l.duration, l.cut, l.custom].map(shaOf)
        let before = Set(model.spec!.assets.map(\.sha256))
        model.setTempo(.fast)
        model.togglePinned(model.candidateRows.first { $0.clipIndex != nil }!.id)
        let excludedID = try #require(model.candidateRows.first { $0.clipIndex == nil }).id
        model.toggleExcluded(excludedID)

        model.suggestAgain()
        let spec = try #require(model.spec)
        #expect(spec.outputs.first?.id == "square")
        #expect(spec.editor?.tempo == "fast")
        #expect(spec.editor?.excludedAssets == [excludedID])
        #expect(!spec.assets.contains { $0.sha256 == excludedID })
        for s in locked where spec.assets.contains(where: { $0.sha256 == s }) {
            let asset = spec.assets.first { $0.sha256 == s }!
            let c = try #require(spec.timeline.first { $0.asset == asset.id })
            #expect(c.motionPreset != nil || c.durationLocked == true || c.transitionLocked == true)
        }
        // Samma urval som innan (uteslutningen gällde en bild som inte var med): lås finns kvar på alla fyra.
        #expect(Set(spec.assets.map(\.sha256)) == before)
        let byPreset = spec.timeline.filter { $0.motionPreset == "panLeft" }
        #expect(byPreset.count == 1)
        #expect(spec.timeline.contains { $0.durationLocked == true && $0.duration == 4.2 })
        #expect(spec.timeline.contains { $0.transitionLocked == true && $0.transitionIn?.type == .cut })
        #expect(spec.timeline.contains { $0.motionPreset == "custom" && $0.motion == customMotion })

        model.startOver()
        let fresh = try #require(model.spec)
        #expect(fresh.editor == nil)
        #expect(fresh.outputs.first?.id == "square")
        #expect(fresh.timeline.allSatisfy { $0.motionPreset == nil && $0.durationLocked == nil && $0.transitionLocked == nil })
    }

    @Test("Föreslå igen behåller en handtillagd bild med egen rörelse, längd och övergång")
    func suggestAgainKeepsLockedAddedImage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let spare = try #require(model.candidateRows.last { $0.clipIndex == nil })
        model.addCandidate(spare.id)
        let id = try #require(model.selectedAssetID)
        model.setCustomMotion(id, fit: .cover, motion: customMotion)
        model.setDuration(id, seconds: 4.4)
        model.setTransition(id, .init(type: .fadeThroughBlack, direction: nil, duration: 0.8))
        #expect(model.spec?.editor?.pinnedAssets == nil)

        for change in [{ model.suggestAgain() }, { model.setCount(4) }] {
            change()
            let spec = try #require(model.spec)
            let asset = try #require(spec.assets.first { $0.sha256 == spare.id })
            let c = try #require(spec.timeline.first { $0.asset == asset.id })
            #expect(c.motionPreset == "custom")
            #expect(c.motion == customMotion)
            #expect(c.duration == 4.4 && c.durationLocked == true)
            #expect(c.transitionLocked == true && c.transitionIn?.type == .fadeThroughBlack)
        }
    }

    @Test("Låst klipp som inte väljs automatiskt behåller sin plats med ordningslås")
    func orderLockKeepsLockedAddedImage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let spare = try #require(model.candidateRows.last { $0.clipIndex == nil })
        model.insertCandidate(spare.id, at: 1)
        let id = try #require(model.selectedAssetID)
        model.setDuration(id, seconds: 3.7)
        model.setOrderLocked(true)
        model.suggestAgain()
        let spec = try #require(model.spec)
        let asset = try #require(spec.assets.first { $0.sha256 == spare.id })
        #expect(spec.timeline.firstIndex { $0.asset == asset.id } == 1)
    }

    @Test("Föreslå igen, antal och Börja om behåller spec-id, höjer revisionen och loggar steget")
    func recomposeContinuesSpec() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // Som efter en skickning och en antagen mäklarversion med brand och textlager.
        var remote = try #require(model.spec)
        remote.brand = .init(id: "maklarhuset", logo: nil, primaryColor: "#123456", font: nil)
        remote.overlays = [.init(type: "address", text: "Lindvägen 12")]
        model.adoptRemoteSpec(remote)
        model.markSynced(revision: 1, status: "proposed")
        let id = model.spec!.id
        let created = model.spec!.createdAt
        var revision = model.spec!.revision
        let edits = model.spec!.provenance.edits?.count ?? 0

        for (step, change) in [("suggestAgain", { model.suggestAgain() }), ("count", { model.setCount(6) }),
                               ("startOver", { model.startOver() })] {
            change()
            let spec = try #require(model.spec)
            #expect(spec.id == id, "\(step)")
            #expect(spec.createdAt == created, "\(step)")
            #expect(spec.revision == revision + 1, "\(step)")
            #expect(spec.status == "draft", "\(step)")
            #expect(spec.brand?.id == "maklarhuset", "\(step)")
            #expect(spec.overlays.count == 1, "\(step)")
            #expect(spec.provenance.edits?.last?.op == step, "\(step)")
            #expect(spec.provenance.edits?.last?.by == "photographer", "\(step)")
            revision = spec.revision
        }
        #expect(model.spec!.provenance.edits!.count == edits + 3)
    }

    @Test("Egen rörelse överlever formatbyte fram och tillbaka med fotografens oklampade nycklar")
    func customMotionSurvivesFormatRoundTrip() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[2].id
        // 3:2-bild i 9:16: cx 0,2 och 0,7 ryms vid zoom 1; i 16:9 täcker utsnittet hela bredden.
        let mine = ReelSpec.Motion(from: .init(cx: 0.2, cy: 0.5, zoom: 1), to: .init(cx: 0.7, cy: 0.5, zoom: 1))
        model.setCustomMotion(id, fit: .cover, motion: mine)
        #expect(clip(model, id)?.motion == mine)
        #expect(clip(model, id)?.customMotion == nil)

        model.setFormat(.landscape)
        #expect(clip(model, id)?.motion.from.cx == 0.5)
        #expect(clip(model, id)?.customMotion == mine)
        model.setDuration(model.clipRows[0].id, seconds: 4)   // en ombyggnad till i 16:9
        model.setFormat(.vertical)
        #expect(clip(model, id)?.motion == mine)
        #expect(clip(model, id)?.customMotion == nil)
        #expect(clip(model, id)?.motionPreset == "custom")
    }

    @Test("Ändrad rörelse (t.ex. av mäklaren) vinner över gamla oklampade nycklar")
    func staleCustomMotionIgnored() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[2].id
        let mine = ReelSpec.Motion(from: .init(cx: 0.2, cy: 0.5, zoom: 1), to: .init(cx: 0.7, cy: 0.5, zoom: 1))
        model.setCustomMotion(id, fit: .cover, motion: mine)
        model.setFormat(.landscape)
        var remote = try #require(model.spec)
        let i = try #require(remote.timeline.firstIndex { $0.asset == id })
        let theirs = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1.4), to: .init(cx: 0.5, cy: 0.5, zoom: 1))
        remote.timeline[i].motion = theirs
        model.adoptRemoteSpec(remote)
        model.setFormat(.vertical)
        #expect(clip(model, id)?.motion.from.zoom == 1.4)
        #expect(clip(model, id)?.customMotion == nil)
    }

    @Test("setCount behåller lås och pinnad bild kommer med")
    func setCountKeepsPins() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let weakest = try #require(model.candidateRows.last { $0.clipIndex == nil })
        model.togglePinned(weakest.id)
        model.setCount(3)
        #expect(model.spec?.assets.contains { $0.sha256 == weakest.id } == true)
        model.setCount(6)
        #expect(model.spec?.assets.contains { $0.sha256 == weakest.id } == true)
        #expect(model.spec?.editor?.pinnedAssets == [weakest.id])
    }

    @Test("Uteslutning tar bort klippet, pinning och uteslutning avlöser varandra")
    func excludeRemovesClip() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let inFilm = try #require(model.candidateRows.first { $0.clipIndex != nil })
        model.togglePinned(inFilm.id)
        #expect(model.spec?.editor?.pinnedAssets == [inFilm.id])
        model.toggleExcluded(inFilm.id)
        #expect(model.spec?.editor?.pinnedAssets == nil)
        #expect(model.spec?.editor?.excludedAssets == [inFilm.id])
        #expect(model.clipRows.count == 4)
        #expect(model.candidateRows.first { $0.id == inFilm.id }?.excludedReason == "Utesluten av dig")
        model.togglePinned(inFilm.id)
        #expect(model.spec?.editor?.excludedAssets == nil)
        model.toggleExcluded(inFilm.id)
        model.toggleExcluded(inFilm.id)
        #expect(model.spec?.editor?.excludedAssets == nil)
        #expect(model.spec?.editor?.isEmpty != false)
    }

    // MARK: Urval

    @Test("Pinnad bild väljs alltid, även när ett hårt filter annars tagit bort den")
    func pinnedAlwaysPicked() {
        var cs = candidates(8)
        cs[7].isUtility = true
        cs[7].quality = 0.1
        let plain = ReelSelector.select(cs, count: 5)
        #expect(plain.excluded.contains { $0.candidateID == sha(7) && $0.kind == .utility })
        let sel = ReelSelector.select(cs, count: 5, pinned: [sha(7)])
        #expect(sel.picks.count == 5)
        #expect(sel.picks.contains { $0.candidateID == sha(7) })
        #expect(!sel.excluded.contains { $0.candidateID == sha(7) })
    }

    @Test("Fler pinnade än count: alla väljs")
    func pinnedMoreThanCount() {
        let cs = candidates(10)
        let pins = [sha(9), sha(8), sha(7), sha(6)]
        let sel = ReelSelector.select(cs, count: 3, pinned: pins)
        #expect(sel.picks.count == 4)
        #expect(Set(pins).isSubset(of: Set(sel.picks.map(\.candidateID))))
    }

    @Test("Uteslutna väljs aldrig, inte heller när få kandidater finns")
    func excludedNeverPicked() {
        let cs = candidates(4)
        let sel = ReelSelector.select(cs, count: 5, excluded: [sha(0)])
        #expect(!sel.picks.contains { $0.candidateID == sha(0) })
        #expect(sel.picks.count == 3)
        #expect(sel.excluded.contains { $0.candidateID == sha(0) && $0.kind == .user && $0.reason == "Utesluten av dig" })
        // Och uteslutning går före pinning.
        let both = ReelSelector.select(cs, count: 3, pinned: [sha(0)], excluded: [sha(0)])
        #expect(!both.picks.contains { $0.candidateID == sha(0) })
    }

    @Test("Utan pinned/excluded är urvalet detsamma som förut")
    func selectionUnchangedWithoutLocks() {
        let cs = candidates(9)
        #expect(ReelSelector.select(cs, count: 6) == ReelSelector.select(cs, count: 6, pinned: [], excluded: []))
        #expect(ReelSelector.select(cs, count: 20).picks.count == 9)
        #expect(ReelSelector.select(candidates(14), count: 20).picks.count == 12)
    }

    // MARK: Ordningslås

    @Test("orderLocked: låst klipp behåller sin position; utan lås följer förslaget")
    func orderLockedKeepsPosition() throws {
        let dir = URL(fileURLWithPath: "/tmp/ReelLockTests", isDirectory: true)
        let specDir = dir.appendingPathComponent("FILM", isDirectory: true)
        let first = ReelComposer.compose(items: items(in: dir), specDirectory: specDir).spec
        // Omordnad fotografversion: bilden som föreslogs på plats 3 ligger på plats 1 och har låst längd.
        let ids = first.timeline.map(\.asset)
        let heldAsset = ids[3]
        let heldSha = first.assets.first { $0.id == heldAsset }!.sha256
        var reordered = ids
        reordered.remove(at: 3)
        reordered.insert(heldAsset, at: 1)
        var overrides = ReelComposer.overrides(in: first)
        overrides[heldAsset] = .init(preset: .auto, duration: 3.7)
        var prior = ReelComposer.rebuild(first, order: reordered, overrides: overrides)
        #expect(prior.assets[1].sha256 == heldSha)

        let free = ReelComposer.compose(items: items(in: dir), specDirectory: specDir, preserving: prior).spec
        #expect(free.assets[3].sha256 == heldSha)
        #expect(free.timeline.first { $0.asset == free.assets[3].id }?.duration == 3.7)

        prior.editor = .init(orderLocked: true)
        let locked = ReelComposer.compose(items: items(in: dir), specDirectory: specDir, preserving: prior)
        #expect(locked.spec.assets[1].sha256 == heldSha)
        #expect(locked.spec.editor?.orderLocked == true)
        #expect(locked.selection.picks.map(\.candidateID) == locked.spec.assets.map(\.sha256))
        // Övriga bilder är samma som förslaget, i förslagets inbördes ordning.
        let others = locked.spec.assets.map(\.sha256).filter { $0 != heldSha }
        #expect(others == first.assets.map(\.sha256).filter { $0 != heldSha })
    }

    // MARK: Planeraren

    private func image(_ id: String, s: Double) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: 6000, height: 4000, focus: .init(x: 0.5, y: 0.5), salientWidth: s,
              isExterior: false, focusWidth: s)
    }

    @Test("Tempo skalar bara automatiska längder")
    func tempoScalesOnlyAuto() {
        let images = [image("a", s: 0.3), image("b", s: 0.3), image("c", s: 0.3), image("d", s: 0.3)]
        let locked: [String: ReelMotionPlanner.ClipOverride] = ["b": .init(preset: .auto, duration: 4.0)]
        let normal = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16, overrides: locked)
        let calm = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16, overrides: locked, tempo: .calm)
        let fast = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16, overrides: locked, tempo: .fast)
        for i in normal.indices {
            if normal[i].asset == "b" {
                #expect(calm[i].duration == 4.0 && fast[i].duration == 4.0)
            } else {
                #expect(abs(calm[i].duration - normal[i].duration * 1.2) < 1e-9)
                #expect(abs(fast[i].duration - normal[i].duration * 0.85) < 1e-9)
            }
        }
        #expect(ReelMotionPlanner.Tempo(editorValue: nil) == .normal)
        #expect(ReelMotionPlanner.Tempo(editorValue: "fast") == .fast)
    }

    @Test("Tempo via modellen: sparas i editor och skalar längderna, normal tar bort fältet")
    func tempoViaModel() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.totalDuration
        model.setTempo(.calm)
        #expect(model.spec?.editor?.tempo == "calm")
        #expect(model.totalDuration > before)
        model.setTempo(.normal)
        #expect(model.spec?.editor == nil)
        #expect(abs(model.totalDuration - before) < 1e-9)
    }

    @Test("Egen rörelse räknas i alterneringen som den rörelse den är")
    func customMotionCountsInAlternation() {
        let images = [image("a", s: 0.6), image("b", s: 0.6), image("c", s: 0.6), image("d", s: 0.3)]
        // Klipp b panorerar åt vänster (egen rörelse): nästa automatiska panorering ska gå åt höger
        // och push-övergången in i c ska följa b:s riktning (innehållet rör sig åt höger).
        let custom = ReelMotionPlanner.CustomMotion(
            fit: .cover, motion: .init(from: .init(cx: 0.6, cy: 0.5, zoom: 1), to: .init(cx: 0.3, cy: 0.5, zoom: 1)))
        let overrides: [String: ReelMotionPlanner.ClipOverride] = ["b": .init(preset: .custom, custom: custom)]
        let clips = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16, overrides: overrides)
        #expect(clips[0].motion.to.cx > clips[0].motion.from.cx)   // a: höger
        #expect(clips[1].motion == custom.motion)
        #expect(clips[2].motion.to.cx > clips[2].motion.from.cx)   // c: höger (alterneringen fortsätter efter b)
        #expect(clips[2].transitionIn?.type == .push && clips[2].transitionIn?.direction == .right)
    }

    @Test("Preset custom utan rörelse behandlas som automatiskt")
    func customWithoutMotionIsAuto() {
        let images = [image("a", s: 0.6), image("b", s: 0.6)]
        let auto = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16)
        let broken = ReelMotionPlanner.plan(images, frameAspect: 9.0 / 16, overrides: ["a": .init(preset: .custom)])
        #expect(auto == broken)
    }

    // MARK: Kodning

    @Test("Nya fält kodas runt; spec utan dem kodas utan nya nycklar")
    func codingRoundTrip() throws {
        let dir = URL(fileURLWithPath: "/tmp/ReelLockTests", isDirectory: true)
        var spec = ReelComposer.compose(items: items(in: dir), specDirectory: dir.appendingPathComponent("FILM")).spec
        let plain = String(decoding: try spec.jsonData(), as: UTF8.self)
        #expect(!plain.contains("\"editor\"") && !plain.contains("transitionLocked"))
        #expect(try ReelSpec.decode(from: spec.jsonData()) == spec)

        spec.timeline[1].transitionLocked = true
        spec.timeline[1].motionPreset = "custom"
        spec.editor = .init(pinnedAssets: [sha(1)], excludedAssets: [sha(2)], orderLocked: true, tempo: "calm")
        let text = String(decoding: try spec.jsonData(), as: UTF8.self)
        #expect(text.contains("\"transitionLocked\" : true"))
        #expect(text.contains("\"pinnedAssets\""))
        #expect(text.contains("\"tempo\" : \"calm\""))
        #expect(try ReelSpec.decode(from: spec.jsonData()) == spec)
        #expect(spec.minReaderVersion == 1)
        // Tomt editor-objekt normaliseras bort.
        #expect(ReelSpec.EditorState(pinnedAssets: [], excludedAssets: [], orderLocked: false, tempo: "normal").normalized == nil)
    }
}
