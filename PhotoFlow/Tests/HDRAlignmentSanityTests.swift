import Foundation
import CoreGraphics
import Testing
@testable import PhotoFlow

/// `HDRAlignment.sanitizedShift`: avvisar felregistreringar, avrundar små rörelser.
struct HDRAlignmentSanityTests {
    @Test("Orimlig förskjutning (tusentals px) avvisas — så såg felet i köksgruppen ut")
    func wildShiftRejected() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: -2, y: -3000), width: 6000, height: 4000) == nil)
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: 200, y: 0), width: 6000, height: 4000) == nil)
    }

    @Test("Liten verklig rörelse rundas till hela pixlar")
    func smallShiftRounded() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: -2.75, y: 2.4), width: 8256, height: 5504) == CGPoint(x: -3, y: 2))
    }

    @Test("Brus under 1,5 px blir ingen förskjutning")
    func noiseIgnored() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: 0.8, y: -1.2), width: 6000, height: 4000) == .zero)
    }

    @Test("NaN/oändligt avvisas")
    func nonFiniteRejected() {
        #expect(HDRAlignment.sanitizedShift(CGPoint(x: Double.nan, y: 0), width: 6000, height: 4000) == nil)
    }

    /// Strukturerad syntetisk bild (summa av sinusar och några skarpa rutor), förskjuten
    /// (dx, dy) px i buffertens koordinater, och med exponeringen skalad med `gain`.
    private func texturedImage(width: Int, height: Int, dx: Int = 0, dy: Int = 0, gain: Float = 1) -> RAWRenderer.RenderedImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sx = Float(x - dx), sy = Float(y - dy)
                var v: Float = 0.45 + 0.15 * sinf(sx * 0.07) * cosf(sy * 0.05) + 0.1 * sinf((sx + 2 * sy) * 0.023)
                if (Int(sx) / 37 + Int(sy) / 29) % 5 == 0 { v += 0.2 }
                v = min(max(v * gain, 0), 1)
                let p = (y * width + x) * 4
                pixels[p] = v; pixels[p + 1] = v; pixels[p + 2] = v
            }
        }
        return RAWRenderer.RenderedImage(width: width, height: height, pixels: pixels)
    }

    @Test("Registreringen rättar åt rätt håll i båda led, även mot en mycket mörkare ram")
    func computeShift_directionIsCorrect() throws {
        let w = 480, h = 360
        let reference = texturedImage(width: w, height: h)
        // Innehållet 6 px åt höger och 4 px nedåt, och 3 EV mörkare.
        let floating = texturedImage(width: w, height: h, dx: 6, dy: 4, gain: 0.125)
        let shift = try HDRAlignment.computeShift(floating: floating, reference: reference, maxAlignDimension: 480)
        #expect(abs(shift.x + 6) <= 1, "x: \(shift.x)")
        #expect(abs(shift.y + 4) <= 1, "y: \(shift.y)")
        // Tillämpad förskjutning lägger bilden på referensen (jämför den oskalade varianten).
        let unscaled = texturedImage(width: w, height: h, dx: 6, dy: 4)
        let aligned = RAWRenderer.shiftRGBA(unscaled.pixels, width: w, height: h, dx: Float(shift.x.rounded()), dy: Float(shift.y.rounded()))
        var diff: Float = 0, count = 0
        for y in 20..<(h - 20) { for x in 20..<(w - 20) { diff += abs(aligned[(y * w + x) * 4] - reference.pixels[(y * w + x) * 4]); count += 1 } }
        #expect(diff / Float(count) < 0.01)
    }
}
