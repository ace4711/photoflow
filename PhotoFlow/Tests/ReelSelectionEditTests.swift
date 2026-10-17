import Foundation
import Testing
@testable import PhotoFlow

/// Tester för Regi R4, urval: infoga en bild på en plats (`insertCandidate`), byte och lås från
/// rutnätet, rutnätets filter (`ReelCandidateFilter`) och släppzonerna i tidslinjen
/// (`ReelTimelineLayout.externalDrop`). Syntetiska analyser, ingen Vision.
struct ReelSelectionEditTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelSelectionEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let rooms: [(String, String)] = [
        ("Fasad", "Exteriör"), ("Trädgård", "Exteriör"), ("Vardagsrum", "Interiör"), ("Kök", "Interiör"),
        ("Sovrum", "Interiör"), ("Badrum", "Interiör"), ("Hall", "Interiör"), ("Kontor", "Interiör"),
        ("Tvättstuga", "Interiör"), ("Balkong", "Exteriör"), ("Matsal", "Interiör"), ("Gästrum", "Interiör"),
        ("Bastu", "Interiör"), ("Garage", "Exteriör"), ("Förråd", "Interiör"), ("Uteplats", "Exteriör"),
    ]

    private func item(_ n: Int, in dir: URL) -> ReelImageAnalyzer.Item {
        var v = [Float](repeating: 0, count: 16)
        v[n % 16] = 1
        let (room, category) = Self.rooms[n % Self.rooms.count]
        let a = ReelImageAnalysis(
            sha256: String(format: "%064x", n), width: 6000, height: 4000, qualityScore: 0.9 - Double(n) * 0.02,
            isUtility: false, horizonAngleDegrees: nil, sharpness: nil, featurePrint: v.withUnsafeBytes { Data($0) },
            saliencyBoxes: [], focus: .init(x: 0.5, y: 0.5), salientWidth: n == 0 ? 0.9 : 0.4, meanLuminance: 0.45,
            exifDate: nil, room: room, category: category, features: nil, caption: nil)
        return .init(url: dir.appendingPathComponent("bild-\(n).jpg"), analysis: a)
    }

    private func makeModel(images: Int = 8) throws -> (ReelEditorModel, URL) {
        let root = try tempDir()
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let model = ReelEditorModel()
        model.prepare(items: (0..<images).map { item($0, in: source) }, sourceDirectory: source,
                      reelDirectory: AddressFolderLayout.reelDir(forSource: source), address: "Lindvägen 12")
        return (model, root)
    }

    private func sha(of model: ReelEditorModel, clip i: Int) -> String {
        let id = model.spec!.timeline[i].asset
        return model.spec!.assets.first { $0.id == id }!.sha256
    }

    private func shas(_ model: ReelEditorModel) -> [String] {
        (0..<model.spec!.timeline.count).map { sha(of: model, clip: $0) }
    }

    // MARK: insertCandidate

    @Test("Infoga: bilden hamnar på platsen, markeras, och ett ångra tar bort den igen")
    func insertAtPlace() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = shas(model)
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil && $0.excludedReason == nil })
        let steps = model.spec!.revision
        model.insertCandidate(spare.id, at: 2)
        var expected = before
        expected.insert(spare.id, at: 2)
        #expect(shas(model) == expected)
        #expect(model.selectedAssetID == model.spec!.timeline[2].asset)
        #expect(model.spec!.revision == steps + 1)
        #expect(model.undoActionName == "Infoga bild")
        #expect(model.candidateRows.first { $0.id == spare.id }?.selectionReason == "Vald av dig")
        model.undo()
        #expect(shas(model) == before)
        #expect(!model.canUndo)
    }

    @Test("Infoga först, sist och utanför intervallet (klampas)")
    func insertEnds() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let spares = model.candidateRows.filter { $0.clipIndex == nil }.map(\.id)
        model.insertCandidate(spares[0], at: 0)
        #expect(shas(model).first == spares[0])
        model.insertCandidate(spares[1], at: 99)
        #expect(shas(model).last == spares[1])
        model.insertCandidate(spares[2], at: -3)
        #expect(shas(model).first == spares[2])
    }

    @Test("Taket: en full film (12 klipp) tar inte emot fler bilder, och inget steg skapas")
    func insertRespectsCap() throws {
        let (model, root) = try makeModel(images: 15)
        defer { try? FileManager.default.removeItem(at: root) }
        model.setCount(ReelEditorModel.countRange.upperBound)
        #expect(model.spec!.timeline.count == 12)
        #expect(!model.canAddClip)
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        let spec = model.spec
        let undoName = model.undoActionName
        model.insertCandidate(spare.id, at: 3)
        model.addCandidate(spare.id)
        #expect(model.spec == spec)
        #expect(model.undoActionName == undoName)
    }

    @Test("Full film: en bild som redan är med får släppas i en skarv (flytt), en ny får inte")
    func fullFilmAcceptsMoveDrop() throws {
        let (model, root) = try makeModel(images: 15)
        defer { try? FileManager.default.removeItem(at: root) }
        model.setCount(ReelEditorModel.countRange.upperBound)
        #expect(!model.canAddClip)
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        let inFilm = try #require(model.candidateRows.first { $0.clipIndex == 5 })
        #expect(model.canInsertCandidate(inFilm.id))
        #expect(!model.canInsertCandidate(spare.id))
        #expect(!model.canInsertCandidate(nil))
        model.insertCandidate(inFilm.id, at: 0)
        #expect(shas(model).first == inFilm.id)
        #expect(model.spec!.timeline.count == 12)
    }

    @Test("Infoga en bild som redan är med flyttar klippet (ingen dubblett)")
    func insertExistingMoves() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = shas(model)
        // Klipp 0 släpps mellan klipp 2 och 3 (plats 3 i nuvarande ordning).
        model.insertCandidate(before[0], at: 3)
        #expect(shas(model) == [before[1], before[2], before[0], before[3], before[4]])
        #expect(model.undoActionName == "Ändra ordning")
        // Sista klippet till plats 1.
        model.insertCandidate(before[4], at: 1)
        #expect(shas(model) == [before[1], before[4], before[2], before[0], before[3]])
        #expect(Set(shas(model)).count == shas(model).count)
    }

    @Test("Infoga en utesluten bild: den blir inte längre utesluten")
    func insertExcludedUnexcludes() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        model.toggleExcluded(spare.id)
        #expect(model.spec?.editor?.excludedAssets == [spare.id])
        model.insertCandidate(spare.id, at: 1)
        #expect(shas(model)[1] == spare.id)
        #expect(model.spec?.editor?.excludedAssets == nil)
        #expect(model.candidateRows.first { $0.id == spare.id }?.excludedReason == nil)
    }

    @Test("Släpp på ett block med en bild som redan är med: klippen byter plats")
    func replaceWithExistingSwaps() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = shas(model)
        model.replaceClip(model.spec!.timeline[1].asset, withCandidate: before[3])
        #expect(shas(model) == [before[0], before[3], before[2], before[1], before[4]])
        let spec = model.spec
        // Samma bild på sitt eget block: ingenting händer.
        model.replaceClip(model.spec!.timeline[1].asset, withCandidate: before[3])
        #expect(model.spec == spec)
    }

    // MARK: Lås i filmen

    @Test("Lås en bild utanför filmen: den läggs till sist i samma steg; släpp låset behåller den")
    func pinAddsLast() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = shas(model)
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil && $0.excludedReason == nil })
        model.togglePinned(spare.id)
        #expect(shas(model) == before + [spare.id])
        #expect(model.spec?.editor?.pinnedAssets == [spare.id])
        #expect(model.candidateRows.first { $0.id == spare.id }?.isPinned == true)
        #expect(model.undoActionName == "Lås bild")
        model.togglePinned(spare.id)
        #expect(shas(model) == before + [spare.id])
        #expect(model.spec?.editor?.pinnedAssets == nil)
        model.undo(); model.undo()
        #expect(shas(model) == before)
    }

    @Test("Lås en bild när filmen är full: bara markerad, och nästa förslag tar med den")
    func pinWhenFullOnlyMarks() throws {
        let (model, root) = try makeModel(images: 15)
        defer { try? FileManager.default.removeItem(at: root) }
        model.setCount(12)
        let before = shas(model)
        let spare = try #require(model.candidateRows.last { $0.clipIndex == nil && $0.excludedReason == nil })
        model.togglePinned(spare.id)
        #expect(shas(model) == before)
        #expect(model.spec?.editor?.pinnedAssets == [spare.id])
        model.suggestAgain()
        #expect(shas(model).contains(spare.id))
    }

    // MARK: Filter

    private func row(_ id: String, room: String?, category: String? = nil, clip: Int? = nil,
                     excluded: String? = nil) -> ReelEditorModel.CandidateRow {
        .init(id: id, url: nil, filename: "\(id).jpg", room: room, category: category, score: 0.5,
              excludedReason: excluded, clipIndex: clip, isUserExcluded: excluded == "Utesluten av dig")
    }

    private var rows: [ReelEditorModel.CandidateRow] {
        [row("a", room: "Kök", clip: 0),
         row("b", room: "Kök"),
         row("c", room: "Badrum", excluded: "Utesluten av dig"),
         row("d", room: nil, category: "Exteriör", excluded: "Verktygsbild"),
         row("e", room: nil, clip: 1, excluded: "Sned horisont"),
         row("f", room: "Sovrum")]
    }

    @Test("Filter: Alla, I filmen, Ej i filmen och Uteslutna")
    func scopes() {
        func ids(_ s: ReelCandidateFilter.Scope) -> [String] { ReelCandidateFilter.filter(rows, scope: s, room: nil).map(\.id) }
        #expect(ids(.all) == ["a", "b", "c", "d", "e", "f"])
        #expect(ids(.inFilm) == ["a", "e"])
        #expect(ids(.notInFilm) == ["b", "f"])
        // Bortfiltrerade räknas som uteslutna även om fotografen lagt in bilden ändå.
        #expect(ids(.excluded) == ["c", "d", "e"])
        #expect(ReelCandidateFilter.Scope.allCases.map(\.label) == ["Alla", "I filmen", "Ej i filmen", "Uteslutna"])
    }

    @Test("Rumsfilter: rummen som finns, kategori som reserv, och kombination med läget")
    func roomFilter() {
        #expect(ReelCandidateFilter.rooms(rows) == ["Badrum", "Exteriör", "Kök", "Okänt rum", "Sovrum"])
        #expect(ReelCandidateFilter.filter(rows, scope: .all, room: "Kök").map(\.id) == ["a", "b"])
        #expect(ReelCandidateFilter.filter(rows, scope: .notInFilm, room: "Kök").map(\.id) == ["b"])
        #expect(ReelCandidateFilter.filter(rows, scope: .excluded, room: "Exteriör").map(\.id) == ["d"])
        #expect(ReelCandidateFilter.filter(rows, scope: .inFilm, room: "Okänt rum").map(\.id) == ["e"])
        let counts = ReelCandidateFilter.counts(rows, room: "Kök")
        #expect(counts[.all] == 2 && counts[.inFilm] == 1 && counts[.notInFilm] == 1 && counts[.excluded] == 0)
    }

    @Test("Modellens rader: lås, uteslutning och urvalsskäl")
    func candidateRowFlags() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let inFilm = model.candidateRows.filter { $0.clipIndex != nil }
        #expect(inFilm.allSatisfy { $0.selectionReason?.isEmpty == false && !$0.isPinned })
        #expect(model.candidateRows.filter { $0.clipIndex == nil }.allSatisfy { $0.selectionReason == nil })
        let spare = try #require(model.candidateRows.first { $0.clipIndex == nil })
        model.toggleExcluded(spare.id)
        let r = try #require(model.candidateRows.first { $0.id == spare.id })
        #expect(r.isUserExcluded && r.excludedReason == "Utesluten av dig")
        #expect(ReelCandidateFilter.filter(model.candidateRows, scope: .excluded, room: nil).map(\.id).contains(spare.id))
    }

    // MARK: Släppzoner i tidslinjen

    private func layout() -> ReelTimelineLayout.Layout {
        // Tre klipp à 100 px med 20 px överlapp: 0–100, 80–180, 160–260.
        let blocks = [ReelTimelineLayout.Block(index: 0, assetID: "a1", start: 0, duration: 2.5, x: 0, width: 100),
                      .init(index: 1, assetID: "a2", start: 2, duration: 2.5, x: 80, width: 100),
                      .init(index: 2, assetID: "a3", start: 4, duration: 2.5, x: 160, width: 100)]
        return .init(blocks: blocks, joins: [], pixelsPerSecond: 40, totalDuration: 6.5)
    }

    @Test("Släpp från rutnätet: mitten av ett block byter bild, skarvar och ändar infogar")
    func externalDropZones() {
        let l = layout()
        #expect(ReelTimelineLayout.externalDrop(l, x: 50) == .replace(0))
        #expect(ReelTimelineLayout.externalDrop(l, x: 130) == .replace(1))
        #expect(ReelTimelineLayout.externalDrop(l, x: 230) == .replace(2))
        #expect(ReelTimelineLayout.externalDrop(l, x: 5) == .insert(0))
        #expect(ReelTimelineLayout.externalDrop(l, x: 90) == .insert(1))     // i överlappet
        #expect(ReelTimelineLayout.externalDrop(l, x: 175) == .insert(2))
        #expect(ReelTimelineLayout.externalDrop(l, x: 255) == .insert(3))
        #expect(ReelTimelineLayout.externalDrop(l, x: 400) == .insert(3))
        #expect(ReelTimelineLayout.externalDrop(l, x: -10) == .insert(0))
    }

    @Test("Släppindikatorn ritas mitt i skarven, och intern flytt använder samma platsregel")
    func insertionGeometry() {
        let l = layout()
        #expect(ReelTimelineLayout.insertionX(l, at: 0) == 0)
        #expect(ReelTimelineLayout.insertionX(l, at: 1) == 90)
        #expect(ReelTimelineLayout.insertionX(l, at: 2) == 170)
        #expect(ReelTimelineLayout.insertionX(l, at: 3) == 260)
        #expect(ReelTimelineLayout.insertionIndex(l, x: 140) == 2)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 0, dx: 100) == ReelTimelineLayout.insertionIndex(l, x: 150, excluding: 0))
    }

    @Test("Dragdata från rutnätet: eget prefix, annan text avvisas")
    func dragPayload() {
        let id = String(format: "%064x", 7)
        #expect(ReelCandidateDrag.candidateID(from: ReelCandidateDrag.payload(id)) == id)
        #expect(ReelCandidateDrag.candidateID(from: id) == nil)
        #expect(ReelCandidateDrag.candidateID(from: ReelCandidateDrag.prefix) == nil)
        #expect(ReelCandidateDrag.candidateID(from: "https://exempel.se") == nil)
    }

    @Test("Antal bilder i huvudet följer filmen vid infogning, låsning och borttagning")
    func countFollowsFilm() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.clipRows.count
        #expect(model.count == before)
        let outside = try #require(model.candidateRows.first { $0.clipIndex == nil && $0.excludedReason == nil })
        model.insertCandidate(outside.id, at: 1)
        #expect(model.count == before + 1)
        model.removeClip(model.clipRows[0].id)
        #expect(model.count == before)
    }
}
