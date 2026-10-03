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
        func layer(_ clip: Int, opacity: Double, offset: CGPoint, z: Int) -> LayerState? {
            guard opacity > 0 else { return nil }
            return makeLayer(spec, clip: clip, start: starts[clip], t: t, frameAspect: frameAspect,
                             frameHeight: Double(outputSize.height), opacity: opacity, offset: offset, z: z)
        }

        if let tr = transition(spec, at: i), t < starts[i] + tr.duration {
            let e = easing(spec.style.easing, (t - starts[i]) / tr.duration)
            switch tr.type {
            case .crossfade:
                // Utgående fullt synligt under; inkommande ovanpå med alfa e.
                // Blandning (1−e)·ut + e·in direkt i sRGB-värden.
                return [layer(i - 1, opacity: 1, offset: .zero, z: 0),
                        layer(i, opacity: e, offset: .zero, z: 1)].compactMap { $0 }
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
                return [layer(i - 1, opacity: 1, offset: CGPoint(x: dx * e, y: dy * e), z: 0),
                        layer(i, opacity: 1, offset: CGPoint(x: dx * (e - 1), y: dy * (e - 1)), z: 1)]
                    .compactMap { $0 }
            case .fadeThroughBlack:
                // Svart bakom. Första halvan (q < 0,5): utgående tonar ut,
                // opacitet 1 − easing(2q). Andra halvan: inkommande tonar in,
                // opacitet easing(2q − 1). Easingen tillämpas alltså på varje
                // halva för sig (e ovan används inte).
                let q = (t - starts[i]) / tr.duration
                if q < 0.5 {
                    let o = 1 - easing(spec.style.easing, 2 * q)
                    return [layer(i - 1, opacity: o, offset: .zero, z: 0)].compactMap { $0 }
                } else {
                    let o = easing(spec.style.easing, 2 * q - 1)
                    return [layer(i, opacity: o, offset: .zero, z: 1)].compactMap { $0 }
                }
            case .cut:
                break // returneras aldrig av `transition`
            }
        }
        return [layer(i, opacity: 1, offset: .zero, z: 1)].compactMap { $0 }
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
        }
    }
}
