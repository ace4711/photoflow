import Foundation
import Testing
@testable import PhotoFlow

struct VerticalCorrectionTests {

    /// Syntetisk bild: lodräta ränder i den "rätade" världen, avbildade som en kamera med
    /// lutningen `pitch`/rotationen `roll` ser dem (inversa homografin).
    private func syntheticLuma(pitch: Double, roll: Double, width w: Int = 600, height h: Int = 400, focal: Double = 0.6) -> [Float] {
        let p = PerspectiveCorrection(pitchDegrees: pitch, rollDegrees: roll, focal: focal, segments: 0)
        let H = VerticalCorrection.homography(p, width: w, height: h)
        var luma = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (xc, yc) = VerticalCorrection.apply(H, Double(x) + 0.5, Double(y) + 0.5)
                let stripe = Int(floor(xc / 37)) & 1
                let band = yc > 30 && yc < Double(h) - 30
                luma[y * w + x] = band ? (stripe == 0 ? 0.2 : 0.8) : 0.5
            }
        }
        return luma
    }

    @Test("Segment: lodräta ränder ger långa segment med rätt vinkel")
    func detectsVerticalSegments() {
        let w = 400, h = 300
        var luma = [Float](repeating: 0.2, count: w * h)
        for y in 0..<h { for x in 200..<w { luma[y * w + x] = 0.8 } }
        let segs = VerticalCorrection.detectSegments(luma: luma, width: w, height: h)
        #expect(!segs.isEmpty)
        #expect(segs.allSatisfy { abs($0.angleFromVertical) < 0.5 })
        #expect(segs.map(\.length).max()! > Double(h) * 0.9)
    }

    @Test("Skattning: syntetisk lutning och rotation återfinns", arguments: [(3.0, 0.0), (-2.5, 0.0), (2.0, 1.0), (0.0, -1.5)])
    func recoversPitchAndRoll(_ c: (Double, Double)) {
        let (w, h) = (600, 400)
        let luma = syntheticLuma(pitch: c.0, roll: c.1, width: w, height: h)
        let segs = VerticalCorrection.detectSegments(luma: luma, width: w, height: h)
        let est = VerticalCorrection.estimate(segments: segs, width: w, height: h, focal: 0.6)
        #expect(est != nil)
        if let est {
            #expect(abs(est.pitchDegrees - c.0) < 0.35, "lutning \(est.pitchDegrees) väntat \(c.0)")
            #expect(abs(est.rollDegrees - c.1) < 0.25, "rotation \(est.rollDegrees) väntat \(c.1)")
            // Efter korrigeringen är segmenten lodräta.
            let H = VerticalCorrection.homography(est, width: w, height: h)
            for s in segs {
                let a = VerticalCorrection.apply(H, s.x0, s.y0), b = VerticalCorrection.apply(H, s.x1, s.y1)
                let corrected = VerticalCorrection.Segment(x0: a.0, y0: a.1, x1: b.0, y1: b.1)
                #expect(abs(corrected.angleFromVertical) < 0.6)
            }
        }
    }

    @Test("Redan lodrätt eller för stor lutning: ingen korrigering")
    func skipsWhenStraightOrExtreme() {
        let (w, h) = (600, 400)
        let straight = syntheticLuma(pitch: 0, roll: 0, width: w, height: h)
        #expect(VerticalCorrection.estimate(segments: VerticalCorrection.detectSegments(luma: straight, width: w, height: h),
                                            width: w, height: h, focal: 0.6) == nil)
        let steep = syntheticLuma(pitch: 12, roll: 0, width: w, height: h)
        #expect(VerticalCorrection.estimate(segments: VerticalCorrection.detectSegments(luma: steep, width: w, height: h),
                                            width: w, height: h, focal: 0.6) == nil)
        // För få segment
        #expect(VerticalCorrection.estimate(segments: [], width: w, height: h, focal: 0.6) == nil)
    }

    @Test("Beskärning utan tomma hörn och med bildens proportioner")
    func cropHasNoEmptyCorners() {
        let (w, h) = (6000, 4000)
        for (pitch, roll) in [(4.0, 0.0), (-6.0, 1.5), (1.0, -3.0)] {
            let p = PerspectiveCorrection(pitchDegrees: pitch, rollDegrees: roll, focal: 0.5, segments: 10)
            let (H, rect) = VerticalCorrection.cropRect(p, width: w, height: h)
            let inv = invert(H)
            for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY)] {
                let (sx, sy) = VerticalCorrection.apply(inv, Double(x), Double(y))
                #expect(sx >= -0.5 && sx <= Double(w) + 0.5 && sy >= -0.5 && sy <= Double(h) + 0.5)
            }
            #expect(abs(Double(rect.width / rect.height) - 1.5) < 0.01)
            #expect(rect.width > Double(w) * 0.75)
        }
    }

    @Test("Största inskrivna rektangel i en axelparallell fyrhörning är hela")
    func inscribedRectIdentity() {
        let r = VerticalCorrection.largestInscribedRect(quad: [(0, 0), (300, 0), (300, 200), (0, 200)], aspect: 1.5)
        #expect(abs(r.width - 300) < 0.5 && abs(r.height - 200) < 0.5)
    }

    private func invert(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d].map { $0 / det }
    }
}
