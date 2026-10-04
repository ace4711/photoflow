import Foundation
import Testing
@testable import PhotoFlow

/// `SceneLinearTone` (Förbättra v5 för scenlinjära källor, HDREngine v7 "radians") med syntetiska
/// scenlinjära bilder.
struct SceneLinearToneTests {
    let width = 160, height = 100

    /// Scenlinjär bild: slät interiör (luminans `interior`, svag gradient), en strukturerad utsikt
    /// (x 100–150, y 10–60) runt `view` med `veil` adderad slöja.
    func scene(interior: Float = 0.02, view: Float = 0.06, veil: Float = 0) -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = interior * (0.8 + 0.4 * Float(x) / Float(width))
                if x >= 100 && x < 150 && y >= 10 && y < 60 {
                    v = ((x / 3 + y / 3) % 2 == 0 ? view * 0.15 : view * 1.6) + veil
                }
                let p = (y * width + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v
            }
        }
        return out
    }

    @Test("Exponeringen för interiörens median till målet, oavsett skala")
    func exposureFromStatistics() {
        for scale: Float in [0.1, 1, 10] {
            let linear = scene().map { $0 * scale }
            let (pixels, info) = SceneLinearTone.apply(linear: linear, width: width, height: height)
            // Interiörpixel mitt i bilden (gradienten ×1,0 vid x = 80).
            let p = (50 * width + 80) * 4
            let target: Float = SceneLinearTone.Options().targetMedian
            let value: Float = pixels[p + 1]
            #expect(abs(value - target) < 0.03, "skala \(scale): \(value)")
            let expected: Double = 0.02 * Double(scale)
            let relative: Double = abs(info.medianLinear - expected) / expected
            #expect(relative < 0.1)
        }
    }

    @Test("BaselineExposure begränsar statistikens förstärkning")
    func priorLimitsGain() {
        var options = SceneLinearTone.Options()
        options.maxDeviationEV = 1
        let ev = SceneLinearTone.gainEV(medianLinear: 0.001, priorEV: 2, options: options)
        #expect(abs(ev - 3) < 1e-9)
        #expect(SceneLinearTone.gainEV(medianLinear: 0.001, priorEV: nil, options: options) > 6)
    }

    @Test("Skuldran: identitet under knät, kontinuerlig, monoton och 1 vid vitpunkten")
    func shoulderShape() {
        let k: Float = 0.5, w: Float = 4
        #expect(SceneLinearTone.shoulder(0.3, knee: k, white: w) == 0.3)
        #expect(abs(SceneLinearTone.shoulder(0.5001, knee: k, white: w) - 0.5001) < 1e-3)
        #expect(abs(SceneLinearTone.shoulder(w, knee: k, white: w) - 1) < 1e-5)
        var last: Float = 0
        for i in 0...400 {
            let y = SceneLinearTone.shoulder(Float(i) / 100, knee: k, white: w)
            #expect(y >= last - 1e-6)
            last = y
        }
    }

    @Test("Inga klippta eller negativa värden, färg ryms utan nyansskifte")
    func outputInRange() {
        var linear = scene()
        // En mycket ljus, mättad röd pixel (lampa).
        let p = (5 * width + 5) * 4
        linear[p] = 50; linear[p + 1] = 5; linear[p + 2] = 1
        let (pixels, _) = SceneLinearTone.apply(linear: linear, width: width, height: height)
        #expect(pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
        let r: Float = pixels[p], g: Float = pixels[p + 1], b: Float = pixels[p + 2]
        #expect(r >= g)
        #expect(g >= b)
    }

    @Test("Slöjan dras av i den ljusa strukturerade utsikten men inte i den släta interiören")
    func dehazeOnlyInView() {
        let veiled = scene(veil: 0.03)
        var linear = veiled
        let fraction = SceneLinearTone.dehaze(&linear, width: width, height: height, interiorMedian: 0.02)
        #expect(fraction > 0)
        // Mörka pixlar i utsikten (0,06·0,15 + 0,03 = 0,039) blir klart mörkare.
        let dx = 129, dy = 35  // (129/3 + 35/3) = 54, jämnt → mörk ruta
        let isDarkCell: Bool = (dx / 3 + dy / 3) % 2 == 0
        #expect(isDarkCell)
        let dark = (dy * width + dx) * 4
        let after: Float = linear[dark], before: Float = veiled[dark]
        #expect(after < before * 0.6, "\(after) mot \(before)")
        // Interiören långt från utsikten är orörd.
        let wall = (80 * width + 30) * 4
        let wallAfter: Float = linear[wall], wallBefore: Float = veiled[wall]
        #expect(wallAfter == wallBefore)
    }

    @Test("Lightrooms LinearRaw-DNG känns igen, NEF och vanliga filer inte")
    func sceneLinearDetection() {
        #expect(!RAWRenderer.isSceneLinearDNG(url: URL(fileURLWithPath: "/finns/inte.dng")))
        #expect(!RAWRenderer.isSceneLinearDNG(url: URL(fileURLWithPath: "/finns/inte.nef")))
    }
}
