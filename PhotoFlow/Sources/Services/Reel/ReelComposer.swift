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

    static let generator = "PhotoFlow ReelComposer v1 / ReelSelector v3 (kollage)"

    nonisolated struct Options: Sendable {
        /// Exakt antal bilder (3...12). nil = automatiskt: en bild per viktig rumstyp, 5...8
        /// (`ReelSelector.select`). Ett exakt antal sparas i specens `editor.fixedCount`.
        var count: Int?
        var format = ReelFormat.vertical
        var address = ""
        var sessionID: String?
        var weights = ReelSelector.Weights()
        /// Bilderna är fotografens egna, redigerade (se `ReelSelector.select`). Pipelinens filmförslag
        /// (FÖRBÄTTRADE/TITTBILDER) är inte kurerat; redigeraren sätter det ur källmappen
        /// (`AddressFolderLayout.isCuratedSource`).
        var curated = false
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
            // Visions nyttobildsflagga gäller hela montaget, som liknar en skärmdump eller ett dokument
            // (två bilder med vit ränna); halvorna är fotografier, så flaggan ignoreras för montage.
            quality: a.qualityScore, isUtility: a.isUtility && (a.panels?.count ?? 0) < 2, horizonDegrees: a.horizonAngleDegrees,
            sharpness: a.sharpness, featureVector: a.featureVector, salientWidth: a.salientWidth,
            meanLuminance: a.meanLuminance, captureHour: hour,
            room: a.room, category: a.category, features: a.features ?? [], caption: a.caption,
            panelRooms: montageRooms(a), width: a.width, height: a.height, focusWidth: a.focusWidth)
    }

    /// Rummet per halva för ett montage med beskrivna halvor (annars tom lista = ingen montage för urvalet).
    static func montageRooms(_ a: ReelImageAnalysis) -> [String] {
        guard let panels = a.panels, panels.count >= 2, let rooms = a.panelRooms, rooms.count == panels.count else { return [] }
        return rooms.map { $0.room ?? "" }
    }

    /// Specens asset för en analyserad bild. Sökvägen är relativ spec-filens mapp.
    static func asset(id: String, item: ReelImageAnalyzer.Item, specDirectory: URL) -> ReelSpec.Asset {
        let a = item.analysis
        return .init(
            id: id, sha256: a.sha256, width: a.width, height: a.height,
            sources: [.init(kind: .local, path: relativePath(from: specDirectory, to: item.url))],
            analysis: .init(room: a.room, category: a.category, focus: a.focus, salientWidth: a.salientWidth,
                            focusWidth: a.focusWidth,
                            panels: a.panels?.isEmpty == false ? a.panels : nil,
                            panelRooms: a.panels?.isEmpty == false && !montageRooms(a).isEmpty ? montageRooms(a) : nil))
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
    /// (förval, längd, övergång, egen rörelse), matchade på sha256 eftersom asset-id:n numreras om.
    /// En bild med något per-bild-lås räknas som pinnad vid urvalet (plan avsnitt 2: ett handändrat
    /// beslut följer med bilden genom "Föreslå igen"), så en bild fotografen lagt in och ändrat
    /// försvinner inte för att urvalet inte hade valt den; som för pinnade bilder kan filmen då bli
    /// längre än begärt antal. Är `editor.orderLocked` satt behåller låsta klipp (pinnade bilder
    /// eller bilder med något per-bild-lås) sin position i filmen när positionen finns kvar; övriga
    /// bilder fyller de lediga platserna i förslagets ordning. Utan `preserving` är resultatet helt
    /// automatiskt (och `editor` från `options` gäller). Specens identitet (id, revision) är alltid ny
    /// här; en redigerare som föreslår om en befintlig film för den vidare med `continuing`.
    static func compose(items: [ReelImageAnalyzer.Item], specDirectory: URL, options: Options = Options(),
                        preserving previous: ReelSpec? = nil) -> Result {
        // Exakta kopior (samma innehåll) är samma bild: behåll första filen.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.analysis.sha256).inserted }
        let candidates = unique.map(candidate(from:))
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.analysis.sha256, $0) })

        var editorState = (previous?.editor ?? options.editor) ?? ReelSpec.EditorState()
        editorState.fixedCount = options.count.map { min(max($0, ReelSelector.minCount), ReelSelector.maxCount) }
        let editor = editorState.normalized

        // Per-bild-lås från förra specen, på sha256 (i filmens ordning).
        var lockedBySha: [String: ReelMotionPlanner.ClipOverride] = [:]
        var lockedOrder: [String] = []
        var oldIndexBySha: [String: Int] = [:]
        // Bilder som ett låst rutklipps andra rutor visar: de är med i klippet och får inget eget klipp.
        var absorbed = Set<String>()
        if let previous {
            let shaByAsset = Dictionary(previous.assets.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
            let perAsset = overrides(in: previous)
            for (i, clip) in previous.timeline.enumerated() {
                guard let sha = shaByAsset[clip.asset] else { continue }
                oldIndexBySha[sha] = i
                if let o = perAsset[clip.asset], lockedBySha[sha] == nil { lockedBySha[sha] = o; lockedOrder.append(sha) }
            }
            for (sha, o) in lockedBySha {
                for panel in o.panels?.panels ?? [] {
                    if let other = shaByAsset[panel.asset], other != sha { absorbed.insert(other) }
                }
            }
        }
        let pinnedIDs = editor?.pinnedAssets ?? []
        let frameAspect = ReelMotionPlanner.frameAspect(options.format.output)
        var selection = ReelSelector.select(candidates, count: options.count, weights: options.weights,
                                            curated: options.curated,
                                            pinned: pinnedIDs + lockedOrder.filter { !pinnedIDs.contains($0) },
                                            excluded: editor?.excludedAssets ?? [],
                                            frameAspect: frameAspect)

        // Ordning: förslagets, men med låsta klipp kvar på sin plats om `orderLocked`. Ett kollages partner
        // har inget eget klipp: den följer sitt ankare (andra rutan) och läggs in som extra bild nedan.
        let partnerIDs = selection.partnerIDs
        var picks = selection.picks.filter {
            byID[$0.candidateID] != nil && !partnerIDs.contains($0.candidateID) && !absorbed.contains($0.candidateID)
        }
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
            // Hela urvalet i den nya ordningen, partnerna direkt efter sina ankare.
            let partnerPicks = Dictionary(selection.picks.filter { partnerIDs.contains($0.candidateID) }.map { ($0.candidateID, $0) },
                                          uniquingKeysWith: { a, _ in a })
            let partnerOf = Dictionary(selection.collages.map { ($0.anchorID, $0.partnerID) }, uniquingKeysWith: { a, _ in a })
            selection.picks = picks.flatMap { pick in
                [pick] + (partnerOf[pick.candidateID].flatMap { partnerPicks[$0] }.map { [$0] } ?? [])
            }
        }

        var assets: [ReelSpec.Asset] = []
        var auto: [ReelSpec.AutoSelection] = []
        var overridesByAsset: [String: ReelMotionPlanner.ClipOverride] = [:]
        for (i, pick) in picks.enumerated() {
            guard let item = byID[pick.candidateID] else { continue }
            let id = "a\(i + 1)"
            assets.append(asset(id: id, item: item, specDirectory: specDirectory))
            auto.append(.init(asset: id, slot: pick.slotKey, reason: pick.reason))
            if let o = lockedBySha[pick.candidateID] { overridesByAsset[id] = o }
        }
        let clipAssetCount = assets.count
        // Kollage (R6c): partnerbilden är andra rutan och ligger som extra asset efter klippens egna.
        var collagePartner: [String: String] = [:]   // ankarets asset-id → partnerns asset-id
        for pair in selection.collages {
            guard let anchor = assets.first(where: { $0.sha256 == pair.anchorID }),
                  let item = byID[pair.partnerID] else { continue }
            let id = "a\(assets.count + 1)"
            assets.append(asset(id: id, item: item, specDirectory: specDirectory))
            collagePartner[anchor.id] = id
            if let pick = selection.picks.first(where: { $0.candidateID == pair.partnerID }) {
                auto.append(.init(asset: id, slot: pick.slotKey, reason: pick.reason))
            }
        }
        // Rutklipp: rutornas bilder bär de gamla asset-id:na; numrera om dem mot de nya (på sha256) och
        // lägg till partnerbilder som inte är något klipps egen bild som extra assets efter klippens.
        if let previous {
            let shaByOldID = Dictionary(previous.assets.map { ($0.id, $0.sha256) }, uniquingKeysWith: { a, _ in a })
            var idBySha = Dictionary(assets.map { ($0.sha256, $0.id) }, uniquingKeysWith: { a, _ in a })
            var next = assets.count
            func newID(forOld old: String) -> String? {
                guard let sha = shaByOldID[old] else { return nil }
                if let id = idBySha[sha] { return id }
                let id = "a\(next + 1)"
                if let item = byID[sha] {
                    assets.append(asset(id: id, item: item, specDirectory: specDirectory))
                } else if var kept = previous.assets.first(where: { $0.id == old }) {
                    kept.id = id
                    assets.append(kept)
                } else { return nil }
                next += 1
                idBySha[sha] = id
                return id
            }
            for (anchor, o) in overridesByAsset {
                guard var lock = o.panels else { continue }
                var remapped: [ReelSpec.Panel] = []
                for var panel in lock.panels {
                    guard let id = newID(forOld: panel.asset) else { continue }
                    panel.asset = id
                    remapped.append(panel)
                }
                guard remapped.count == lock.panels.count else {
                    overridesByAsset[anchor]?.panels = nil   // en ruta saknar bild: klippet blir ett vanligt klipp
                    continue
                }
                lock.panels = remapped
                overridesByAsset[anchor]?.panels = lock
            }
        }

        let output = options.format.output
        let style = previous?.style ?? defaultStyle
        // Planeraren ser bara klippens egna bilder (picks); extra rutbilder ligger sist i `assets`.
        let clipAssets = Array(assets.prefix(clipAssetCount))
        let imageByID = Dictionary(plannerImages(assets).map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let clips = ReelMotionPlanner.plan(plannerImages(clipAssets), frameAspect: ReelMotionPlanner.frameAspect(output),
                                           overrides: overridesByAsset,
                                           tempo: .init(editorValue: editor?.tempo),
                                           defaultTransition: style.defaultTransition,
                                           collages: collagePartner.compactMapValues { imageByID[$0] })
        // En bild ingen ruta visar (t.ex. urvalets kollagepartner till ett klipp som fotografen låst med en annan
        // partner) hör inte hemma i specen.
        let referenced = Set(clips.flatMap(\.referencedAssetIDs))
        if assets.contains(where: { !referenced.contains($0.id) }) {
            assets.removeAll { !referenced.contains($0.id) }
            auto.removeAll { !referenced.contains($0.asset) }
        }
        var spec = ReelSpec(
            schema: ReelSpec.schemaName, version: 1, minReaderVersion: 1,
            id: options.specID, revision: 1, status: "draft",
            createdAt: wholeSeconds(options.now), updatedAt: wholeSeconds(options.now), updatedBy: options.updatedBy,
            property: .init(address: options.address, sessionID: options.sessionID,
                            kind: selection.template == .house ? "house" : "apartment"),
            assets: assets, style: style, timeline: clips, audio: nil, overlays: [], brand: nil,
            outputs: [output],
            provenance: .init(generator: generator, autoSelection: auto, edits: nil))
        spec.editor = editor
        spec = spec.updatingVersions()
        return Result(spec: spec, selection: selection, candidates: candidates,
                      urls: Dictionary(unique.map { ($0.analysis.sha256, $0.url) }, uniquingKeysWith: { a, _ in a }))
    }

    /// En nykomponerad film (`compose`) som nästa version av `previous`, för "Föreslå igen", ändrat
    /// antal och "Börja om helt" i redigeraren: samma id, `createdAt`, objekt (`property`), brand och
    /// textlager, revisionen höjd över den förra och en `edit` med `op` tillagd i den förra loggen,
    /// precis som `rebuild`. Annars skulle en ny spec med revision 1 se synkad ut mot mäklaren
    /// (som jämför revisionsnummer) och kunna skrivas över vid nästa hämtning.
    static func continuing(_ new: ReelSpec, from previous: ReelSpec, op: String,
                           by: ReelSpec.UpdatedBy = .init(role: "photographer", name: nil),
                           now: Date = Date()) -> ReelSpec {
        var out = new
        out.id = previous.id
        out.createdAt = previous.createdAt
        out.property = previous.property
        out.brand = previous.brand
        out.overlays = previous.overlays
        out.revision = previous.revision + 1
        out.status = "draft"
        out.updatedAt = wholeSeconds(now)
        out.updatedBy = by
        out.provenance.edits = (previous.provenance.edits ?? []) + [.init(at: wholeSeconds(now), by: by.role, op: op)]
        return out
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
        var used = order.filter { known[$0] != nil }

        var out = spec
        if let format { out.outputs = [format.output] }
        let aspect = ReelMotionPlanner.frameAspect(out.outputs.first ?? ReelFormat.vertical.output)
        // Fotografens val (rörelse, längd) följer med bilden; utan `overrides` läses de ur nuvarande klipp.
        var kept = overrides ?? Self.overrides(in: spec)
        let images = Dictionary(plannerImages(Array(known.values)).map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        // Formatbyte: ett låst rutklipps layout och nycklar anpassas till det nya formatet.
        if format != nil, let old = spec.outputs.first, abs(ReelMotionPlanner.frameAspect(old) - aspect) > 1e-9 {
            for (id, o) in kept {
                if let lock = o.panels { kept[id]?.panels = ReelPanelEdit.adapted(lock, images: images, frameAspect: aspect) }
            }
        }

        // Automatiska kollage (R6c) följer med bilden: ankaret finns kvar i `order` (annars lämnar båda
        // bilderna filmen), partnern är en extra bild. Ett kollage som inte längre gäller (formatet
        // motiverar det inte, en bild är utesluten, ankaret har fått ett eget förval) löses upp: partnern
        // blir ett eget klipp direkt efter ankaret, om den inte är utesluten.
        let excludedSha = Set(spec.editor?.excludedAssets ?? [])
        var collages: [String: ReelMotionPlanner.Image] = [:]
        var dissolved = Set<String>()
        for clip in spec.timeline {
            guard let partnerID = autoCollagePartner(clip), used.contains(clip.asset), !used.contains(partnerID),
                  let anchor = images[clip.asset], let partner = images[partnerID],
                  let anchorSha = known[clip.asset]?.sha256, let partnerSha = known[partnerID]?.sha256 else { continue }
            let blocked = excludedSha.contains(anchorSha) || excludedSha.contains(partnerSha)
            if !blocked, ReelMotionPlanner.collageActive(anchor: anchor, partner: partner, frameAspect: aspect,
                                                         override: kept[clip.asset]) {
                collages[clip.asset] = partner
                continue
            }
            dissolved.insert(clip.asset); dissolved.insert(partnerID)
            // Partnern blir ett eget klipp direkt efter ankaret (även en extra bild: kollaget kommer då tillbaka när
            // formatet passar igen, se nedan), om den inte är utesluten och filmen inte är full.
            if !excludedSha.contains(partnerSha), used.count < ReelSelector.maxCount,
               let at = used.firstIndex(of: clip.asset) { used.insert(partnerID, at: at + 1) }
        }
        // Kollage som löstes upp av ett formatbyte kommer tillbaka när formatet passar igen: två intilliggande
        // automatiska klipp som båda bär märkningen "löstes upp" och som `collageActive` godkänner slås ihop.
        // (Fotografens eget "Dela upp" märks inte, se `ReelEditorModel.splitPanels`, och slås inte ihop.)
        var restoredReasons: [String: String] = [:]
        if let layout = ReelMotionPlanner.collageLayout(frameAspect: aspect) {
            let marked = Set((spec.provenance.autoSelection ?? []).filter { $0.reason.hasPrefix(dissolvedReason) }.map(\.asset))
            func isAuto(_ id: String) -> Bool {
                (kept[id]?.effectivePreset ?? .auto) == .auto && kept[id]?.panels == nil
                    && !excludedSha.contains(known[id]?.sha256 ?? "")
            }
            var i = 0
            while i + 1 < used.count {
                let a = used[i], b = used[i + 1]
                if marked.contains(a), marked.contains(b), collages[a] == nil, isAuto(a), isAuto(b),
                   let ia = images[a], let ib = images[b],
                   ReelMotionPlanner.collageActive(anchor: ia, partner: ib, frameAspect: aspect, override: kept[a]) {
                    collages[a] = ib
                    used.remove(at: i + 1)
                    let pane = ReelMotionPlanner.ratioText(ReelMotionPlanner.collagePaneAspect(layout: layout, frameAspect: aspect))
                    let reason = "Kollage: \(ReelMotionPlanner.collageRoomsText(ia, ib)), båda ryms i \(pane) (kom tillbaka när formatet passade igen)"
                    restoredReasons[a] = reason; restoredReasons[b] = reason
                }
                i += 1
            }
        }
        let assets = used.compactMap { known[$0] }
        out.timeline = ReelMotionPlanner.plan(plannerImages(assets), frameAspect: aspect, overrides: kept,
                                              tempo: .init(editorValue: spec.editor?.tempo),
                                              defaultTransition: spec.style.defaultTransition, collages: collages)
        // Bilder som rutklippens rutor pekar på men som inte är något klipps egen bild ligger kvar i `assets`.
        var extras: [ReelSpec.Asset] = []
        let have = Set(assets.map(\.id))
        for clip in out.timeline {
            for id in clip.referencedAssetIDs where !have.contains(id) && !extras.contains(where: { $0.id == id }) {
                if let a = known[id] { extras.append(a) }
            }
        }
        out.assets = assets + extras
        out = out.updatingVersions()
        out.revision += 1
        out.updatedAt = wholeSeconds(now)
        out.updatedBy = by
        out.status = "draft"
        var prov = spec.provenance
        // Klippens bilder och rutornas (en kollagepartner har ingen egen plats i `order`).
        let referenced = Set(out.timeline.flatMap(\.referencedAssetIDs))
        prov.autoSelection = prov.autoSelection?.filter { sel in referenced.contains(sel.asset) }.map { sel in
            var s = sel
            if let reason = restoredReasons[sel.asset] { s.reason = reason; return s }
            // Ett upplöst kollage har inget kollage att motivera längre.
            guard dissolved.contains(sel.asset), sel.reason.hasPrefix("Kollage:") else { return sel }
            s.reason = dissolvedReason
            return s
        }
        prov.edits = (prov.edits ?? []) + [.init(at: wholeSeconds(now), by: by.role, op: op)]
        out.provenance = prov
        return out
    }

    // MARK: - Hjälp

    /// Urvalsskälet för bilder som var del av ett automatiskt kollage som löstes upp av ett formatbyte. Märket
    /// används för att sätta ihop kollaget igen när formatet passar (se `rebuild`).
    static let dissolvedReason = "Var del av ett kollage som löstes upp"

    /// Partnerns asset-id om klippet är ett automatiskt kollage (`stack`/`side` med två rutor, ankaret
    /// först, utan fotografens `custom`-lås); annars nil.
    static func autoCollagePartner(_ clip: ReelSpec.Clip) -> String? {
        guard clip.fit == .panels, clip.layout == .stack || clip.layout == .side,
              clip.motionPreset != ReelMotionPlanner.Preset.custom.rawValue,
              let panels = clip.panels, panels.count == 2, panels[0].asset == clip.asset,
              panels[1].asset != clip.asset else { return nil }
        return panels[1].asset
    }

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
    /// `transitionLocked`; för `custom` även `fit` och `motion`). En egen rörelse läses ur de
    /// oklampade nycklarna (`customMotion`) när `motion` fortfarande är just dem klampade mot nuvarande
    /// format; har `motion` ändrats på annat sätt (t.ex. i mäklarens redigerare) gäller `motion`.
    static func overrides(in spec: ReelSpec) -> [String: ReelMotionPlanner.ClipOverride] {
        var result: [String: ReelMotionPlanner.ClipOverride] = [:]
        let images = Dictionary(plannerImages(spec.assets).map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let aspect = ReelMotionPlanner.frameAspect(spec.outputs.first ?? ReelFormat.vertical.output)
        for clip in spec.timeline {
            let preset = clip.motionPreset.flatMap(ReelMotionPlanner.Preset.init(rawValue:)) ?? .auto
            let locked = clip.transitionLocked == true
            if clip.fit == .panels, preset == .custom, let layout = clip.layout, let panels = clip.panels, !panels.isEmpty {
                // Rutklipp (spec v2) med `motionPreset == "custom"`: utformningen är fotografens låsta val
                // (längd och övergång som för andra klipp). Ett rutklipp utan `custom` är planerarens eget
                // (ett montage i ett smalt format) och planeras om vid varje ombyggnad, så att det följer
                // formatet; då gäller bara längd- och övergångslås, som för vanliga klipp.
                result[clip.asset] = .init(
                    preset: .auto, duration: clip.durationLocked == true ? clip.duration : nil,
                    transitionLocked: locked, transition: locked ? clip.transitionIn : nil, custom: nil,
                    panels: .init(layout: layout, panels: panels, gutter: clip.gutter, entrance: clip.entrance))
                continue
            }
            var custom: ReelMotionPlanner.CustomMotion?
            if preset == .custom {
                custom = .init(fit: clip.fit, motion: clip.motion)
                if let source = clip.customMotion, let image = images[clip.asset] {
                    let mine = ReelMotionPlanner.CustomMotion(fit: clip.fit, motion: source)
                    if ReelMotionPlanner.clampedCustomMotion(image, frameAspect: aspect, custom: mine) == clip.motion { custom = mine }
                }
            }
            let o = ReelMotionPlanner.ClipOverride(
                preset: preset, duration: clip.durationLocked == true ? clip.duration : nil,
                transitionLocked: locked, transition: locked ? clip.transitionIn : nil, custom: custom)
            if !o.isDefault { result[clip.asset] = o }
        }
        return result
    }

    static func plannerImages(_ assets: [ReelSpec.Asset]) -> [ReelMotionPlanner.Image] {
        assets.map { a in
            let c = ReelCandidate(id: a.id, filename: "", room: a.analysis?.room, category: a.analysis?.category)
            return .init(assetID: a.id, width: a.width, height: a.height,
                         focus: a.analysis?.focus, salientWidth: a.analysis?.salientWidth,
                         isExterior: ReelSelector.isExterior(c) == true, focusWidth: a.analysis?.focusWidth,
                         panels: a.analysis?.panels ?? [], room: a.analysis?.room)
        }
    }
}
