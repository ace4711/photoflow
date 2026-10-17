import Foundation
import Testing
@testable import PhotoFlow

/// Tester för Regi R2: planerarens skäl och standardövergång, stilen i redigeringsmodellen
/// (`setStyle`, "Använd på alla"), inspektörens hjälpfunktioner och förhandsvisningsfönstret.
struct ReelTransitionStyleTests {
    private let vertical = 1080.0 / 1920.0

    private func image(_ id: String, s: Double?, exterior: Bool = false) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: 6000, height: 4000, focus: .init(x: 0.5, y: 0.5), salientWidth: s, isExterior: exterior)
    }

    /// Panorering, zoom, zoom, zoom, zoom: övergång 1 är push, 2–3 mjuk tona, 4 (sista) längre tona.
    private var images: [ReelMotionPlanner.Image] {
        [image("a", s: 0.7), image("b", s: 0.3), image("c", s: 0.3), image("d", s: 0.3), image("e", s: 0.3)]
    }

    // MARK: Planeraren

    @Test("Standardstilen ger exakt det planeraren alltid gjort")
    func standardIsUnchanged() {
        let a = ReelMotionPlanner.plan(images, frameAspect: vertical)
        let b = ReelMotionPlanner.plan(images, frameAspect: vertical, defaultTransition: ReelComposer.defaultStyle.defaultTransition)
        #expect(a == b)
        #expect(a[1].transitionIn == .init(type: .push, direction: .left, duration: 0.5))
        #expect(a[2].transitionIn == .init(type: .crossfade, direction: nil, duration: 0.5))
        #expect(a[4].transitionIn == .init(type: .crossfade, direction: nil, duration: 0.6))
        #expect(a[0].transitionIn == nil)
    }

    @Test("Annan längd på mjuk tona skalar alla, och sista får 1,2 gånger")
    func crossfadeOtherDuration() {
        let d = ReelSpec.Transition(type: .crossfade, direction: nil, duration: 0.8)
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical, defaultTransition: d)
        #expect(clips[1].transitionIn == .init(type: .push, direction: .left, duration: 0.8))
        #expect(clips[2].transitionIn == d)
        #expect(abs((clips[4].transitionIn?.duration ?? 0) - 0.96) < 1e-9)
        // Taket 1,5 s.
        let long = ReelMotionPlanner.plan(images, frameAspect: vertical,
                                          defaultTransition: .init(type: .crossfade, direction: nil, duration: 1.4))
        #expect(long[4].transitionIn?.duration == 1.5)
    }

    @Test("Annan standardövergång än mjuk tona gäller alla automatiska, utan push-regel och förlängning")
    func otherDefaults() {
        for d in [ReelSpec.Transition(type: .cut, direction: nil, duration: 0),
                  .init(type: .fadeThroughBlack, direction: nil, duration: 0.7),
                  .init(type: .push, direction: .up, duration: 0.4)] {
            let clips = ReelMotionPlanner.plan(images, frameAspect: vertical, defaultTransition: d)
            #expect(clips[0].transitionIn == nil)
            for c in clips.dropFirst() { #expect(c.transitionIn == d) }
        }
    }

    @Test("Låst övergång vinner över standardövergången")
    func lockedWinsOverDefault() {
        let cut = ReelSpec.Transition(type: .cut, direction: nil, duration: 0)
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical,
                                           overrides: ["c": .init(transitionLocked: true, transition: cut)],
                                           defaultTransition: .init(type: .fadeThroughBlack, direction: nil, duration: 0.7))
        #expect(clips[2].transitionIn == cut && clips[2].transitionLocked == true)
        #expect(clips[1].transitionIn?.type == .fadeThroughBlack)
    }

    @Test("Skälen följer planerarens regel")
    func reasons() {
        let std = ReelMotionPlanner.standardTransition
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical)
        #expect(ReelMotionPlanner.transitionReason(previous: clips[0], isLast: false, defaultTransition: std)
                == "Skjut åt vänster eftersom förra klippet panorerade åt höger")
        #expect(ReelMotionPlanner.transitionReason(previous: clips[1], isLast: false, defaultTransition: std)
                == "Mjuk tona (standard)")
        #expect(ReelMotionPlanner.transitionReason(previous: clips[3], isLast: true, defaultTransition: std)
                == "Längre tona in i sista bilden")
        #expect(ReelMotionPlanner.transitionReason(previous: clips[0], isLast: false,
                                                   defaultTransition: .init(type: .cut, direction: nil, duration: 0))
                == "Hårt klipp (filmens standardövergång)")
        #expect(ReelMotionPlanner.transitionReason(previous: clips[0], isLast: true,
                                                   defaultTransition: .init(type: .push, direction: .right, duration: 0.5))
                == "Skjut åt höger (filmens standardövergång)")
    }

    @Test("Skälet stämmer med den planerade övergången för varje klipp")
    func reasonMatchesPlan() {
        // Panorering åt vänster och åt höger, zoomar, och en egen rörelse med sidledsrörelse.
        let motion = ReelSpec.Motion(from: .init(cx: 0.6, cy: 0.5, zoom: 1.0), to: .init(cx: 0.4, cy: 0.5, zoom: 1.0))
        let imgs = [image("a", s: 0.7), image("b", s: 0.7), image("c", s: 0.3), image("d", s: 0.3), image("e", s: 0.3)]
        let overrides: [String: ReelMotionPlanner.ClipOverride] = [
            "c": .init(preset: .custom, custom: .init(fit: .cover, motion: motion))]
        let clips = ReelMotionPlanner.plan(imgs, frameAspect: vertical, overrides: overrides)
        let std = ReelMotionPlanner.standardTransition
        for i in 1..<clips.count {
            let reason = ReelMotionPlanner.transitionReason(previous: clips[i - 1], isLast: i == clips.count - 1, defaultTransition: std)
            switch clips[i].transitionIn?.type {
            case .push: #expect(reason.hasPrefix("Skjut \(clips[i].transitionIn?.direction == .left ? "åt vänster" : "åt höger")"), "klipp \(i): \(reason)")
            case .crossfade:
                #expect(reason == (i == clips.count - 1 ? "Längre tona in i sista bilden" : "Mjuk tona (standard)"), "klipp \(i): \(reason)")
            default: Issue.record("oväntad typ i klipp \(i)")
            }
        }
        // Egen rörelse åt vänster ger en push åt höger efter sig.
        #expect(clips[3].transitionIn?.direction == .right)
    }

    @Test("Komponeraren skickar stilen till planeraren (rebuild)")
    func rebuildUsesStyle() throws {
        var spec = try ReelTimelineTests.example()
        spec.style.defaultTransition = .init(type: .fadeThroughBlack, direction: nil, duration: 0.9)
        let rebuilt = ReelComposer.rebuild(spec, order: spec.assets.map(\.id))
        for c in rebuilt.timeline.dropFirst() { #expect(c.transitionIn?.type == .fadeThroughBlack && c.transitionIn?.duration == 0.9) }
    }

    // MARK: Modellen

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelTransitionStyleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func item(_ n: Int, room: String, category: String, q: Double, in dir: URL, s: Double = 0.4) -> ReelImageAnalyzer.Item {
        var v = [Float](repeating: 0, count: 16)
        v[n % 16] = 1
        let a = ReelImageAnalysis(
            sha256: String(format: "%064x", n), width: 6000, height: 4000, qualityScore: q, isUtility: false,
            horizonAngleDegrees: nil, sharpness: nil, featurePrint: v.withUnsafeBytes { Data($0) },
            saliencyBoxes: [], focus: .init(x: 0.5, y: 0.5), salientWidth: s, meanLuminance: 0.45, exifDate: nil,
            room: room, category: category, features: nil, caption: nil)
        return .init(url: dir.appendingPathComponent("bild-\(n).jpg"), analysis: a)
    }

    private func makeModel() throws -> (ReelEditorModel, URL) {
        let root = try tempDir()
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let items = [item(0, room: "Fasad", category: "Exteriör", q: 0.9, in: source, s: 0.9),
                     item(1, room: "Trädgård", category: "Exteriör", q: 0.8, in: source),
                     item(2, room: "Vardagsrum", category: "Interiör", q: 0.85, in: source, s: 0.7),
                     item(3, room: "Kök", category: "Interiör", q: 0.8, in: source),
                     item(4, room: "Sovrum", category: "Interiör", q: 0.75, in: source),
                     item(5, room: "Badrum", category: "Interiör", q: 0.7, in: source)]
        let model = ReelEditorModel()
        model.prepare(items: items, sourceDirectory: source,
                      reelDirectory: AddressFolderLayout.reelDir(forSource: source), address: "Lindvägen 12")
        return (model, root)
    }

    @Test("setStyle: ångra och gör om, revision, namn och sparad fil")
    func setStyleUndoRedo() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(model.spec?.style)
        model.setStyle({ $0.defaultTransition = .init(type: .fadeThroughBlack, direction: nil, duration: 0.8) }, op: "defaultTransition")
        #expect(model.spec?.revision == 2)
        #expect(model.undoActionName == "Ändra standardövergång")
        #expect(model.spec?.timeline.dropFirst().allSatisfy { $0.transitionIn?.type == .fadeThroughBlack } == true)
        model.setStyle({ $0.easing = .linear }, op: "easing")
        #expect(model.undoActionName == "Ändra rörelsekurva")
        model.setStyle({ $0.background = .init(type: "black", amount: nil) }, op: "background")
        #expect(model.undoActionName == "Ändra bakgrund")
        model.undo(); model.undo()
        #expect(model.spec?.style.easing == .easeInOut)
        #expect(model.spec?.style.defaultTransition.type == .fadeThroughBlack)
        model.undo()
        #expect(model.spec?.style == original)
        #expect(model.spec?.timeline.dropFirst().contains { $0.transitionIn?.type == .fadeThroughBlack } == false)
        model.redo()
        #expect(model.spec?.style.defaultTransition.type == .fadeThroughBlack)
        let saved = try ReelSpec.decode(from: Data(contentsOf: try #require(model.reelDirectory).appendingPathComponent(ReelEditorModel.specFileName)))
        #expect(saved.style == model.spec?.style)
    }

    @Test("setStyle utan ändring ger inget steg; sammanslagen dragning ger ett steg")
    func setStyleNoopAndCoalescing() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setStyle({ $0.easing = .easeInOut }, op: "easing")
        #expect(!model.canUndo)
        model.beginCoalescing()
        for amount in [0.1, 0.3, 0.8] { model.setStyle({ $0.background = .init(type: "blur", amount: amount) }, op: "background") }
        model.endCoalescing()
        #expect(model.spec?.revision == 2)
        model.undo()
        #expect(model.spec?.style.background.amount == 0.6)
        #expect(!model.canUndo)
    }

    @Test("Standardövergång ändrar inte låsta övergångar")
    func defaultKeepsLocks() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        let lockedCut = ReelSpec.Transition(type: .cut, direction: nil, duration: 0)
        model.setTransition(ids[2], lockedCut)
        model.setStyle({ $0.defaultTransition = .init(type: .push, direction: .down, duration: 0.4) }, op: "defaultTransition")
        let spec = try #require(model.spec)
        #expect(spec.timeline[2].transitionIn == lockedCut && spec.timeline[2].transitionLocked == true)
        #expect(spec.timeline[1].transitionIn == .init(type: .push, direction: .down, duration: 0.4))
    }

    @Test("Använd på alla: sätter stilen, släpper alla lås, ett ångringssteg")
    func applyToAll() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        let push = ReelSpec.Transition(type: .push, direction: .right, duration: 0.7)
        model.setTransition(ids[1], push)
        model.setTransition(ids[3], .init(type: .cut, direction: nil, duration: 0))
        model.setPreset(ids[2], .zoomOut)   // andra lås ska vara kvar
        let steps = model.spec?.provenance.edits?.count
        model.applyTransitionToAll(from: ids[1])
        let spec = try #require(model.spec)
        #expect(spec.style.defaultTransition == push)
        #expect(spec.timeline.allSatisfy { $0.transitionLocked != true })
        for c in spec.timeline.dropFirst() { #expect(c.transitionIn == push) }
        #expect(spec.timeline[2].motionPreset == "zoomOut")
        #expect(model.undoActionName == "Använd övergång på alla")
        #expect(spec.provenance.edits?.count == (steps ?? 0) + 1)
        model.undo()
        #expect(model.spec?.timeline[1].transitionLocked == true && model.spec?.timeline[3].transitionLocked == true)
        #expect(model.spec?.style.defaultTransition == ReelComposer.defaultStyle.defaultTransition)
    }

    @Test("Använd på alla från ett hårt klipp ger hårt klipp överallt")
    func applyCutToAll() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.setTransition(ids[2], .init(type: .cut, direction: nil, duration: 0))
        model.applyTransitionToAll(from: ids[2])
        let spec = try #require(model.spec)
        #expect(spec.style.defaultTransition.type == .cut)
        #expect(spec.timeline.dropFirst().allSatisfy { $0.transitionIn?.type == .cut })
        #expect(ReelTimeline.totalDuration(spec) == spec.timeline.map(\.duration).reduce(0, +))
    }

    // MARK: Hjälpfunktioner

    @Test("Kortas-varningen visas bara när klampningen gör övergången kortare")
    func shortened() {
        let t = ReelSpec.Transition(type: .crossfade, direction: nil, duration: 1.0)
        #expect(ReelTransitionEditor.shortenedTo(configured: t, effective: .init(type: .crossfade, direction: nil, duration: 0.6)) == 0.6)
        #expect(ReelTransitionEditor.shortenedTo(configured: t, effective: t) == nil)
        #expect(ReelTransitionEditor.shortenedTo(configured: t, effective: nil) == 0)
        #expect(ReelTransitionEditor.shortenedTo(configured: .init(type: .cut, direction: nil, duration: 0), effective: nil) == nil)
        #expect(ReelTransitionEditor.seconds(0.45) == "0,45 s")
    }

    @Test("Förhandsvisningsfönstret: 1 s före till 1 s efter, klampat")
    func previewWindow() {
        let w = ReelPreviewModel.transitionWindow(start: 5, duration: 0.5, total: 12)
        #expect(w.from == 4 && w.to == 6.5)
        let e = ReelPreviewModel.transitionWindow(start: 0.4, duration: 0.5, total: 1.2)
        #expect(e.from == 0 && e.to == 1.2)
        let cut = ReelPreviewModel.transitionWindow(start: 5, duration: 0, total: 12)
        #expect(cut.from == 4 && cut.to == 6)
    }
}
