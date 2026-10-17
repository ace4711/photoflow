import Foundation
import CoreGraphics

/// Redigering av rutklipp (R6d, plan 8.5): Dela ruta med…, Dela upp, Byt plats, layout, ingång, inramning
/// per ruta och Tillbaka till automatiskt. All logik ligger här och i `ReelPanelEdit`; vyerna anropar bara.
///
/// Varje ändring låser rutklippet (`motionPreset == "custom"`, så att en ombyggnad och "Föreslå igen"
/// behåller det) och går via `apply`, alltså ett ångringssteg med revision och sparning. Klippets identitet
/// är första rutans bild (`clip.asset`); byter första rutan bild följer klippets id med i ordningen.
extension ReelEditorModel {

    /// En ruta i ett rutklipp, för rörelseeditorn.
    struct PanelInfo: Identifiable, Equatable {
        var index: Int
        var assetID: String
        var sha256: String
        /// Bildens längsta sida i pixlar (för att ladda en lagom stor kopia).
        var originalLongEdge: Int
        /// Urvalsskälet för bilden ("Vald av dig" för en bild fotografen lagt in själv).
        var reason: String
        var url: URL?
        var filename: String
        var room: String?
        var source: ReelSpec.UnitRect?
        var imageSize: CGSize
        /// Rutans bildförhållande i layouten.
        var paneAspect: Double
        /// Nyckeln inramningen visas för (början; mittpunkten är densamma i slutet).
        var key: ReelSpec.MotionKey
        var id: Int { index }
    }

    /// Montagets två visningssätt (`setMontageLayout`).
    enum MontageLayout: Equatable { case sequence, whole }

    // MARK: Uppslag

    func clip(forAsset id: String) -> ReelSpec.Clip? { spec?.timeline.first { $0.asset == id } }

    func panelKind(forAsset id: String?) -> ReelPanelEdit.Kind {
        id.flatMap(clip(forAsset:)).map(ReelPanelEdit.kind(of:)) ?? .none
    }

    var frameAspect: Double? { spec?.outputs.first.map(ReelMotionPlanner.frameAspect) }

    /// Layouter fotografen kan välja för klippet i nuvarande format: kollage stapel/sida/sekvens (de som
    /// ger rimliga rutor), montage bara sekvens (hela bilden väljs med `setMontageLayout`).
    func availableLayouts(forAsset id: String) -> [ReelSpec.PanelLayout] {
        guard let aspect = frameAspect else { return [] }
        switch panelKind(forAsset: id) {
        case .collage: return ReelPanelEdit.collageLayouts(frameAspect: aspect)
        case .montage: return [.sequence]
        case .none: return []
        }
    }

    /// Är klippets bild ett montage (två halvor i analysen) som kan visas som sekvens eller som hela bilden?
    func isMontageClip(_ id: String) -> Bool {
        guard let asset = spec?.assets.first(where: { $0.id == id }) else { return false }
        return (asset.analysis?.panels?.count ?? 0) >= 2 && panelKind(forAsset: id) != .collage
    }

    /// Hur ett montageklipp visas nu: som sekvens (rutklipp) eller som hela bilden.
    func montageLayout(forAsset id: String) -> MontageLayout? {
        guard isMontageClip(id) else { return nil }
        return panelKind(forAsset: id) == .montage ? .sequence : .whole
    }

    func panelInfos(forAsset id: String) -> [PanelInfo] {
        guard let spec, let clip = clip(forAsset: id), let panels = clip.panels, let aspect = frameAspect,
              ReelPanelEdit.kind(of: clip) != .none else { return [] }
        let pane = ReelPanelEdit.paneAspect(layout: clip.layout ?? .stack, frameAspect: aspect, gutter: clip.gutter)
        let reasons = Dictionary((spec.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) }, uniquingKeysWith: { a, _ in a })
        return panels.enumerated().compactMap { k, panel in
            guard let asset = spec.assets.first(where: { $0.id == panel.asset }) else { return nil }
            let candidate = candidates.first { $0.id == asset.sha256 }
            return PanelInfo(
                index: k, assetID: asset.id, sha256: asset.sha256, originalLongEdge: max(asset.width, asset.height),
                reason: reasons[asset.id] ?? "Vald av dig", url: urls[asset.sha256],
                filename: candidate?.filename ?? asset.sources.first?.path ?? asset.id,
                room: asset.analysis?.room, source: panel.source,
                imageSize: CGSize(width: asset.width, height: asset.height), paneAspect: pane, key: panel.motion.from)
        }
    }

    private func plannerImage(_ assetID: String) -> ReelMotionPlanner.Image? {
        spec?.assets.first { $0.id == assetID }.flatMap { ReelComposer.plannerImages([$0]).first }
    }

    private func sha(_ assetID: String) -> String? { spec?.assets.first { $0.id == assetID }?.sha256 }

    private func index(of assetID: String) -> Int? { spec?.timeline.firstIndex { $0.asset == assetID } }

    // MARK: Dela ruta med…

    /// Startar "Dela ruta med…": nästa bild som väljs i rutnätet blir klippets partner. Bara vanliga klipp.
    func beginPickingPartner(for assetID: String) {
        guard analysisReady, let clip = clip(forAsset: assetID), clip.fit != .panels else { return }
        selectedAssetID = assetID
        partnerPickAssetID = assetID
    }

    func cancelPickingPartner() { partnerPickAssetID = nil }

    /// Kan bilden (sha256) bli partner till klippet? Inte bilden själv, och inte en bild som redan är med i ett
    /// annat rutklipp (dela upp det först): ett kollage ska aldrig ta en ruta från ett annat.
    func canPair(_ assetID: String, withCandidate id: String) -> Bool {
        guard analysisReady, let spec, let clip = clip(forAsset: assetID), clip.fit != .panels, sha(assetID) != id else { return false }
        let inFilm = Set(order)
        for other in spec.timeline where other.fit == .panels {
            if other.referencedAssetIDs.contains(where: { rid in self.sha(rid) == id }) { return false }
        }
        return candidates.contains { $0.id == id } || spec.assets.contains { $0.sha256 == id && inFilm.contains($0.id) }
    }

    /// Gör klippet till ett kollage med bilden som andra ruta. Formatet bestämmer layouten (stapel i 9:16, sida
    /// vid sida i 16:9; i 1:1 den som beskär minst). Är bilden redan ett eget klipp går det upp i kollaget; en
    /// utesluten bild blir inte längre utesluten. Returnerar false utan ändring om bilden inte kan vara partner.
    @discardableResult
    func pairClip(_ assetID: String, withCandidate id: String) -> Bool {
        guard canPair(assetID, withCandidate: id), let spec, let aspect = frameAspect,
              let idx = index(of: assetID), let anchorAsset = spec.assets.first(where: { $0.id == assetID }) else { return false }
        let clip = spec.timeline[idx]
        let inFilm = Set(order)
        let partner: ReelSpec.Asset
        var added: [ReelSpec.Asset] = []
        if let own = spec.assets.first(where: { $0.sha256 == id && inFilm.contains($0.id) }) {
            partner = own
        } else if let fresh = newAsset(forCandidate: id) {
            partner = fresh
            added = [fresh]
        } else { return false }
        let images = ReelComposer.plannerImages([anchorAsset, partner])
        let layout = ReelPanelEdit.preferredLayout(images[0], images[1], frameAspect: aspect)
        let panels = ReelMotionPlanner.collagePanels(anchor: images[0], partner: images[1], layout: layout,
                                                     frameAspect: aspect, duration: ReelMotionPlanner.collageBaseDuration)
        let locked = ReelPanelEdit.lockedClip(clip, layout: layout, panels: panels, entrance: ReelMotionPlanner.collageEntrance)
        var newOrder = order
        newOrder.removeAll { $0 == partner.id }
        apply(order: newOrder, newAssets: added, editor: Self.unexclude(id), edit: { $0.timeline[idx] = locked }, op: "pair")
        selectedAssetID = assetID
        return true
    }

    // MARK: Dela upp, byt plats

    /// Dela upp: kollagets rutor blir vanliga klipp efter varandra (märkta "Delades upp av dig", så att de inte
    /// sätts ihop igen vid formatbyte); ett montage blir ett vanligt klipp med hela bilden.
    func splitPanels(_ assetID: String) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID) else { return }
        switch ReelPanelEdit.kind(of: clip) {
        case .none: return
        case .montage: setMontageLayout(assetID, .whole)
        case .collage:
            dissolve(assetID, clip: clip, index: idx, reason: "Delades upp av dig", op: "splitPanels")
        }
    }

    /// Rutorna blir vanliga klipp: första rutans bild behåller klippets plats, övriga kommer direkt efter.
    private func dissolve(_ assetID: String, clip: ReelSpec.Clip, index idx: Int, reason: String?, op: String) {
        let others = (clip.panels ?? []).dropFirst().map(\.asset).filter { $0 != assetID }
        var newOrder = order
        if let at = newOrder.firstIndex(of: assetID) {
            for (n, id) in others.enumerated() where !newOrder.contains(id) { newOrder.insert(id, at: at + 1 + n) }
        }
        let touched = Set([assetID] + others)
        apply(order: newOrder, edit: { s in
            s.timeline[idx] = ReelPanelEdit.plainClip(clip, asset: assetID)
            guard let reason else { return }
            s.provenance.autoSelection = s.provenance.autoSelection?.map { sel in
                guard touched.contains(sel.asset), sel.reason.hasPrefix("Kollage:") || sel.reason.hasPrefix(ReelComposer.dissolvedReason)
                else { return sel }
                var changed = sel
                changed.reason = reason
                return changed
            }
        }, op: op)
    }

    /// Byt plats: kollagets rutor byter ordning (den andra bilden blir klippets bild och första rutan); ett
    /// montages halvor visas i omvänd ordning.
    func swapPanels(_ assetID: String) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID), let aspect = frameAspect,
              let panels = clip.panels, panels.count == 2 else { return }
        switch ReelPanelEdit.kind(of: clip) {
        case .none: return
        case .collage:
            let swapped = Array(panels.reversed())
            let locked = ReelPanelEdit.lockedClip(clip, layout: clip.layout ?? .stack, panels: swapped, entrance: clip.entrance)
            apply(order: order.map { $0 == assetID ? swapped[0].asset : $0 }, edit: { $0.timeline[idx] = locked }, op: "swapPanels")
            selectedAssetID = swapped[0].asset
        case .montage:
            guard var image = plannerImage(assetID) else { return }
            image.panels = panels.compactMap(\.source).reversed()
            let segment = clip.duration / 2
            let locked = ReelPanelEdit.lockedClip(clip, layout: .sequence,
                                                  panels: ReelMotionPlanner.montagePanels(image, frameAspect: aspect, segment: segment),
                                                  entrance: nil)
            apply(order: order, edit: { $0.timeline[idx] = locked }, op: "swapPanels")
        }
    }

    // MARK: Layout, ingång, inramning

    /// Byter layout för ett kollage (stapel, sida vid sida, efter varandra). Inramningen behålls så långt den ryms
    /// i de nya rutorna.
    func setPanelLayout(_ assetID: String, _ layout: ReelSpec.PanelLayout) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID), let aspect = frameAspect,
              ReelPanelEdit.kind(of: clip) == .collage, availableLayouts(forAsset: assetID).contains(layout),
              layout != clip.layout, let spec else { return }
        let pane = ReelPanelEdit.paneAspect(layout: layout, frameAspect: aspect, gutter: clip.gutter)
        let panels = (clip.panels ?? []).map { panel -> ReelSpec.Panel in
            guard let asset = spec.assets.first(where: { $0.id == panel.asset }) else { return panel }
            return ReelPanelEdit.retargeted(panel, imageSize: CGSize(width: asset.width, height: asset.height), paneAspect: pane)
        }
        let locked = ReelPanelEdit.lockedClip(clip, layout: layout, panels: panels, entrance: clip.entrance)
        apply(order: order, edit: { $0.timeline[idx] = locked }, op: "panelLayout", target: assetID)
    }

    /// Montage: "Som två klipp (sekvens)" eller "Som montage (hela bilden)". Båda låser valet.
    func setMontageLayout(_ assetID: String, _ layout: MontageLayout) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID), let aspect = frameAspect,
              isMontageClip(assetID), montageLayout(forAsset: assetID) != layout || ReelPanelEdit.isLocked(clip) == false
        else { return }
        switch layout {
        case .whole:
            let whole = ReelPanelEdit.wholeMontageClip(clip)
            apply(order: order, edit: { $0.timeline[idx] = whole }, op: "panelLayout", target: assetID)
        case .sequence:
            guard let image = plannerImage(assetID), image.panels.count >= 2 else { return }
            var base = clip
            base.durationLocked = nil
            let panels = ReelMotionPlanner.montagePanels(image, frameAspect: aspect, segment: ReelMotionPlanner.montageSegmentDuration)
            let locked = ReelPanelEdit.lockedClip(base, layout: .sequence, panels: panels, entrance: nil)
            apply(order: order, edit: { $0.timeline[idx] = locked }, op: "panelLayout", target: assetID)
        }
    }

    /// Ingång för kollage i stapel eller sida vid sida: Glid in, Tona in eller Ingen.
    func setEntrance(_ assetID: String, _ type: ReelSpec.EntranceType) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID),
              ReelPanelEdit.kind(of: clip) == .collage, let layout = clip.layout, layout != .sequence,
              clip.entrance?.type != type || !ReelPanelEdit.isLocked(clip) else { return }
        var entrance = clip.entrance ?? ReelMotionPlanner.collageEntrance
        entrance.type = type
        let locked = ReelPanelEdit.lockedClip(clip, layout: layout, panels: clip.panels ?? [], entrance: entrance)
        apply(order: order, edit: { $0.timeline[idx] = locked }, op: "entrance", target: assetID)
    }

    /// Flyttar mitten på rutans stilla utsnitt till (`cx`, `cy`) i bildens koordinater (klampas inom bilden
    /// och rutans `source`). Ingen panorering: båda nycklarna får samma mittpunkt.
    func setPanelCenter(_ assetID: String, panel k: Int, cx: Double, cy: Double) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID), let layout = clip.layout,
              ReelPanelEdit.kind(of: clip) != .none, let panels = clip.panels, panels.indices.contains(k),
              let info = panelInfos(forAsset: assetID).first(where: { $0.index == k }) else { return }
        var updated = panels
        updated[k] = ReelPanelEdit.recentered(panels[k], cx: cx, cy: cy, imageSize: info.imageSize, paneAspect: info.paneAspect)
        guard updated != panels else { return }
        let locked = ReelPanelEdit.lockedClip(clip, layout: layout, panels: updated, entrance: clip.entrance)
        apply(order: order, edit: { $0.timeline[idx] = locked }, op: "framing", target: "\(assetID)#\(k)")
    }

    /// Byter bilden i en ruta mot en bild ur rutnätet (klick med ett markerat kollage, eller ruta + bild).
    /// Bilden får rutans mitt på sitt motiv. Är bilden redan med i filmen sker ingenting.
    func replacePanel(_ assetID: String, panel k: Int, withCandidate id: String) {
        guard let spec, let clip = clip(forAsset: assetID), let idx = index(of: assetID), let aspect = frameAspect,
              ReelPanelEdit.kind(of: clip) == .collage, let panels = clip.panels, panels.indices.contains(k),
              self.assetID(forCandidate: id) == nil, let fresh = newAsset(forCandidate: id),
              let other = spec.assets.first(where: { $0.id == panels[1 - k].asset }) else { return }
        let layout = clip.layout ?? .stack
        let images = ReelComposer.plannerImages(k == 0 ? [fresh, other] : [other, fresh])
        let rebuilt = ReelMotionPlanner.collagePanels(anchor: images[0], partner: images[1], layout: layout,
                                                      frameAspect: aspect, duration: ReelMotionPlanner.collageBaseDuration)
        var updated = panels
        updated[k] = rebuilt[k]
        let locked = ReelPanelEdit.lockedClip(clip, layout: layout, panels: updated, entrance: clip.entrance)
        let newOrder = order.map { $0 == assetID ? locked.asset : $0 }
        apply(order: newOrder, newAssets: [fresh], editor: Self.unexclude(id), edit: { $0.timeline[idx] = locked }, op: "panels")
        selectedAssetID = locked.asset
    }

    // MARK: Tillbaka till automatiskt

    /// Släpper rutklippets lås. Ett kollage blir planerarens eget igen när formatet och bilderna motiverar det
    /// (stapel i 9:16, sida vid sida i 16:9, motiven ryms); annars (1:1, eller motiven ryms inte) blir rutorna
    /// vanliga klipp, märkta så att kollaget kommer tillbaka om formatet byts till ett som passar. Ett montage
    /// planeras om av planeraren (sekvens i smala format, vanligt klipp i 16:9).
    func restorePanelsAuto(_ assetID: String) {
        guard let clip = clip(forAsset: assetID), let idx = index(of: assetID), let aspect = frameAspect else { return }
        switch ReelPanelEdit.kind(of: clip) {
        case .collage:
            guard ReelPanelEdit.isLocked(clip), let panels = clip.panels, panels.count == 2,
                  let layout = ReelMotionPlanner.collageLayout(frameAspect: aspect),
                  let a = plannerImage(panels[0].asset), let b = plannerImage(panels[1].asset),
                  ReelMotionPlanner.collageActive(anchor: a, partner: b, frameAspect: aspect, override: nil) else {
                guard ReelPanelEdit.isLocked(clip) else { return }
                dissolve(assetID, clip: clip, index: idx, reason: ReelComposer.dissolvedReason, op: "panels")
                return
            }
            let auto = ReelMotionPlanner.collagePanels(anchor: a, partner: b, layout: layout, frameAspect: aspect,
                                                       duration: ReelMotionPlanner.collageBaseDuration)
            var restored = clip
            restored.layout = layout
            restored.panels = auto
            restored.motion = auto[0].motion
            restored.gutter = nil
            restored.entrance = ReelMotionPlanner.collageEntrance
            restored.motionPreset = nil
            apply(order: order, edit: { $0.timeline[idx] = restored }, op: "panels")
        case .montage:
            guard ReelPanelEdit.isLocked(clip) else { return }
            apply(order: order, edit: { $0.timeline[idx] = ReelPanelEdit.plainClip(clip, asset: assetID) }, op: "panels")
        case .none:
            // Montage som hela bilden (custom contain-blur): vanligt "tillbaka till automatisk".
            if isMontageClip(assetID), clip.motionPreset != nil { setPreset(assetID, .auto) }
        }
    }
}
