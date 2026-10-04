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
    }
}
