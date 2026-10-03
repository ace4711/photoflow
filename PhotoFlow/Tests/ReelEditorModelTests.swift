import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelEditorModel`: omordning, byte av bild, längd, format, rörelseval och
/// att `reel.json` sparas och läses tillbaka. Syntetiska analyser, ingen Vision.
struct ReelEditorModelTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelEditorModelTests-\(UUID().uuidString)")
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

    @Test("Förslaget har 5 klipp, kandidater med poäng och är redo")
    func suggestion() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.phase == .ready)
        #expect(model.clipRows.count == 5)
        #expect(model.candidateRows.count == 7)
        #expect(model.candidateRows.filter { $0.clipIndex != nil }.count == 5)
        #expect(model.clipRows.allSatisfy { !$0.reason.isEmpty })
        #expect(model.totalDuration > 10)
    }

    @Test("Omordning: klippet flyttas, ordningen sparas i reel.json och revisionen höjs")
    func reorder() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.clipRows.map(\.id)
        let token = model.revisionToken
        model.moveClip(before[3], to: 0)
        let after = model.clipRows.map(\.id)
        #expect(after == [before[3], before[0], before[1], before[2], before[4]])
        #expect(model.revisionToken > token)
        #expect(model.spec?.revision == 2)
        let saved = try ReelSpec.decode(from: Data(contentsOf: reel.appendingPathComponent("reel.json")))
        #expect(saved.timeline.map(\.asset) == after)
        #expect(saved.provenance.edits?.last?.op == "reorder")
        // Att släppa på ett annat klipp ger det klippets plats.
        model.moveClip(after[0], before: after[4])
        #expect(model.clipRows.map(\.id).last == after[0])
    }

    @Test("Ta bort ett klipp, men aldrig det sista")
    func remove() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.removeClip(ids[1])
        #expect(model.clipRows.count == 4)
        #expect(!model.clipRows.contains { $0.id == ids[1] })
        for id in model.clipRows.map(\.id).dropFirst() { model.removeClip(id) }
        #expect(model.clipRows.count == 1)
        model.removeClip(model.clipRows[0].id)
        #expect(model.clipRows.count == 1)
    }

    @Test("Byte av bild: kandidaten tar klippets plats, nytt asset-id, gammal bild kan väljas igen")
    func replace() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let unused = try #require(model.candidateRows.first { $0.clipIndex == nil })
        let target = model.clipRows[2]
        model.selectedAssetID = target.id
        model.selectCandidate(unused.id)
        #expect(model.clipRows.count == 5)
        #expect(model.clipRows[2].filename == unused.filename)
        #expect(model.clipRows[2].id != target.id)
        #expect(model.clipRows[2].reason == "Vald av dig")
        #expect(model.selectedAssetID == model.clipRows[2].id)
        // Den utbytta bilden är åter en ledig kandidat.
        #expect(model.candidateRows.first { $0.filename == target.filename }?.clipIndex == nil)
    }

    @Test("Klick utan markerat klipp lägger till sist; klick på vald bild markerar den")
    func addAndSelect() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let unused = model.candidateRows.filter { $0.clipIndex == nil }
        model.selectCandidate(unused[0].id)
        #expect(model.clipRows.count == 6)
        #expect(model.clipRows.last?.filename == unused[0].filename)
        model.selectedAssetID = nil
        let chosen = model.clipRows[1]
        model.selectCandidate(model.candidateRows.first { $0.clipIndex == 1 }!.id)
        #expect(model.selectedAssetID == chosen.id)
        #expect(model.clipRows.count == 6)
    }

    @Test("Längd per klipp: ändras, klampas, följer med vid omordning och kan nollställas")
    func duration() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[2].id
        let total = model.totalDuration
        model.setDuration(id, seconds: 4.0)
        #expect(model.clipRows[2].duration == 4.0 && model.clipRows[2].durationLocked)
        #expect(model.totalDuration > total)
        model.setDuration(id, seconds: 99)
        #expect(model.clipRows[2].duration == ReelEditorModel.durationRange.upperBound)
        model.setDuration(id, seconds: 4.0)
        model.moveClip(id, to: 0)
        #expect(model.clipRows[0].id == id && model.clipRows[0].duration == 4.0)
        model.clearDuration(id)
        #expect(!model.clipRows[0].durationLocked)
        #expect(model.clipRows[0].duration != 4.0)
    }

    @Test("Rörelseval: Zooma ut ger avtagande zoom, och valet följer med vid omordning")
    func preset() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = model.clipRows[1].id
        model.setPreset(id, .zoomOut)
        var clip = try #require(model.spec?.timeline.first { $0.asset == id })
        #expect(clip.motion.from.zoom > clip.motion.to.zoom)
        #expect(model.clipRows[1].preset == .zoomOut)
        model.moveClip(id, to: 3)
        clip = try #require(model.spec?.timeline.first { $0.asset == id })
        #expect(clip.motion.from.zoom > clip.motion.to.zoom)
        model.setPreset(id, .contain)
        #expect(model.spec?.timeline.first { $0.asset == id }?.fit == .containBlur)
        model.setPreset(id, .auto)
        #expect(model.spec?.timeline.first { $0.asset == id }?.motionPreset == nil)
    }

    @Test("Formatbyte byter output men behåller urval, ordning och val")
    func format() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.setPreset(ids[1], .panLeft)
        model.setFormat(.landscape)
        #expect(model.format == .landscape)
        #expect(model.spec?.outputs.first?.aspect == "16:9")
        #expect(model.clipRows.map(\.id) == ids)
        #expect(model.clipRows[1].preset == .panLeft)
        #expect(model.videoURL?.lastPathComponent == "reel_16x9.mp4")
        #expect(model.videoURL?.deletingLastPathComponent() == reel)
        model.setFormat(.vertical)
        #expect(model.videoURL?.lastPathComponent == "reel_9x16.mp4")
    }

    @Test("Antal bilder ger nytt förslag med rätt antal")
    func count() throws {
        let (model, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setCount(3)
        #expect(model.clipRows.count == 3)
        model.setCount(7)
        #expect(model.clipRows.count == 7)
        model.setCount(20)
        #expect(model.count == 8)
        #expect(model.clipRows.count == 7)   // bara sju bilder finns
    }

    @Test("reel.json återställer läget när fönstret öppnas igen (ordning, längd, rörelse, format)")
    func restoreFromSavedSpec() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.clipRows.map(\.id)
        model.moveClip(ids[4], to: 1)
        model.setDuration(ids[0], seconds: 3.7)
        model.setPreset(ids[2], .zoomOut)
        model.setFormat(.square)
        let expected = model.clipRows

        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let reopened = ReelEditorModel()
        reopened.prepare(items: items(in: source), sourceDirectory: source, reelDirectory: reel, address: "Lindvägen 12")
        #expect(reopened.clipRows.map(\.id) == expected.map(\.id))
        #expect(reopened.clipRows.map(\.duration) == expected.map(\.duration))
        #expect(reopened.clipRows.map(\.preset) == expected.map(\.preset))
        #expect(reopened.format == .square)
        #expect(reopened.spec == model.spec)
    }

    @Test("En reel.json vars bilder saknas ignoreras (nytt förslag)")
    func staleSpecIgnored() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.moveClip(model.clipRows[0].id, to: 2)
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let other = ReelEditorModel()
        other.prepare(items: (10..<17).map { item($0, room: "Kök", category: "Interiör", q: 0.7, in: source) },
                      sourceDirectory: source, reelDirectory: reel, address: "Lindvägen 12")
        #expect(other.spec?.revision == 1)
        #expect(other.clipRows.count == 5)
    }

    @Test("Utmappen härleds ur källmappen och ändringar sparas där")
    func outputDirectory() throws {
        let (model, root, reel) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reel.lastPathComponent == "Lindvägen 12 FILM")
        #expect(!FileManager.default.fileExists(atPath: reel.appendingPathComponent("reel.json").path))
        model.setCount(4)
        #expect(FileManager.default.fileExists(atPath: reel.appendingPathComponent("reel.json").path))
        #expect(model.saveError == nil)
    }

    @Test("Historiken: FÄRDIGA-mappen används om den finns, annars mappväljare från outputmappen")
    func launchFromHistory() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let none = ReelLaunchRequest.forSession(outputDirectory: root, address: "Lindvägen 12")
        #expect(none.sourcePath == nil && none.startPath == root.path)
        let finished = AddressFolderLayout.finishedDir(in: root, folderName: "Lindvägen 12")
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        let found = ReelLaunchRequest.forSession(outputDirectory: root, address: "Lindvägen 12")
        #expect(found.sourcePath == finished.path)
        #expect(ReelLaunchRequest.forSession(outputDirectory: root, address: nil).sourcePath == nil)
    }
}
