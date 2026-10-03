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

    /// Historiken: `<adress> FÄRDIGA` i sessionens outputmapp om den finns, annars
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
    }

    struct CandidateRow: Identifiable, Equatable {
        var id: String            // sha256
        var url: URL?
        var filename: String
        var room: String?
        var category: String?
        var score: Double
        var excludedReason: String?
        /// Plats i filmen (0-baserad) om bilden är vald.
        var clipIndex: Int?
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
    private(set) var count = 5
    private(set) var saveError: String?
    var selectedAssetID: String?

    static let specFileName = "reel.json"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]
    static let durationRange = 1.0...10.0
    static let countRange = 3...8

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Injicerbara för tester.
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }

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
                durationLocked: clip.durationLocked == true)
        }
    }

    /// Alla bilder med poäng, bäst först; bortfiltrerade sist med skälet.
    var candidateRows: [CandidateRow] {
        let scores = selection?.scores ?? [:]
        let excluded = Dictionary((selection?.excluded ?? []).map { ($0.candidateID, $0.reason) },
                                  uniquingKeysWith: { a, _ in a })
        let placed = Dictionary(uniqueKeysWithValues: (spec?.timeline ?? []).enumerated().compactMap { i, clip in
            spec?.assets.first { $0.id == clip.asset }.map { ($0.sha256, i) }
        })
        let rows = candidates.map { c in
            CandidateRow(id: c.id, url: urls[c.id], filename: c.filename, room: c.room, category: c.category,
                         score: scores[c.id] ?? 0, excludedReason: excluded[c.id], clipIndex: placed[c.id])
        }
        return rows.sorted {
            if ($0.excludedReason == nil) != ($1.excludedReason == nil) { return $0.excludedReason == nil }
            return $0.score > $1.score
        }
    }

    // MARK: Källa och analys

    /// Bildfilerna i en mapp, i filnamnsordning.
    static func imageFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Öppnar en källmapp: analyserar (cache i `reel_analysis.json` i utmappen) och föreslår film.
    func open(source: URL, address: String? = nil, sessionID: String? = nil, aiTagsDirectory: URL? = nil) {
        cancelAll()
        let source = source.resolvingSymlinksInPath()
        let reelDir = AddressFolderLayout.reelDir(forSource: source)
        let files = Self.imageFiles(in: source)
        guard !files.isEmpty else {
            phase = .failed("Inga bilder hittades i \"\(source.lastPathComponent)\".")
            return
        }
        reset()
        sourceDirectory = source
        reelDirectory = reelDir
        self.address = address ?? AddressFolderLayout.addressName(fromFinishedDir: source.lastPathComponent) ?? source.lastPathComponent
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
            count = min(max(restored.assets.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        }
        selectedAssetID = nil
        revisionToken += 1
        phase = .ready
    }

    private func options() -> ReelComposer.Options {
        var o = ReelComposer.Options()
        o.count = count
        o.format = format
        o.address = address
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
        guard restored.timeline.allSatisfy({ clip in restored.assets.contains { $0.id == clip.asset } }) else { return nil }
        return restored
    }

    private func reset() {
        items = []; candidates = []; urls = [:]; selection = nil; spec = nil
        selectedAssetID = nil; saveError = nil
        revisionToken += 1
    }

    func cancelAll() {
        analysisTask?.cancel(); analysisTask = nil
        renderTask?.cancel(); renderTask = nil
    }

    // MARK: Redigering (allt via ReelComposer.rebuild)

    private var order: [String] { spec?.timeline.map(\.asset) ?? [] }

    private func apply(order: [String], newAssets: [ReelSpec.Asset] = [], format: ReelFormat? = nil,
                       overrides: [String: ReelMotionPlanner.ClipOverride]? = nil, op: String) {
        guard let current = spec else { return }
        spec = ReelComposer.rebuild(current, order: order, newAssets: newAssets, format: format,
                                    overrides: overrides, op: op, now: now())
        if let format { self.format = format }
        revisionToken += 1
        if case .rendered = phase { phase = .ready }
        saveSpec()
    }

    private func currentOverrides() -> [String: ReelMotionPlanner.ClipOverride] {
        spec.map(ReelComposer.overrides(in:)) ?? [:]
    }

    private func nextAssetID() -> String {
        let used = (spec?.assets ?? []).compactMap { Int($0.id.dropFirst()) }
        return "a\((used.max() ?? 0) + 1)"
    }

    private func newAsset(forCandidate id: String) -> ReelSpec.Asset? {
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

    /// Lägger bilden sist i filmen (högst 8 klipp).
    func addCandidate(_ id: String) {
        guard order.count < Self.countRange.upperBound, let asset = newAsset(forCandidate: id) else { return }
        apply(order: order + [asset.id], newAssets: [asset], op: "add")
        selectedAssetID = asset.id
    }

    /// Byter klippets bild mot en annan; klippets rörelseval och längd följer inte med.
    func replaceClip(_ assetID: String, withCandidate id: String) {
        guard let pos = order.firstIndex(of: assetID), let asset = newAsset(forCandidate: id) else { return }
        var o = order
        o[pos] = asset.id
        apply(order: o, newAssets: [asset], op: "replace")
        selectedAssetID = asset.id
    }

    /// Klick i kandidatrutnätet: redan vald bild markeras, annars byts det markerade klippets bild,
    /// och utan markerat klipp läggs bilden till sist.
    func selectCandidate(_ id: String) {
        if let row = candidateRows.first(where: { $0.id == id }), let i = row.clipIndex {
            selectedAssetID = order[i]
        } else if let selectedAssetID, order.contains(selectedAssetID) {
            replaceClip(selectedAssetID, withCandidate: id)
        } else {
            addCandidate(id)
        }
    }

    func setDuration(_ assetID: String, seconds: Double) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.duration = min(max(seconds, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        o[assetID] = entry
        apply(order: order, overrides: o, op: "duration")
    }

    /// Tillbaka till automatisk längd för klippet.
    func clearDuration(_ assetID: String) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.duration = nil
        o[assetID] = entry.isDefault ? nil : entry
        apply(order: order, overrides: o, op: "duration")
    }

    func setPreset(_ assetID: String, _ preset: ReelMotionPlanner.Preset) {
        var o = currentOverrides()
        var entry = o[assetID] ?? .init()
        entry.preset = preset
        o[assetID] = entry.isDefault ? nil : entry
        apply(order: order, overrides: o, op: "motion")
    }

    func setFormat(_ newFormat: ReelFormat) {
        guard newFormat != format else { return }
        apply(order: order, format: newFormat, op: "format")
    }

    /// Nytt automatiskt förslag med `n` bilder. Ersätter manuella ändringar.
    func setCount(_ n: Int) {
        let clamped = min(max(n, Self.countRange.lowerBound), Self.countRange.upperBound)
        guard clamped != count || spec == nil else { return }
        count = clamped
        suggestAgain()
    }

    /// Kastar manuella ändringar och föreslår filmen på nytt (nuvarande antal och format).
    func suggestAgain() {
        guard !items.isEmpty else { return }
        let specDir = reelDirectory ?? FileManager.default.temporaryDirectory
        let result = ReelComposer.compose(items: items, specDirectory: specDir, options: options())
        candidates = result.candidates
        urls = result.urls
        selection = result.selection
        spec = result.spec
        selectedAssetID = nil
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
        spec = remote
        format = ReelFormat(rawValue: remote.outputs.first?.id ?? "") ?? format
        count = min(max(remote.assets.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        selectedAssetID = nil
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
        renderTask = Task { [weak self] in
            let last = ProgressGate()
            do {
                try await ReelRenderer.export(spec: spec, specDirectory: dir, output: output, to: url) { p in
                    let pct = Int(p * 100)
                    guard last.advance(to: pct) else { return }
                    Task { @MainActor in self?.renderProgress(p) }
                }
                self?.phase = .rendered(url)
            } catch is CancellationError {
                self?.phase = .ready
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.renderTask = nil
        }
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
