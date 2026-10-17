import Foundation
import Testing
import CoreGraphics
@testable import PhotoFlow

/// Tester för `ReelMotionGeometry` (Regi R3): ram ↔ nyckel mot `ReelTimeline.cropRect`/`containCrop`,
/// flytt, hörnskalning, klampning och tempomått.
struct ReelMotionGeometryTests {

    private let aspects: [(String, Double)] = [("9:16", 9.0 / 16), ("1:1", 1), ("16:9", 16.0 / 9)]
    private let images: [CGSize] = [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000)]

    @Test("Ramen är exakt ReelTimeline.cropRect / containCrop")
    func frameMatchesTimeline() {
        for (_, fa) in aspects { for size in images {
            let key = ReelSpec.MotionKey(cx: 0.3, cy: 0.62, zoom: 1.7)
            let cover = ReelMotionGeometry.frame(for: key, fit: .cover, imageSize: size, frameAspect: fa)
            #expect(cover == ReelTimeline.cropRect(imageSize: size, frameAspect: fa, center: CGPoint(x: 0.3, y: 0.62), zoom: 1.7))
            let contain = ReelMotionGeometry.frame(for: key, fit: .containBlur, imageSize: size, frameAspect: fa)
            #expect(contain == ReelTimeline.containCrop(center: CGPoint(x: 0.3, y: 0.62), zoom: 1.7))
        } }
    }

    @Test("Rundtur nyckel -> ram -> nyckel för klampade nycklar, alla format och båda bildriktningarna")
    func roundTrip() {
        let raw: [ReelSpec.MotionKey] = [
            .init(cx: 0.5, cy: 0.5, zoom: 1), .init(cx: 0.2, cy: 0.8, zoom: 1.4), .init(cx: 0.95, cy: 0.05, zoom: 2.5),
            .init(cx: 0.5, cy: 0.5, zoom: 3), .init(cx: -0.3, cy: 1.4, zoom: 0.5), .init(cx: 0.7, cy: 0.33, zoom: 1.12)]
        for (_, fa) in aspects { for size in images { for fit in [ReelSpec.Fit.cover, .containBlur] { for k in raw {
            let key = ReelMotionGeometry.clamped(k, fit: fit, imageSize: size, frameAspect: fa)
            let rect = ReelMotionGeometry.frame(for: key, fit: fit, imageSize: size, frameAspect: fa)
            let back = ReelMotionGeometry.key(for: rect, fit: fit, imageSize: size, frameAspect: fa)
            #expect(abs(back.cx - key.cx) < 1e-9 && abs(back.cy - key.cy) < 1e-9 && abs(back.zoom - key.zoom) < 1e-9)
            #expect(rect.minX >= -1e-12 && rect.minY >= -1e-12 && rect.maxX <= 1 + 1e-12 && rect.maxY <= 1 + 1e-12)
        } } } }
    }

    @Test("Zoom klampas till 1...3 och ramen kan inte lämna bilden")
    func clampsZoomAndPosition() {
        let size = images[0]
        let tiny = CGRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01)
        #expect(ReelMotionGeometry.key(for: tiny, fit: .containBlur, imageSize: size, frameAspect: 9.0 / 16).zoom == ReelMotionGeometry.maxZoom)
        let huge = CGRect(x: -1, y: -1, width: 5, height: 5)
        let k = ReelMotionGeometry.key(for: huge, fit: .cover, imageSize: size, frameAspect: 16.0 / 9)
        #expect(k.zoom == 1)
        let base = ReelMotionGeometry.baseSize(fit: .cover, imageSize: size, frameAspect: 9.0 / 16)
        #expect(abs(base.width - (9.0 / 16) / 1.5) < 1e-12 && base.height == 1)
    }

    @Test("Flytt behåller storleken och stannar i bilden")
    func move() {
        let r = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5)
        let m = ReelMotionGeometry.moved(r, by: CGSize(width: 0.1, height: -0.1))
        #expect(abs(m.minX - 0.3) < 1e-12 && abs(m.minY - 0.1) < 1e-12 && m.size == r.size)
        let far = ReelMotionGeometry.moved(r, by: CGSize(width: 5, height: -5))
        #expect(far == CGRect(x: 0.7, y: 0, width: 0.3, height: 0.5))
    }

    @Test("Hörnskalning: motsatt hörn står still, bildförhållandet bibehålls, klampas")
    func resize() {
        let size = images[0], fa = 9.0 / 16
        let base = ReelMotionGeometry.baseSize(fit: .cover, imageSize: size, frameAspect: fa)
        let ratio = base.width / base.height
        let rect = CGRect(x: 0.3, y: 0.1, width: base.width / 2, height: base.height / 2)
        // Dra nedre högra hörnet utåt längs diagonalen.
        let grown = ReelMotionGeometry.resized(rect, corner: .bottomRight,
                                               to: CGPoint(x: rect.minX + base.width * 0.75, y: rect.minY + base.height * 0.75),
                                               fit: .cover, imageSize: size, frameAspect: fa)
        #expect(abs(grown.minX - rect.minX) < 1e-12 && abs(grown.minY - rect.minY) < 1e-12)
        #expect(abs(grown.width / grown.height - ratio) < 1e-9)
        #expect(abs(grown.width - base.width * 0.75) < 1e-9)
        // Dra övre vänstra hörnet: nedre högra står still.
        let tl = ReelMotionGeometry.resized(rect, corner: .topLeft, to: CGPoint(x: rect.minX + 0.01, y: rect.minY + 0.1),
                                            fit: .cover, imageSize: size, frameAspect: fa)
        #expect(abs(tl.maxX - rect.maxX) < 1e-12 && abs(tl.maxY - rect.maxY) < 1e-12)
        #expect(tl.width < rect.width)
        // Långt utanför: aldrig större än basramen och aldrig utanför bilden.
        let wild = ReelMotionGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 9, y: 9),
                                              fit: .cover, imageSize: size, frameAspect: fa)
        #expect(wild.width <= base.width + 1e-12 && wild.maxX <= 1 + 1e-12 && wild.maxY <= 1 + 1e-12)
        // Hopklämd: aldrig mindre än zoom 3.
        let squeezed = ReelMotionGeometry.resized(rect, corner: .bottomRight, to: CGPoint(x: 0, y: 0),
                                                  fit: .cover, imageSize: size, frameAspect: fa)
        #expect(abs(squeezed.width - base.width / ReelMotionGeometry.maxZoom) < 1e-12)
        // Contain-blur: kvadratisk i normaliserade koordinater.
        let c = ReelMotionGeometry.resized(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), corner: .bottomLeft,
                                           to: CGPoint(x: 0.1, y: 0.9), fit: .containBlur, imageSize: size, frameAspect: fa)
        #expect(abs(c.width - c.height) < 1e-12 && abs(c.maxX - 0.7) < 1e-12 && abs(c.minY - 0.2) < 1e-12)
    }

    @Test("Tempomått jämförs med planerarens tak")
    func pace() {
        let size = images[0]
        let calm = ReelSpec.Motion(from: .init(cx: 0.4, cy: 0.5, zoom: 1), to: .init(cx: 0.6, cy: 0.5, zoom: 1))
        let p1 = ReelMotionGeometry.pace(calm, duration: 3, imageSize: size)
        #expect(abs(p1.panPerSecond - 0.2 / 3) < 1e-12 && !p1.tooFastPan && !p1.tooFastZoom)
        #expect(ReelMotionGeometry.pace(calm, duration: 1.5, imageSize: size).tooFastPan)
        // Exakt vid taket varnar inte (planeraren producerar sådana rörelser).
        let atCap = ReelSpec.Motion(from: .init(cx: 0.3, cy: 0.5, zoom: 1), to: .init(cx: 0.3 + 0.1 * 2.8, cy: 0.5, zoom: 1))
        #expect(!ReelMotionGeometry.pace(atCap, duration: 2.8, imageSize: size).isTooFast)
        let zoom = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.5))
        #expect(ReelMotionGeometry.pace(zoom, duration: 3, imageSize: size).tooFastZoom)
        let out = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1.5), to: .init(cx: 0.5, cy: 0.5, zoom: 1))
        #expect(ReelMotionGeometry.pace(out, duration: 3, imageSize: size).zoomPerSecond == ReelMotionGeometry.pace(zoom, duration: 3, imageSize: size).zoomPerSecond)
        let slow = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.12))
        #expect(!ReelMotionGeometry.pace(slow, duration: 3, imageSize: size).isTooFast)
    }
}
