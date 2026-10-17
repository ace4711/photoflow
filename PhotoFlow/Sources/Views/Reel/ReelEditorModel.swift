import Foundation
import Observation
import SwiftUI

enum ReelWindow {
    static let id = "reel"
}

/// Vad som öppnar bildspelsfönstret: bara värden, så att det går att skicka till
/// `openWindow(id:value:)` (och används som fönstrets identitet).
struct ReelLaunchRequest: Codable, Hashable {
    /// Mapp med färdiga bilder. Nil = användaren väljer.
    var sourcePath: String?
    /// Där mappväljaren börjar när `sourcePath` saknas (sessionens outputmapp).
    var startPath: String?
    /// Sessionens outputmapp (ai_tags.json för rum/bildtext ligger där).
    var outputPath: String?
    var address: String?
    var sessionID: String?
    /// Öppna "Skicka till mäklare" så fort filmen är laddad (filmlistans "Ny länk…").
    var showShare: Bool?

    /// Historiken: `<adress> FÄRDIGA` (eller `<adress> red`) i sessionens outputmapp om den finns, annars
    /// en mappväljare som börjar i outputmappen.
    static func forSession(outputDirectory: URL, address: String?, sessionID: String? = nil) -> ReelLaunchRequest {
        var request = ReelLaunchRequest(startPath: outputDirectory.path, outputPath: outputDirectory.path,
                                        address: address, sessionID: sessionID)
        if let address, !address.isEmpty {
            let finished = AddressFolderLayout.finishedDir(in: outputDirectory, folderName: address)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: finished.path, isDirectory: &isDir), isDir.boolValue {
                request.sourcePath = finished.path
            }
        }
        return request
    }
}

/// Vymodellen för bildspelsfönstret ("Objektfilm"): all logik som inte är ritning.
/// Alla ändringar går via `ReelComposer.rebuild` och sparas i `reel.json`, så att ett
/// nytt öppnande återställer läget. Tung analys och rendering körs utanför huvudtråden
/// (`@concurrent`); modellen själv är MainActor och bara håller tillståndet.
@Observable
final class ReelEditorModel {

    enum Phase: Equatable {
        case idle
        case analyzing(done: Int, total: Int)
        case ready
        case rendering(Double)
        case rendered(URL)
        case failed(String)
    }

    struct ClipRow: Identifiable, Equatable {
        var id: String            // asset-id
        var index: Int
        var url: URL?
        var filename: String
        var room: String?
        var reason: String
        var duration: Double
        var preset: ReelMotionPlanner.Preset
        var durationLocked: Bool
        /// Rutklipp (spec v2): layouten, och andra rutans bild (kollage; hos ett montage samma bild som `url`).
        var layout: ReelSpec.PanelLayout?
        var secondURL: URL?
        var panelKind: ReelPanelEdit.Kind = .none
        /// Klippet är ett rutklipp som fotografen låst (`custom`), till skillnad från planerarens eget.
        var panelsLocked = false
    }

    nonisolated struct CandidateRow: Identifiable, Equatable, Sendable {
        var id: String            // sha256
        var url: URL?
        var filename: String
        var room: String?
        var category: String?
        var score: Double
        /// Bortfallsskäl: urvalets (verktygsbild, sned horisont, oskarp, dubblett) eller "Utesluten av dig".
        var excludedReason: String?
        /// Plats i filmen (0-baserad) om bilden är vald.
        var clipIndex: Int?
        /// Rutan (0-baserad) bilden har i klippet och antalet rutor, när klippet är ett kollage med två
        /// olika bilder; annars nil. Rutnätet visar "klipp N · ruta 1/2".
        var panelIndex: Int?
        var panelCount: Int?
        /// Låst i filmen (`editor.pinnedAssets`).
        var isPinned = false
        /// Utesluten av fotografen (`editor.excludedAssets`), till skillnad från urvalets bortfall.
        var isUserExcluded = false
        /// Urvalsskäl för en bild i filmen (`provenance.autoSelection`), "Vald av dig" för en bild
        /// fotografen lagt in själv; nil för bilder utanför filmen.
        var selectionReason: String?

        /// Platsen i filmen som text: "klipp 3", "klipp 3 · ruta 2/2" för en bild i ett kollage; nil utanför filmen.
        var filmLabel: String? {
            guard let clipIndex else { return nil }
            guard let panelIndex, let panelCount else { return "klipp \(clipIndex + 1)" }
            return "klipp \(clipIndex + 1) · ruta \(panelIndex + 1)/\(panelCount)"
        }

        /// Rummet som visas och filtreras på: rum, annars kategori, annars "Okänt rum".
        var roomLabel: String { room ?? category ?? "Okänt rum" }
    }

    // MARK: Tillstånd

    private(set) var phase: Phase = .idle
    private(set) var sourceDirectory: URL?
    private(set) var reelDirectory: URL?
    private(set) var address = ""
    private(set) var sessionID: String?
    private(set) var items: [ReelImageAnalyzer.Item] = []
    private(set) var candidates: [ReelCandidate] = []
    private(set) var urls: [String: URL] = [:]
    private(set) var selection: ReelSelector.Selection?
    private(set) var spec: ReelSpec?
    /// Ökar för varje ändring av specen, så att förhandsvisningen laddar om.
    private(set) var revisionToken = 0
    private(set) var format: ReelFormat = .vertical
    /// Antal bilder i filmen (följer filmen, 3...12).
    private(set) var count = 5
    /// Fotografens exakta antal (Bilder-steppern), eller nil när antalet är automatiskt. Sparas i
    /// `spec.editor.fixedCount`, så ångra, omstart och "Föreslå igen" följer med.
    var fixedCount: Int? { spec?.editor?.fixedCount }
    private(set) var saveError: String?
    /// Antal klipp med egen rörelse som den senaste ändringen klampade om (t.ex. vid formatbyte).
    /// UI:t kan visa "Egna rörelser har anpassats" när det är > 0.
    private(set) var adaptedCustomMotions = 0
    /// Markerat klipp. Ett markerat klipp och en markerad övergång utesluter varandra.
    var selectedAssetID: String? {
        didSet {
            if selectedAssetID != nil { selectedTransitionAssetID = nil }
            // "Dela ruta med…" gäller ett klipp: väljs ett annat klipp (eller inget) avbryts läget.
            if partnerPickAssetID != nil, partnerPickAssetID != selectedAssetID { partnerPickAssetID = nil }
            if oldValue != selectedAssetID { selectedPanelIndex = 0 }
        }
    }
    /// Markerad övergång, angiven med det *inkommande* klippets asset-id (övergången ligger i
    /// klippets `transitionIn`, så första klippet har ingen).
    var selectedTransitionAssetID: String? {
        didSet { if selectedTransitionAssetID != nil { selectedAssetID = nil } }
    }

    /// "Dela ruta med…": klippet (asset-id) som väntar på att fotografen klickar på en partnerbild i rutnätet.
    /// Nästa klick i rutnätet väljer partner i stället för att markera eller byta (`selectCandidate`).
    var partnerPickAssetID: String?
    /// Vilken ruta i det markerade rutklippet som nästa bild i rutnätet byter (0 = första). Sätts av rutredigeraren.
    var selectedPanelIndex = 0

    static let specFileName = "reel.json"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]
    static let durationRange = 1.0...10.0
    static let countRange = 3...ReelSelector.maxCount

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Fönstrets `UndoManager` (sätts av vyn). Modellen äger historiken; managern får ett anrop
    /// per steg så att ⌘Z, ⇧⌘Z och menyn Redigera fungerar och visar stegets namn.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Injicerbara för tester.
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }

    // MARK: Historik (ångra / gör om)

    /// Ett steg i historiken: tillståndet som ska återställas, och namnet på ändringen (`op`).
    /// Ångra-stacken håller tillståndet *före* ändringen, gör om-stacken tillståndet *efter*.
    private struct HistoryEntry {
        var spec: ReelSpec
        var selection: ReelSelector.Selection?
        var op: String
    }

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    /// Högsta antal ångringssteg.
    static let historyLimit = 100
    @ObservationIgnored private var coalescing = false
    @ObservationIgnored private var coalescedStepOpen = false
    /// Vilken ändring det öppna sammanslagna steget gäller (`op` och klipp), se `recordStep`.
    @ObservationIgnored private var coalescedKey: String?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Namn på nästa ångringssteg ("Ändra ordning"), eller nil.
    var undoActionName: String? { undoStack.last.map { Self.actionName(forOp: $0.op) } }
    var redoActionName: String? { redoStack.last.map { Self.actionName(forOp: $0.op) } }

    /// Svenskt namn på en ändring, härlett från `op` (samma värden som loggas i `provenance.edits`).
    static func actionName(forOp op: String) -> String {
        switch op {
        case "reorder": return "Ändra ordning"
        case "remove": return "Ta bort bild"
        case "add": return "Lägg till bild"
        case "insert": return "Infoga bild"
        case "replace": return "Byt bild"
        case "duration": return "Ändra längd"
        case "motion": return "Ändra rörelse"
        case "transition": return "Ändra övergång"
        case "tempo": return "Ändra tempo"
        case "defaultTransition": return "Ändra standardövergång"
        case "applyTransitionToAll": return "Använd övergång på alla"
        case "easing": return "Ändra rörelsekurva"
        case "background": return "Ändra bakgrund"
        case "orderLock": return "Lås ordning"
        case "panels": return "Ändra rutor"
        case "pair": return "Dela ruta"
        case "splitPanels": return "Dela upp"
        case "swapPanels": return "Byt plats på rutor"
        case "panelLayout": return "Ändra layout"
        case "entrance": return "Ändra ingång"
        case "framing": return "Flytta inramning"
        case "pin": return "Lås bild"
        case "exclude": return "Uteslut bild"
        case "format": return "Byt format"
        case "count": return "Ändra antal bilder"
        case "suggestAgain": return "Föreslå igen"
        case "startOver": return "Börja om helt"
        case "pull": return "Hämta ändringar"
        default: return "Ändra bildspelet"
        }
    }

    /// Slår ihop ändringar mellan `beginCoalescing()` och `endCoalescing()` till ett enda
    /// ångringssteg (och ett enda revisionssteg), t.ex. en dragning som uppdaterar specen löpande.
    /// Bara samma sorts ändring på samma klipp som den första slås ihop; något annat (en annan
    /// `op`, ett annat klipp, ett nytt förslag, en hämtning) avslutar sammanslagningen och blir ett
    /// eget steg, så att t.ex. ett bildbyte strax efter en piltangentsknuff kan ångras för sig.
    func beginCoalescing() {
        coalescing = true
        coalescedStepOpen = false
        coalescedKey = nil
    }

    func endCoalescing() {
        coalescing = false
        coalescedStepOpen = false
        coalescedKey = nil
    }

    /// Pågår en sammanslagning (mellan `beginCoalescing` och `endCoalescing`, och inte avbruten)?
    var isCoalescing: Bool { coalescing }

    /// Lägger nuvarande tillstånd på ångra-stacken inför en ändring. Returnerar false om ändringen
    /// fortsätter ett sammanslaget steg som redan är öppet (samma `op` och `target`; inget nytt steg).
    @discardableResult
    func recordStep(op: String, target: String? = nil) -> Bool {
        guard let spec else { return false }
        if coalescing {
            let key = "\(op)|\(target ?? "")"
            if coalescedStepOpen {
                if key == coalescedKey { return false }
                endCoalescing()
            } else {
                coalescedStepOpen = true
                coalescedKey = key
            }
        }
        undoStack.append(.init(spec: spec, selection: selection, op: op))
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        redoStack.removeAll()
        if let undoManager {
            undoManager.levelsOfUndo = Self.historyLimit
            undoManager.registerUndo(withTarget: self) { $0.undoFromManager() }
            undoManager.setActionName(Self.actionName(forOp: op))
        }
        return true
    }

    private func clearHistory() {
        undoStack.removeAll(); redoStack.removeAll()
        endCoalescing()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Ångrar senaste steget. Går via `UndoManager` när den finns, så att dess stackar följer med.
    func undo() {
        if let undoManager, undoManager.canUndo { undoManager.undo() } else { performUndo() }
    }

    func redo() {
        if let undoManager, undoManager.canRedo { undoManager.redo() } else { performRedo() }
    }

    /// Anropas av `UndoManager` under ångra: återställer och registrerar gör om-steget.
    private func undoFromManager() {
        guard let op = performUndo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.redoFromManager() }
        undoManager?.setActionName(Self.actionName(forOp: op))
    }

    private func redoFromManager() {
        guard let op = performRedo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.undoFromManager() }
        undoManager?.setActionName(Self.actionName(forOp: op))
    }

    @discardableResult
    private func performUndo() -> String? {
        guard let entry = undoStack.popLast(), let current = spec else { return nil }
        redoStack.append(.init(spec: current, selection: selection, op: entry.op))
        restore(entry, replacing: current, op: "undo")
        return entry.op
    }

    @discardableResult
    private func performRedo() -> String? {
        guard let entry = redoStack.popLast(), let current = spec else { return nil }
        undoStack.append(.init(spec: current, selection: selection, op: entry.op))
        restore(entry, replacing: current, op: "redo")
        return entry.op
    }

    /// Återställer specen från ett historiksteg. Revisionen höjs till över både nuvarande och den
    /// återställda: en äldre spec med lägre revision skulle annars se ut som "ingen ändring" (eller
    /// som en äldre version) för synken mot mäklaren, som jämför revisionsnummer. Samma skäl gör
    /// att status blir "draft" och en `edit` loggas, precis som för vilken annan ändring som helst.
    private func restore(_ entry: HistoryEntry, replacing current: ReelSpec, op: String) {
        endCoalescing()
        var restored = entry.spec
        restored.revision = max(current.revision, restored.revision) + 1
        let stamp = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        restored.updatedAt = stamp
        restored.status = "draft"
        restored.provenance.edits = (restored.provenance.edits ?? []) + [.init(at: stamp, by: restored.updatedBy.role, op: op)]
        spec = restored
        selection = entry.selection
        format = ReelFormat(rawValue: restored.outputs.first?.id ?? "") ?? format
        count = min(max(restored.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        adaptedCustomMotions = 0
        // Steg som numrerar om asset-id:n: samma id kan nu vara en annan bild.
        if Self.renumberingOps.contains(entry.op) { clearSelection() }
        dropStaleSelection()
        revisionToken += 1
        if case .rendered = phase { phase = .ready }
        saveSpec()
    }

    /// Ändringar som ersätter hela filmen och numrerar om asset-id:n (a1…an), så att en markering
    /// efter dem skulle peka på en annan bild eller skarv.
    private static let renumberingOps: Set<String> = ["suggestAgain", "startOver", "count", "pull"]

    /// Avmarkerar klipp och övergång, så att sidopanelen visar filmens stil.
    func clearSelection() {
        selectedAssetID = nil
        selectedTransitionAssetID = nil
    }

    /// Släpper markeringar som pekar på klipp som inte finns kvar.
    private func dropStaleSelection() {
        let ids = Set(order)
        if let id = selectedAssetID, !ids.contains(id) { selectedAssetID = nil }
        if let id = selectedTransitionAssetID, !ids.contains(id) || order.first == id { selectedTransitionAssetID = nil }
    }

    // MARK: Härledda värden

    var totalDuration: Double { spec.map(ReelTimeline.totalDuration) ?? 0 }
    var specURL: URL? { reelDirectory?.appendingPathComponent(Self.specFileName) }
    var hasFilm: Bool { !(spec?.timeline.isEmpty ?? true) }
    var isBusy: Bool {
        switch phase { case .analyzing, .rendering: return true; default: return false }
    }

    var videoURL: URL? {
        guard let spec, let out = spec.outputs.first, let dir = reelDirectory else { return nil }
        return dir.appendingPathComponent("reel_\(out.aspect.replacingOccurrences(of: ":", with: "x")).mp4")
    }

    var clipRows: [ClipRow] {
        guard let spec else { return [] }
        let reasons = Dictionary((spec.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) },
                                 uniquingKeysWith: { a, _ in a })
        return spec.timeline.enumerated().map { i, clip in
            let asset = spec.assets.first { $0.id == clip.asset }
            let candidate = candidates.first { $0.id == asset?.sha256 }
            return ClipRow(
                id: clip.asset, index: i,
                url: asset.flatMap { urls[$0.sha256] },
                filename: candidate?.filename ?? asset?.sources.first?.path ?? clip.asset,
                room: asset?.analysis?.room,
                reason: reasons[clip.asset] ?? "Vald av dig",
                duration: clip.duration,
                preset: clip.motionPreset.flatMap(ReelMotionPlanner.Preset.init(rawValue:)) ?? .auto,
                durationLocked: clip.durationLocked == true,
                layout: clip.fit == .panels ? clip.layout : nil,
                secondURL: clip.panels.flatMap { $0.count > 1 ? $0[1] : nil }.flatMap { p in
                    spec.assets.first { $0.id == p.asset }.flatMap { urls[$0.sha256] }
                },
                panelKind: ReelPanelEdit.kind(of: clip), panelsLocked: ReelPanelEdit.isLocked(clip))
        }
    }

    /// Alla bilder med poäng, bäst först; bortfiltrerade sist med skälet.
    var candidateRows: [CandidateRow] {
        let scores = selection?.scores ?? [:]
        let excluded = Dictionary((selection?.excluded ?? []).map { ($0.candidateID, $0.reason) },
                                  uniquingKeysWith: { a, _ in a })
        // Bild (sha256) → första klippet som visar den, även som ruta i ett rutklipp. Samma bild kan
        // förekomma flera gånger (montage i sequence har samma bild i båda rutorna): första klippet gäller.
        var placed: [String: Int] = [:]
        for (i, clip) in (spec?.timeline ?? []).enumerated() {
            for id in clip.referencedAssetIDs {
                if let sha = spec?.assets.first(where: { $0.id == id })?.sha256, placed[sha] == nil { placed[sha] = i }
            }
        }
        let userExcluded = Set(spec?.editor?.excludedAssets ?? [])
        let pinned = Set(spec?.editor?.pinnedAssets ?? [])
        let reasons = Dictionary((spec?.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) },
                                 uniquingKeysWith: { a, _ in a })
        let rows = candidates.map { c in
            let index = placed[c.id]
            // Bildens egen asset i klippet (en kollagepartner har ett annat asset än klippets).
            let clip = index.flatMap { spec?.timeline[$0] }
            let panelAsset = clip.flatMap { clip in
                clip.referencedAssetIDs.first { id in spec?.assets.first(where: { $0.id == id })?.sha256 == c.id }
            }
            let assetID = panelAsset ?? clip?.asset
            var panelIndex: Int?, panelCount: Int?
            if let clip, ReelPanelEdit.kind(of: clip) == .collage, let at = clip.panels?.firstIndex(where: { $0.asset == panelAsset }) {
                panelIndex = at; panelCount = clip.panels?.count
            }
            return CandidateRow(id: c.id, url: urls[c.id], filename: c.filename, room: c.room, category: c.category,
                                score: scores[c.id] ?? 0,
                                excludedReason: userExcluded.contains(c.id) ? "Utesluten av dig" : excluded[c.id],
                                clipIndex: index, panelIndex: panelIndex, panelCount: panelCount,
                                isPinned: pinned.contains(c.id), isUserExcluded: userExcluded.contains(c.id),
                                selectionReason: assetID.map { reasons[$0] ?? "Vald av dig" })
        }
        return rows.sorted {
            if ($0.excludedReason == nil) != ($1.excludedReason == nil) { return $0.excludedReason == nil }
            return $0.score > $1.score
        }
    }

    // MARK: Källa och analys

    /// Bildfilerna i en mapp, i filnamnsordning, utan TIFF-tvillingar (se `ReelFileIndex.withoutTiffTwins`).
    /// `filmDirectory`: filmmappen, vars `reel.json` talar om vilka TIFF-filer som ändå ska vara med.
    static func imageFiles(in directory: URL, filmDirectory: URL? = nil) -> [URL] {
        ReelFileIndex.filmImages(in: directory, filmDirectory: filmDirectory)
    }

    /// Öppnar en källmapp: analyserar (cache i `reel_analysis.json` i utmappen) och föreslår film.
    func open(source: URL, address: String? = nil, sessionID: String? = nil, aiTagsDirectory: URL? = nil) {
        cancelAll()
        let source = source.resolvingSymlinksInPath()
        let reelDir = AddressFolderLayout.reelDir(forSource: source)
        let files = Self.imageFiles(in: source, filmDirectory: reelDir)
        guard !files.isEmpty else {
            phase = .failed("Inga bilder hittades i \"\(source.lastPathComponent)\".")
            return
        }
        reset()
        sourceDirectory = source
        reelDirectory = reelDir
        self.address = address ?? AddressFolderLayout.addressName(fromSourceDir: source.lastPathComponent) ?? source.lastPathComponent
        self.sessionID = sessionID
        phase = .analyzing(done: 0, total: files.count)
        let ownerDir = reelDir
        let tags = aiTagsDirectory ?? source
        analysisTask = Task { [weak self] in
            do {
                let items = try await Self.analyze(files: files, cacheDirectory: ownerDir, aiTagsDirectory: tags) { done, total in
                    self?.analysisProgress(done: done, total: total)
                }
                guard let self, !Task.isCancelled else { return }
                guard !items.isEmpty else { self.phase = .failed("Ingen av bilderna gick att analysera."); return }
                self.prepare(items: items)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Analysen körs utanför huvudtråden (cacheläsning och skrivning ingår).
    @concurrent
    private static func analyze(files: [URL], cacheDirectory: URL, aiTagsDirectory: URL,
                                progress: @escaping @Sendable @MainActor (Int, Int) -> Void) async throws -> [ReelImageAnalyzer.Item] {
        try await ReelImageAnalyzer.analyze(urls: files, cacheDirectory: cacheDirectory,
                                            aiTagsDirectory: aiTagsDirectory, progress: progress)
    }

    private func analysisProgress(done: Int, total: Int) {
        if case .analyzing = phase { phase = .analyzing(done: done, total: total) }
    }

    /// Tar emot färdiga analyser: återställer `reel.json` om den finns och passar, annars
    /// föreslår filmen. Synkron och utan disk utöver `reel.json`, så den går att testa.
    func prepare(items: [ReelImageAnalyzer.Item], sourceDirectory: URL? = nil, reelDirectory: URL? = nil,
                 address: String? = nil, sessionID: String? = nil) {
        if let sourceDirectory { self.sourceDirectory = sourceDirectory }
        if let reelDirectory { self.reelDirectory = reelDirectory }
        if let address { self.address = address }
        if let sessionID { self.sessionID = sessionID }
        self.items = items
        let specDir = self.reelDirectory ?? FileManager.default.temporaryDirectory
        let result = ReelComposer.compose(items: items, specDirectory: specDir, options: options())
        candidates = result.candidates
        urls = result.urls
        selection = result.selection
        spec = result.spec
        if let restored = restoredSpec(specDirectory: specDir) {
            spec = restored
            format = ReelFormat(rawValue: restored.outputs.first?.id ?? "") ?? format
            count = min(max(restored.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        }
        clearSelection()
        clearHistory()
        revisionToken += 1
        phase = .ready
    }

    private func options() -> ReelComposer.Options {
        var o = ReelComposer.Options()
        o.count = fixedCount
        o.format = format
        o.address = address
        o.curated = sourceDirectory.map(AddressFolderLayout.isCuratedSource) ?? false
        o.sessionID = sessionID
        o.now = now()
        return o
    }

    /// `reel.json` från en tidigare session, om den går att läsa och alla bilder finns kvar
    /// (matchade på innehållshash, så en omdöpt fil fungerar). Källsökvägarna uppdateras.
    private func restoredSpec(specDirectory: URL) -> ReelSpec? {
        let file = specDirectory.appendingPathComponent(Self.specFileName)
        guard let data = try? Data(contentsOf: file), let saved = try? ReelSpec.decode(from: data),
              saved.isReadable, !saved.timeline.isEmpty else { return nil }
        let bySha = Dictionary(items.map { ($0.analysis.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        var restored = saved
        for i in restored.assets.indices {
            guard let item = bySha[restored.assets[i].sha256] else { return nil }
            restored.assets[i].sources = [.init(kind: .local, path: ReelComposer.relativePath(from: specDirectory, to: item.url))]
        }
        let known = Set(restored.assets.map(\.id))
        guard restored.timeline.allSatisfy({ clip in clip.referencedAssetIDs.allSatisfy(known.contains) }) else { return nil }
        return restored
    }

    private func reset() {
        items = []; candidates = []; urls = [:]; selection = nil; spec = nil
        clearSelection(); saveError = nil
        clearHistory()
        revisionToken += 1
    }

    func cancelAll() {
        analysisTask?.cancel(); analysisTask = nil
        renderTask?.cancel(); renderTask = nil
    }

    // MARK: Redigering (allt via ReelComposer.rebuild)

    var order: [String] { spec?.timeline.map(\.asset) ?? [] }

    /// `editor` ändrar redigerarens val (`spec.editor`) i samma steg; tomma val tas bort. `target` är
    /// klippet ändringen gäller (för sammanslagning, se `beginCoalescing`).
    ///
    /// `edit` ändrar specen (klippens rutor) innan den byggs om; fotografens val läses sedan ur den
    /// ändrade specen (`ReelComposer.overrides(in:)`), så ett rutklipp som låsts med `edit` bevaras.
    func apply(order: [String], newAssets: [ReelSpec.Asset] = [], format: ReelFormat? = nil,
               overrides: [String: ReelMotionPlanner.ClipOverride]? = nil,
               editor: ((inout ReelSpec.EditorState) -> Void)? = nil,
               style: ((inout ReelSpec.Style) -> Void)? = nil,
               edit: ((inout ReelSpec) -> Void)? = nil, op: String, target: String? = nil) {
        guard var current = spec else { return }
        let continuesStep = !recordStep(op: op, target: target)
        if let edit { edit(&current) }
        if let style { style(&current.style) }
        if let editor {
            var e = current.editor ?? .init()
            editor(&e)
            current.editor = e.normalized
        }
        var rebuilt = ReelComposer.rebuild(current, order: order, newAssets: newAssets, format: format,
                                           overrides: overrides, op: op, now: now())
        if continuesStep {
            // Fortsättning på ett sammanslaget steg: samma revision och samma loggpost som första ändringen.
            rebuilt.revision = current.revision
            rebuilt.provenance.edits = current.provenance.edits
        }
        // Ett fast antal följer filmen när klipp läggs till eller tas bort för hand.
        if var e = rebuilt.editor, e.fixedCount != nil {
            e.fixedCount = min(max(rebuilt.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
            rebuilt.editor = e
        }
        adaptedCustomMotions = ReelComposer.adaptedCustomMotions(from: current, to: rebuilt)
        spec = rebuilt
        if let format { self.format = format }
        // "Bilder: N" i huvudet följer filmen när klipp läggs till eller tas bort för hand.
        count = min(max(rebuilt.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        dropStaleSelection()
        revisionToken += 1
        if case .rendered = phase { phase = .ready }
        saveSpec()
    }

    func currentOverrides() -> [String: ReelMotionPlanner.ClipOverride] {
        spec.map(ReelComposer.overrides(in:)) ?? [:]
    }

    func nextAssetID() -> String {
        let used = (spec?.assets ?? []).compactMap { Int($0.id.dropFirst()) }
        return "a\((used.max() ?? 0) + 1)"
    }

    func newAsset(forCandidate id: String) -> ReelSpec.Asset? {
        guard let item = items.first(where: { $0.analysis.sha256 == id }) else { return nil }
        return ReelComposer.asset(id: nextAssetID(), item: item, specDirectory: reelDirectory ?? FileManager.default.temporaryDirectory)
    }

    /// Flyttar klippet till plats `index` (0-baserad, i listan efter att klippet tagits bort).
    func moveClip(_ assetID: String, to index: Int) {
        var o = order
        guard let from = o.firstIndex(of: assetID) else { return }
        o.remove(at: from)
        o.insert(assetID, at: min(max(index, 0), o.count))
        guard o != order else { return }
        apply(order: o, op: "reorder")
    }

    func moveClip(_ assetID: String, before target: String) {
        guard assetID != target, let t = order.firstIndex(of: target) else { return }
        // Klippet tar målets plats (dras det framåt hamnar det alltså efter målet, bakåt före).
        moveClip(assetID, to: t)
    }

    func removeClip(_ assetID: String) {
        guard order.count > 1, order.contains(assetID) else { return }
        var o = order
        o.removeAll { $0 == assetID }
        if selectedAssetID == assetID { selectedAssetID = nil }
        apply(order: o, op: "remove")
    }

    /// Får en bild till läggas till (filmen har färre än `countRange.upperBound` klipp)?
    var canAddClip: Bool { order.count < Self.countRange.upperBound }

    /// Får bilden (sha256) släppas i en skarv i tidslinjen? Ja om det finns plats, eller om den redan
    /// är med (då flyttas klippet, se `insertCandidate`). nil (okänd bild) räknas som ny.
    func canInsertCandidate(_ id: String?) -> Bool {
        canAddClip || id.flatMap(assetID(forCandidate:)) != nil
    }

    /// Bilden som just nu dras från rutnätet (sätts när dragningen börjar), så att tidslinjen kan visa
    /// om ett släpp i en skarv går innan dragdatan lästs. Kan vara kvar efter en avbruten dragning.
    var draggedCandidateID: String?

    /// Klippets asset-id om bilden (sha256) redan är med i filmen.
    func assetID(forCandidate id: String) -> String? {
        guard let spec else { return nil }
        let inFilm = Set(order)
        // Först klippens egna bilder; en bild som bara är ruta i ett rutklipp räknas som med via klippets bild.
        if let own = spec.assets.first(where: { $0.sha256 == id && inFilm.contains($0.id) }) { return own.id }
        let panelIDs = Set(spec.timeline.flatMap(\.referencedAssetIDs))
        guard let partner = spec.assets.first(where: { $0.sha256 == id && panelIDs.contains($0.id) }) else { return nil }
        return spec.timeline.first { $0.referencedAssetIDs.contains(partner.id) }?.asset
    }

    /// En bild som fotografen själv lägger in i filmen är inte längre utesluten.
    static func unexclude(_ id: String) -> (inout ReelSpec.EditorState) -> Void {
        { $0.excludedAssets?.removeAll { $0 == id } }
    }

    /// Lägger bilden sist i filmen (högst `countRange.upperBound` klipp).
    func addCandidate(_ id: String) {
        guard canAddClip, let asset = newAsset(forCandidate: id) else { return }
        apply(order: order + [asset.id], newAssets: [asset], editor: Self.unexclude(id), op: "add")
        selectedAssetID = asset.id
    }

    /// Infogar bilden som nytt klipp på plats `index` (0 = först, antal klipp = sist), inom taket
    /// `countRange.upperBound` och som ett ångringssteg. Är bilden redan med i filmen flyttas dess
    /// klipp dit i stället (ingen dubblett); `index` räknas då i nuvarande ordning, alltså före flytten.
    /// En utesluten bild blir inte längre utesluten.
    func insertCandidate(_ id: String, at index: Int) {
        let clamped = min(max(index, 0), order.count)
        if let existing = assetID(forCandidate: id), let from = order.firstIndex(of: existing) {
            moveClip(existing, to: from < clamped ? clamped - 1 : clamped)
            selectedAssetID = existing
            return
        }
        guard canAddClip, let asset = newAsset(forCandidate: id) else { return }
        var o = order
        o.insert(asset.id, at: clamped)
        apply(order: o, newAssets: [asset], editor: Self.unexclude(id), op: "insert")
        selectedAssetID = asset.id
    }

    /// Byter klippets bild mot en annan; klippets rörelseval och längd följer inte med. Är bilden
    /// redan med i filmen byter de två klippen plats i stället (ingen dubblett). En utesluten bild
    /// blir inte längre utesluten.
    func replaceClip(_ assetID: String, withCandidate id: String) {
        // Ett kollage behåller sina rutor: bilden byter markerad ruta (första om ingen) i stället för att ta bort kollaget.
        if panelKind(forAsset: assetID) == .collage, self.assetID(forCandidate: id) == nil {
            replacePanel(assetID, panel: selectedAssetID == assetID ? selectedPanelIndex : 0, withCandidate: id)
            return
        }
        guard let pos = order.firstIndex(of: assetID) else { return }
        if let existing = self.assetID(forCandidate: id) {
            guard existing != assetID, let other = order.firstIndex(of: existing) else { return }
            var o = order
            o.swapAt(pos, other)
            apply(order: o, op: "reorder")
            selectedAssetID = existing
            return
        }
        guard let asset = newAsset(forCandidate: id) else { return }
        var o = order
        o[pos] = asset.id
        apply(order: o, newAssets: [asset], editor: Self.unexclude(id), op: "replace")
        selectedAssetID = asset.id
    }

    /// Klick i kandidatrutnätet: redan vald bild markeras, annars byts det markerade klippets bild,
    /// och utan markerat klipp läggs bilden till sist.
    func selectCandidate(_ id: String) {
        // "Dela ruta med…" pågår: bilden blir partner (en ogiltig bild avbryter inte läget).
        if let anchor = partnerPickAssetID {
            if pairClip(anchor, withCandidate: id) { partnerPickAssetID = nil }
            return
        }
        if let row = candidateRows.first(where: { $0.id == id }), let i = row.clipIndex {
            selectedAssetID = order[i]
        } else if let selectedAssetID, order.contains(selectedAssetID) {
            if panelKind(forAsset: selectedAssetID) == .collage {
                replacePanel(selectedAssetID, panel: selectedPanelIndex, withCandidate: id)
            } else {
                replaceClip(selectedAssetID, withCandidate: id)
            }
        } else {
            addCandidate(id)
        }
    }

    func setDuration(_ assetID: String, seconds: Double) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        // Hundradelar: snäppta dragningar (0,1 s) ska inte skriva flyttalsbrus som 3.4000000000000004.
        let clamped = min(max(seconds, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        entry.duration = (clamped * 100).rounded() / 100
        o[assetID] = entry
        apply(order: order, overrides: o, op: "duration", target: assetID)
    }

    /// Tillbaka till automatisk längd för klippet.
    func clearDuration(_ assetID: String) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.duration = nil
        o[assetID] = entry.isDefault ? nil : entry
        apply(order: order, overrides: o, op: "duration", target: assetID)
    }

    /// Förval av rörelse. `.custom` utan egen rörelse sedan tidigare utgår från klippets nuvarande
    /// fit och rörelse; vilket annat förval som helst släpper en egen rörelse.
    func setPreset(_ assetID: String, _ preset: ReelMotionPlanner.Preset) {
        guard !isPanelsClip(assetID) else { return }
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.preset = preset
        if preset == .custom {
            if entry.custom == nil, let clip = spec?.timeline.first(where: { $0.asset == assetID }) {
                entry.custom = .init(fit: clip.fit, motion: clip.motion)
            }
        } else {
            entry.custom = nil
        }
        o[assetID] = entry.isDefault ? nil : entry
        apply(order: order, overrides: o, op: "motion", target: assetID)
    }

    /// Egen rörelse (dragna start/slut): låser klippets rörelse som `custom`.
    func setCustomMotion(_ assetID: String, fit: ReelSpec.Fit, motion: ReelSpec.Motion) {
        guard !isPanelsClip(assetID) else { return }
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.preset = .custom
        entry.custom = .init(fit: fit, motion: motion)
        o[assetID] = entry
        apply(order: order, overrides: o, op: "motion", target: assetID)
    }

    /// Är klippet ett rutklipp (spec v2)? Det har ingen rörelseredigering förrän R6d: rörelseändringar ignoreras.
    func isPanelsClip(_ assetID: String) -> Bool {
        spec?.timeline.first(where: { $0.asset == assetID })?.fit == .panels
    }

    /// Klippets analys (matchad mot assetens sha256), för motivlager och "Centrera på motivet".
    func analysis(forAsset assetID: String) -> ReelImageAnalysis? {
        guard let sha = spec?.assets.first(where: { $0.id == assetID })?.sha256 else { return nil }
        return items.first { $0.analysis.sha256 == sha }?.analysis
    }

    /// Varför klippet fick sin rörelse (plan 4.5): beräknas på nytt ur specen med planerarens
    /// regel (`ReelMotionPlanner.motionReasons`), med klippens nuvarande lås. "Vald av dig" när
    /// rörelsen är ett förval eller dragen för hand.
    func motionReason(forAsset assetID: String) -> ReelMotionPlanner.MotionReason? {
        guard let spec, let i = spec.timeline.firstIndex(where: { $0.asset == assetID }) else { return nil }
        let reasons = Self.motionReasons(spec)
        return reasons.indices.contains(i) ? reasons[i] : nil
    }

    /// Rörelseskälen för alla klipp i specens ordning (samma indata som `ReelComposer.rebuild` ger planeraren).
    nonisolated static func motionReasons(_ spec: ReelSpec) -> [ReelMotionPlanner.MotionReason] {
        let byID = Dictionary(spec.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let assets = spec.timeline.compactMap { byID[$0.asset] }
        guard assets.count == spec.timeline.count, let output = spec.outputs.first else { return [] }
        let images = Dictionary(ReelComposer.plannerImages(spec.assets).map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var collages: [String: ReelMotionPlanner.Image] = [:]
        for clip in spec.timeline {
            if let partner = ReelComposer.autoCollagePartner(clip).flatMap({ images[$0] }) { collages[clip.asset] = partner }
        }
        return ReelMotionPlanner.motionReasons(ReelComposer.plannerImages(assets),
                                               frameAspect: ReelMotionPlanner.frameAspect(output),
                                               overrides: ReelComposer.overrides(in: spec), collages: collages)
    }

    /// Bildens storlek och utformatets bildförhållande för geometriberäkningar i rörelseeditorn.
    func motionGeometryContext(forAsset assetID: String) -> (imageSize: CGSize, frameAspect: Double)? {
        guard let spec, let asset = spec.assets.first(where: { $0.id == assetID }),
              let output = spec.outputs.first, asset.width > 0, asset.height > 0 else { return nil }
        return (CGSize(width: asset.width, height: asset.height), ReelMotionPlanner.frameAspect(output))
    }

    /// Byter start och slut på klippets rörelse. Låser rörelsen som egen (`custom`).
    func swapMotionEnds(_ assetID: String) {
        guard let clip = spec?.timeline.first(where: { $0.asset == assetID }) else { return }
        setCustomMotion(assetID, fit: clip.fit, motion: .init(from: clip.motion.to, to: clip.motion.from))
    }

    /// Flyttar båda ramarnas mitt till motivets tyngdpunkt (analysens `focus`), med bibehållen zoom
    /// och klampat mot bilden. Gör inget utan känt motiv.
    func centerMotionOnSubject(_ assetID: String) {
        guard let clip = spec?.timeline.first(where: { $0.asset == assetID }),
              let focus = analysis(forAsset: assetID)?.focus,
              let g = motionGeometryContext(forAsset: assetID) else { return }
        func centered(_ key: ReelSpec.MotionKey) -> ReelSpec.MotionKey {
            ReelMotionGeometry.clamped(.init(cx: focus.x, cy: focus.y, zoom: key.zoom),
                                       fit: clip.fit, imageSize: g.imageSize, frameAspect: g.frameAspect)
        }
        setCustomMotion(assetID, fit: clip.fit, motion: .init(from: centered(clip.motion.from), to: centered(clip.motion.to)))
    }

    /// Låser klippets övergång in. `nil` = låst på filmens standardövergång; `{type: cut}` ger hårt klipp.
    func setTransition(_ assetID: String, _ transition: ReelSpec.Transition?) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.transitionLocked = true
        entry.transition = transition
        o[assetID] = entry
        apply(order: order, overrides: o, op: "transition", target: assetID)
    }

    /// Tillbaka till automatisk övergång för klippet.
    func clearTransition(_ assetID: String) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.transitionLocked = false
        entry.transition = nil
        o[assetID] = entry.isDefault ? nil : entry
        apply(order: order, overrides: o, op: "transition", target: assetID)
    }

    /// Ändrar filmens stil (standardövergång, rörelsekurva, bakgrund). Går via `apply`: ett
    /// ångringssteg, ny revision, sparas, och automatiska övergångar planeras om efter den nya
    /// standardövergången. Låsta övergångar påverkas inte. Ingen ändring = inget steg.
    func setStyle(_ change: @escaping (inout ReelSpec.Style) -> Void, op: String) {
        guard let current = spec else { return }
        var changed = current.style
        change(&changed)
        guard changed != current.style else { return }
        apply(order: order, style: change, op: op)
    }

    /// "Använd på alla": gör övergången in till klippet `assetID` till filmens standardövergång och
    /// släpper låsen på alla övergångar, så att alla följer stilen. Ett ångringssteg.
    func applyTransitionToAll(from assetID: String) {
        guard let spec, let i = spec.timeline.firstIndex(where: { $0.asset == assetID }), i > 0 else { return }
        var transition = spec.timeline[i].transitionIn ?? spec.style.defaultTransition
        if transition.type != .push { transition.direction = nil }
        var o = currentOverrides()
        for (id, var entry) in o {
            entry.transitionLocked = false
            entry.transition = nil
            o[id] = entry.isDefault ? nil : entry
        }
        apply(order: order, overrides: o, style: { $0.defaultTransition = transition }, op: "applyTransitionToAll")
    }

    func setTempo(_ tempo: ReelMotionPlanner.Tempo) {
        apply(order: order, editor: { $0.tempo = tempo.rawValue }, op: "tempo")
    }

    func setOrderLocked(_ locked: Bool) {
        apply(order: order, editor: { $0.orderLocked = locked }, op: "orderLock")
    }

    /// Låser/släpper en bild (sha256) som "ska vara med" vid nästa förslag. Låsning släpper en
    /// uteslutning. En låst bild som inte är med i filmen läggs till sist i samma ångringssteg om
    /// det finns plats (under `countRange.upperBound`); är filmen full markeras den bara som låst och
    /// kommer med vid nästa "Föreslå igen" (som då kan göra filmen längre än begärt antal). Att
    /// släppa låset tar inte bort bilden ur filmen.
    func togglePinned(_ candidateID: String) {
        let pinning = !(spec?.editor?.pinnedAssets ?? []).contains(candidateID)
        var o = order
        var added: [ReelSpec.Asset] = []
        if pinning, assetID(forCandidate: candidateID) == nil, canAddClip, let asset = newAsset(forCandidate: candidateID) {
            o.append(asset.id)
            added = [asset]
        }
        // Att låsa en bild i ett automatiskt kollage låser kollaget som det är (båda bilderna och layouten
        // följer med vid "Föreslå igen"); det släpps med "Tillbaka till automatiskt".
        var lockIndex: Int?
        if pinning, let spec {
            lockIndex = spec.timeline.firstIndex { clip in
                ReelComposer.autoCollagePartner(clip) != nil
                    && clip.referencedAssetIDs.contains { rid in spec.assets.first { $0.id == rid }?.sha256 == candidateID }
            }
        }
        apply(order: o, newAssets: added, editor: { e in
            var pinned = e.pinnedAssets ?? []
            if let i = pinned.firstIndex(of: candidateID) { pinned.remove(at: i) } else {
                pinned.append(candidateID)
                e.excludedAssets?.removeAll { $0 == candidateID }
            }
            e.pinnedAssets = pinned
        }, edit: lockIndex.map { i in { $0.timeline[i].motionPreset = ReelMotionPlanner.Preset.custom.rawValue } }, op: "pin")
        if let asset = added.first { selectedAssetID = asset.id }
    }

    /// Utesluter/återtar en bild (sha256). Uteslutning släpper en låsning, och en bild som är med i
    /// filmen tas bort ur den om filmen har fler än ett klipp.
    func toggleExcluded(_ candidateID: String) {
        let excluding = !(spec?.editor?.excludedAssets ?? []).contains(candidateID)
        var o = order
        // Ett kollage som fotografen låst: den uteslutna bilden går ur, den andra blir ett vanligt klipp på samma plats.
        var splitEdit: ((inout ReelSpec) -> Void)?
        if excluding, let spec,
           let i = spec.timeline.firstIndex(where: { clip in
               ReelPanelEdit.kind(of: clip) == .collage && ReelPanelEdit.isLocked(clip)
                   && clip.referencedAssetIDs.contains { rid in spec.assets.first { $0.id == rid }?.sha256 == candidateID }
           }) {
            let clip = spec.timeline[i]
            if let keep = clip.referencedAssetIDs.first(where: { rid in spec.assets.first { $0.id == rid }?.sha256 != candidateID }) {
                splitEdit = { $0.timeline[i] = ReelPanelEdit.plainClip(clip, asset: keep) }
                o = o.map { $0 == clip.asset ? keep : $0 }
                if selectedAssetID == clip.asset { selectedAssetID = keep }
            }
        }
        if splitEdit == nil, excluding, o.count > 1,
           let asset = spec?.assets.first(where: { $0.sha256 == candidateID && o.contains($0.id) }) {
            // Ankaret i ett automatiskt kollage: kollaget löses upp och partnern tar klippets plats.
            if let clip = spec?.timeline.first(where: { $0.asset == asset.id }),
               let partner = ReelComposer.autoCollagePartner(clip), !o.contains(partner),
               let at = o.firstIndex(of: asset.id) {
                o[at] = partner
            } else {
                o.removeAll { $0 == asset.id }
            }
            if selectedAssetID == asset.id { selectedAssetID = nil }
        }
        apply(order: o, editor: { e in
            var excluded = e.excludedAssets ?? []
            if let i = excluded.firstIndex(of: candidateID) { excluded.remove(at: i) } else {
                excluded.append(candidateID)
                e.pinnedAssets?.removeAll { $0 == candidateID }
            }
            e.excludedAssets = excluded
        }, edit: splitEdit, op: "exclude")
    }

    /// Bildens innehållshash (kandidat-id i rutnätet) för ett klipp i filmen.
    func candidateID(forAsset assetID: String) -> String? {
        spec?.assets.first { $0.id == assetID }?.sha256
    }

    /// Om bilden är låst i filmen ("ska vara med" vid nästa förslag).
    func isPinned(asset assetID: String) -> Bool {
        candidateID(forAsset: assetID).map { (spec?.editor?.pinnedAssets ?? []).contains($0) } ?? false
    }

    func setFormat(_ newFormat: ReelFormat) {
        guard newFormat != format else { return }
        apply(order: order, format: newFormat, op: "format")
    }

    /// Nytt förslag med exakt `n` bilder; antalet blir fast (`fixedCount`) tills fotografen väljer
    /// automatiskt (`useAutoCount`). Låsta val behålls (se `suggestAgain`).
    func setCount(_ n: Int) {
        let clamped = min(max(n, Self.countRange.lowerBound), Self.countRange.upperBound)
        guard clamped != count || spec == nil else { return }
        recompose(preserving: spec, op: "count", changesCount: true, count: clamped)
    }

    /// Nytt förslag med automatiskt antal (en bild per viktig rumstyp, 5...8). Låsta val behålls.
    func useAutoCount() {
        guard fixedCount != nil else { return }
        recompose(preserving: spec, op: "count", changesCount: true, count: nil)
    }

    /// Föreslår filmen på nytt (nuvarande antal och format) men behåller låsen: pinnade och
    /// uteslutna bilder, bilder med per-bild-lås (förval, längd, övergång, egen rörelse) med sina lås,
    /// tempo och ordningslås (se `ReelComposer.compose(preserving:)`).
    func suggestAgain() {
        recompose(preserving: spec, op: "suggestAgain")
    }

    /// Som `suggestAgain` men kastar alla lås, inklusive redigerarens val (`editor`).
    func startOver() {
        recompose(preserving: nil, op: "startOver")
    }

    /// `count` är antalet förslaget ska ha (nil = automatiskt); utan angivet värde behålls nuvarande
    /// läge (fast antal eller automatiskt).
    private func recompose(preserving previous: ReelSpec?, op: String, changesCount: Bool = false, count requested: Int? = nil) {
        guard !items.isEmpty else { return }
        recordStep(op: op)
        let specDir = reelDirectory ?? FileManager.default.temporaryDirectory
        var opts = options()
        if changesCount { opts.count = requested }
        if previous == nil { opts.count = nil }
        let result = ReelComposer.compose(items: items, specDirectory: specDir, options: opts, preserving: previous)
        candidates = result.candidates
        urls = result.urls
        selection = result.selection
        // Samma film i en ny version (id, revision, brand och logg följer med), även vid "Börja om helt".
        spec = spec.map { ReelComposer.continuing(result.spec, from: $0, op: op, now: now()) } ?? result.spec
        // Låsta bilder kan göra filmen längre än begärt antal; automatiskt antal visas som det faktiska.
        count = min(max(result.spec.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        adaptedCustomMotions = 0
        clearSelection()
        revisionToken += 1
        if case .rendered = phase { phase = .ready }
        saveSpec()
    }

    // MARK: Spara

    @discardableResult
    func saveSpec() -> Bool {
        guard let spec, let dir = reelDirectory else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try spec.jsonData().write(to: dir.appendingPathComponent(Self.specFileName), options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = "Kunde inte spara reel.json: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Synk mot mäklaren

    /// Ersätter filmen med en spec från servern (redan översatt till lokala källor, se `ReelSyncMerger`).
    func adoptRemoteSpec(_ remote: ReelSpec) {
        recordStep(op: "pull")
        spec = remote
        format = ReelFormat(rawValue: remote.outputs.first?.id ?? "") ?? format
        count = min(max(remote.timeline.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        clearSelection()
        revisionToken += 1
        if case .rendered = phase { phase = .ready }
        saveSpec()
    }

    /// Efter lyckad skickning: lokala specen får serverns revision och status (utan att räknas som en ändring).
    func markSynced(revision: Int, status: String) {
        guard var current = spec else { return }
        current.revision = revision
        current.status = status
        spec = current
        saveSpec()
    }

    // MARK: Rendera

    func render() {
        guard let spec, hasFilm, let dir = reelDirectory, let url = videoURL, let output = spec.outputs.first,
              !isBusy else { return }
        guard saveSpec() else { phase = .failed(saveError ?? "Kunde inte spara reel.json."); return }
        phase = .rendering(0)
        let token = revisionToken
        renderTask = Task { [weak self] in
            let last = ProgressGate()
            do {
                try await ReelRenderer.export(spec: spec, specDirectory: dir, output: output, to: url) { p in
                    let pct = Int(p * 100)
                    guard last.advance(to: pct) else { return }
                    Task { @MainActor in self?.renderProgress(p) }
                }
                if let self { self.phase = Self.phaseAfterRender(url, renderedToken: token, currentToken: self.revisionToken) }
            } catch is CancellationError {
                self?.phase = .ready
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.renderTask = nil
        }
    }

    /// Läget när en export är klar: "klar" bara om filmen inte ändrats under tiden (redigering och
    /// ⌘Z fungerar medan exporten pågår); annars är filen en äldre version och det går att rendera igen.
    nonisolated static func phaseAfterRender(_ url: URL, renderedToken: Int, currentToken: Int) -> Phase {
        renderedToken == currentToken ? .rendered(url) : .ready
    }

    private func renderProgress(_ p: Double) {
        if case .rendering = phase { phase = .rendering(p) }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    func dismissError() {
        if case .failed = phase { phase = items.isEmpty ? .idle : .ready }
    }
}
