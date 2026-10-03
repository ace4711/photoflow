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
        #expect(EnhancementEngine.straightenRotation(forHorizon: 1.5) == -1.5)
        #expect(EnhancementEngine.straightenRotation(forHorizon: -3.0) == 3.0)

        let flat = grayGradient(lo: 0.05, hi: 0.95)
        #expect(params(flat, horizon: 1.2).parameters.rotationDegrees == -1.2)
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
}
