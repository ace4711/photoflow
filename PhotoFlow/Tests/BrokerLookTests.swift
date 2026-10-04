import Foundation
import Testing
@testable import PhotoFlow

struct BrokerLookTests {

    @Test("Tonkurvan: källa = mål ger identitet i stödpunkterna, taket hålls")
    func curveIdentityWhenOnTarget() {
        let t = BrokerLook.targetPercentiles
        let c = BrokerLook.curve(sourcePercentiles: t)
        for (x, y) in zip(c.x.dropFirst().dropLast(), c.y.dropFirst().dropLast()) {
            #expect(abs(x - y) < 1e-3)
        }
        #expect(c.x.first == 0 && c.y.first == 0)
        #expect(c.x.last == 1 && c.y.last == BrokerLook.whiteCeiling)
    }

    @Test("Tonkurvan: mörk bild lyfts mot målet men högst maxLift per punkt")
    func curveLiftIsLimited() {
        let dark = [0.01, 0.03, 0.10, 0.20, 0.30, 0.45, 0.60]
        let c = BrokerLook.curve(sourcePercentiles: dark)
        for i in 1..<(c.x.count - 1) {
            #expect(c.y[i] >= c.x[i])
            #expect(c.y[i] - c.x[i] <= BrokerLook.maxLift + 1e-9)
        }
        // strikt växande
        for i in 1..<c.x.count {
            #expect(c.x[i] > c.x[i - 1])
            #expect(c.y[i] > c.y[i - 1])
        }
    }

    @Test("Monoton kubisk interpolation går genom punkterna och är monoton")
    func evaluateMonotone() {
        let c = BrokerLook.curve(sourcePercentiles: [0.02, 0.08, 0.30, 0.45, 0.60, 0.80, 0.93])
        for (x, y) in zip(c.x, c.y) {
            #expect(abs(BrokerLook.evaluate(x: c.x, y: c.y, at: x) - y) < 1e-9)
        }
        var prev = -1.0
        for i in 0...1000 {
            let v = BrokerLook.evaluate(x: c.x, y: c.y, at: Double(i) / 1000)
            #expect(v >= prev - 1e-12)
            prev = v
        }
        #expect(BrokerLook.evaluate(x: c.x, y: c.y, at: -1) == 0)
        #expect(BrokerLook.evaluate(x: c.x, y: c.y, at: 2) == BrokerLook.whiteCeiling)
    }

    @Test("Looken: grått förblir grått och följer kurvan; mättnad 1 bevarar färgförhållandet")
    func lookColorNeutralAndRatio() {
        let c = BrokerLook.curve(sourcePercentiles: [0.03, 0.10, 0.30, 0.45, 0.60, 0.80, 0.93])
        let (r, g, b) = BrokerLook.lookColor(0.4, 0.4, 0.4, curveX: c.x, curveY: c.y, saturation: 0.8, hueSaturation: BrokerLook.hueSaturation)
        let expected = BrokerLook.evaluate(x: c.x, y: c.y, at: 0.4)
        #expect(abs(r - expected) < 2e-3 && abs(g - expected) < 2e-3 && abs(b - expected) < 2e-3)
        let (r2, g2, b2) = BrokerLook.lookColor(0.5, 0.3, 0.2, curveX: c.x, curveY: c.y, saturation: 1, hueSaturation: [Double](repeating: 1, count: 8))
        #expect(abs(r2 / g2 - 0.5 / 0.3) < 1e-6 && abs(g2 / b2 - 0.3 / 0.2) < 1e-6)
    }

    @Test("Lägre mättnad minskar Lab-krominansen")
    func saturationReducesChroma() {
        let id = ([0.0, 1.0], [0.0, 1.0])
        let (r, g, b) = BrokerLook.lookColor(0.7, 0.4, 0.2, curveX: id.0, curveY: id.1, saturation: 0.8, hueSaturation: [Double](repeating: 1, count: 8))
        let before = BrokerLook.Lab.fromSRGB(0.7, 0.4, 0.2), after = BrokerLook.Lab.fromSRGB(r, g, b)
        #expect(abs(hypot(after.a, after.b) - 0.8 * hypot(before.a, before.b)) < 0.3)
        #expect(abs(after.l - before.l) < 0.3)
    }

    @Test("Lab fram och tillbaka")
    func labRoundTrip() {
        for (r, g, b) in [(0.1, 0.5, 0.9), (0.9, 0.9, 0.9), (0.3, 0.2, 0.05)] {
            let o = BrokerLook.Lab.fromSRGB(r, g, b).toSRGB()
            #expect(abs(o.0 - r) < 1e-4 && abs(o.1 - g) < 1e-4 && abs(o.2 - b) < 1e-4)
        }
    }

    @Test("Nyansbandets faktor: i ett isolerat bands mitt och mitt emellan två band")
    func hueFactor() {
        let f: [Double] = [1, 2, 3, 4, 5, 6, 7, 8]
        let h = 200.0 * .pi / 180  // cyan: grannarna ligger 65° bort, bara egen vikt
        #expect(abs(BrokerLook.hueFactor(a: cos(h), b: sin(h), factors: f) - 5) < 1e-9)
        let mid = 167.5 * .pi / 180  // mitt emellan grönt (135) och cyan (200): medelvärdet
        #expect(abs(BrokerLook.hueFactor(a: cos(mid), b: sin(mid), factors: f) - 4.5) < 1e-9)
    }

    @Test("Utomhuspoäng och exteriörvikt")
    func outdoorScoreAndWeight() {
        let n = 16 * 16
        let green = [Float]((0..<n).flatMap { _ in [Float(0.2), 0.5, 0.15, 1] })
        let gray = [Float]((0..<n).flatMap { _ in [Float(0.6), 0.6, 0.6, 1] })
        #expect(BrokerLook.outdoorScore(pixels: green, width: 16, height: 16) > 0.99)
        #expect(BrokerLook.outdoorScore(pixels: gray, width: 16, height: 16) == 0)
        #expect(BrokerLook.exteriorWeight(outdoorScore: 0.02, taggedExterior: false) == 0)
        #expect(BrokerLook.exteriorWeight(outdoorScore: 0.02, taggedExterior: true) == 1)
        #expect(BrokerLook.exteriorWeight(outdoorScore: 0.4, taggedExterior: false) == 1)
        let mid = BrokerLook.exteriorWeight(outdoorScore: 0.165, taggedExterior: false)
        #expect(mid > 0.4 && mid < 0.6)
    }

    @Test("Vitbalans: varm grå yta kyls (negativ temperatur)")
    func whiteBalanceCoolsWarmGray() {
        let n = 32 * 32
        let warm = [Float]((0..<n).flatMap { _ in [Float(0.63), 0.6, 0.56, 1] })
        let wb = BrokerLook.whiteBalance(pixels: warm, width: 32, height: 32, mask: nil)
        #expect(wb.temperature < -0.1)
        #expect(wb.neutralFraction > 0.99)
        // Efter korrigeringen är ytan neutral.
        let g = EnhancementEngine.wbGains(temperature: wb.temperature, tint: wb.tint)
        let r = HDRImageOps.toLinear(0.63) * g.r, gg = HDRImageOps.toLinear(0.6) * g.g, b = HDRImageOps.toLinear(0.56) * g.b
        #expect(abs(r / gg - 1) < 0.02 && abs(b / gg - 1) < 0.02)
    }

    @Test("Fönsterkurvan v4: pressad kring pivoten, monoton, skonar mörka partier och når högst 0,99")
    func windowCompressMonotone() {
        let c = BrokerLook.curve(sourcePercentiles: [0.03, 0.12, 0.40, 0.60, 0.75, 0.88, 0.95])
        let pivot = 0.8
        var prev = -1.0
        for i in 0...200 {
            let x = Double(i) / 200
            let y = BrokerLook.evaluate(x: c.x, y: c.y, at: x)
            let v = BrokerLook.windowCompress(x: x, y: y, pivot: pivot)
            #expect(v >= prev - 1e-12)
            #expect(v <= BrokerLook.windowCeiling)
            prev = v
            if x <= 0.1 { #expect(v == y) }
            if x >= 0.35 {
                #expect(abs(v - min(pivot + BrokerLook.windowContrast * (y - pivot) + BrokerLook.windowLift, BrokerLook.windowCeiling)) < 1e-12)
            }
        }
    }

    @Test("Looken med fönstermedian: fönsterkurvan (ev. pressad) och värme; utan median som förut")
    func lookParametersWindow() {
        let src = [0.03, 0.12, 0.40, 0.60, 0.75, 0.88, 0.95]
        let plain = BrokerLook.lookParameters(sourcePercentiles: src)
        let withWindow = BrokerLook.lookParameters(sourcePercentiles: src, windowMedian: 0.85)
        #expect(plain.windowWarmth == nil)
        #expect(withWindow.windowWarmth == BrokerLook.windowWarmth)
        #expect(withWindow.curveY == plain.curveY)
        for i in 1..<withWindow.windowCurveY.count { #expect(withWindow.windowCurveY[i] > withWindow.windowCurveY[i - 1]) }
        #expect(withWindow.windowCurveY.allSatisfy { $0 <= BrokerLook.windowCeiling })
        // Toppen (x = 1) får nå högre än huvudkurvans tak.
        #expect(withWindow.windowCurveY.last! >= plain.windowCurveY.last!)
    }

    @Test("Ljusa ytor avmättas mer än mörka; värme höjer b*")
    func highlightSaturationAndWarmth() {
        let flat = [Double](repeating: 1, count: 8)
        let id: (Double) -> Double = { $0 }
        func chroma(_ c: (Double, Double, Double)) -> Double {
            let l = BrokerLook.Lab.fromSRGB(c.0, c.1, c.2); return hypot(l.a, l.b)
        }
        let bright = (0.97, 0.92, 0.85), dark = (0.30, 0.25, 0.20)
        let b1 = BrokerLook.lookColor(bright.0, bright.1, bright.2, curve: id, saturation: 1, hueSaturation: flat)
        let b08 = BrokerLook.lookColor(bright.0, bright.1, bright.2, curve: id, saturation: 1, hueSaturation: flat, highlightSaturation: 0.8)
        #expect(chroma(b08) < 0.85 * chroma(b1))
        let d1 = BrokerLook.lookColor(dark.0, dark.1, dark.2, curve: id, saturation: 1, hueSaturation: flat)
        let d08 = BrokerLook.lookColor(dark.0, dark.1, dark.2, curve: id, saturation: 1, hueSaturation: flat, highlightSaturation: 0.8)
        #expect(abs(chroma(d08) - chroma(d1)) < 1e-6)
        let gray = BrokerLook.lookColor(0.7, 0.7, 0.7, curve: id, saturation: 1, hueSaturation: flat, warmth: 2)
        let lab = BrokerLook.Lab.fromSRGB(gray.0, gray.1, gray.2)
        #expect(abs(lab.b - 2) < 0.1)
    }

    @Test("Fönstrets median räknas bara i masken; nästan tom mask ger nil")
    func windowMedianInMask() {
        let w = 40, h = 20
        var pixels = [Float](repeating: 0, count: w * h * 4)
        var mask = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let v: Float = i % w < 20 ? 0.2 : 0.8
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v; pixels[i * 4 + 3] = 1
            if i % w >= 20 { mask[i] = 1 }
        }
        let m = BrokerLook.windowMedian(pixels: pixels, width: w, height: h, mask: mask, gains: (1, 1, 1))
        #expect(abs((m ?? 0) - 0.8) < 1e-3)
        var tiny = [Float](repeating: 0, count: w * h); tiny[5] = 1
        #expect(BrokerLook.windowMedian(pixels: pixels, width: w, height: h, mask: tiny, gains: (1, 1, 1)) == nil)
    }

    @Test("Parametrar och profil utan de nya fälten avkodas (gamla JSON-filer)")
    func backwardCompatibleDecoding() throws {
        let params = try JSONDecoder().decode(EnhancementParameters.self, from: Data(#"{"exposureEV":0.5,"temperature":0,"tint":0,"blackPoint":0,"whitePoint":1,"shadows":0,"highlights":0,"contrast":0,"vibrance":0,"saturation":0,"clarity":0.3,"sharpness":0.5,"rotationDegrees":0}"#.utf8))
        #expect(params.look == nil && params.perspective == nil && params.exposureEV == 0.5)
        var old = EnhancementProfile.automatic
        old.look = nil
        let data = try JSONEncoder().encode(old)
        var dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "look")
        let profile = try JSONDecoder().decode(EnhancementProfile.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(profile.look == nil && profile.id == "auto")
        // Mäklarstil v1-loggar saknar windowWarmth.
        let look = try JSONDecoder().decode(LookParameters.self, from: Data(#"{"curveX":[0,1],"curveY":[0,0.97],"windowCurveY":[0,0.97],"saturation":0.8,"hueSaturation":[1,1,1,1,1,1,1,1],"noiseReduction":0.5,"chromaNoiseReduction":0.8,"texture":0.15,"exteriorWeight":0}"#.utf8))
        #expect(look.windowWarmth == nil)
    }
}
