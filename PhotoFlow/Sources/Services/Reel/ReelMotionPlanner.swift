import Foundation
import CoreGraphics

/// Väljer fit, rörelse, längd och övergång för varje klipp (plan 4.2–4.4).
/// Ren logik: bara geometri, inga bilder. All klampning görs med
/// `ReelTimeline.cropRect`/`containCrop`, så att nyckelbildernas mittpunkter
/// aldrig behöver korrigeras av renderaren.
nonisolated enum ReelMotionPlanner {

    // MARK: - Konstanter (startvärden ur planen, kalibreras med fotografen)

    static let firstDuration = 3.0
    static let lastDuration = 3.4
    static let panDuration = 2.8
    static let zoomDuration = 2.5
    static let containDuration = 2.6
    static let transitionDuration = 0.5
    static let lastTransitionDuration = 0.6

    /// Zoom in/ut för vanliga klipp och för contain-blur.
    static let zoomAmount = 1.12
    static let containZoomAmount = 1.06
    /// Tempotak: andel av bildens bredd per sekund vid panorering, och andel zoom per sekund
    /// (medelvärde över klippet; easeInOut har som mest 1,5 gånger högre toppfart).
    static let maxPanPerSecond = 0.06
    static let maxZoomPerSecond = 0.04
    /// Över den här motivbredden (och exteriör) används contain-blur.
    static let wideSubject = 0.85
    /// Sista klippet rör sig lugnare: så stor andel av vanlig amplitud.
    static let closingMotionScale = 0.6

    // MARK: - Indata

    nonisolated struct Image: Sendable, Equatable {
        var assetID: String
        var width: Int
        var height: Int
        var focus: ReelSpec.Point?
        /// Motivets sammanlagda bredd, andel av bildbredden.
        var salientWidth: Double?
        var isExterior: Bool

        var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    nonisolated enum Kind: String, Sendable, Equatable {
        case zoom, pan, containBlur
    }

    /// Ramens bildförhållande för en output.
    static func frameAspect(_ output: ReelSpec.Output) -> Double {
        output.height > 0 ? Double(output.width) / Double(output.height) : 9.0 / 16.0
    }

    /// Synlig bredd (andel av bildbredden) i ett cover-utsnitt vid zoom 1.
    static func visibleWidth(imageAspect: Double, frameAspect: Double) -> Double {
        min(1, frameAspect / imageAspect)
    }

    // MARK: - Val av rörelsetyp

    static func kind(of image: Image, frameAspect: Double) -> Kind {
        let w = visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
        let s = image.salientWidth ?? 0.5
        // Ryms motivet, eller är bilden nästan lika bred som ramen (ingenting att panorera): zooma.
        if s <= w || w >= wideSubject { return .zoom }
        if s <= wideSubject { return .pan }
        return image.isExterior ? .containBlur : .pan
    }

    // MARK: - Planering

    static func plan(_ images: [Image], frameAspect: Double) -> [ReelSpec.Clip] {
        var clips: [ReelSpec.Clip] = []
        var zoomIn = true            // alterneras mellan zoom-/contain-klipp
        var panRight = true          // alterneras mellan panoreringar
        var previousPanSign = 0.0    // riktningen (+1 höger) som föregående klipp panorerade, 0 = ingen

        for (i, image) in images.enumerated() {
            let isFirst = i == 0, isLast = i == images.count - 1 && images.count > 1
            let kind = kind(of: image, frameAspect: frameAspect)
            let duration = isFirst ? firstDuration : (isLast ? lastDuration : baseDuration(kind))
            let scale = isLast ? closingMotionScale : 1.0
            let focus = image.focus ?? .init(x: 0.5, y: 0.5)

            var fit = ReelSpec.Fit.cover
            var motion: ReelSpec.Motion
            var panSign = 0.0

            switch kind {
            case .zoom, .containBlur:
                fit = kind == .zoom ? .cover : .containBlur
                let amount = kind == .zoom ? zoomAmount : containZoomAmount
                let end = endZoom(amount: amount, scale: scale, duration: duration)
                let (z0, z1) = zoomIn ? (1.0, end) : (end, 1.0)
                zoomIn.toggle()
                // Litet drift i sidled under zoomen (bara för cover; contain-blur står still).
                let drift = kind == .zoom ? 0.01 * (panRight ? 1 : -1) : 0
                let from = key(image, frameAspect, fit, cx: focus.x - drift, cy: focus.y, zoom: z0)
                let to = key(image, frameAspect, fit, cx: focus.x + drift, cy: focus.y, zoom: z1)
                motion = .init(from: from, to: to)
            case .pan:
                let w = visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
                let s = image.salientWidth ?? 1
                let cap = maxPanPerSecond * duration * scale
                let travel = min(cap, max(s - w, 0.08 * scale))
                let sign = panRight ? 1.0 : -1.0
                panRight.toggle()
                let (a, b) = panRange(image, frameAspect, centerX: focus.x, travel: travel, sign: sign)
                let y = clampedCenter(image, frameAspect, fit, cx: focus.x, cy: focus.y, zoom: 1).y
                motion = .init(from: .init(cx: a, cy: y, zoom: 1), to: .init(cx: b, cy: y, zoom: 1))
                panSign = b == a ? 0 : (b > a ? 1 : -1)
            }

            var transition: ReelSpec.Transition?
            if i > 0 {
                if isLast {
                    transition = .init(type: .crossfade, direction: nil, duration: lastTransitionDuration)
                } else if previousPanSign != 0 {
                    // Föregående klipp panorerade åt höger → innehållet rör sig åt vänster → push åt vänster.
                    transition = .init(type: .push, direction: previousPanSign > 0 ? .left : .right,
                                       duration: transitionDuration)
                } else {
                    transition = .init(type: .crossfade, direction: nil, duration: transitionDuration)
                }
            }
            previousPanSign = panSign
            clips.append(.init(asset: image.assetID, duration: duration, fit: fit, motion: motion, transitionIn: transition))
        }
        return clips
    }

    // MARK: - Hjälpfunktioner

    static func baseDuration(_ kind: Kind) -> Double {
        switch kind {
        case .pan: return panDuration
        case .zoom: return zoomDuration
        case .containBlur: return containDuration
        }
    }

    /// Slutzoom efter tempotaket: z ≤ (1 + maxZoomPerSecond)^längd (geometrisk zoom, som i `ReelTimeline`).
    static func endZoom(amount: Double, scale: Double, duration: Double) -> Double {
        let wanted = 1 + (amount - 1) * scale
        return min(wanted, pow(1 + maxZoomPerSecond, duration))
    }

    private static func clampedCenter(_ image: Image, _ frameAspect: Double, _ fit: ReelSpec.Fit,
                                      cx: Double, cy: Double, zoom: Double) -> CGPoint {
        let c = CGPoint(x: cx, y: cy)
        switch fit {
        case .cover:
            let r = ReelTimeline.cropRect(imageSize: image.size, frameAspect: frameAspect, center: c, zoom: zoom)
            return CGPoint(x: r.midX, y: r.midY)
        case .containBlur:
            let r = ReelTimeline.containCrop(center: c, zoom: zoom)
            return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private static func key(_ image: Image, _ frameAspect: Double, _ fit: ReelSpec.Fit,
                            cx: Double, cy: Double, zoom: Double) -> ReelSpec.MotionKey {
        let p = clampedCenter(image, frameAspect, fit, cx: cx, cy: cy, zoom: zoom)
        return .init(cx: Double(p.x), cy: Double(p.y), zoom: zoom)
    }

    /// Start- och slutmittpunkt (x) för en panorering åt `sign`, kring `centerX`, högst `travel` lång,
    /// och helt inom det tillåtna intervallet för cover-utsnittet vid zoom 1.
    private static func panRange(_ image: Image, _ frameAspect: Double, centerX: Double,
                                 travel: Double, sign: Double) -> (Double, Double) {
        let r = ReelTimeline.cropRect(imageSize: image.size, frameAspect: frameAspect,
                                      center: CGPoint(x: 0.5, y: 0.5), zoom: 1)
        let lo = Double(r.width) / 2, hi = 1 - Double(r.width) / 2
        guard hi > lo else { return (0.5, 0.5) }
        let t = min(travel, hi - lo)
        // Mittpunktens läge så att hela sträckan ryms, så nära motivets mitt som möjligt.
        let startMin = lo, startMax = hi - t
        let start = min(max(centerX - t / 2, startMin), startMax)
        let end = start + t
        return sign > 0 ? (start, end) : (end, start)
    }
}
