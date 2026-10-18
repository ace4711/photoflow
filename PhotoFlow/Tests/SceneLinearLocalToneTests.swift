import Foundation
import Testing
@testable import PhotoFlow

/// `SceneLinearLocalTone` (HDR v8, "Lightroom-lik framkallning") med syntetiska scenlinjära bilder.
struct SceneLinearLocalToneTests {
    let width = 240, height = 120

    func luma(_ px: [Float], _ i: Int) -> Float {
        0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2]
    }

    /// Grått, logaritmisk ramp i x: 2^lo … 2^hi (linjärt), samma på alla rader.
    func ramp(lo: Float = -8, hi: Float = 5) -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = exp2f(lo + (hi - lo) * Float(x) / Float(width - 1))
                let p = (y * width + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v
            }
        }
        return out
    }

    /// Steg: interiör (0,02, svag textur) till vänster, ljust "fönster" (2,0 ≈ +6,6 EV) till höger om `edge`.
    func step(edge: Int = 120) -> [Float] {
        var out = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let texture: Float = ((x / 4 + y / 4) % 2 == 0) ? 0.95 : 1.05
                let v: Float = (x < edge ? 0.02 : 2.0) * texture
                let p = (y * width + x) * 4
                out[p] = v; out[p + 1] = v; out[p + 2] = v
            }
        }
        return out
    }

    @Test("Kurvorna: kompressionen och S-kurvan är monotona, tån är 0 i 0")
    func curveShapes() {
        var last = -Float.infinity
        for i in -800...800 {
            let b = Float(i) / 100
            let c = SceneLinearLocalTone.compressBase(b, highlightStart: 0.8, highlightRange: 1.0, shadowRange: 12)
            #expect(c >= last - 1e-6)
            last = c
        }
        #expect(SceneLinearLocalTone.compressBase(0.5, highlightStart: 0.8, highlightRange: 1, shadowRange: 12) == 0.5)
        #expect(SceneLinearLocalTone.compressBase(100, highlightStart: 0.8, highlightRange: 1, shadowRange: 12) <= 1.8 + 1e-5)
        var lastS: Float = -1
        for i in 0...1000 {
            let s = SceneLinearLocalTone.sCurve(Float(i) / 1000, strength: 0.3, pivot: 0.45)
            #expect(s >= lastS - 1e-6)
            lastS = s
        }
        #expect(abs(SceneLinearLocalTone.sCurve(0.45, strength: 0.3, pivot: 0.45) - 0.45) < 1e-6)
        #expect(SceneLinearLocalTone.sCurve(1, strength: 0.3, pivot: 0.45) == 1)
        #expect(SceneLinearLocalTone.toe(0, black: 0.01) == 0)
        #expect(SceneLinearLocalTone.toe(1, black: 0.01) < 1)
    }

    @Test("Monoton längs en jämn ramp, utan NaN och inom 0…1")
    func monotoneRamp() {
        let (px, _) = SceneLinearLocalTone.apply(linear: ramp(), width: width, height: height)
        #expect(px.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        let row = height / 2
        var last: Float = -1
        for x in 0..<width {
            let v = luma(px, row * width + x)
            #expect(v >= last - 0.004, "x = \(x): \(v) < \(last)")
            last = max(last, v)
        }
    }

    @Test("Svart- och vitpunkt: riktiga svärtor och vitt i rampens ändar")
    func blackAndWhitePoints() {
        let (px, info) = SceneLinearLocalTone.apply(linear: ramp(lo: -10, hi: 6), width: width, height: height)
        let row = height / 2
        #expect(luma(px, row * width) < 0.03)
        #expect(luma(px, row * width + width - 1) > 0.95)
        #expect(info.black > 0)
        #expect(info.white > info.black)
    }

    @Test("Medianen kalibreras till målet oberoende av radiansens skala")
    func medianCalibration() {
        for scale: Float in [0.01, 1, 50] {
            // Rampen (kontinuerlig fördelning — i steget ligger medianen i glappet mellan två kluster).
            let linear = ramp().map { $0 * scale }
            let (px, info) = SceneLinearLocalTone.apply(linear: linear, width: width, height: height)
            #expect(abs(info.calibratedMedian - Double(SceneLinearLocalTone.Options().targetMedian)) < 0.02)
            var lumas = (0..<(width * height)).map { luma(px, $0) }
            lumas.sort()
            #expect(abs(lumas[lumas.count / 2] - SceneLinearLocalTone.Options().targetMedian) < 0.08, "skala \(scale)")
        }
    }

    @Test("Inga NaN för nollor, negativa och mycket stora värden")
    func robustInput() {
        var linear = step()
        for i in stride(from: 0, to: linear.count, by: 37) { linear[i] = 0 }
        for i in stride(from: 1, to: linear.count, by: 53) { linear[i] = -0.5 }
        for i in stride(from: 2, to: linear.count, by: 71) { linear[i] = 1e6 }
        let (px, _) = SceneLinearLocalTone.apply(linear: linear, width: width, height: height, clipCeiling: 4)
        #expect(px.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    @Test("Fönstret behåller struktur och klipps inte; halon vid kanten är begränsad")
    func stepEdgeHalo() {
        let edge = 120
        let (px, _) = SceneLinearLocalTone.apply(linear: step(edge: edge), width: width, height: height)
        let row = height / 2
        func mean(_ xs: Range<Int>) -> Float {
            var s: Float = 0
            for y in (row - 20)..<(row + 20) { for x in xs { s += luma(px, y * width + x) } }
            return s / Float(xs.count * 40)
        }
        // Fönstret: ljusare än rummet, under vitt, texturen syns.
        let window = mean((edge + 40)..<(edge + 100))
        let room = mean(10..<(edge - 40))
        #expect(window > room + 0.15)
        #expect(window < 0.97)
        let a = luma(px, row * width + edge + 60), b = luma(px, (row + 4) * width + edge + 60)
        #expect(abs(a - b) > 0.01, "texturen i fönstret ska synas")
        // Halo: nära kanten skiljer sig högst lite från långt ifrån, på båda sidor.
        let roomNear = mean((edge - 8)..<(edge - 2)), windowNear = mean((edge + 2)..<(edge + 8))
        #expect(abs(roomNear - room) < 0.08, "rum nära kanten \(roomNear) mot \(room)")
        #expect(abs(windowNear - window) < 0.10, "fönster nära kanten \(windowNear) mot \(window)")
    }

    @Test("Kulören bevaras: blå himmel förblir blå när den trycks ned, mellantoner behåller nyansen")
    func chromaPreserved() {
        var linear = step()
        // Blå himmel i fönstret (y < 40), orange i rummet (y > 80).
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                if x >= 140 && y < 40 { linear[p] = 1.2; linear[p + 1] = 1.8; linear[p + 2] = 3.6 }
                if x < 100 && y > 80 { linear[p] = 0.04; linear[p + 1] = 0.02; linear[p + 2] = 0.008 }
            }
        }
        let (px, _) = SceneLinearLocalTone.apply(linear: linear, width: width, height: height)
        let sky = (20 * width + 190) * 4
        #expect(px[sky + 2] > px[sky + 1] && px[sky + 1] > px[sky])
        #expect(px[sky + 2] - px[sky] > 0.08, "himlen ska inte bli vit/grå")
        let orange = (100 * width + 50) * 4
        #expect(px[orange] > px[orange + 1] && px[orange + 1] > px[orange + 2])
    }

    @Test("Klippt i alla ramar blir vitt, rosa kantpixlar avmättas")
    func clippedCeiling() {
        var linear = step()
        let ceiling: Float = 2.2
        for y in 0..<height {
            for x in 180..<width {
                let p = (y * width + x) * 4
                linear[p] = ceiling; linear[p + 1] = ceiling; linear[p + 2] = ceiling
            }
        }
        // Magenta kant (delvis klippt grön kanal) i ljust parti.
        for y in 0..<height {
            let p = (y * width + 179) * 4
            linear[p] = 2.0; linear[p + 1] = 1.2; linear[p + 2] = 1.8
        }
        let (px, _) = SceneLinearLocalTone.apply(linear: linear, width: width, height: height, clipCeiling: ceiling)
        let white = (60 * width + 220) * 4
        #expect(px[white] > 0.97 && px[white + 1] > 0.97 && px[white + 2] > 0.97)
        let fringe = (60 * width + 179) * 4
        #expect(min(px[fringe], px[fringe + 2]) - px[fringe + 1] < 0.08)
    }

    @Test("Parametrar efter namn (CLI:ts --tone)")
    func setByName() {
        var o = SceneLinearLocalTone.Options()
        let detailSet = o.set("detail", 1.5)
        let blackSet = o.set("blackClip", 0.01)
        let unknownSet = o.set("finns-inte", 1)
        #expect(detailSet && blackSet && !unknownSet)
        #expect(o.detail == 1.5)
        #expect(o.blackClip == 0.01)
    }
}

struct RadianceCacheTests {
    @Test("Radianscachen skrivs och läses tillbaka oförändrad")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("radcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("g.pfrad")
        let pixels: [Float] = (0..<(5 * 3 * 4)).map { Float($0) * 0.25 }
        try RadianceCache.write(pixels, width: 5, height: 3, ratios: [0.25, 1, 4], ghostFraction: 0.125, to: url)
        let entry = try #require(RadianceCache.read(url))
        #expect(entry.width == 5 && entry.height == 3)
        #expect(entry.pixels == pixels)
        #expect(entry.ratios == [0.25, 1, 4])
        #expect(entry.ghostFraction == 0.125)
        try Data("nej".utf8).write(to: url)
        #expect(RadianceCache.read(url) == nil)
    }
}
