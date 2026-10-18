import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Fönster-id för HDR-jämförelsen (`WindowGroup("HDR-jämförelse", id: "hdr-compare")`).
enum HDRCompareWindow {
    static let id = "hdr-compare"
}

enum HDRCompareMode: String, CaseIterable, Identifiable {
    case sideBySide, swipe, flip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sideBySide: return "Sida vid sida"
        case .swipe: return "Svep"
        case .flip: return "A/B-växling"
        }
    }
    var symbol: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .swipe: return "slider.horizontal.below.rectangle"
        case .flip: return "arrow.left.arrow.right"
        }
    }
}

/// Bildinläsning för visning: ImageIO, nedskalat för vanlig visning och full upplösning för 100 %.
nonisolated enum HDRCompareImageLoader {
    struct Box: @unchecked Sendable { let image: CGImage? }

    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func full(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Full upplösning men med orienteringen tillämpad: miniatyr med maxstorlek över bildens egen.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return thumbnail(url, maxPixel: max(w, h, 1))
    }

    @concurrent static func loadThumbnail(_ url: URL, maxPixel: Int) async -> Box { Box(image: thumbnail(url, maxPixel: maxPixel)) }
    @concurrent static func loadFull(_ url: URL) async -> Box { Box(image: full(url)) }
}

/// All logik för jämförelsefönstret; vyerna ritar bara.
@MainActor @Observable
final class HDRCompareModel {
    static let defaultsKey = "hdrCompareManifestPath"
    static let displayMaxPixel = 3000

    /// Kommer ihåg senast öppnade manifest (av i tester).
    var remembersLastManifest = true

    // Manifest
    var manifestURL: URL?
    var manifest: HDRCompareManifest?
    var loadError: String?
    /// Variant-id som finns som fil på disk, per grupp.
    var available: [String: Set<String>] = [:]
    var thumbnails: [String: CGImage] = [:]

    // Urval och visning
    var selectedGroupID: String? {
        didSet { if selectedGroupID != oldValue { groupChanged() } }
    }
    /// Användarens val av A/B; gäller i alla grupper där båda finns, annars gruppens standardpar.
    var preferredA: String?
    var preferredB: String?
    var showReference = false
    var mode: HDRCompareMode = .sideBySide
    var blind = false
    var flipIndex = 0
    var swipeFraction: CGFloat = 0.5
    var showSummary = false
    var showLightroomSheet = false
    let viewport = CompareViewport()
    var images: [String: CGImage] = [:]
    var fullImages: [String: CGImage] = [:]
    private var imageTask: Task<Void, Never>?
    private var fullTask: Task<Void, Never>?

    // Betyg
    var verdictFile = HDRCompareVerdictFile(blindSeed: 1)
    var draftAspects: Set<HDRCompareAspect> = []
    var draftNote = ""
    var saveError: String?

    // Mått
    var metrics: HDRCompareMetricsFile?
    var metricsProgress: (done: Int, total: Int)?
    private var metricsTask: Task<Void, Never>?

    // MARK: - Manifest

    var groups: [HDRCompareManifest.Group] { manifest?.groups ?? [] }

    var selectedGroup: HDRCompareManifest.Group? {
        groups.first { $0.id == selectedGroupID }
    }

    var baseURL: URL? { manifestURL?.deletingLastPathComponent() }

    func openStoredOrDefault() {
        guard manifest == nil else { return }
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey).map { URL(fileURLWithPath: $0) }
        let candidate = stored ?? HDRCompareManifest.defaultURL
        if FileManager.default.fileExists(atPath: candidate.path) {
            load(candidate)
        } else {
            manifestURL = candidate
            loadError = "Hittar inget manifest på \(candidate.path). Välj ett med “Öppna manifest…”."
        }
    }

    func pickManifest() {
        let panel = NSOpenPanel()
        panel.title = "Öppna manifest"
        panel.message = "Välj manifest.json för HDR-jämförelsen."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.directoryURL = HDRCompareManifest.defaultDirectory
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        do {
            let m = try HDRCompareManifest.load(from: url)
            metricsTask?.cancel()
            manifestURL = url
            manifest = m
            loadError = nil
            if remembersLastManifest { UserDefaults.standard.set(url.path, forKey: Self.defaultsKey) }
            verdictFile = HDRCompareVerdictStore.load(forManifest: url)
            metrics = HDRCompareMetricsFile.load(forManifest: url)
            thumbnails = [:]
            images = [:]
            fullImages = [:]
            refreshAvailability()
            selectedGroupID = nil
            selectedGroupID = m.groups.first?.id
        } catch {
            manifest = nil
            manifestURL = url
            loadError = "Kunde inte läsa \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func refreshAvailability() {
        guard let base = baseURL else { return }
        var out: [String: Set<String>] = [:]
        for g in groups {
            out[g.id] = Set(g.allImages.filter {
                FileManager.default.fileExists(atPath: HDRCompareRunner.resolve($0.value, base: base).path)
            }.keys)
        }
        available = out
    }

    func url(for variant: String, in group: HDRCompareManifest.Group) -> URL? {
        guard let base = baseURL, let path = group.allImages[variant] else { return nil }
        return HDRCompareRunner.resolve(path, base: base)
    }

    // MARK: - Par och ordning

    /// Valbara varianter för gruppen (finns på disk).
    func variants(of group: HDRCompareManifest.Group) -> [String] {
        let have = available[group.id] ?? []
        return group.orderedVariantIDs.filter { have.contains($0) }
    }

    /// Paret (A, B) i kanonisk ordning för gruppen.
    func pair(for group: HDRCompareManifest.Group) -> (a: String, b: String)? {
        let have = available[group.id] ?? []
        if let a = preferredA, let b = preferredB, a != b, have.contains(a), have.contains(b) { return (a, b) }
        if let a = preferredA, have.contains(a), let b = group.defaultPair(available: have)?.b, b != a { return (a, b) }
        if let b = preferredB, have.contains(b), let a = group.defaultPair(available: have)?.a, a != b { return (a, b) }
        return group.defaultPair(available: have)
    }

    var canonicalPair: (a: String, b: String)? { selectedGroup.flatMap { pair(for: $0) } }

    var isSwapped: Bool {
        guard blind, let g = selectedGroup else { return false }
        return HDRCompareBlind.isSwapped(seed: verdictFile.blindSeed, groupId: g.id)
    }

    /// Vad som visas till vänster respektive höger (efter blindslumpning).
    var displayPair: (left: String, right: String)? {
        guard let p = canonicalPair else { return nil }
        return isSwapped ? (p.b, p.a) : p
    }

    /// Referensbilden visas som tredje ruta om den finns och inte redan är A eller B.
    var referenceVariant: String? {
        guard showReference, let g = selectedGroup, let p = canonicalPair,
              (available[g.id] ?? []).contains(HDRCompareManifest.Group.referenceID),
              p.a != HDRCompareManifest.Group.referenceID, p.b != HDRCompareManifest.Group.referenceID else { return nil }
        return HDRCompareManifest.Group.referenceID
    }

    var currentVerdict: HDRCompareVerdict? {
        guard let g = selectedGroup, let p = canonicalPair else { return nil }
        return verdictFile.verdict(groupId: g.id, pair: [p.a, p.b])
    }

    /// Etiketter döljs i blindläge tills gruppen är bedömd.
    var labelsHidden: Bool { blind && currentVerdict == nil }

    func label(for variant: String, position: String) -> String {
        labelsHidden ? position : "\(position) · \(variant)"
    }

    func isRated(_ group: HDRCompareManifest.Group) -> Bool {
        guard let p = pair(for: group) else { return false }
        return verdictFile.verdict(groupId: group.id, pair: [p.a, p.b]) != nil
    }

    /// Valet sett från det som visas just nu (A = vänster).
    var displayedChoice: HDRCompareChoice? {
        guard let v = currentVerdict, let d = displayPair else { return nil }
        guard let winner = v.winner else { return .tie }
        return winner == d.left ? .left : .right
    }

    /// Bilden som visas i A/B-växlingen just nu.
    var flipSequence: [String] {
        guard let d = displayPair else { return [] }
        return [d.left, d.right] + (referenceVariant.map { [$0] } ?? [])
    }

    func missingText(_ group: HDRCompareManifest.Group) -> String? {
        let have = available[group.id] ?? []
        let expected = ["pf-radiance", "lr-auto"]
        let missing = expected.filter { !have.contains($0) }
        return missing.isEmpty ? nil : "saknar " + missing.joined(separator: ", ")
    }

    // MARK: - Urval och bilder

    private func groupChanged() {
        viewport.reset()
        flipIndex = 0
        if let v = currentVerdict {
            draftAspects = Set(v.aspects.compactMap(HDRCompareAspect.init(rawValue:)))
            draftNote = v.note
        } else {
            draftAspects = []
            draftNote = ""
        }
        loadImages()
    }

    func selectRelative(_ delta: Int) {
        let ids = groups.map(\.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: selectedGroupID ?? "") ?? (delta > 0 ? -1 : ids.count)
        selectedGroupID = ids[min(max(i + delta, 0), ids.count - 1)]
    }

    /// Läser in bilderna för valda varianter (nedskalade).
    func loadImages() {
        imageTask?.cancel()
        fullTask?.cancel()
        images = [:]
        fullImages = [:]
        guard let g = selectedGroup, let p = canonicalPair else { return }
        var ids = [p.a, p.b]
        if let r = referenceVariant { ids.append(r) }
        // En enda uppgift per grupp: pickers och R-växlaren ändrar bara vilka som behövs.
        let urls = ids.compactMap { id in url(for: id, in: g).map { (id, $0) } }
        imageTask = Task {
            await withTaskGroup(of: (String, HDRCompareImageLoader.Box).self) { tg in
                for (id, url) in urls {
                    tg.addTask { (id, await HDRCompareImageLoader.loadThumbnail(url, maxPixel: Self.displayMaxPixel)) }
                }
                for await (id, box) in tg {
                    if Task.isCancelled { return }
                    if let img = box.image { images[id] = img }
                }
            }
        }
    }

    /// Full upplösning för 100 %-läget (laddas när man zoomar in).
    func ensureFullResolution() {
        guard let g = selectedGroup, let p = canonicalPair else { return }
        var ids = [p.a, p.b]
        if let r = referenceVariant { ids.append(r) }
        let needed = ids.filter { fullImages[$0] == nil }
        guard !needed.isEmpty, fullTask == nil || fullTask?.isCancelled == true else { return }
        let urls = needed.compactMap { id in url(for: id, in: g).map { (id, $0) } }
        let groupID = g.id
        fullTask = Task {
            defer { fullTask = nil }
            for (id, url) in urls {
                let box = await HDRCompareImageLoader.loadFull(url)
                if Task.isCancelled || selectedGroupID != groupID { return }
                if let img = box.image { fullImages[id] = img }
            }
        }
    }

    /// Bilden att rita för en variant: full upplösning när den finns och man zoomat förbi visningsbilden.
    func image(for variant: String) -> CGImage? {
        if viewport.scale > 1.5, let full = fullImages[variant] { return full }
        return images[variant] ?? fullImages[variant]
    }

    func loadThumbnail(for group: HDRCompareManifest.Group) async {
        guard thumbnails[group.id] == nil else { return }
        let have = available[group.id] ?? []
        let id = (group.defaultPair(available: have)?.a) ?? group.orderedVariantIDs.first { have.contains($0) }
        guard let id, let url = url(for: id, in: group) else { return }
        let box = await HDRCompareImageLoader.loadThumbnail(url, maxPixel: 160)
        if let img = box.image { thumbnails[group.id] = img }
    }

    func variantChanged() {
        flipIndex = 0
        draftChangedForPair()
        loadImages()
    }

    /// Byte av par: aspekter och kommentar följer med det bedömda paret, annars nollställs de.
    private func draftChangedForPair() {
        if let v = currentVerdict {
            draftAspects = Set(v.aspects.compactMap(HDRCompareAspect.init(rawValue:)))
            draftNote = v.note
        } else {
            draftAspects = []
            draftNote = ""
        }
    }

    // MARK: - Zoom

    /// Zoomnivån där en bildpunkt motsvarar en skärmpixel för bilden i den första rutan.
    func hundredPercentScale(paneSize: CGSize, displayScale: CGFloat) -> CGFloat? {
        guard let d = displayPair, let id = fullImages[d.left] ?? images[d.left] else { return nil }
        // Alltid mot bildens verkliga upplösning: ur filen, inte den nedskalade visningsbilden.
        let realWidth = fullImages[d.left]?.width ?? realPixelWidth(of: d.left) ?? id.width
        let fit = CompareViewport.fitSize(aspect: CGFloat(id.width) / CGFloat(max(id.height, 1)), in: paneSize)
        guard fit.width > 0 else { return nil }
        return max(1, CGFloat(realWidth) / displayScale / fit.width)
    }

    private func realPixelWidth(of variant: String) -> Int? {
        guard let g = selectedGroup, let url = url(for: variant, in: g),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orienteringen kan byta sida; långsidan är densamma, men bredd vid liggande/stående skiljer.
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? h : w
    }

    func toggleHundredPercent(paneSize: CGSize, displayScale: CGFloat) {
        if viewport.isFit {
            ensureFullResolution()
            if let s = hundredPercentScale(paneSize: paneSize, displayScale: displayScale) {
                viewport.setScale(s)
            } else {
                viewport.setScale(2)
            }
        } else {
            viewport.reset()
        }
    }

    // MARK: - Betyg

    func rate(_ choice: HDRCompareChoice) {
        guard let g = selectedGroup, let d = displayPair else { return }
        let verdict = HDRCompareVerdict(
            groupId: g.id, left: d.left, right: d.right, blind: blind, seed: verdictFile.blindSeed, verdict: choice,
            aspects: HDRCompareAspect.allCases.filter(draftAspects.contains).map(\.rawValue),
            note: draftNote, ratedAt: Date())
        verdictFile.upsert(verdict)
        saveVerdicts()
    }

    func clearVerdict() {
        guard let g = selectedGroup, let p = canonicalPair else { return }
        verdictFile.remove(groupId: g.id, pair: [p.a, p.b])
        saveVerdicts()
    }

    /// Aspekter och kommentar sparas direkt om gruppen redan är bedömd.
    func draftChanged() {
        guard let choice = displayedChoice, let v = currentVerdict else { return }
        let aspects = HDRCompareAspect.allCases.filter(draftAspects.contains).map(\.rawValue)
        guard aspects != v.aspects || draftNote != v.note else { return }
        rate(choice)
    }

    private func saveVerdicts() {
        guard let url = manifestURL else { return }
        do {
            try HDRCompareVerdictStore.save(verdictFile, forManifest: url)
            saveError = nil
        } catch {
            saveError = "Kunde inte spara verdicts.json: \(error.localizedDescription)"
        }
    }

    var ratedCount: Int { groups.filter(isRated).count }

    // MARK: - Mått och sammanfattning

    var summary: HDRCompareSummary.Result? {
        guard let m = manifest else { return nil }
        return HDRCompareSummary.compute(manifest: m, verdicts: verdictFile.verdicts, metrics: metrics)
    }

    func computeMetrics(force: Bool = false) {
        guard let manifest, let url = manifestURL, metricsTask == nil else { return }
        metricsProgress = (0, manifest.groups.count)
        metricsTask = Task {
            let result = await HDRCompareRunner.compute(manifest: manifest, manifestURL: url, force: force) { done, total in
                Task { @MainActor in self.metricsProgress = (done, total) }
            }
            metrics = result
            metricsProgress = nil
            metricsTask = nil
        }
    }

    func cancelMetrics() {
        metricsTask?.cancel()
    }

    /// Skriver `summary.json` och `summary.md` bredvid manifestet; returnerar Markdown-filens URL.
    @discardableResult
    func exportSummary(to markdownURL: URL? = nil) -> URL? {
        guard let result = summary, let manifestURL else { return nil }
        let dir = manifestURL.deletingLastPathComponent()
        let mdURL = markdownURL ?? dir.appendingPathComponent("summary.md")
        do {
            try HDRCompareSummary.markdown(result).write(to: mdURL, atomically: true, encoding: .utf8)
            let json = try JSONSerialization.data(withJSONObject: HDRCompareSummary.jsonObject(result), options: [.prettyPrinted, .sortedKeys])
            try json.write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
            return mdURL
        } catch {
            saveError = "Kunde inte exportera: \(error.localizedDescription)"
            return nil
        }
    }

    func exportSummaryWithPanel() {
        guard let manifestURL else { return }
        let panel = NSSavePanel()
        panel.title = "Exportera sammanfattning"
        panel.nameFieldStringValue = "summary.md"
        panel.directoryURL = manifestURL.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            if let written = exportSummary(to: url) { NSWorkspace.shared.activateFileViewerSelecting([written]) }
        }
    }
}
