import Foundation
import Testing
import CoreGraphics
@testable import PhotoFlow

/// Tester för Regi R3 på modellnivå: dragning inom coalescing, byt start/slut, centrera på motivet
/// och den isolerade specen som förhandsvisningen använder under dragning.
struct ReelMotionEditTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelMotionEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func item(_ n: Int, room: String, category: String, q: Double, in dir: URL,
                      focus: ReelSpec.Point = .init(x: 0.5, y: 0.5)) -> ReelImageAnalyzer.Item {
        var v = [Float](repeating: 0, count: 16)
        v[n % 16] = 1
        let a = ReelImageAnalysis(
            sha256: String(format: "%064x", n), width: 6000, height: 4000, qualityScore: q, isUtility: false,
            horizonAngleDegrees: nil, sharpness: nil, featurePrint: v.withUnsafeBytes { Data($0) },
            saliencyBoxes: [.init(x: 0.1, y: 0.2, width: 0.2, height: 0.2)], focus: focus, salientWidth: 0.4,
            meanLuminance: 0.45, exifDate: nil, room: room, category: category, features: nil, caption: nil)
        return .init(url: dir.appendingPathComponent("bild-\(n).jpg"), analysis: a)
    }

    private func makeModel() throws -> (ReelEditorModel, URL) {
        let root = try tempDir()
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let items = [
            item(0, room: "Fasad", category: "Exteriör", q: 0.9, in: source),
            item(1, room: "Kök", category: "Interiör", q: 0.8, in: source, focus: .init(x: 0.2, y: 0.3)),
            item(2, room: "Sovrum", category: "Interiör", q: 0.75, in: source),
            item(3, room: "Hall", category: "Interiör", q: 0.7, in: source)]
        let model = ReelEditorModel()
        model.prepare(items: items, sourceDirectory: source,
                      reelDirectory: AddressFolderLayout.reelDir(forSource: source), address: "Lindvägen 12")
        return (model, root)
    }

    private func clip(_ model: ReelEditorModel, _ id: String) -> ReelSpec.Clip? {
        model.spec?.timeline.first { $0.asset == id }
    }

    @Test("En dragning inom coalescing ger ett ångringssteg, en revision och förvalet custom")
    func dragIsOneUndoStep() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[1].id
        let before = clip(model, id)!
        let revision = model.spec!.revision

        model.beginCoalescing()
        for i in 1...20 {
            let x = 0.3 + Double(i) * 0.01
            model.setCustomMotion(id, fit: .cover, motion: .init(from: .init(cx: x, cy: 0.5, zoom: 1.2), to: .init(cx: 0.7, cy: 0.5, zoom: 1.5)))
        }
        model.endCoalescing()

        let after = clip(model, id)!
        #expect(after.motionPreset == "custom")
        #expect(after.motion.to.zoom == 1.5)
        #expect(model.spec!.revision == revision + 1)
        #expect(model.clipRows[1].preset == .custom)
        model.undo()
        #expect(clip(model, id)?.motion == before.motion)
        #expect(clip(model, id)?.motionPreset == before.motionPreset)
        #expect(!model.canUndo || model.undoActionName != "Ändra rörelse")
    }

    @Test("Byt start/slut låser som custom och kan ångras")
    func swap() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[1].id
        let before = clip(model, id)!.motion
        model.swapMotionEnds(id)
        let after = clip(model, id)!
        #expect(after.motion.from == before.to && after.motion.to == before.from)
        #expect(after.motionPreset == "custom")
        model.swapMotionEnds(id)
        #expect(clip(model, id)!.motion == before)
    }

    @Test("Centrera på motivet flyttar båda ramarna till focus, behåller zoom och klampar")
    func centerOnSubject() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // Köket (bild 1) har focus (0,2; 0,3); dess plats i filmen beror på urvalet.
        let id = model.spec!.assets.first { $0.sha256 == String(format: "%064x", 1) }!.id
        model.setCustomMotion(id, fit: .cover, motion: .init(from: .init(cx: 0.6, cy: 0.5, zoom: 1.5), to: .init(cx: 0.8, cy: 0.5, zoom: 2)))
        model.centerMotionOnSubject(id)
        let m = clip(model, id)!.motion
        let g = model.motionGeometryContext(forAsset: id)!
        for key in [m.from, m.to] {
            let r = ReelMotionGeometry.frame(for: key, fit: .cover, imageSize: g.imageSize, frameAspect: g.frameAspect)
            // Mitten är focus om ramen ryms, annars klampad mot kanten (men aldrig utanför bilden).
            #expect(r.minX >= -1e-12 && r.minY >= -1e-12 && r.maxX <= 1 + 1e-12 && r.maxY <= 1 + 1e-12)
            #expect(abs(key.cy - max(0.3, r.height / 2)) < 1e-9)
            #expect(abs(key.cx - max(0.2, r.width / 2)) < 1e-9)
        }
        #expect(m.from.zoom == 1.5 && m.to.zoom == 2)
        #expect(clip(model, id)!.motionPreset == "custom")
    }

    @Test("Format byte efter custom klampar om rörelsen mot det nya formatet")
    func formatChangeClamps() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[1].id
        model.setFormat(.vertical)
        // Zoom 1 vid kanten ryms i 9:16 (smal ram), men mittpunkten måste flyttas i 16:9.
        model.setCustomMotion(id, fit: .cover, motion: .init(from: .init(cx: 0.2, cy: 0.5, zoom: 1), to: .init(cx: 0.8, cy: 0.5, zoom: 1)))
        model.setFormat(.landscape)
        let m = clip(model, id)!.motion
        let g = model.motionGeometryContext(forAsset: id)!
        for key in [m.from, m.to] {
            #expect(ReelMotionGeometry.clamped(key, fit: .cover, imageSize: g.imageSize, frameAspect: g.frameAspect) == key)
        }
        #expect(clip(model, id)!.motionPreset == "custom")
    }

    @Test("Isolerad spec: bara klippet, utan övergång, med den nya rörelsen")
    func isolatedSpec() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = model.spec!
        let id = model.clipRows[2].id
        let motion = ReelSpec.Motion(from: .init(cx: 0.3, cy: 0.4, zoom: 1.1), to: .init(cx: 0.6, cy: 0.5, zoom: 1.3))
        let iso = try #require(ReelPreviewModel.isolatedClipSpec(spec, assetID: id, motion: motion))
        #expect(iso.timeline.count == 1 && iso.timeline[0].asset == id && iso.timeline[0].transitionIn == nil)
        #expect(iso.timeline[0].motion == motion)
        let size = CGSize(width: 360, height: 640)
        let start = ReelTimeline.state(at: 0, spec: iso, outputSize: size)
        let end = ReelTimeline.state(at: ReelTimeline.totalDuration(iso), spec: iso, outputSize: size)
        let g = model.motionGeometryContext(forAsset: id)!
        #expect(start.count == 1 && start[0].opacity == 1)
        #expect(start[0].crop == ReelMotionGeometry.frame(for: motion.from, fit: iso.timeline[0].fit, imageSize: g.imageSize, frameAspect: g.frameAspect)
                || iso.timeline[0].fit == .containBlur)
        #expect(end.count == 1 && end[0].crop != start[0].crop)
        #expect(ReelPreviewModel.isolatedClipSpec(spec, assetID: "saknas", motion: motion) == nil)
    }
}
