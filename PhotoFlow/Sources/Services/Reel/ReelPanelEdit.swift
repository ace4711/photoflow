import Foundation
import CoreGraphics

/// Ren logik för fotografens redigering av rutklipp (R6d): layouter som passar formatet, nycklar per
/// ruta (inramning), klipp som byggs om till låsta rutklipp (`motionPreset == "custom"`) och tillbaka
/// till vanliga klipp. Inget UI och ingen disk; `ReelEditorModel` anropar funktionerna och lägger
/// resultatet i specen via `apply`. Testas i `ReelPanelEditTests`.
nonisolated enum ReelPanelEdit {

    // MARK: - Slag av rutklipp

    nonisolated enum Kind: Equatable, Sendable {
        /// Inte ett rutklipp.
        case none
        /// Två olika bilder (stapel, sida vid sida eller efter varandra).
        case collage
        /// Samma bild i alla rutor (montagets halvor, `source` satt).
        case montage
    }

    static func kind(of clip: ReelSpec.Clip) -> Kind {
        guard clip.fit == .panels, let panels = clip.panels, panels.count >= 2 else { return .none }
        return Set(panels.map(\.asset)).count == 1 ? .montage : .collage
    }

    /// Är rutklippet låst av fotografen (`custom`)? Planerarens egna rutklipp (montage, kollage) är det inte.
    static func isLocked(_ clip: ReelSpec.Clip) -> Bool {
        clip.fit == .panels && clip.motionPreset == ReelMotionPlanner.Preset.custom.rawValue
    }

    // MARK: - Layouter

    /// Layoutens namn och SF-symbol i menyer och tidslinjen.
    static func label(_ layout: ReelSpec.PanelLayout) -> String {
        switch layout {
        case .stack: return "Stapel"
        case .side: return "Sida vid sida"
        case .sequence: return "Efter varandra"
        }
    }

    static func symbol(_ layout: ReelSpec.PanelLayout) -> String {
        switch layout {
        case .stack: return "rectangle.split.1x2"
        case .side: return "rectangle.split.2x1"
        case .sequence: return "arrow.right.square"
        }
    }

    static func label(_ type: ReelSpec.EntranceType) -> String {
        switch type {
        case .slide: return "Glid in"
        case .fade: return "Tona in"
        case .none: return "Ingen"
        }
    }

    /// Bildförhållande för en ruta i layouten. `sequence` fyller hela ramen.
    static func paneAspect(layout: ReelSpec.PanelLayout, frameAspect: Double, gutter: Double?) -> Double {
        if layout == .sequence { return frameAspect }
        return ReelMotionPlanner.collagePaneAspect(layout: layout, frameAspect: frameAspect,
                                                   gutter: gutter ?? ReelSpec.Clip.defaultGutter)
    }

    /// Rutor smalare eller bredare än så här passar inte i ramen (9:16 sida vid sida ger 0,28).
    static let paneAspectRange = 0.45...2.2

    /// Layouter ett kollage kan få i ramen, i menyordning: stapel och sida vid sida när rutorna blir
    /// rimliga (9:16: stapel; 16:9: sida vid sida; 1:1: båda), efter varandra alltid.
    static func collageLayouts(frameAspect: Double) -> [ReelSpec.PanelLayout] {
        var result: [ReelSpec.PanelLayout] = []
        for layout in [ReelSpec.PanelLayout.stack, .side]
        where paneAspectRange.contains(paneAspect(layout: layout, frameAspect: frameAspect, gutter: nil)) {
            result.append(layout)
        }
        return result + [.sequence]
    }

    /// Andel av bildens yta som syns i en ruta med bildförhållandet `pane` (cover): 1 = ingen beskärning.
    static func visibleShare(_ image: ReelMotionPlanner.Image, pane: Double) -> Double {
        let a = max(image.aspect, 1e-9), p = max(pane, 1e-9)
        return min(a, p) / max(a, p)
    }

    /// Layouten för ett nytt kollage: stapel i 9:16, sida vid sida i 16:9. I 1:1 den av stapel och sida som
    /// ger minst beskärning av de två bilderna (vid lika: stapel).
    static func preferredLayout(_ a: ReelMotionPlanner.Image, _ b: ReelMotionPlanner.Image,
                                frameAspect: Double) -> ReelSpec.PanelLayout {
        if let layout = ReelMotionPlanner.collageLayout(frameAspect: frameAspect) { return layout }
        func share(_ layout: ReelSpec.PanelLayout) -> Double {
            let pane = paneAspect(layout: layout, frameAspect: frameAspect, gutter: nil)
            return visibleShare(a, pane: pane) + visibleShare(b, pane: pane)
        }
        return share(.side) > share(.stack) + 1e-9 ? .side : .stack
    }

    // MARK: - Nycklar och inramning

    /// Nyckeln klampad så att rutans utsnitt (cover mot `source`, annars hela bilden) ligger inom bilden.
    /// Räknar lokalt i `source` med `ReelMotionGeometry` och går tillbaka till hela bildens koordinater.
    static func clamped(_ key: ReelSpec.MotionKey, source: ReelSpec.UnitRect?, imageSize: CGSize,
                        paneAspect: Double) -> ReelSpec.MotionKey {
        guard let s = source, s.w > 0, s.h > 0 else {
            return ReelMotionGeometry.clamped(key, fit: .cover, imageSize: imageSize, frameAspect: paneAspect)
        }
        let local = ReelSpec.MotionKey(cx: (key.cx - s.x) / s.w, cy: (key.cy - s.y) / s.h, zoom: key.zoom)
        let size = CGSize(width: s.w * imageSize.width, height: s.h * imageSize.height)
        let c = ReelMotionGeometry.clamped(local, fit: .cover, imageSize: size, frameAspect: paneAspect)
        return .init(cx: s.x + c.cx * s.w, cy: s.y + c.cy * s.h, zoom: c.zoom)
    }

    /// Rutans utsnitt (hela bildens koordinater) för en nyckel: det som renderas.
    static func frame(of key: ReelSpec.MotionKey, source: ReelSpec.UnitRect?, imageSize: CGSize,
                      paneAspect: Double) -> CGRect {
        ReelTimeline.panelCrop(imageSize: imageSize, source: source, destAspect: paneAspect,
                               center: CGPoint(x: key.cx, y: key.cy), zoom: key.zoom)
    }

    /// Rutan med den stilla utsnittets mitt flyttad till (`cx`, `cy`): båda nycklarna får samma mittpunkt
    /// (ingen panorering), zoomen behålls per nyckel och mittpunkten klampas inom bilden.
    static func recentered(_ panel: ReelSpec.Panel, cx: Double, cy: Double, imageSize: CGSize,
                           paneAspect: Double) -> ReelSpec.Panel {
        var p = panel
        // Mitten räknas på nyckeln med minst zoom: dess utrymme är det minsta, och en högre zoom ryms alltid inom det.
        let lowIsFrom = p.motion.from.zoom <= p.motion.to.zoom
        let low = lowIsFrom ? p.motion.from : p.motion.to
        var probe = low
        probe.cx = cx; probe.cy = cy
        let center = clamped(probe, source: p.source, imageSize: imageSize, paneAspect: paneAspect)
        for isEnd in [false, true] {
            var key = isEnd ? p.motion.to : p.motion.from
            key.cx = center.cx; key.cy = center.cy
            key = clamped(key, source: p.source, imageSize: imageSize, paneAspect: paneAspect)
            if isEnd { p.motion.to = key } else { p.motion.from = key }
        }
        // Exakt samma mittpunkt (klampningen kan ge ett flyttalsbrus): den ligger redan inom båda nycklarnas utrymme.
        let master = lowIsFrom ? p.motion.from : p.motion.to
        p.motion.from.cx = master.cx; p.motion.from.cy = master.cy
        p.motion.to.cx = master.cx; p.motion.to.cy = master.cy
        return p
    }

    /// Rutans nycklar klampade mot en ny ruta (annan layout eller format).
    static func retargeted(_ panel: ReelSpec.Panel, imageSize: CGSize, paneAspect: Double) -> ReelSpec.Panel {
        var p = panel
        p.motion.from = clamped(p.motion.from, source: p.source, imageSize: imageSize, paneAspect: paneAspect)
        p.motion.to = clamped(p.motion.to, source: p.source, imageSize: imageSize, paneAspect: paneAspect)
        return p
    }

    // MARK: - Bygga om klipp

    /// Klippet som ett låst rutklipp (`custom`): `panels[0].asset` blir klippets bild. Längd- och
    /// övergångslås behålls; ingången gäller bara `stack`/`side`.
    static func lockedClip(_ base: ReelSpec.Clip, layout: ReelSpec.PanelLayout, panels: [ReelSpec.Panel],
                           entrance: ReelSpec.Entrance?) -> ReelSpec.Clip {
        var c = base
        c.fit = .panels
        c.layout = layout
        c.panels = panels
        c.asset = panels[0].asset
        c.motion = panels[0].motion
        c.motionPreset = ReelMotionPlanner.Preset.custom.rawValue
        c.customMotion = nil
        c.entrance = layout == .sequence ? nil : (entrance ?? ReelMotionPlanner.collageEntrance)
        if layout == .sequence { c.gutter = nil }
        return c
    }

    /// Klippet som ett vanligt automatiskt klipp av `asset` (rutorna borta, planeraren väljer rörelse).
    /// Längdlåset släpps (kollagets längd gäller inte ett vanligt klipp), övergångslåset behålls.
    static func plainClip(_ base: ReelSpec.Clip, asset: String) -> ReelSpec.Clip {
        var c = base
        c.asset = asset
        c.fit = .cover
        c.layout = nil
        c.panels = nil
        c.gutter = nil
        c.entrance = nil
        c.motionPreset = nil
        c.customMotion = nil
        c.durationLocked = nil
        return c
    }

    /// Klippet som ett vanligt klipp med hela montagebilden (contain-blur, svag zoom): fotografens val
    /// "Som montage (hela bilden)". Låst som `custom`, så att planeraren inte delar det i halvor.
    static func wholeMontageClip(_ base: ReelSpec.Clip) -> ReelSpec.Clip {
        var c = plainClip(base, asset: base.asset)
        c.fit = .containBlur
        c.motion = .init(from: .init(cx: 0.5, cy: 0.5, zoom: 1),
                         to: .init(cx: 0.5, cy: 0.5, zoom: ReelMotionPlanner.containZoomAmount))
        c.motionPreset = ReelMotionPlanner.Preset.custom.rawValue
        return c
    }

    /// Ett låst rutklipps layout och nycklar anpassade till ett nytt format (se `ReelComposer.rebuild`):
    /// en layout som inte passar (9:16 sida vid sida) byts mot formatets, och nycklarna klampas mot de
    /// nya rutorna. Montage (`sequence` med `source`) behåller layouten.
    static func adapted(_ lock: ReelMotionPlanner.PanelsLock, images: [String: ReelMotionPlanner.Image],
                        frameAspect: Double) -> ReelMotionPlanner.PanelsLock {
        var out = lock
        if lock.layout != .sequence, !collageLayouts(frameAspect: frameAspect).contains(lock.layout) {
            out.layout = collageLayouts(frameAspect: frameAspect).first ?? .sequence
            if out.layout == .sequence { out.entrance = nil }
        }
        let pane = paneAspect(layout: out.layout, frameAspect: frameAspect, gutter: out.gutter)
        out.panels = lock.panels.map { panel in
            guard let image = images[panel.asset] else { return panel }
            return retargeted(panel, imageSize: image.size, paneAspect: pane)
        }
        return out
    }
}
