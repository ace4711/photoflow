import Foundation
import Testing
@testable import PhotoFlow

/// Tester för Regi R1: ångra/gör om i `ReelEditorModel` (historik av hela specar), sammanslagning
/// av dragningar, kopplingen till `UndoManager` och markeringen av övergångar.
struct ReelUndoTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelUndoTests-\(UUID().uuidString)")
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

    private func items(in dir: URL) -> [ReelImageAnalyzer.Item] {
        [item(0, room: "Fasad", category: "Exteriör", q: 0.9, in: dir, s: 0.9),
         item(1, room: "Trädgård", category: "Exteriör", q: 0.8, in: dir),
         item(2, room: "Vardagsrum", category: "Interiör", q: 0.85, in: dir, s: 0.7),
         item(3, room: "Kök", category: "Interiör", q: 0.8, in: dir),
         item(4, room: "Sovrum", category: "Interiör", q: 0.75, in: dir),
         item(5, room: "Badrum", category: "Interiör", q: 0.7, in: dir),
         item(6, room: "Hall", category: "Interiör", q: 0.6, in: dir)]
    }

    private func makeModel() throws -> (ReelEditorModel, URL, URL) {
        let root = try tempDir()
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let reel = AddressFolderLayout.reelDir(forSource: source)
        let model = ReelEditorModel()
        model.prepare(items: items(in: source), sourceDirectory: source, reelDirectory: reel, address: "Lindvägen 12")
        return (model, root, reel)
    }

    @Test("Nytt förslag har ingen historik")
    func startsEmpty() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.canUndo && !model.canRedo)
        #expect(model.undoActionName == nil)
        model.undo(); model.redo()
        #expect(model.spec?.revision == 1)
    }

    @Test("Ångra och gör om omordning, med namn och sparad reel.json")
    func reorder() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.clipRows.map(\.id)
        model.moveClip(before[3], to: 0)
        let after = model.clipRows.map(\.id)
        #expect(after != before)
        #expect(model.undoActionName == "Ändra ordning")

        let token = model.revisionToken
        model.undo()
        #expect(model.clipRows.map(\.id) == before)
        #expect(model.revisionToken > token)
        #expect(model.redoActionName == "Ändra ordning")
        let saved = try ReelSpec.decode(from: Data(contentsOf: reel.appendingPathComponent("reel.json")))
        #expect(saved.timeline.map(\.asset) == before)

        model.redo()
        #expect(model.clipRows.map(\.id) == after)
        #expect(!model.canRedo && model.canUndo)
    }

    @Test("Längd, övergång, tempo och pin kan ångras och göras om")
    func varietyOfSteps() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        let cleanTimeline = model.spec!.timeline
        let cleanEditor = model.spec?.editor

        model.setDuration(ids[1], seconds: 6.0)
        #expect(model.undoActionName == "Ändra längd")
        model.setTransition(ids[2], .init(type: .cut, direction: nil, duration: 0))
        #expect(model.undoActionName == "Ändra övergång")
        model.setTempo(.fast)
        #expect(model.undoActionName == "Ändra tempo")
        let sha = model.spec!.assets[0].sha256
        model.togglePinned(sha)
        #expect(model.undoActionName == "Lås bild")
        #expect(model.spec?.editor?.pinnedAssets == [sha])

        model.undo()
        #expect(model.spec?.editor?.pinnedAssets == nil)
        model.undo()
        #expect(model.spec?.editor?.tempo == nil)
        model.undo()
        #expect(model.spec?.timeline[2].transitionLocked != true)
        model.undo()
        #expect(model.spec?.timeline == cleanTimeline)
        #expect(model.spec?.editor == cleanEditor)
        #expect(!model.canUndo)

        model.redo(); model.redo()
        #expect(model.spec?.timeline[2].transitionIn?.type == .cut)
        #expect(model.spec?.timeline[2].transitionLocked == true)
        model.redo(); model.redo()
        #expect(model.spec?.editor?.tempo == "fast")
        #expect(model.spec?.editor?.pinnedAssets == [sha])
    }

    @Test("Föreslå igen och antal bilder kan ångras, och count/format följer specen")
    func suggestAgainAndCount() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = model.clipRows.map(\.id)
        model.setFormat(.landscape)
        model.setCount(7)
        #expect(model.count == 7)
        #expect(model.undoActionName == "Ändra antal bilder")
        model.undo()
        #expect(model.count == 5)
        #expect(model.format == .landscape)
        model.suggestAgain()
        #expect(model.undoActionName == "Föreslå igen")
        model.startOver()
        #expect(model.undoActionName == "Börja om helt")
        model.undo(); model.undo()
        model.undo()   // formatbytet
        #expect(model.format == .vertical)
        #expect(model.clipRows.map(\.id) == original)
        #expect(!model.canUndo)
    }

    @Test("Ny ändring tömmer gör om-stacken")
    func newChangeClearsRedo() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.setDuration(ids[0], seconds: 4)
        model.undo()
        #expect(model.canRedo)
        model.setDuration(ids[0], seconds: 5)
        #expect(!model.canRedo)
        model.redo()
        #expect(model.clipRows[0].duration == 5)
    }

    @Test("Historiken har tak 100 steg")
    func limit() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[0].id
        for i in 0..<(ReelEditorModel.historyLimit + 20) {
            model.setDuration(id, seconds: 2.0 + Double(i % 2) * 0.5)
        }
        var steps = 0
        while model.canUndo { model.undo(); steps += 1 }
        #expect(steps == ReelEditorModel.historyLimit)
    }

    @Test("Sammanslagning: många ändringar mellan begin och end blir ett steg och en revision")
    func coalescing() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[0].id
        let original = model.clipRows[0].duration
        let revision = model.spec!.revision
        let edits = model.spec!.provenance.edits?.count ?? 0
        model.beginCoalescing()
        for d in [3.1, 3.2, 3.3, 3.4, 3.5] { model.setDuration(id, seconds: d) }
        model.endCoalescing()
        #expect(model.clipRows[0].duration == 3.5)
        #expect(model.spec?.revision == revision + 1)
        #expect(model.spec?.provenance.edits?.count == edits + 1)
        model.undo()
        #expect(model.clipRows[0].duration == original)
        #expect(!model.canUndo)
        // Efter endCoalescing är nästa ändring ett eget steg.
        model.setDuration(id, seconds: 4)
        model.setDuration(id, seconds: 4.5)
        model.undo()
        #expect(model.clipRows[0].duration == 4)
    }

    @Test("Revisionen stiger monotont genom ångra och gör om")
    func revisionMonotonic() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[0].id
        var seen = [model.spec!.revision]
        model.setDuration(id, seconds: 4); seen.append(model.spec!.revision)
        model.setDuration(id, seconds: 5); seen.append(model.spec!.revision)
        model.undo(); seen.append(model.spec!.revision)
        model.undo(); seen.append(model.spec!.revision)
        model.redo(); seen.append(model.spec!.revision)
        model.markSynced(revision: 40, status: "proposed")
        model.undo(); seen.append(model.spec!.revision)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 || $0 == 40 })
        #expect(seen.last! > 40)
        #expect(model.spec?.status == "draft")
    }

    @Test("markSynced är inget ångringssteg")
    func markSyncedNotAStep() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markSynced(revision: 3, status: "proposed")
        #expect(!model.canUndo)
    }

    @Test("Hämta ändringar är ett ångringsbart steg")
    func adoptRemote() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = model.spec!
        var remote = local
        remote.revision = 9
        remote.timeline.removeLast()
        remote.assets.removeLast()
        model.adoptRemoteSpec(remote)
        #expect(model.clipRows.count == 4)
        #expect(model.undoActionName == "Hämta ändringar")
        model.undo()
        #expect(model.clipRows.count == 5)
        #expect(model.spec!.revision > 9)
    }

    @Test("prepare nollställer historiken")
    func prepareResets() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setDuration(model.clipRows[0].id, seconds: 4)
        model.undo()
        #expect(model.canRedo)
        model.prepare(items: items(in: root))
        #expect(!model.canUndo && !model.canRedo)
    }

    @Test("Kopplad till UndoManager: registrerar, ångrar och gör om med stegets namn")
    func undoManagerIntegration() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = UndoManager()
        model.undoManager = manager
        let id = model.clipRows[0].id
        let original = model.clipRows[0].duration
        model.setDuration(id, seconds: 6)
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Ändra längd")
        manager.undo()
        #expect(model.clipRows[0].duration == original)
        #expect(manager.canRedo)
        #expect(model.canRedo)
        manager.redo()
        #expect(model.clipRows[0].duration == 6)
        #expect(manager.canUndo)
        // model.undo() går via managern, så stackarna följer med.
        model.undo()
        #expect(model.clipRows[0].duration == original)
        #expect(manager.canRedo)
    }

    @Test("Markerat klipp och markerad övergång utesluter varandra och rensas när klippet försvinner")
    func transitionSelection() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.selectedAssetID = ids[1]
        model.selectedTransitionAssetID = ids[2]
        #expect(model.selectedAssetID == nil)
        model.selectedAssetID = ids[1]
        #expect(model.selectedTransitionAssetID == nil)
        model.selectedTransitionAssetID = ids[2]
        model.removeClip(ids[2])
        #expect(model.selectedTransitionAssetID == nil)
        model.undo()
        #expect(model.clipRows.count == 5)
    }

    @Test("Markeringar släpps när filmen numreras om: nytt förslag, hämtning, ny mapp och ångra av dem")
    func selectionClearedOnRenumbering() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)

        model.selectedTransitionAssetID = ids[2]
        model.suggestAgain()
        #expect(model.selectedTransitionAssetID == nil)

        model.selectedTransitionAssetID = ids[2]
        model.setCount(6)
        #expect(model.selectedTransitionAssetID == nil)

        model.selectedTransitionAssetID = ids[2]
        model.startOver()
        #expect(model.selectedTransitionAssetID == nil)

        model.selectedTransitionAssetID = ids[2]
        model.undo()   // Börja om
        #expect(model.selectedTransitionAssetID == nil)
        model.selectedAssetID = ids[1]
        model.redo()
        #expect(model.selectedAssetID == nil)

        model.selectedTransitionAssetID = ids[2]
        model.adoptRemoteSpec(model.spec!)
        #expect(model.selectedTransitionAssetID == nil)

        model.selectedTransitionAssetID = ids[2]
        model.prepare(items: items(in: root))
        #expect(model.selectedTransitionAssetID == nil)

        // Vanliga ändringar behåller en markering som finns kvar.
        model.selectedTransitionAssetID = ids[2]
        model.setDuration(ids[0], seconds: 4)
        model.undo()
        #expect(model.selectedTransitionAssetID == ids[2])
    }

    @Test("Sammanslagning gäller bara samma ändring på samma klipp: annat bryter och blir eget steg")
    func coalescingIsScoped() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        let clip = model.spec!.timeline[1]
        func nudged(_ dx: Double) -> ReelSpec.Motion {
            var m = clip.motion
            m.to.zoom = max(m.to.zoom, m.from.zoom) + 0.05 + dx
            return m
        }
        // Som piltangenterna: fönstret öppet, två knuffar på samma klipp.
        model.beginCoalescing()
        model.setCustomMotion(ids[1], fit: clip.fit, motion: nudged(0))
        model.setCustomMotion(ids[1], fit: clip.fit, motion: nudged(0.05))
        let revision = model.spec!.revision
        let edits = model.spec!.provenance.edits?.count ?? 0
        // Inom fönstret: en annan ändring (byt bild) och ett nytt förslag.
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        model.replaceClip(ids[3], withCandidate: spare.id)
        #expect(model.undoActionName == "Byt bild")
        #expect(model.spec!.revision == revision + 1)
        #expect(model.spec!.provenance.edits?.count == edits + 1)
        #expect(model.spec!.provenance.edits?.last?.op == "replace")
        #expect(!model.isCoalescing)
        model.endCoalescing()   // fönstret stängs sent: ofarligt

        model.undo()
        #expect(model.spec!.assets.contains { $0.sha256 == spare.id } == false)
        #expect(model.spec!.timeline[1].motionPreset == "custom")
        #expect(model.undoActionName == "Ändra rörelse")
        model.undo()
        #expect(model.spec!.timeline[1].motionPreset == nil)
        #expect(!model.canUndo)
    }

    @Test("Ångra under ett sammanslaget fönster avslutar det, så nästa knuff öppnar ett nytt steg")
    func undoEndsCoalescing() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[0].id
        model.setDuration(id, seconds: 4)
        model.beginCoalescing()
        model.setDuration(id, seconds: 4.1)
        #expect(model.isCoalescing)
        model.undo()
        #expect(!model.isCoalescing)
    }
}

