import Foundation
import CoreGraphics

/// Ren geometri för rörelseeditorn (Regi R3): omräkning mellan en nyckel `{cx, cy, zoom}` och
/// den ram (rektangel i normaliserade bildkoordinater, origo uppe till vänster) som renderas,
/// samt flytt och hörnskalning av en ram med klampning. Ramen räknas alltid med
/// `ReelTimeline.cropRect` (cover) respektive `containCrop` (contain-blur), så det man ser i
/// editorn är exakt det som renderas. Ingen grafik; testas i `ReelMotionGeometryTests`.
nonisolated enum ReelMotionGeometry {

    /// Högsta zoom som editorn tillåter (4x skulle ge en ram på en fjärdedel av bilden; 3 är
    /// redan mycket nära för en fastighetsbild).
    static let maxZoom = 3.0

    nonisolated enum Corner: Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Hur snabb en rörelse är jämfört med planerarens tak.
    nonisolated struct Pace: Sendable, Equatable {
        /// Panorering som andel av bildbredden per sekund (medelvärde över klippet).
        var panPerSecond: Double
        /// Zoom per sekund som andel (geometriskt medelvärde: (z1/z0)^(1/längd) − 1, alltid ≥ 0).
        var zoomPerSecond: Double
        var tooFastPan: Bool
        var tooFastZoom: Bool
        var isTooFast: Bool { tooFastPan || tooFastZoom }
    }

    // MARK: - Nyckel ↔ ram

    /// Ramens storlek vid zoom 1 i normaliserade bildkoordinater: cover-utsnittets basstorlek
    /// (spec 5.1) eller, för contain-blur, hela bilden (1×1, spec 5.2).
    static func baseSize(fit: ReelSpec.Fit, imageSize: CGSize, frameAspect: Double) -> CGSize {
        switch fit {
        case .cover, .panels:   // rutklipp redigeras inte här (R6d); geometrin är cover så att inget kraschar
            let r = ReelTimeline.cropRect(imageSize: imageSize, frameAspect: frameAspect,
                                          center: CGPoint(x: 0.5, y: 0.5), zoom: 1)
            return r.size
        case .containBlur:
            return CGSize(width: 1, height: 1)
        }
    }

    /// Ramen för en nyckel, exakt som renderaren klipper ut den.
    static func frame(for key: ReelSpec.MotionKey, fit: ReelSpec.Fit, imageSize: CGSize, frameAspect: Double) -> CGRect {
        let center = CGPoint(x: key.cx, y: key.cy)
        switch fit {
        case .cover, .panels:
            return ReelTimeline.cropRect(imageSize: imageSize, frameAspect: frameAspect, center: center, zoom: key.zoom)
        case .containBlur:
            return ReelTimeline.containCrop(center: center, zoom: key.zoom)
        }
    }

    /// Nyckeln för en ram: `cx, cy` är mittpunkten och zoom baseW / w (cover) eller 1/s
    /// (contain-blur). Klampad så att zoom ∈ [1, `maxZoom`] och ramen ligger inom bilden.
    static func key(for rect: CGRect, fit: ReelSpec.Fit, imageSize: CGSize, frameAspect: Double) -> ReelSpec.MotionKey {
        let base = baseSize(fit: fit, imageSize: imageSize, frameAspect: frameAspect)
        let zoom = min(max(base.width / max(rect.width, 1e-9), 1), maxZoom)
        return clamped(ReelSpec.MotionKey(cx: Double(rect.midX), cy: Double(rect.midY), zoom: zoom),
                       fit: fit, imageSize: imageSize, frameAspect: frameAspect)
    }

    /// Nyckeln klampad: zoom ∈ [1, `maxZoom`] och mittpunkten så att ramen ligger inom bilden.
    static func clamped(_ key: ReelSpec.MotionKey, fit: ReelSpec.Fit, imageSize: CGSize, frameAspect: Double) -> ReelSpec.MotionKey {
        var k = key
        k.zoom = min(max(key.zoom, 1), maxZoom)
        let r = frame(for: k, fit: fit, imageSize: imageSize, frameAspect: frameAspect)
        k.cx = Double(r.midX)
        k.cy = Double(r.midY)
        return k
    }

    // MARK: - Flytt och skalning

    /// Ramen flyttad med `delta` (normaliserade bildkoordinater), storleken oförändrad och kvar i bilden.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let x = min(max(rect.minX + delta.width, 0), 1 - rect.width)
        let y = min(max(rect.minY + delta.height, 0), 1 - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Ramen skalad genom att dra `corner` till `point` (normaliserade bildkoordinater). Motsatt
    /// hörn står still, bildförhållandet bibehålls (projektion på diagonalen) och storleken
    /// klampas till zoom ∈ [1, `maxZoom`] och till bildens kant.
    static func resized(_ rect: CGRect, corner: Corner, to point: CGPoint,
                        fit: ReelSpec.Fit, imageSize: CGSize, frameAspect: Double) -> CGRect {
        let base = baseSize(fit: fit, imageSize: imageSize, frameAspect: frameAspect)
        let ratio = Double(base.width / base.height)   // bredd / höjd
        let anchorX = (corner == .topLeft || corner == .bottomLeft) ? Double(rect.maxX) : Double(rect.minX)
        let anchorY = (corner == .topLeft || corner == .topRight) ? Double(rect.maxY) : Double(rect.minY)
        let growsRight = (corner == .topRight || corner == .bottomRight)
        let growsDown = (corner == .bottomLeft || corner == .bottomRight)
        // Avstånd från ankaret till pekaren i hörnets riktning (negativt = pekaren på fel sida).
        let dx = growsRight ? Double(point.x) - anchorX : anchorX - Double(point.x)
        let dy = growsDown ? Double(point.y) - anchorY : anchorY - Double(point.y)
        var h = (dx * ratio + dy) / (ratio * ratio + 1)
        // Tak: bildens kant åt hörnets håll, och zoom 1.
        let roomW = growsRight ? 1 - anchorX : anchorX
        let roomH = growsDown ? 1 - anchorY : anchorY
        let maxH = min(roomH, roomW / ratio, Double(base.height))
        let minH = Double(base.height) / maxZoom
        h = min(max(h, minH), max(maxH, minH))
        let w = h * ratio
        let x = growsRight ? anchorX : anchorX - w
        let y = growsDown ? anchorY : anchorY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Hörnets position i ramen.
    static func point(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: - Tempo

    /// Rörelsens fart jämfört med planerarens tak (`maxPanPerSecond`, `maxZoomPerSecond`).
    /// Panoreringen är mittpunktens förflyttning som andel av bildbredden (lodrät förflyttning
    /// räknas om till bildbredder). Bara en varning i editorn, ingen spärr.
    static func pace(_ motion: ReelSpec.Motion, duration: Double, imageSize: CGSize) -> Pace {
        let d = max(duration, 0.1)
        let imageAspect = Double(imageSize.width / max(imageSize.height, 1))
        let dx = motion.to.cx - motion.from.cx
        let dy = (motion.to.cy - motion.from.cy) / max(imageAspect, 1e-9)
        let pan = (dx * dx + dy * dy).squareRoot() / d
        let z0 = max(motion.from.zoom, 1e-9), z1 = max(motion.to.zoom, 1e-9)
        let zoom = exp(abs(log(z1 / z0)) / d) - 1
        let tolerance = 1e-6
        return Pace(panPerSecond: pan, zoomPerSecond: zoom,
                    tooFastPan: pan > ReelMotionPlanner.maxPanPerSecond + tolerance,
                    tooFastZoom: zoom > ReelMotionPlanner.maxZoomPerSecond + tolerance)
    }
}
