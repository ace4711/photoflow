import Foundation
import Testing
@testable import PhotoFlow

/// `RadianceMerge` (HDREngine v7) med syntetiska linjära exponeringar av en känd scen.
struct RadianceMergeTests {
    let width = 120, height = 80

    /// Scenens radians: interiör 0,05–0,15, ett ljust fönster (x 80–110, y 10–50) med struktur runt 2,0.
    func scene(_ x: Int, _ y: Int) -> Float {
        if x >= 80 && x < 110 && y >= 10 && y < 50 { return (x / 2) % 2 == 0 ? 1.5 : 2.5 }
        return 0.05 + 0.1 * Float(x) / Float(width)
    }

    /// En linjär exponering (RGBA, sensorn klipper vid 1) med faktorn `exposure`; `override` ger
    /// en annan radians för vissa pixlar (rörelse).
    func frame(_ exposure: Float, override: ((Int, Int) -> Float?)? = nil) -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = min((override?(x, y) ?? scene(x, y)) * exposure, 1)
                let p = (y * width + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v
            }
        }
        return out
    }

    @Test("Hattvikten: 0 i klippta och svarta värden, 1 i mitten")
    func hatShape() {
        let o = RadianceMerge.Options()
        #expect(RadianceMerge.hat(0.5, options: o) == 1)
        #expect(RadianceMerge.hat(0.96, options: o) == 0)
        #expect(RadianceMerge.hat(0.0001, options: o) == 0)
        #expect(RadianceMerge.hat(0.9, options: o) > 0 && RadianceMerge.hat(0.9, options: o) < 1)
    }

    @Test("Exponeringskvoterna mäts ur bilderna och kedjas relativt referensen")
    func ratiosMeasured() {
        let images = [frame(0.125), frame(0.5), frame(2)]
        let r = RadianceMerge.relativeExposures(images: images, count: width * height, reference: 1, fallback: nil, options: .init())
        #expect(abs(r[0] - 0.25) < 0.01)
        #expect(r[1] == 1)
        #expect(abs(r[2] - 4) < 0.1)
    }

    @Test("Statisk scen: radiansen återskapas i referensens skala, även fönstret som är klippt i referensen")
    func staticSceneRecovered() {
        let images = [frame(0.125), frame(0.5), frame(2)]
        let result = RadianceMerge.merge(images: images, width: width, height: height, reference: 1)
        for (x, y) in [(10, 40), (60, 70), (85, 20), (90, 30)] {
            let p = (y * width + x) * 4
            let expected = scene(x, y) * 0.5
            let got: Float = result.pixels[p + 1]
            #expect(abs(got - expected) / expected < 0.03, "(\(x),\(y)): \(got) mot \(expected)")
        }
        #expect(result.ghostFraction < 0.01)
    }

    @Test("Rörelse: ett föremål som bara finns i en ram ger inget spöke (ankaret används)")
    func movingObjectSuppressed() {
        // I den ljusa ramen står ett mörkt föremål i interiören (x 20–40, y 20–40); i referensen inte.
        let moving: (Int, Int) -> Float? = { x, y in (x >= 20 && x < 40 && y >= 20 && y < 40) ? 0.01 : nil }
        let images = [frame(0.125), frame(0.5), frame(2, override: moving)]
        let result = RadianceMerge.merge(images: images, width: width, height: height, reference: 1)
        let p = (30 * width + 30) * 4
        let expected = scene(30, 30) * 0.5
        let got: Float = result.pixels[p + 1]
        #expect(abs(got - expected) / expected < 0.05, "\(got) mot \(expected)")
        #expect(result.ghostFraction > 0)
    }
}
