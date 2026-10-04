import Foundation
import CoreImage
import Testing
@testable import PhotoFlow

/// Tester för `EnhancementEngine`: parametrarna ur syntetiska bilder (ingen
/// riktig fotografi behövs) och att renderingen behåller storlek och [0,1].
struct EnhancementEngineTests {

    /// RGBA float32 (sRGB-gammakodat) där varje pixel ges av `color(x, y)` (0…1).
    private func image(width: Int = 96, height: Int = 64, _ color: (Int, Int) -> (Float, Float, Float)) -> [Float] {
        var px = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                px[i] = r; px[i + 1] = g; px[i + 2] = b
            }
        }
        return px
    }

    /// Grå horisontell gradient mellan `lo` och `hi`.
    private func grayGradient(lo: Float, hi: Float, width: Int = 96, height: Int = 64) -> [Float] {
        image(width: width, height: height) { x, _ in
            let v = lo + (hi - lo) * Float(x) / Float(width - 1)
            return (v, v, v)
        }
    }

    private func params(_ pixels: [Float], width: Int = 96, height: Int = 64, horizon: Double? = nil, sharpened: Bool = false)
        -> (parameters: EnhancementParameters, analysis: EnhancementAnalysis) {
        EnhancementEngine.automaticParameters(.init(pixels: pixels, width: width, height: height, horizonDegrees: horizon, alreadySharpened: sharpened))
    }

    @Test("En för mörk bild ger exponering uppåt")
    func darkImage_raisesExposure() {
        let (p, a) = params(grayGradient(lo: 0.05, hi: 0.32))
        #expect(a.medianLuma < 0.25)
        #expect(p.exposureEV > 0.4)
        #expect(p.exposureEV <= 0.9)
    }

    @Test("En för ljus bild ger exponering nedåt, men begränsat")
    func brightImage_lowersExposure() {
        let (p, _) = params(grayGradient(lo: 0.60, hi: 0.90))
        #expect(p.exposureEV < -0.1)
        #expect(p.exposureEV >= -0.6)
    }

    @Test("Blåstick på grå yta: vitbalansen går mot neutral men begränsat")
    func blueCast_balancesTowardNeutralButLimited() {
        // Neutral yta med kraftig blåstick (B 30 % över R i gammakodat värde).
        let cast = image { x, _ in
            let v = 0.35 + 0.25 * Float(x) / 95
            return (v, v * 1.08, v * 1.30)
        }
        let (p, a) = params(cast)
        #expect(a.neutralFraction > 0.5)
        #expect(a.neutralBG > 1.2)                       // blå stick mäts
        #expect(p.temperature > 0.1)                     // varmare = mot neutral
        #expect(p.temperature <= EnhancementEngine.maxAutoTemperature + 1e-9)
        #expect(abs(p.tint) <= EnhancementEngine.maxAutoTint + 1e-9)

        // Efter förstärkningarna är B/R-kvoten närmare 1 men inte (nödvändigtvis) exakt 1.
        let gains = EnhancementEngine.wbGains(temperature: p.temperature, tint: p.tint)
        let before = a.neutralBG / a.neutralRG
        let after = before * Double(gains.b / gains.r)
        #expect(abs(after - 1) < abs(before - 1))
    }

    @Test("Färgstarka bilder utan neutrala ytor får ingen vitbalansändring")
    func saturatedImage_noWhiteBalance() {
        let red = image { _, _ in (0.8, 0.2, 0.15) }
        let (p, a) = params(red)
        #expect(a.neutralFraction < 0.02)
        #expect(p.temperature == 0)
        #expect(p.tint == 0)
    }

    @Test("En redan bra bild får bara små justeringar")
    func goodImage_getsSmallAdjustments() {
        // Jämn gradient 0,04…0,96 med median ≈ målet.
        let (p, _) = params(grayGradient(lo: 0.04, hi: 0.96))
        #expect(abs(p.exposureEV) < 0.2)
        #expect(abs(p.temperature) < 0.05)
        #expect(abs(p.tint) < 0.05)
        #expect(p.blackPoint < 0.06)
        #expect(p.shadows < 0.25)
        #expect(p.highlights < 0.25)
        #expect(p.contrast <= 0.2)
        #expect(p.vibrance <= 0.35)
    }

    @Test("Svart- och vitpunkt kommer från percentilerna")
    func blackAndWhitePoints_fromPercentiles() {
        let (p, a) = params(grayGradient(lo: 0.05, hi: 0.90))
        #expect(p.blackPoint > 0.03 && p.blackPoint <= 0.08)
        #expect(p.whitePoint >= 0.90 && p.whitePoint < 0.97)
        #expect(a.blackPercentile < a.whitePercentile)

        // Full omfång: ingen svartpunkt, vitpunkten ligger nära 1 (exponeringen kan dra ned toppen något).
        let (full, _) = params(grayGradient(lo: 0, hi: 1))
        #expect(full.blackPoint == 0)
        #expect(full.whitePoint >= 0.90)
    }

    @Test("Svartpunkten höjs aldrig över 0,08 och vitpunkten sänks aldrig under 0,90")
    func levels_areCapped() {
        let (p, _) = params(grayGradient(lo: 0.30, hi: 0.60))
        #expect(p.blackPoint <= 0.08)
        #expect(p.whitePoint >= 0.90)
    }

    @Test("Rätning bara inom 0,3–3 grader")
    func straighten_onlyWithinRange() {
        #expect(EnhancementEngine.straightenRotation(forHorizon: nil) == 0)
        #expect(EnhancementEngine.straightenRotation(forHorizon: 0.1) == 0)
        #expect(EnhancementEngine.straightenRotation(forHorizon: -0.29) == 0)
        #expect(EnhancementEngine.straightenRotation(forHorizon: 3.5) == 0)
        #expect(EnhancementEngine.straightenRotation(forHorizon: 25) == 0)
        #expect(EnhancementEngine.straightenRotation(forHorizon: 1.5) == 1.5)
        #expect(EnhancementEngine.straightenRotation(forHorizon: -3.0) == -3.0)

        let flat = grayGradient(lo: 0.05, hi: 0.95)
        #expect(params(flat, horizon: 1.2).parameters.rotationDegrees == 1.2)
        #expect(params(flat, horizon: 7).parameters.rotationDegrees == 0)
    }

    @Test("Källa som redan skärpts får mindre slutskärpa")
    func alreadySharpened_lessSharpening() {
        let g = grayGradient(lo: 0.05, hi: 0.95)
        #expect(params(g, sharpened: true).parameters.sharpness < params(g, sharpened: false).parameters.sharpness)
    }

    @Test("Alla automatparametrar ligger inom sina intervall")
    func parametersWithinRanges() {
        for pixels in [grayGradient(lo: 0, hi: 0.1), grayGradient(lo: 0.9, hi: 1), image { _, _ in (0.9, 0.1, 0.1) }] {
            let (p, _) = params(pixels, horizon: 2)
            #expect(p == p.clamped())
        }
    }

    // MARK: - Rendering

    private func ciImage(width: Int, height: Int, _ color: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        let px = image(width: width, height: height, color)
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func testScene(width: Int = 240, height: Int = 160) -> CIImage {
        ciImage(width: width, height: height) { x, y in
            let v = 0.15 + 0.7 * Float(x) / Float(width - 1)
            return (v, v * 0.95, v * 1.0 * (y % 40 < 20 ? 1 : 0.9))
        }
    }

    @Test("Rendering med identitetsparametrar ger samma bild")
    func render_identityKeepsPixels() throws {
        let src = testScene()
        let ctx = EnhancementEngine.makeContext()
        let out = EnhancementEngine.render(src, parameters: .identity)
        let a = try #require(EnhancementEngine.renderPixels(src, context: ctx))
        let b = try #require(EnhancementEngine.renderPixels(out, context: ctx))
        #expect(a.width == b.width && a.height == b.height)
        var maxDiff: Float = 0
        for i in 0..<a.pixels.count where i % 4 != 3 { maxDiff = max(maxDiff, abs(a.pixels[i] - b.pixels[i])) }
        #expect(maxDiff < 0.01)
    }

    @Test("Rendering behåller storleken och håller värdena inom [0,1]")
    func render_sameSizeAndInRange() throws {
        let src = testScene()
        let ctx = EnhancementEngine.makeContext()
        let small = try #require(EnhancementEngine.renderPixels(src, context: ctx))
        let (auto, _) = EnhancementEngine.automaticParameters(.init(
            pixels: small.pixels, width: small.width, height: small.height, horizonDegrees: nil, alreadySharpened: false))
        var strong = EnhancementProfile.automatic.finalParameters(auto: auto)
        strong.exposureEV = 1.5; strong.shadows = 0.6; strong.highlights = 0.4; strong.contrast = 0.4
        strong.vibrance = 0.8; strong.clarity = 1; strong.sharpness = 1.5

        for p in [EnhancementProfile.automatic.finalParameters(auto: auto), strong.clamped()] {
            let out = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p), context: ctx))
            #expect(out.width == small.width && out.height == small.height)
            for i in 0..<out.pixels.count {
                #expect(out.pixels[i] >= 0 && out.pixels[i] <= 1.0001)
            }
        }
    }

    @Test("Exponering uppåt gör bilden ljusare")
    func render_exposureBrightens() throws {
        let src = testScene()
        let ctx = EnhancementEngine.makeContext()
        func mean(_ p: EnhancementParameters) throws -> Float {
            let out = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p), context: ctx))
            return stride(from: 1, to: out.pixels.count, by: 4).reduce(0) { $0 + out.pixels[$1] } / Float(out.pixels.count / 4)
        }
        var up = EnhancementParameters.identity; up.exposureEV = 0.7
        #expect(try mean(up) > mean(.identity) + 0.03)
    }

    @Test("Rotation beskär minimalt: förväntad storlek, inga tomma hörn")
    func render_rotationCropsMinimally() throws {
        let w = 400, h = 300
        // Helvit bild: tomma (transparenta/svarta) hörn efter rotation skulle synas som mörka pixlar.
        let src = ciImage(width: w, height: h) { _, _ in (1, 1, 1) }
        let ctx = EnhancementEngine.makeContext()
        var p = EnhancementParameters.identity
        p.rotationDegrees = 2
        let rotated = EnhancementEngine.render(src, parameters: p)
        let s = EnhancementEngine.cropScale(width: Double(w), height: Double(h), rotationDegrees: 2)
        #expect(s > 1 && s < 1.1)
        #expect(abs(Double(rotated.extent.width) - Double(w) / s) <= 2)
        #expect(abs(Double(rotated.extent.height) - Double(h) / s) <= 2)
        #expect(rotated.extent.minX == 0 && rotated.extent.minY == 0)

        let out = try #require(EnhancementEngine.renderPixels(rotated, context: ctx))
        var minValue: Float = 1
        for i in stride(from: 0, to: out.pixels.count, by: 4) { minValue = min(minValue, out.pixels[i], out.pixels[i + 1], out.pixels[i + 2]) }
        #expect(minValue > 0.97, "Roterad bild har tomma hörn (lägsta värde \(minValue))")
    }

    @Test("Beskärningsfaktorn är 1 utan rotation och växer med vinkeln")
    func cropScale_growsWithAngle() {
        #expect(abs(EnhancementEngine.cropScale(width: 300, height: 200, rotationDegrees: 0) - 1) < 1e-9)
        #expect(EnhancementEngine.cropScale(width: 300, height: 200, rotationDegrees: 3)
                > EnhancementEngine.cropScale(width: 300, height: 200, rotationDegrees: 1))
    }

    // MARK: - Golden (version 1)

    /// En scen med detaljer (kanter, färg) för golden-jämförelsen.
    private func goldenScene() -> [Float] {
        image(width: 160, height: 120) { x, y in
            let v = 0.08 + 0.55 * Float(x) / 159
            let stripe: Float = (x / 12 + y / 12) % 2 == 0 ? 1 : 0.85
            let bright: Float = (x > 100 && x < 140 && y > 20 && y < 60) ? 1.6 : 1
            return (min(v * stripe * bright * 1.05, 1), min(v * stripe * bright, 1), min(v * stripe * bright * 0.9, 1))
        }
    }

    /// Uppmätt med version 1 (före fönstermasken): utan mask ska analysen och
    /// renderingen vara oförändrade.
    private static let goldenParams = #"{"blackPoint":0.08,"clarity":0.3,"contrast":0.08,"exposureEV":0.8813495412007065,"highlights":0.11851562499999999,"rotationDegrees":0,"saturation":0,"shadows":0.09875,"sharpness":0.5,"temperature":-0.25,"tint":0.12,"vibrance":0.35,"whitePoint":1}"#
    private static let goldenAnalysis = #"{"blackPercentile":0.09970674486803519,"brightFraction":0.04140625,"darkFraction":0.115625,"meanSaturation":0.06017747223304728,"medianLuma":0.32649071358748777,"neutralBG":0.7979178016375911,"neutralFraction":0.74125,"neutralRG":1.111148160541468,"p5":0.1378299120234604,"p95":0.906158357771261,"whitePercentile":0.9990224828934506}"#
    private static let goldenRenders: [(width: Int, height: Int, sum: Double, samples: [Float])] = [
        (160, 120, 43384.56797326729, [0.040940206, 0.40227133, 0.08652869, 1.0, 0.1866664, 0.66387945, 0.29600915, 1.0, 0.34893098, 0.033139855, 0.46480882, 1.0, 0.6165271, 0.24570093, 0.9025757, 1.0, 0.8134148, 0.43781486, 0.06356239, 1.0, 0.17712149, 0.824782, 0.18390219, 1.0, 0.383156, 0.6421128, 0.33060318, 1.0, 0.4480989, 0.13617277, 0.96672046, 1.0, 1.0, 0.298672, 0.72388464, 1.0, 0.078690924, 0.9277729, 0.18488972, 1.0, 0.24729148, 0.71584713, 0.35775912, 1.0, 0.51436746, 0.11917324, 0.4142738, 1.0, 0.69130766, 0.3145114, 0.5601659, 1.0, 0.047412753, 0.4060716, 0.12636544, 1.0, 0.24974874, 0.55657, 0.23605624, 1.0, 0.3626651, 0.03502394, 0.37297648, 1.0, 0.5254091, 0.19303405, 0.6282438, 1.0, 0.8105607, 0.45213026, 0.046033036, 1.0, 0.13621345, 0.6190179, 0.24316058, 1.0, 0.3882278, 0.6510906]),
        (154, 114, 39831.61969833076, [0.06347236, 0.54616344, 0.17383844, 1.0, 0.46502745, 0.09502847, 0.5508754, 1.0, 0.6769517, 0.5044894, 0.14061171, 1.0, 0.4209845, 0.059946995, 0.8691921, 1.0, 0.6293491, 0.47252703, 0.13750869, 1.0, 0.29031068, 0.7454474, 0.37656194, 1.0, 1.0, 0.33946532, 0.10619074, 1.0, 0.27544725, 0.7533171, 0.35957155, 1.0, 1.0, 0.30335182, 0.06788555, 1.0, 0.28935105, 0.7157301, 0.3306646, 1.0, 0.65183437, 0.26660177, 0.7215841, 1.0, 0.1989891, 0.693579, 0.3404716, 1.0, 0.50344926, 0.29575512, 0.5595606, 1.0, 0.14201795, 0.537969, 0.33514154, 1.0, 0.4744036, 0.2516473, 0.5403862, 1.0, 0.10482226, 0.50501895, 0.29545507, 1.0, 0.43423408, 0.21117786, 0.5111412, 1.0, 0.06644844, 0.4710127, 0.2585658])
    ]

    @Test("Utan mask: analys och rendering identiska med version 1")
    func noMask_identicalToVersion1() throws {
        let px = goldenScene()
        let (p, a) = EnhancementEngine.automaticParameters(.init(pixels: px, width: 160, height: 120, horizonDegrees: nil, alreadySharpened: false))
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        #expect(String(data: try enc.encode(p), encoding: .utf8) == Self.goldenParams)
        #expect(String(data: try enc.encode(a), encoding: .utf8) == Self.goldenAnalysis)

        // En helt tom mask ändrar inga parametrar heller.
        let (pz, az) = EnhancementEngine.automaticParameters(.init(pixels: px, width: 160, height: 120, horizonDegrees: nil,
                                                                   alreadySharpened: false, mask: [Float](repeating: 0, count: 160 * 120)))
        #expect(pz == p)
        #expect(az.windowMaskFraction == 0)
        #expect(az.medianLuma == a.medianLuma && az.neutralBG == a.neutralBG && az.whitePercentile == a.whitePercentile)

        var q = p; q.rotationDegrees = 1.5
        let src = ciFrom(px, width: 160, height: 120)
        let ctx = EnhancementEngine.makeContext()
        for (par, golden) in zip([p, q], Self.goldenRenders) {
            let out = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: par), context: ctx))
            #expect(out.width == golden.width && out.height == golden.height)
            var sum = 0.0
            for v in out.pixels { sum += Double(v) }
            #expect(abs(sum - golden.sum) < 1e-6 * golden.sum)
            let samples = stride(from: 0, to: out.pixels.count, by: 997).map { out.pixels[$0] }
            let maxDiff = zip(samples, golden.samples).map { abs($0 - $1) }.max() ?? 1
            #expect(samples.count == golden.samples.count && maxDiff < 1e-5, "Största avvikelse mot version 1: \(maxDiff)")
        }
    }

    // MARK: - Fönstermask (version 2)

    private func ciFrom(_ px: [Float], width: Int, height: Int) -> CIImage {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Skriver masken som gråskale-PNG (samma format som HDR-steget) och läser tillbaka
    /// den som renderingen och analysen gör.
    private func maskFile(width: Int, height: Int, _ inside: (Int, Int) -> Bool) throws -> URL {
        var data = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where inside(x, y) { data[y * width + x] = 1 } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mask-\(UUID().uuidString).png")
        try HDRImageOps.writeGrayPNG(ExposureFusion.Plane(width: width, height: height, data: data), to: url)
        return url
    }

    @Test("Maskpixlar läses tillbaka med rätt värden och orientering")
    func maskPixels_roundTrip() throws {
        let url = try maskFile(width: 40, height: 20) { x, y in x >= 30 && y < 5 }
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try #require(EnhancementEngine.maskPixels(url, width: 40, height: 20))
        #expect(m[2 * 40 + 35] > 0.99)        // övre högra hörnet
        #expect(m[17 * 40 + 35] < 0.01)       // nedre högra
        #expect(m[2 * 40 + 5] < 0.01)
    }

    @Test("Blått fönster i masken påverkar inte vitbalansen")
    func windowInMask_doesNotAffectWhiteBalance() throws {
        let w = 120, h = 80
        let isWindow: (Int, Int) -> Bool = { x, y in x >= 70 && y >= 10 && y < 60 }
        // Neutral grå interiör, blåaktig utsikt (mättnad < 0,30: räknas annars som "neutral").
        let px = image(width: w, height: h) { x, y in
            if isWindow(x, y) { return (0.55, 0.62, 0.76) }
            let v = 0.35 + 0.2 * Float(x) / Float(w)
            return (v, v, v)
        }
        let url = try maskFile(width: w / 2, height: h / 2) { x, y in isWindow(x * 2, y * 2) }
        defer { try? FileManager.default.removeItem(at: url) }
        let mask = try #require(EnhancementEngine.maskPixels(url, width: w, height: h))

        let (pNo, aNo) = params(px, width: w, height: h)
        let (pMask, aMask) = EnhancementEngine.automaticParameters(.init(pixels: px, width: w, height: h, horizonDegrees: nil,
                                                                         alreadySharpened: false, mask: mask))
        #expect(aNo.neutralBG > 1.1)                    // utan mask: utsikten drar mot blått…
        #expect(pNo.temperature > 0.05)                 // …och bilden värms
        #expect(abs(aMask.neutralBG - 1) < 0.01)        // med mask: bara den grå interiören
        #expect(abs(pMask.temperature) < 0.01)
        #expect(abs(pMask.tint) < 0.01)
        #expect(abs((aMask.windowMaskFraction ?? 0) - Double(50 * 50) / Double(w * h)) < 0.03)
    }

    @Test("Exponeringshöjningen klipper inte fönstret i masken")
    func windowInMask_notClippedByExposure() throws {
        let w = 240, h = 160
        let isWindow: (Int, Int) -> Bool = { x, y in x >= 140 && x < 220 && y >= 30 && y < 120 }
        // Mörk interiör, utdragen (oklippt) utsikt med struktur 0,70–0,90 (block om 6 px).
        let px = image(width: w, height: h) { x, y in
            if isWindow(x, y) {
                let v: Float = 0.70 + 0.2 * Float((x / 6 * 7 + y / 6 * 13) % 17) / 16
                return (v * 0.97, v, v * 0.95)
            }
            let v = 0.10 + 0.08 * Float((x / 8 + y / 8) % 2)
            return (v, v, v)
        }
        let url = try maskFile(width: w, height: h, isWindow)
        defer { try? FileManager.default.removeItem(at: url) }
        let mask = try #require(EnhancementEngine.maskPixels(url, width: w, height: h))
        let (p, a) = EnhancementEngine.automaticParameters(.init(pixels: px, width: w, height: h, horizonDegrees: nil,
                                                                 alreadySharpened: false, mask: mask))
        #expect(p.exposureEV > 0.5)                     // interiören lyfts
        #expect(a.whitePercentile < 0.9)                // vitpunkten ur interiören, inte fönstret

        let src = ciFrom(px, width: w, height: h)
        let ctx = EnhancementEngine.makeContext()
        let maskImage = try #require(EnhancementEngine.loadMask(url))
        func windowStats(_ out: [Float]) -> (clipped: Double, spread: Float) {
            var clipped = 0, n = 0
            var lo: Float = 1, hi: Float = 0
            for y in 36..<114 { for x in 146..<214 {
                let i = (y * w + x) * 4
                let mx = max(out[i], out[i + 1], out[i + 2])
                if mx >= 0.99 { clipped += 1 }
                lo = min(lo, out[i + 1]); hi = max(hi, out[i + 1])
                n += 1
            } }
            return (Double(clipped) / Double(n), hi - lo)
        }
        let plain = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p), context: ctx))
        let masked = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p, windowMask: maskImage), context: ctx))
        let sPlain = windowStats(plain.pixels), sMasked = windowStats(masked.pixels)
        #expect(sPlain.clipped > 0.3, "Testet förutsätter att fönstret klipps utan mask (\(sPlain.clipped))")
        #expect(sMasked.clipped < 0.02, "Klippt andel i masken: \(sMasked.clipped)")
        #expect(sMasked.spread > 0.1)                   // strukturen i utsikten finns kvar
        // Interiören (långt från fönstret) renderas som utan mask.
        let i = (80 * w + 40) * 4
        #expect(abs(plain.pixels[i + 1] - masked.pixels[i + 1]) < 0.002)
    }

    @Test("Ingen clarity-halo vid maskkanten")
    func clarity_noHaloAtMaskEdge() throws {
        let w = 320, h = 240
        let isWindow: (Int, Int) -> Bool = { x, y in x >= 160 && x < 260 && y >= 60 && y < 180 }
        let px = image(width: w, height: h) { x, y in isWindow(x, y) ? (0.95, 0.95, 0.95) : (0.4, 0.4, 0.4) }
        let url = try maskFile(width: w, height: h, isWindow)
        defer { try? FileManager.default.removeItem(at: url) }
        var p = EnhancementParameters.identity
        p.clarity = 1
        let src = ciFrom(px, width: w, height: h)
        let ctx = EnhancementEngine.makeContext()
        let maskImage = try #require(EnhancementEngine.loadMask(url))
        // Interiören 2–10 px till vänster om fönstret jämfört med långt bort.
        func halo(_ out: [Float]) -> Float {
            var worst: Float = 0
            let far = out[(120 * w + 20) * 4 + 1]
            for y in 80..<160 { for x in 150..<158 { worst = max(worst, abs(out[(y * w + x) * 4 + 1] - far)) } }
            return worst
        }
        let plain = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p), context: ctx))
        let masked = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p, windowMask: maskImage), context: ctx))
        #expect(halo(plain.pixels) > 0.03, "Testet förutsätter en halo utan mask (\(halo(plain.pixels)))")
        #expect(halo(masked.pixels) < 0.005, "Halo med mask: \(halo(masked.pixels))")
    }

    @Test("Masken skalas och roteras/beskärs som bilden")
    func mask_followsRotationAndScale() throws {
        let w = 400, h = 300
        let rect = (x0: 290, x1: 370, y0: 30, y1: 110)   // nära hörnet: rotationen flyttar det märkbart
        let isWindow: (Int, Int) -> Bool = { x, y in x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1 }
        let px = image(width: w, height: h) { x, y in isWindow(x, y) ? (0.85, 0.85, 0.85) : (0.3, 0.3, 0.3) }
        // Masken i halv upplösning (som HDR-stegets ~1500 px-mask).
        let url = try maskFile(width: w / 2, height: h / 2) { x, y in isWindow(x * 2, y * 2) }
        defer { try? FileManager.default.removeItem(at: url) }
        var p = EnhancementParameters.identity
        p.exposureEV = 0.9; p.rotationDegrees = 3
        let src = ciFrom(px, width: w, height: h)
        let ctx = EnhancementEngine.makeContext()
        let maskImage = try #require(EnhancementEngine.loadMask(url))
        let plain = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p), context: ctx))
        let masked = try #require(EnhancementEngine.renderPixels(EnhancementEngine.render(src, parameters: p, windowMask: maskImage), context: ctx))
        #expect(plain.width == masked.width && plain.height == masked.height)

        // Samma geometri som `render`: utpixel → källkoordinat (Core Image, origo nere till vänster).
        let theta = CGFloat(3 * Double.pi / 180)
        let t = CGAffineTransform(translationX: CGFloat(w) / 2, y: CGFloat(h) / 2).rotated(by: theta)
            .translatedBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        let s = EnhancementEngine.cropScale(width: Double(w), height: Double(h), rotationDegrees: 3)
        let cropW = floor(Double(w) / s / 2) * 2, cropH = floor(Double(h) / s / 2) * 2
        let minX = ((Double(w) - cropW) / 2).rounded(.down), minY = ((Double(h) - cropH) / 2).rounded(.down)
        let inv = t.inverted()
        var insideDiff: Float = 1, outsideDiff: Float = 0
        for row in 0..<plain.height { for col in 0..<plain.width {
            let ci = CGPoint(x: Double(col) + 0.5 + minX, y: Double(plain.height - row) - 0.5 + minY).applying(inv)
            let sx = Double(ci.x), sy = Double(h) - Double(ci.y)          // källrad uppifrån
            let dx = max(Double(rect.x0) - sx, sx - Double(rect.x1)), dy = max(Double(rect.y0) - sy, sy - Double(rect.y1))
            let d = max(dx, dy)                                            // > 0 utanför, < 0 innanför
            let i = (row * plain.width + col) * 4 + 1
            let diff = abs(plain.pixels[i] - masked.pixels[i])
            if d < -4 { insideDiff = min(insideDiff, diff) }
            if d > 4 { outsideDiff = max(outsideDiff, diff) }
        } }
        #expect(insideDiff > 0.02, "Fönstret dämpas inte överallt: \(insideDiff)")
        #expect(outsideDiff < 0.002, "Masken påverkar utanför fönstret: \(outsideDiff)")
    }

    @Test("Roll-off: identitet under knät, monoton och under 1 ovanför")
    func rolloff_isSoft() {
        #expect(EnhancementEngine.rolloffValue(0.5) == 0.5)
        var last: Float = 0
        for i in 0...400 {
            let y = EnhancementEngine.rolloffValue(Float(i) / 100)
            #expect(y >= last && y <= 1)
            last = y
        }
        #expect(EnhancementEngine.rolloffValue(1.0) < 0.95)
    }

}
