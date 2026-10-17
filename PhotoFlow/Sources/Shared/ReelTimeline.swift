import Foundation
import CoreGraphics

/// Ren tidslinjematematik för ReelSpec v1: klippstarter, easing, utsnitt och
/// lagerstatus vid en given tid. Ingen grafik, så samma formler kan skrivas en
/// gång till i TypeScript och testas mot samma vektorfil
/// (`Tests/Fixtures/Reel/timeline-vectors.json`). Den normativa beskrivningen
/// finns i `docs/reel-spec-v1.md`; ändra aldrig en formel här utan att ändra den.
///
/// Alla utsnitt anges i normaliserade bildkoordinater [0,1]² (origo uppe till
/// vänster, y neråt) och alla förskjutningar i normaliserade ramkoordinater, så
/// att resultatet inte beror på någon upplösning.
nonisolated enum ReelTimeline {

    // MARK: - Lagerstatus

    /// Ett synligt lager vid en viss tid. Renderaren ritar lagren i stigande
    /// `z`, med `opacity` som vanlig "over"-blandning i sRGB.
    nonisolated struct LayerState: Equatable, Sendable {
        /// Bakgrund för `contain-blur`: bildens cover-utsnitt, ritat över hela
        /// ramen och suddat med `sigma` (i utpixlar).
        nonisolated struct Backdrop: Equatable, Sendable {
            var crop: CGRect
            var sigma: Double
        }

        var asset: String
        var fit: ReelSpec.Fit
        /// Den del av bilden som visas, i normaliserade bildkoordinater.
        var crop: CGRect
        /// Var utsnittet ritas, i normaliserade ramkoordinater (före `offset`).
        /// `cover`: hela ramen. `contain-blur`: den centrerade "contain"-rutan.
        var dest: CGRect
        /// 0...1. Lager med opacitet 0 returneras aldrig.
        var opacity: Double
        /// Förskjutning av hela lagret (inkl. bakgrund), i andelar av ramens
        /// bredd (x) och höjd (y). Positivt x = åt höger, positivt y = nedåt.
        var offset: CGPoint
        /// Ritordning, lägst först. Utgående lager 0, inkommande 1.
        var z: Int
        /// Bara för `contain-blur` med suddig bakgrund.
        var backdrop: Backdrop?
        /// Bara för rutlager (`fit == .panels`, version 2). `opacity` och `offset` ovan gäller då hela
        /// klippets grupp (alla rutor med samma `z` ritas först på en svart ram och blandas sedan,
        /// som `contain-blur`-gruppen); rutans egen ingång ligger här.
        var panel: PanelInfo?
    }

    /// Rutans egna värden inom gruppen (spec v2, avsnitt 4–5).
    nonisolated struct PanelInfo: Equatable, Sendable {
        /// Rutans ordning i klippet (0 = första).
        var index: Int
        /// Rutans egen opacitet (ingång `fade`), 0...1. Rutor med 0 returneras aldrig.
        var opacity: Double
        /// Rutans egen förskjutning (ingång `slide`, intern skjutning i `sequence`), ramandelar.
        var offset: CGPoint
    }

    // MARK: - Tid

    /// Övergången som gäller in till klipp `index`, eller nil (första klippet,
    /// `cut` och längd 0 ger ingen övergång). Klippets egen `transitionIn` går
    /// före `style.defaultTransition`. Längden begränsas till det kortaste av
    /// de två klippens längder så att övergången alltid ryms i båda.
    static func transition(_ spec: ReelSpec, at index: Int) -> ReelSpec.Transition? {
        guard index > 0, index < spec.timeline.count else { return nil }
        var t = spec.timeline[index].transitionIn ?? spec.style.defaultTransition
        if t.type == .cut { return nil }
        let limit = min(spec.timeline[index - 1].duration, spec.timeline[index].duration)
        t.duration = min(max(t.duration, 0), limit)
        return t.duration > 0 ? t : nil
    }

    /// Starttid (sekunder) för varje klipp:
    /// start(i) = start(i−1) + duration(i−1) − övergångens längd(i).
    /// Övergången ligger alltså *inom* båda klippens längd.
    static func clipStarts(_ spec: ReelSpec) -> [Double] {
        var starts: [Double] = []
        for i in spec.timeline.indices {
            if i == 0 {
                starts.append(0)
            } else {
                let d = transition(spec, at: i)?.duration ?? 0
                starts.append(starts[i - 1] + spec.timeline[i - 1].duration - d)
            }
        }
        return starts
    }

    static func totalDuration(_ spec: ReelSpec) -> Double {
        guard let last = spec.timeline.last else { return 0 }
        return clipStarts(spec).last! + last.duration
    }

    // MARK: - Easing och interpolation

    /// `easeInOut` är smoothstep p²(3−2p); `linear` är p. Indata klampas till [0,1].
    static func easing(_ kind: ReelSpec.Easing, _ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch kind {
        case .linear: return p
        case .easeInOut: return p * p * (3 - 2 * p)
        }
    }

    /// Mittpunkt interpoleras linjärt med e, zoom geometriskt: z = z0·(z1/z0)^e
    /// (jämn upplevd zoomhastighet).
    static func interpolate(_ motion: ReelSpec.Motion, e: Double) -> ReelSpec.MotionKey {
        let a = motion.from, b = motion.to
        return ReelSpec.MotionKey(
            cx: a.cx + (b.cx - a.cx) * e,
            cy: a.cy + (b.cy - a.cy) * e,
            zoom: a.zoom * pow(b.zoom / a.zoom, e)
        )
    }

    // MARK: - Utsnitt

    /// Cover-utsnittet i normaliserade bildkoordinater. Basutsnittet är det
    /// största utsnitt med ramens bildförhållande som ryms i bilden; vid zoom z
    /// har utsnittet basstorleken / z (z < 1 behandlas som 1, så att utsnittet
    /// aldrig lämnar bilden). Mittpunkten (cx, cy) klampas så att hela utsnittet
    /// ligger inom [0,1]².
    static func cropRect(imageSize: CGSize, frameAspect: Double, center: CGPoint, zoom: Double) -> CGRect {
        let imageAspect = Double(imageSize.width / imageSize.height)
        let baseW: Double, baseH: Double
        if imageAspect >= frameAspect {
            baseW = frameAspect / imageAspect
            baseH = 1
        } else {
            baseW = 1
            baseH = imageAspect / frameAspect
        }
        let z = max(zoom, 1)
        let w = baseW / z, h = baseH / z
        let x = min(max(Double(center.x) - w / 2, 0), 1 - w)
        let y = min(max(Double(center.y) - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Den centrerade rutan (normaliserade ramkoordinater) där hela bilden ryms
    /// ("contain") i en ram med bildförhållandet `frameAspect`.
    static func containRect(imageSize: CGSize, frameAspect: Double) -> CGRect {
        let imageAspect = Double(imageSize.width / imageSize.height)
        let w: Double, h: Double
        if imageAspect >= frameAspect {
            w = 1
            h = frameAspect / imageAspect
        } else {
            h = 1
            w = imageAspect / frameAspect
        }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Utsnittet för `contain-blur`-förgrunden: hela bilden vid zoom 1, annars
    /// ett utsnitt med storleken 1/z kring (cx, cy), klampat inom [0,1]².
    /// Förgrunden ritas alltid i samma `containRect`, så zoomen sker *inuti*
    /// rutan och bildens kanter flyttar sig aldrig.
    static func containCrop(center: CGPoint, zoom: Double) -> CGRect {
        let s = 1 / max(zoom, 1)
        let x = min(max(Double(center.x) - s / 2, 0), 1 - s)
        let y = min(max(Double(center.y) - s / 2, 0), 1 - s)
        return CGRect(x: x, y: y, width: s, height: s)
    }

    // MARK: - Rutor (spec v2)

    /// Rutornas `dest` i ramkoordinater för `stack` och `side` (avsnitt 3.1 i `reel-spec-v2.md`).
    /// `gutter` är andel av ramens kortsida, klampad till [0, 0,1].
    static func panelDests(layout: ReelSpec.PanelLayout, frameAspect: Double, gutter: Double) -> [CGRect] {
        let g = min(max(gutter, 0), 0.1)
        switch layout {
        case .stack:
            let gy = g * min(frameAspect, 1)
            let h = (1 - gy) / 2
            return [CGRect(x: 0, y: 0, width: 1, height: h), CGRect(x: 0, y: (1 + gy) / 2, width: 1, height: h)]
        case .side:
            let gx = g * min(1, 1 / frameAspect)
            let w = (1 - gx) / 2
            return [CGRect(x: 0, y: 0, width: w, height: 1), CGRect(x: (1 + gx) / 2, y: 0, width: w, height: 1)]
        case .sequence:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }
    }

    /// Cover-utsnittet inom en rutas `source` mot en ruta med bildförhållandet `destAspect`, omräknat
    /// till hela bildens koordinater (avsnitt 2 i `reel-spec-v2.md`). Mittpunkten (hela bildens
    /// koordinater) klampas inom `source`.
    static func panelCrop(imageSize: CGSize, source: ReelSpec.UnitRect?, destAspect: Double,
                          center: CGPoint, zoom: Double) -> CGRect {
        guard let s = source, s.w > 0, s.h > 0 else {
            return cropRect(imageSize: imageSize, frameAspect: destAspect, center: center, zoom: zoom)
        }
        let local = CGPoint(x: (Double(center.x) - s.x) / s.w, y: (Double(center.y) - s.y) / s.h)
        let r = cropRect(imageSize: CGSize(width: s.w * Double(imageSize.width), height: s.h * Double(imageSize.height)),
                         frameAspect: destAspect, center: local, zoom: zoom)
        return CGRect(x: s.x + Double(r.minX) * s.w, y: s.y + Double(r.minY) * s.h,
                      width: Double(r.width) * s.w, height: Double(r.height) * s.h)
    }

    /// Tiden en intern skjutning mellan två rutor i `sequence` tar: min(0,4, D / (2n)).
    static func sequencePushDuration(clipDuration d: Double, panelCount n: Int) -> Double {
        min(0.4, d / Double(2 * max(n, 1)))
    }

    /// Rutlagren för klipp `index` vid tid `t`. `opacity`/`offset`/`z` är gruppens.
    private static func panelLayers(_ spec: ReelSpec, clip index: Int, start: Double, t: Double,
                                    frameAspect: Double, opacity: Double, offset: CGPoint, z: Int) -> [LayerState] {
        let clip = spec.timeline[index]
        guard clip.fit == .panels, let layout = clip.layout, let panels = clip.panels, panels.count >= 2,
              clip.duration > 0 else { return [] }
        let d = clip.duration
        let tau = min(max(t - start, 0), d)

        func make(_ k: Int, dest: CGRect, motionP: Double, panelOpacity: Double, panelOffset: CGPoint) -> LayerState? {
            guard panelOpacity > 0,
                  let asset = spec.assets.first(where: { $0.id == panels[k].asset }) else { return nil }
            let imageSize = CGSize(width: asset.width, height: asset.height)
            let key = interpolate(panels[k].motion, e: easing(spec.style.easing, motionP))
            let destAspect = Double(dest.width) * frameAspect / Double(dest.height)
            let crop = panelCrop(imageSize: imageSize, source: panels[k].source, destAspect: destAspect,
                                 center: CGPoint(x: key.cx, y: key.cy), zoom: key.zoom)
            return LayerState(asset: asset.id, fit: .panels, crop: crop, dest: dest, opacity: opacity,
                              offset: offset, z: z, backdrop: nil,
                              panel: PanelInfo(index: k, opacity: panelOpacity, offset: panelOffset))
        }

        switch layout {
        case .stack, .side:
            guard panels.count == 2 else { return [] }
            let dests = panelDests(layout: layout, frameAspect: frameAspect, gutter: clip.gutter ?? ReelSpec.Clip.defaultGutter)
            let p = min(max(tau / d, 0), 1)
            let din = min(max(clip.entrance?.duration ?? ReelSpec.Entrance.defaultDuration, 0), d / 2)
            let stagger = min(max(clip.entrance?.stagger ?? ReelSpec.Entrance.defaultStagger, 0), d / 2)
            return (0..<2).compactMap { k in
                var o = 1.0, off = CGPoint.zero
                if let type = clip.entrance?.type, type != .none {
                    let q = din > 0 ? min(max((tau - Double(k) * stagger) / din, 0), 1) : 1
                    let e = easing(spec.style.easing, q)
                    if type == .fade {
                        o = e
                    } else {
                        let sign = k == 0 ? -1.0 : 1.0
                        off = layout == .stack ? CGPoint(x: sign * (1 - e), y: 0) : CGPoint(x: 0, y: sign * (1 - e))
                    }
                }
                return make(k, dest: dests[k], motionP: p, panelOpacity: o, panelOffset: off)
            }
        case .sequence:
            let n = panels.count
            let seg = d / Double(n)
            let dp = sequencePushDuration(clipDuration: d, panelCount: n)
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            func progress(_ k: Int) -> Double { min(max((tau - Double(k) * seg) / seg, 0), 1) }
            // Pågår skjutningen k−1 → k? Den ligger i [k·seg − dp/2, k·seg + dp/2).
            for k in 1..<n {
                let from = Double(k) * seg - dp / 2
                guard tau >= from, tau < from + dp else { continue }
                let e = easing(spec.style.easing, (tau - from) / dp)
                return [make(k - 1, dest: full, motionP: progress(k - 1), panelOpacity: 1, panelOffset: CGPoint(x: -e, y: 0)),
                        make(k, dest: full, motionP: progress(k), panelOpacity: 1, panelOffset: CGPoint(x: 1 - e, y: 0))]
                    .compactMap { $0 }
            }
            // Annars: den ruta vars skjutning in är klar (största k med tau ≥ k·seg + dp/2).
            var current = 0
            for k in 1..<n where tau >= Double(k) * seg + dp / 2 { current = k }
            return [make(current, dest: full, motionP: progress(current), panelOpacity: 1, panelOffset: .zero)]
                .compactMap { $0 }
        }
    }

    // MARK: - Tillstånd vid tid t

    /// Lagren som syns vid tid `t` (klampas till [0, total]), lägst `z` först.
    /// Utanför övergångar ett lager; under en övergång två (utgående z 0,
    /// inkommande z 1), förutom `fadeThroughBlack` där bara ett lager syns åt
    /// gången. Lager med opacitet 0 utelämnas (alltså inget lager alls i exakt
    /// mitten av `fadeThroughBlack`: svart bild).
    static func state(at t: Double, spec: ReelSpec, outputSize: CGSize) -> [LayerState] {
        guard !spec.timeline.isEmpty else { return [] }
        let starts = clipStarts(spec)
        let t = min(max(t, 0), totalDuration(spec))
        // Det klipp som senast börjat (vid lika start vinner det senare).
        var i = 0
        for k in spec.timeline.indices where starts[k] <= t { i = k }

        let frameAspect = Double(outputSize.width / outputSize.height)
        func layer(_ clip: Int, opacity: Double, offset: CGPoint, z: Int) -> [LayerState] {
            guard opacity > 0 else { return [] }
            if spec.timeline[clip].fit == .panels {
                return panelLayers(spec, clip: clip, start: starts[clip], t: t, frameAspect: frameAspect,
                                   opacity: opacity, offset: offset, z: z)
            }
            return makeLayer(spec, clip: clip, start: starts[clip], t: t, frameAspect: frameAspect,
                             frameHeight: Double(outputSize.height), opacity: opacity, offset: offset, z: z)
                .map { [$0] } ?? []
        }

        if let tr = transition(spec, at: i), t < starts[i] + tr.duration {
            let e = easing(spec.style.easing, (t - starts[i]) / tr.duration)
            switch tr.type {
            case .crossfade:
                // Utgående fullt synligt under; inkommande ovanpå med alfa e.
                // Blandning (1−e)·ut + e·in direkt i sRGB-värden.
                return layer(i - 1, opacity: 1, offset: .zero, z: 0)
                    + layer(i, opacity: e, offset: .zero, z: 1)
            case .push:
                let dir = tr.direction ?? .left
                let (dx, dy): (Double, Double)
                switch dir {
                case .left: (dx, dy) = (-1, 0)
                case .right: (dx, dy) = (1, 0)
                case .up: (dx, dy) = (0, -1)
                case .down: (dx, dy) = (0, 1)
                }
                // Utgående glider e ramar i riktningen; inkommande startar en
                // ram bakom och når 0 när e = 1.
                return layer(i - 1, opacity: 1, offset: CGPoint(x: dx * e, y: dy * e), z: 0)
                    + layer(i, opacity: 1, offset: CGPoint(x: dx * (e - 1), y: dy * (e - 1)), z: 1)
            case .fadeThroughBlack:
                // Svart bakom. Första halvan (q < 0,5): utgående tonar ut,
                // opacitet 1 − easing(2q). Andra halvan: inkommande tonar in,
                // opacitet easing(2q − 1). Easingen tillämpas alltså på varje
                // halva för sig (e ovan används inte).
                let q = (t - starts[i]) / tr.duration
                if q < 0.5 {
                    let o = 1 - easing(spec.style.easing, 2 * q)
                    return layer(i - 1, opacity: o, offset: .zero, z: 0)
                } else {
                    let o = easing(spec.style.easing, 2 * q - 1)
                    return layer(i, opacity: o, offset: .zero, z: 1)
                }
            case .cut:
                break // returneras aldrig av `transition`
            }
        }
        return layer(i, opacity: 1, offset: .zero, z: 1)
    }

    private static func makeLayer(_ spec: ReelSpec, clip index: Int, start: Double, t: Double,
                                  frameAspect: Double, frameHeight: Double,
                                  opacity: Double, offset: CGPoint, z: Int) -> LayerState? {
        let clip = spec.timeline[index]
        guard let asset = spec.assets.first(where: { $0.id == clip.asset }) else { return nil }
        let imageSize = CGSize(width: asset.width, height: asset.height)
        let p = clip.duration > 0 ? min(max((t - start) / clip.duration, 0), 1) : 1
        let key = interpolate(clip.motion, e: easing(spec.style.easing, p))
        let center = CGPoint(x: key.cx, y: key.cy)

        switch clip.fit {
        case .cover:
            return LayerState(asset: asset.id, fit: .cover,
                              crop: cropRect(imageSize: imageSize, frameAspect: frameAspect, center: center, zoom: key.zoom),
                              dest: CGRect(x: 0, y: 0, width: 1, height: 1),
                              opacity: opacity, offset: offset, z: z, backdrop: nil)
        case .containBlur:
            var backdrop: LayerState.Backdrop?
            if spec.style.background.type == "blur" {
                // σ = amount · 0,05 · ramens höjd i utpixlar.
                let sigma = (spec.style.background.amount ?? 0) * 0.05 * frameHeight
                backdrop = .init(crop: cropRect(imageSize: imageSize, frameAspect: frameAspect, center: center, zoom: 1),
                                 sigma: sigma)
            }
            return LayerState(asset: asset.id, fit: .containBlur,
                              crop: containCrop(center: center, zoom: key.zoom),
                              dest: containRect(imageSize: imageSize, frameAspect: frameAspect),
                              opacity: opacity, offset: offset, z: z, backdrop: backdrop)
        case .panels:
            return nil   // ritas av `panelLayers`
        }
    }
}
