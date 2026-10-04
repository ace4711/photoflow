import Foundation
import Testing
@testable import PhotoFlow

/// `BaseFrameMerge` (HDREngine v6) och fönsterrutornas hjälpfunktioner i `WindowPull`
/// med syntetiska bilder: en scen i linjärt ljus "fotograferad" med olika exponering.
struct BaseFrameMergeTests {
    let width = 120, height = 80

    /// Scenens linjära luminans: interiör 0,15–0,25 med mjuk gradient, ett fönster (x 80–110,
    /// y 10–50) med strukturerad utsikt kring 2,0 (≈ 3,5 EV ljusare).
    func scene(_ x: Int, _ y: Int) -> Float {
        if x >= 80 && x < 110 && y >= 10 && y < 50 { return (x / 2) % 2 == 0 ? 1.6 : 2.4 }
        return 0.15 + 0.1 * Float(x) / Float(width)
    }

    /// En exponering (gammakodad RGBA, klippt vid 1) med faktorn `exposure`.
    func frame(_ exposure: Float) -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = HDRImageOps.toGamma(min(scene(x, y) * exposure, 1))
                let p = (y * width + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v
            }
        }
        return out
    }

    @Test("Basramen: den ljusaste med median under gränsen, annars den mörkaste")
    func baseIndexChoice() {
        #expect(BaseFrameMerge.baseIndex(medians: [0.1, 0.3, 0.55, 0.8], maxMedian: 0.6) == 2)
        #expect(BaseFrameMerge.baseIndex(medians: [0.7, 0.8], maxMedian: 0.6) == 0)
        #expect(BaseFrameMerge.baseIndex(medians: [0.1, 0.2], maxMedian: 0.6) == 1)
    }

    @Test("Ljuskvoten mellan två exponeringar mäts i linjärt ljus")
    func exposureRatioMeasured() {
        let bright = frame(2), dark = frame(0.5)
        let r = BaseFrameMerge.exposureRatio(bright: bright, dark: dark, count: width * height)
        #expect(abs(r - 4) < 0.15)
    }

    @Test("Skuldran: identitet under knät, monoton och under 1")
    func shoulderMonotone() {
        #expect(BaseFrameMerge.shoulder(0.5, start: 0.8) == 0.5)
        var prev: Float = 0
        for i in 0...300 {
            let v = BaseFrameMerge.shoulder(Float(i) / 100, start: 0.8)
            #expect(v >= prev && v < 1)
            prev = v
        }
    }

    @Test("Interiören tas från basramen, klippta fönstret från mörkare ramar (ordning bevarad)")
    func mergeKeepsBaseAndRecoversHighlights() {
        // Mörkast först: 0,25×, 1×, 3× (basram: median ≈ 0,6 → 3× har median > 0,6?).
        let frames = [frame(0.25), frame(1), frame(3)]
        let result = BaseFrameMerge.merge(images: frames, width: width, height: height)
        let base = frames[result.baseIndex]
        // Interiören (långt från fönstret) är basramens värde (under skuldran oförändrad).
        let p = (60 * width + 20) * 4
        #expect(abs(result.pixels[p] - base[p]) < 1e-4)
        // Fönstret har struktur igen (ränderna skiljer sig) och är inte klippt.
        let a = (30 * width + 90) * 4, b = (30 * width + 92) * 4
        #expect(abs(result.pixels[a] - result.pixels[b]) > 0.01)
        #expect(result.pixels[a] < 1 && result.pixels[b] < 1)
        // Ljusare scen ger ljusare resultat (ingen tonomkastning mellan interiör och fönster).
        #expect(result.pixels[a] > result.pixels[p])
        #expect(!result.ratios.isEmpty)
    }

    @Test("Konvext hölje: kvadratens fyra hörn, inre punkter bort")
    func convexHullSquare() {
        let pts: [(Double, Double)] = [(0, 0), (4, 0), (4, 4), (0, 4), (2, 2), (1, 3), (2, 0)]
        let hull = WindowPull.convexHull(pts)
        #expect(hull.count == 4)
        #expect(Set(hull.map { "\($0.0),\($0.1)" }) == ["0.0,0.0", "4.0,0.0", "4.0,4.0", "0.0,4.0"])
    }

    @Test("Rutfyllnad: ∩-formad detektering fylls till hel ruta, men inte där `allowed` säger nej")
    func fillPanesFillsHullExceptDisallowed() {
        let w = 120, h = 80
        var mask = [Float](repeating: 0, count: w * h)
        // ∩: vänster, höger och överkant av rutan x 10–40, y 5–30 (glaset klippt längs karmen).
        for y in 5..<30 { for x in 10..<40 where x < 14 || x >= 36 || y < 9 { mask[y * w + x] = 1 } }
        // Ett "föremål framför fönstret" (x 20–24, y 18–30, når fönsterbänken nedanför) får inte fyllas.
        let filled = WindowPull.fillPanes(mask, width: w, height: h, minFraction: 0.001, maxHullRatio: 8) { p in
            let x = p % w, y = p / w
            return !(x >= 20 && x < 24 && y >= 18)
        }
        #expect(filled[15 * w + 25] == 1)      // rutans mitt fylld
        #expect(filled[20 * w + 22] == 0)      // föremålet lämnat
        #expect(filled[2 * w + 25] == 0)       // ovanför rutan orört
        #expect(filled[15 * w + 50] == 0 && filled[15 * w + 100] == 0) // utanför höljet orört
    }

    @Test("Planhetsmasken: ljusgradient är plan, ränder är det inte")
    func flatMaskGradientVsStripes() {
        let w = 40, h = 20
        var luma = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { luma[y * w + x] = x < 20 ? 0.2 + 0.01 * Float(x) : ((x / 2) % 2 == 0 ? 0.3 : 0.5) } }
        let m = WindowPull.flatMask(luma, width: w, height: h, radius: 1, threshold: 0.01)
        #expect(m[10 * w + 8] == 1)
        #expect(m[10 * w + 30] == 0)
    }

    @Test("Slöjborttagning: bara inom fönsterrutorna, strukturerad slöjad utsikt får mörkare svärta")
    func dehazeOnlyInsideBoxes() {
        let w = 200, h = 120
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                // Vänster halva: slöjad "utsikt" (struktur 0,35–0,75); höger halva: vit kakelvägg med fogar.
                let v: Float = x < 100 ? (((x / 3) + (y / 3)) % 2 == 0 ? 0.35 : 0.75) : ((x % 10 == 0 || y % 10 == 0) ? 0.6 : 0.95)
                px[p] = v; px[p + 1] = v; px[p + 2] = v
            }
        }
        // Utan rutor: ingenting ändras.
        let none = WindowPull.dehazeWindows(px, width: w, height: h, boxes: [])
        #expect(none.pixels == px && none.fraction == 0)
        // Ruta över vänster halva: svärtan sänks där, kakelväggen till höger är orörd.
        let out = WindowPull.dehazeWindows(px, width: w, height: h, boxes: [[0, 0, 0.45, 1]])
        let dark = (60 * w + 42) * 4 // en mörk ruta i utsikten, långt från rutans kant
        let darkV = px[dark] == 0.35 ? dark : dark + 4 * 3
        #expect(out.pixels[darkV] < px[darkV] - 0.05)
        let tile = (60 * w + 175) * 4
        #expect(out.pixels[tile] == px[tile])
        #expect(out.fraction > 0)
    }
}
