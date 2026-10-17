import Foundation
import CoreGraphics

/// De utdataformat bildspelsmodulen kan göra (plan 4.1). Alla delar
/// kodningsprofilen H.264 High, 30 fps, tyst AAC-spår, cirka 14 Mbit/s.
nonisolated enum ReelFormat: String, Sendable, CaseIterable, Equatable {
    case vertical   // 9:16
    case square     // 1:1
    case landscape  // 16:9

    var output: ReelSpec.Output {
        let (aspect, w, h): (String, Int, Int)
        switch self {
        case .vertical: (aspect, w, h) = ("9:16", 1080, 1920)
        case .square: (aspect, w, h) = ("1:1", 1080, 1080)
        case .landscape: (aspect, w, h) = ("16:9", 1920, 1080)
        }
        return .init(id: rawValue, aspect: aspect, width: w, height: h, fps: 30,
                     encoding: .init(codec: "h264", bitrateMbps: 14, audio: "aac-silent"))
    }
}

/// Sätter ihop analys, urval och rörelse till en komplett `ReelSpec`, och
/// bygger om specen när användaren bytt eller ordnat om bilderna. Ren logik
/// (inget Vision, ingen disk): analyserna kommer in färdiga.
nonisolated enum ReelComposer {

    static let generator = "PhotoFlow ReelComposer v1 / ReelSelector v1"

    nonisolated struct Options: Sendable {
        var count = 5
        var format = ReelFormat.vertical
        var address = ""
        var sessionID: String?
        var weights = ReelSelector.Weights()
        /// Injicerbara för tester.
        var now = Date()
        var specID = UUID().uuidString.lowercased()
        var updatedBy = ReelSpec.UpdatedBy(role: "agent", name: "PhotoFlow")
        /// Redigerarens val (pinnade/uteslutna bilder, ordningslås, tempo). Om `compose` får en
        /// `preserving`-spec gäller i stället dess `editor`.
        var editor: ReelSpec.EditorState?
    }

    nonisolated struct Result: Sendable {
        var spec: ReelSpec
        var selection: ReelSelector.Selection
        /// Alla kandidater (id = sha256) i indataordning, så att UI:t kan visa dem med poäng.
        var candidates: [ReelCandidate]
        /// Filen varje kandidat kom från.
        var urls: [String: URL]
    }

    // MARK: - Från analys till kandidat/asset

    static func candidate(from item: ReelImageAnalyzer.Item) -> ReelCandidate {
        let a = item.analysis
        let hour = a.exifDate.map { Calendar.current.component(.hour, from: $0) }
        return ReelCandidate(
            id: a.sha256, filename: item.url.lastPathComponent,
            quality: a.qualityScore, isUtility: a.isUtility, horizonDegrees: a.horizonAngleDegrees,
            sharpness: a.sharpness, featureVector: a.featureVector, salientWidth: a.salientWidth,
            meanLuminance: a.meanLuminance, captureHour: hour,
            room: a.room, category: a.category, features: a.features ?? [], caption: a.caption)
    }

    /// Specens asset för en analyserad bild. Sökvägen är relativ spec-filens mapp.
    static func asset(id: String, item: ReelImageAnalyzer.Item, specDirectory: URL) -> ReelSpec.Asset {
        let a = item.analysis
        return .init(
            id: id, sha256: a.sha256, width: a.width, height: a.height,
            sources: [.init(kind: .local, path: relativePath(from: specDirectory, to: item.url))],
            analysis: .init(room: a.room, category: a.category, focus: a.focus, salientWidth: a.salientWidth,
                            focusWidth: a.focusWidth))
    }

    /// Sökvägen till `file` relativt mappen `dir` ("../X FÄRDIGA/bild.jpg"). Symlänkar löses inte upp.
    static func relativePath(from dir: URL, to file: URL) -> String {
        func comps(_ u: URL) -> [String] { u.standardizedFileURL.pathComponents.filter { $0 != "/" } }
        let d = comps(dir), f = comps(file)
        var common = 0
        while common < d.count, common < f.count - 1, d[common] == f[common] { common += 1 }
        return (Array(repeating: "..", count: d.count - common) + f[common...]).joined(separator: "/")
    }

    // MARK: - Komponera

    /// ISO 8601 i specen har hela sekunder; avrunda så att koda/avkoda ger samma värde.
    private static func wholeSeconds(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }

    /// Komponerar en film. Med `preserving` (nuvarande spec) behålls fotografens val när filmen
    /// föreslås om: `editor` (pinnade, uteslutna, ordningslås, tempo), stilen, och per-bild-lås
    /// (förval, längd, övergång, egen rörelse) för bilder som väljs igen, matchade på sha256 eftersom
    /// asset-id:n numreras om. Är `editor.orderLocked` satt behåller låsta klipp (pinnade bilder eller
    /// bilder med något per-bild-lås som väljs igen) sin position i filmen när positionen finns kvar;
    /// övriga bilder fyller de lediga platserna i förslagets ordning. Utan `preserving` är resultatet
    /// helt automatiskt (och `editor` från `options` gäller).
    static func compose(items: [ReelImageAnalyzer.Item], specDirectory: URL, options: Options = Options(),
                        preserving previous: ReelSpec? = nil) -> Result {
        // Exakta kopior (samma innehåll) är samma bild: behåll första filen.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.analysis.sha256).inserted }
        let candidates = unique.map(candidate(from:))
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.analysis.sha256, $0) })

        let editor = (previous?.editor ?? options.editor)?.normalized
        var selection = ReelSelector.select(candidates, count: options.count, weights: options.weights,
                                            pinned: editor?.pinnedAssets ?? [], excluded: editor?.excludedAssets ?? [])

        // Per-bild-lås från förra specen, på sha256.
        var lockedBySha: [String: ReelMotionPlanner.ClipOverride] = [:]
        var oldIndexBySha: [String: Int] = [:]
        if let previous {
            let shaByAsset = Dictionary(previous.assets.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
            let perAsset = overrides(in: previous)
            for (i, clip) in previous.timeline.enumerated() {
                guard let sha = shaByAsset[clip.asset] else { continue }
                oldIndexBySha[sha] = i
                if let o = perAsset[clip.asset] { lockedBySha[sha] = o }
            }
        }

        // Ordning: förslagets, men med låsta klipp kvar på sin plats om `orderLocked`.
        var picks = selection.picks.filter { byID[$0.candidateID] != nil }
        if editor?.orderLocked == true {
            let pinned = Set(editor?.pinnedAssets ?? [])
            let n = picks.count
            var placed = [ReelSelector.Pick?](repeating: nil, count: n)
            // Låsta i gammal ordning; den som saknar plats (index utanför filmen eller upptaget) fylls på som övriga.
            let heldFirst = picks.filter { pinned.contains($0.candidateID) || lockedBySha[$0.candidateID] != nil }
                .sorted { (oldIndexBySha[$0.candidateID] ?? Int.max) < (oldIndexBySha[$1.candidateID] ?? Int.max) }
            var held = Set<String>()
            for pick in heldFirst {
                if let i = oldIndexBySha[pick.candidateID], i < n, placed[i] == nil {
                    placed[i] = pick; held.insert(pick.candidateID)
                }
            }
            let rest = picks.filter { !held.contains($0.candidateID) }
            var it = rest.makeIterator()
            for i in placed.indices where placed[i] == nil { placed[i] = it.next() }
            picks = placed.compactMap { $0 }
            selection.picks = picks
        }

        var assets: [ReelSpec.Asset] = []
        var auto: [ReelSpec.AutoSelection] = []
        var overridesByAsset: [String: ReelMotionPlanner.ClipOverride] = [:]
        for (i, pick) in picks.enumerated() {
            guard let item = byID[pick.candidateID] else { continue }
            let id = "a\(i + 1)"
            assets.append(asset(id: id, item: item, specDirectory: specDirectory))
            auto.append(.init(asset: id, slot: pick.slot.rawValue, reason: pick.reason))
            if let o = lockedBySha[pick.candidateID] { overridesByAsset[id] = o }
        }

        let output = options.format.output
        let style = previous?.style ?? defaultStyle
        let clips = ReelMotionPlanner.plan(plannerImages(assets), frameAspect: ReelMotionPlanner.frameAspect(output),
                                           overrides: overridesByAsset,
                                           tempo: .init(editorValue: editor?.tempo),
                                           defaultTransition: style.defaultTransition)
        var spec = ReelSpec(
            schema: ReelSpec.schemaName, version: ReelSpec.currentVersion, minReaderVersion: 1,
            id: options.specID, revision: 1, status: "draft",
            createdAt: wholeSeconds(options.now), updatedAt: wholeSeconds(options.now), updatedBy: options.updatedBy,
            property: .init(address: options.address, sessionID: options.sessionID,
                            kind: selection.template == .house ? "house" : "apartment"),
            assets: assets, style: style, timeline: clips, audio: nil, overlays: [], brand: nil,
            outputs: [output],
            provenance: .init(generator: generator, autoSelection: auto, edits: nil))
        spec.editor = editor
        return Result(spec: spec, selection: selection, candidates: candidates,
                      urls: Dictionary(unique.map { ($0.analysis.sha256, $0.url) }, uniquingKeysWith: { a, _ in a }))
    }

    static let defaultStyle = ReelSpec.Style(
        defaultTransition: ReelMotionPlanner.standardTransition,
        easing: .easeInOut,
        background: .init(type: "blur", amount: 0.6))

    // MARK: - Bygg om

    /// Bygger om specen när användaren bytt eller ordnat bilder: klippen följer
    /// `order` (asset-id:n, användarens ordning), rörelse, längder och övergångar
    /// planeras om, och allt annat (id, stil, egenskaper, output) behålls.
    /// `newAssets` är bilder som lagts till (se `asset(id:item:specDirectory:)`);
    /// asset som inte används längre tas bort. `format` byter output om det anges.
    /// Okända id:n i `order` hoppas över. Revisionen höjs och en `edit` loggas.
    static func rebuild(
        _ spec: ReelSpec,
        order: [String],
        newAssets: [ReelSpec.Asset] = [],
        format: ReelFormat? = nil,
        overrides: [String: ReelMotionPlanner.ClipOverride]? = nil,
        op: String = "reorder",
        by: ReelSpec.UpdatedBy = .init(role: "photographer", name: nil),
        now: Date = Date()
    ) -> ReelSpec {
        var known = Dictionary(spec.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for a in newAssets { known[a.id] = a }
        let used = order.filter { known[$0] != nil }
        let assets = used.compactMap { known[$0] }

        var out = spec
        if let format { out.outputs = [format.output] }
        let aspect = ReelMotionPlanner.frameAspect(out.outputs.first ?? ReelFormat.vertical.output)
        out.assets = assets
        // Fotografens val (rörelse, längd) följer med bilden; utan `overrides` läses de ur nuvarande klipp.
        let kept = overrides ?? Self.overrides(in: spec)
        out.timeline = ReelMotionPlanner.plan(plannerImages(assets), frameAspect: aspect, overrides: kept,
                                              tempo: .init(editorValue: spec.editor?.tempo),
                                              defaultTransition: spec.style.defaultTransition)
        out.revision += 1
        out.updatedAt = wholeSeconds(now)
        out.updatedBy = by
        out.status = "draft"
        var prov = spec.provenance
        prov.autoSelection = prov.autoSelection?.filter { sel in used.contains(sel.asset) }
        prov.edits = (prov.edits ?? []) + [.init(at: wholeSeconds(now), by: by.role, op: op)]
        out.provenance = prov
        return out
    }

    // MARK: - Hjälp

    /// Antal klipp med egen rörelse vars nycklar ändrades av en ombyggnad (klampning mot ett annat
    /// format). UI:t kan visa "Egna rörelser har anpassats" när det är > 0.
    static func adaptedCustomMotions(from old: ReelSpec, to new: ReelSpec) -> Int {
        let oldByAsset = Dictionary(old.timeline.map { ($0.asset, $0) }, uniquingKeysWith: { a, _ in a })
        func same(_ a: ReelSpec.MotionKey, _ b: ReelSpec.MotionKey) -> Bool {
            abs(a.cx - b.cx) < 1e-6 && abs(a.cy - b.cy) < 1e-6 && abs(a.zoom - b.zoom) < 1e-6
        }
        return new.timeline.filter { clip in
            let custom = ReelMotionPlanner.Preset.custom.rawValue
            guard clip.motionPreset == custom, let o = oldByAsset[clip.asset], o.motionPreset == custom else { return false }
            return !same(o.motion.from, clip.motion.from) || !same(o.motion.to, clip.motion.to)
        }.count
    }

    /// Fotografens val per asset-id, avlästa ur specens klipp (`motionPreset`, `durationLocked`,
    /// `transitionLocked`; för `custom` även `fit` och `motion`).
    static func overrides(in spec: ReelSpec) -> [String: ReelMotionPlanner.ClipOverride] {
        var result: [String: ReelMotionPlanner.ClipOverride] = [:]
        for clip in spec.timeline {
            let preset = clip.motionPreset.flatMap(ReelMotionPlanner.Preset.init(rawValue:)) ?? .auto
            let locked = clip.transitionLocked == true
            let o = ReelMotionPlanner.ClipOverride(
                preset: preset, duration: clip.durationLocked == true ? clip.duration : nil,
                transitionLocked: locked, transition: locked ? clip.transitionIn : nil,
                custom: preset == .custom ? .init(fit: clip.fit, motion: clip.motion) : nil)
            if !o.isDefault { result[clip.asset] = o }
        }
        return result
    }

    static func plannerImages(_ assets: [ReelSpec.Asset]) -> [ReelMotionPlanner.Image] {
        assets.map { a in
            let c = ReelCandidate(id: a.id, filename: "", room: a.analysis?.room, category: a.analysis?.category)
            return .init(assetID: a.id, width: a.width, height: a.height,
                         focus: a.analysis?.focus, salientWidth: a.analysis?.salientWidth,
                         isExterior: ReelSelector.isExterior(c) == true, focusWidth: a.analysis?.focusWidth)
        }
    }
}
