import Foundation
import Accelerate
import CoreGraphics
import simd
import Vision

/// Objektiva mått för jämförelsen av två HDR-varianter (se docs/plan-hdr-jamforelse.md, avsnitt 6).
/// Rena funktioner på `RAWRenderer.RenderedImage` (RGBA-float, sRGB-gamma, 0…1) som redan är
/// nedskalade till arbetsstorlek (`workingDimension`); inläsning och cache ligger i
/// `HDRCompareRunner`. Alla mått räknas i gammakodade sRGB-värden om inget annat sägs.
nonisolated enum HDRCompareMetrics {
    typealias Image = RAWRenderer.RenderedImage
    typealias Plane = ExposureFusion.Plane

    /// Långsidan som bilderna skalas till före måtten (hastighet).
    static let workingDimension = 1500
    /// Registreringens kvarvarande förskjutning (px, vid arbetsstorlek) över vilken en variant flaggas.
    static let maxRegistrationResidual = 2.0

    // MARK: - Resultattyper

    struct Registration: Codable, Equatable, Sendable {
        /// 3×3 (radvis) som avbildar den storleksmatchade varianten på referensramen, i bildkoordinater
        /// med origo uppe till vänster (pixlar).
        var transform: [Double]
        /// Kvarvarande förskjutning efter warp, mätt med en translationsregistrering (px).
        var residualPixels: Double
        /// Falskt vid dålig registrering: ΔE utesluts då.
        var ok: Bool
    }

    struct WindowDetail: Codable, Equatable, Sendable {
        /// Maskens andel av bilden.
        var maskFraction: Double
        /// Andel av maskens pixlar där någon kanal är ≥ 0,98.
        var clippedFraction: Double
        /// p95 − p5 av luma i masken.
        var lumaSpread: Double
        /// Pearson-korrelation mellan gradientstyrka i varianten och i den mörkaste ramen, i masken.
        var structureCorrelation: Double
    }

    struct ColorCast: Codable, Equatable, Sendable {
        var meanA: Double
        var meanB: Double
        /// Andel av pixlarna som räknades som nära neutrala.
        var neutralFraction: Double
    }

    struct Tone: Codable, Equatable, Sendable {
        var medianLuma: Double
        var p5: Double
        var p95: Double
        var localContrast: Double
    }

    struct VariantMetrics: Codable, Equatable, Sendable {
        var registration: Registration?
        var clippedHighlights: Double
        var clippedShadows: Double
        var window: WindowDetail?
        /// Andel 32 px-rutor där varianten avviker strukturellt från referensramen.
        var ghostTileFraction: Double?
        /// Robust σ (MAD av Laplace) i släta, mörka rutor, i gammakodade enheter.
        var noiseSigma: Double?
        var colorCast: ColorCast?
        var tone: Tone
    }

    struct PairMetrics: Codable, Equatable, Sendable {
        var deltaEMean: Double
        var deltaEP95: Double
        var deltaEInsideWindow: Double?
        var deltaEOutsideWindow: Double?
    }

    /// Variant efter registrering: samma storlek som referensen, `valid` är falskt utanför täckningen.
    struct Registered {
        var image: Image
        var valid: [Bool]
        var registration: Registration?
    }

    // MARK: - Bildhjälp

    static func lumaPlane(_ image: Image) -> Plane {
        HDRImageOps.lumaPlane(image.pixels, width: image.width, height: image.height)
    }

    /// Skalar så att långsidan blir `maxDimension` (aldrig större än bilden).
    static func downscaled(_ image: Image, maxDimension: Int = workingDimension) -> Image {
        let size = HDRImageOps.scaledSize(width: image.width, height: image.height, maxDimension: maxDimension)
        guard size.width != image.width || size.height != image.height else { return image }
        let px = HDRImageOps.scaleRGBA(image.pixels, width: image.width, height: image.height, toWidth: size.width, toHeight: size.height)
        return Image(width: size.width, height: size.height, pixels: px)
    }

    /// Sträcker `image` till `width`×`height` (Visions registrering kräver lika stora bilder).
    static func matchSize(_ image: Image, width: Int, height: Int) -> Image {
        guard image.width != width || image.height != height else { return image }
        let px = HDRImageOps.scaleRGBA(image.pixels, width: image.width, height: image.height, toWidth: width, toHeight: height)
        return Image(width: width, height: height, pixels: px)
    }

    // MARK: - Registrering

    /// Registrerar `floating` mot `reference` med en homografi (Vision). Nil om Vision inte hittar någon.
    /// Luman exponeringsmatchas först (histogram), annars jämför Vision en mörk ram mot en ljus bild.
    static func register(floating: Image, reference: Image) -> Registration? {
        let fl = matchSize(floating, width: reference.width, height: reference.height)
        let w = reference.width, h = reference.height
        let refLuma = lumaPlane(reference).data
        let flLuma = HDRAlignment.matchHistogram(lumaPlane(fl).data, to: refLuma)
        guard let refCG = grayCGImage(refLuma, width: w, height: h),
              let flCG = grayCGImage(flLuma, width: w, height: h) else { return nil }
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: flCG, options: [:], completionHandler: nil)
        let handler = VNImageRequestHandler(cgImage: refCG, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }

        // Vision: pixlar, origo nere till vänster, kolumnvektorer, avbildar den flytande bilden på referensen.
        let m = obs.warpTransform
        var vis = simd_double3x3(
            SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
        // y_upp = (h-1) - y_ned; F är sin egen invers.
        let flip = simd_double3x3(SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, Double(h - 1), 1))
        vis = flip * vis * flip
        guard vis.columns.0.x.isFinite, abs(vis.determinant) > 1e-6 else { return nil }

        // Orimliga transformer (hörnen flyttas mer än en kvarts bild) räknas som misslyckad registrering.
        for (x, y) in [(0.0, 0.0), (Double(w - 1), 0.0), (0.0, Double(h - 1)), (Double(w - 1), Double(h - 1))] {
            let p = vis * SIMD3(x, y, 1)
            guard p.z.isFinite, abs(p.z) > 1e-9 else { return nil }
            if abs(p.x / p.z - x) > Double(w) * 0.25 || abs(p.y / p.z - y) > Double(h) * 0.25 { return nil }
        }

        var reg = Registration(transform: rowMajor(vis), residualPixels: 0, ok: false)
        let warped = warp(fl, with: vis, width: w, height: h, fill: reference)
        reg.residualPixels = translationResidual(warped.image, reference: reference) ?? .infinity
        reg.ok = reg.residualPixels <= maxRegistrationResidual
        return reg
    }

    /// Registrerar och warpar `floating` till referensens rutnät. Utan lyckad registrering returneras
    /// den storleksmatchade bilden som den är (`registration == nil`).
    static func registered(_ floating: Image, to reference: Image) -> Registered {
        let fl = matchSize(floating, width: reference.width, height: reference.height)
        guard let reg = register(floating: floating, reference: reference) else {
            return Registered(image: fl, valid: [Bool](repeating: true, count: fl.width * fl.height), registration: nil)
        }
        let result = warp(fl, with: matrix(reg.transform), width: fl.width, height: fl.height, fill: nil)
        return Registered(image: result.image, valid: result.valid, registration: reg)
    }

    private static func rowMajor(_ m: simd_double3x3) -> [Double] {
        [m.columns.0.x, m.columns.1.x, m.columns.2.x,
         m.columns.0.y, m.columns.1.y, m.columns.2.y,
         m.columns.0.z, m.columns.1.z, m.columns.2.z]
    }

    private static func matrix(_ r: [Double]) -> simd_double3x3 {
        simd_double3x3(SIMD3(r[0], r[3], r[6]), SIMD3(r[1], r[4], r[7]), SIMD3(r[2], r[5], r[8]))
    }

    /// Inverskartläggning med bilinjär sampling: utpixel (x, y) hämtas från H⁻¹·(x, y). Pixlar som
    /// hamnar utanför källan blir ogiltiga (och tas från `fill` om den finns).
    static func warp(_ source: Image, with h: simd_double3x3, width: Int, height: Int, fill: Image?) -> (image: Image, valid: [Bool]) {
        let inv = h.inverse
        let sw = source.width, sh = source.height
        var out = [Float](repeating: 0, count: width * height * 4)
        var valid = [Bool](repeating: false, count: width * height)
        source.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                valid.withUnsafeMutableBufferPointer { val in
                    for y in 0..<height {
                        for x in 0..<width {
                            let p = inv * SIMD3(Double(x), Double(y), 1)
                            let o = (y * width + x) * 4
                            guard abs(p.z) > 1e-12 else { continue }
                            let sx = p.x / p.z, sy = p.y / p.z
                            if sx < 0 || sy < 0 || sx > Double(sw - 1) || sy > Double(sh - 1) { continue }
                            let x0 = min(Int(sx), sw - 2 < 0 ? 0 : sw - 2), y0 = min(Int(sy), sh - 2 < 0 ? 0 : sh - 2)
                            let x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1)
                            let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                            for c in 0..<4 {
                                let a = src[(y0 * sw + x0) * 4 + c], b = src[(y0 * sw + x1) * 4 + c]
                                let cc = src[(y1 * sw + x0) * 4 + c], d = src[(y1 * sw + x1) * 4 + c]
                                dst[o + c] = (a * (1 - fx) + b * fx) * (1 - fy) + (cc * (1 - fx) + d * fx) * fy
                            }
                            val[y * width + x] = true
                        }
                    }
                }
            }
        }
        if let fill, fill.width == width, fill.height == height {
            for p in 0..<(width * height) where !valid[p] {
                for c in 0..<4 { out[p * 4 + c] = fill.pixels[p * 4 + c] }
            }
        }
        return (Image(width: width, height: height, pixels: out), valid)
    }

    /// Kvarvarande translation (px) mellan två redan warpade bilder, via Visions translationsregistrering.
    private static func translationResidual(_ image: Image, reference: Image) -> Double? {
        let w = reference.width, h = reference.height
        let refLuma = lumaPlane(reference).data
        let flLuma = HDRAlignment.matchHistogram(lumaPlane(image).data, to: refLuma)
        guard let refCG = grayCGImage(refLuma, width: w, height: h),
              let flCG = grayCGImage(flLuma, width: w, height: h) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: flCG, options: [:], completionHandler: nil)
        guard (try? VNImageRequestHandler(cgImage: refCG, options: [:]).perform([request])) != nil,
              let t = request.results?.first?.alignmentTransform else { return nil }
        return Double(hypot(t.tx, t.ty))
    }

    private static func grayCGImage(_ luma: [Float], width: Int, height: Int) -> CGImage? {
        let pixels8 = luma.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(pixels8) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Klippning och ton

    /// Andel (bland giltiga pixlar) med någon kanal ≥ 0,98 respektive luma ≤ 0,02.
    static func clipping(_ image: Image, valid: [Bool]? = nil) -> (highlights: Double, shadows: Double) {
        var hi = 0, lo = 0, n = 0
        for p in 0..<(image.width * image.height) {
            if let valid, !valid[p] { continue }
            let r = image.pixels[p * 4], g = image.pixels[p * 4 + 1], b = image.pixels[p * 4 + 2]
            n += 1
            if max(r, g, b) >= 0.98 { hi += 1 }
            if HDRImageOps.luma(r, g, b) <= 0.02 { lo += 1 }
        }
        guard n > 0 else { return (0, 0) }
        return (Double(hi) / Double(n), Double(lo) / Double(n))
    }

    static func tone(_ image: Image, valid: [Bool]? = nil) -> Tone {
        let luma = lumaPlane(image)
        let local = HDRImageOps.boxMean(luma, radius: 8)
        var values: [Float] = [], high: [Float] = []
        values.reserveCapacity(luma.data.count)
        for p in 0..<luma.data.count {
            if let valid, !valid[p] { continue }
            values.append(luma.data[p])
            high.append(luma.data[p] - local.data[p])
        }
        guard !values.isEmpty else { return Tone(medianLuma: 0, p5: 0, p95: 0, localContrast: 0) }
        let mean = high.reduce(0, +) / Float(high.count)
        let variance = high.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(high.count)
        return Tone(medianLuma: Double(HDRImageOps.percentile(values, 0.5)),
                    p5: Double(HDRImageOps.percentile(values, 0.05)),
                    p95: Double(HDRImageOps.percentile(values, 0.95)),
                    localContrast: Double(variance.squareRoot()))
    }

    // MARK: - Fönsterdetalj

    /// Fönstermask: klippt i referensramen men informativ (varken svart eller klippt) i den mörkaste ramen.
    static func windowMask(reference: Image, dark: Image) -> [Bool] {
        let n = reference.width * reference.height
        let d = dark.width == reference.width && dark.height == reference.height
            ? dark : matchSize(dark, width: reference.width, height: reference.height)
        let refMax = HDRImageOps.boxMean(HDRImageOps.maxChannelPlane(reference.pixels, width: reference.width, height: reference.height), radius: 1)
        var mask = [Bool](repeating: false, count: n)
        for p in 0..<n {
            let dMax = max(d.pixels[p * 4], d.pixels[p * 4 + 1], d.pixels[p * 4 + 2])
            mask[p] = refMax.data[p] >= 0.97 && dMax >= 0.08 && dMax <= 0.95
        }
        return mask
    }

    static func windowDetail(_ image: Image, mask: [Bool], dark: Image, valid: [Bool]? = nil) -> WindowDetail? {
        let n = image.width * image.height
        let d = dark.width == image.width && dark.height == image.height
            ? dark : matchSize(dark, width: image.width, height: image.height)
        var idx: [Int] = []
        for p in 0..<n where mask[p] && (valid?[p] ?? true) { idx.append(p) }
        // För litet fönster ger inga meningsfulla mått.
        guard idx.count >= max(50, n / 2000) else { return nil }
        let luma = lumaPlane(image), darkLuma = lumaPlane(d)
        var clipped = 0
        var lumas: [Float] = []
        for p in idx {
            if max(image.pixels[p * 4], image.pixels[p * 4 + 1], image.pixels[p * 4 + 2]) >= 0.98 { clipped += 1 }
            lumas.append(luma.data[p])
        }
        let gi = gradientMagnitude(luma), gd = gradientMagnitude(darkLuma)
        let corr = pearson(idx.map { gi[$0] }, idx.map { gd[$0] })
        return WindowDetail(maskFraction: Double(idx.count) / Double(n), clippedFraction: Double(clipped) / Double(idx.count),
                            lumaSpread: Double(HDRImageOps.percentile(lumas, 0.95) - HDRImageOps.percentile(lumas, 0.05)),
                            structureCorrelation: corr)
    }

    static func gradientMagnitude(_ plane: Plane) -> [Float] {
        let w = plane.width, h = plane.height
        var out = [Float](repeating: 0, count: w * h)
        guard w > 2, h > 2 else { return out }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = plane.data[y * w + x + 1] - plane.data[y * w + x - 1]
                let gy = plane.data[(y + 1) * w + x] - plane.data[(y - 1) * w + x]
                out[y * w + x] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return out
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Double(a.count)
        let ma = a.reduce(0.0) { $0 + Double($1) } / n, mb = b.reduce(0.0) { $0 + Double($1) } / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        guard saa > 1e-12, sbb > 1e-12 else { return 0 }
        return sab / (saa * sbb).squareRoot()
    }

    // MARK: - Spöken

    /// Andel 32 px-rutor där varianten är strukturellt olik referensramen: referensens luma
    /// histogrammatchas mot variantens, medelvärdet tas bort per ruta, och rutan räknas som spöke när
    /// både medelavvikelsen är hög och korrelationen låg. Plana rutor (nästan ingen kontrast) räknas inte.
    static func ghosting(_ image: Image, reference: Image, valid: [Bool]? = nil, tile: Int = 32,
                         diffThreshold: Float = 0.05, correlationThreshold: Double = 0.7) -> Double? {
        guard image.width == reference.width, image.height == reference.height else { return nil }
        let w = image.width, h = image.height
        let a = lumaPlane(image).data
        let b = HDRAlignment.matchHistogram(lumaPlane(reference).data, to: a)
        var tiles = 0, ghost = 0
        var y0 = 0
        while y0 + tile <= h {
            var x0 = 0
            while x0 + tile <= w {
                defer { x0 += tile }
                var ta: [Float] = [], tb: [Float] = []
                ta.reserveCapacity(tile * tile); tb.reserveCapacity(tile * tile)
                var ok = true
                for y in y0..<(y0 + tile) {
                    for x in x0..<(x0 + tile) {
                        if let valid, !valid[y * w + x] { ok = false; break }
                        ta.append(a[y * w + x]); tb.append(b[y * w + x])
                    }
                    if !ok { break }
                }
                guard ok else { continue }
                let ma = ta.reduce(0, +) / Float(ta.count), mb = tb.reduce(0, +) / Float(tb.count)
                var sad: Float = 0, va: Float = 0, vb: Float = 0
                for i in 0..<ta.count {
                    let da = ta[i] - ma, db = tb[i] - mb
                    sad += abs(da - db); va += da * da; vb += db * db
                }
                let sa = (va / Float(ta.count)).squareRoot(), sb = (vb / Float(ta.count)).squareRoot()
                // Båda rutorna plana: inget att jämföra.
                guard max(sa, sb) > 0.02 else { continue }
                tiles += 1
                let corr = pearson(ta, tb)
                if sad / Float(ta.count) > diffThreshold && corr < correlationThreshold { ghost += 1 }
            }
            y0 += tile
        }
        guard tiles > 0 else { return nil }
        return Double(ghost) / Double(tiles)
    }

    // MARK: - Brus

    /// Robust brus-σ: median över släta, mörka rutor (16 px, medelluma 0,05–0,25, blockmedelvärden
    /// nästan likadana) av 1,4826·MAD(Laplace)/6. 6 är normen av 3×3-Laplacekärnan [1 -2 1; -2 4 -2; 1 -2 1].
    static func noiseSigma(_ image: Image, valid: [Bool]? = nil, tile: Int = 16) -> Double? {
        let w = image.width, h = image.height
        let luma = lumaPlane(image).data
        var sigmas: [Float] = []
        var y0 = 0
        while y0 + tile <= h {
            var x0 = 0
            while x0 + tile <= w {
                defer { x0 += tile }
                var mean: Float = 0
                var ok = true
                for y in y0..<(y0 + tile) {
                    for x in x0..<(x0 + tile) {
                        if let valid, !valid[y * w + x] { ok = false }
                        mean += luma[y * w + x]
                    }
                }
                mean /= Float(tile * tile)
                guard ok, mean >= 0.05, mean <= 0.25 else { continue }
                // Slät: 4×4-blockens medelvärden varierar knappt (brus medelvärdesbildas bort, struktur inte).
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                for by in stride(from: 0, to: tile, by: 4) {
                    for bx in stride(from: 0, to: tile, by: 4) {
                        var s: Float = 0
                        for y in 0..<4 { for x in 0..<4 { s += luma[(y0 + by + y) * w + x0 + bx + x] } }
                        s /= 16
                        lo = min(lo, s); hi = max(hi, s)
                    }
                }
                guard hi - lo < 0.02 else { continue }
                var lap: [Float] = []
                for y in (y0 + 1)..<(y0 + tile - 1) {
                    for x in (x0 + 1)..<(x0 + tile - 1) {
                        let c = luma[y * w + x]
                        let edges = luma[(y - 1) * w + x] + luma[(y + 1) * w + x] + luma[y * w + x - 1] + luma[y * w + x + 1]
                        let corners = luma[(y - 1) * w + x - 1] + luma[(y - 1) * w + x + 1] + luma[(y + 1) * w + x - 1] + luma[(y + 1) * w + x + 1]
                        lap.append(4 * c - 2 * edges + corners)
                    }
                }
                let med = HDRImageOps.percentile(lap, 0.5)
                let mad = HDRImageOps.percentile(lap.map { abs($0 - med) }, 0.5)
                sigmas.append(1.4826 * mad / 6)
            }
            y0 += tile
        }
        guard sigmas.count >= 4 else { return nil }
        return Double(HDRImageOps.percentile(sigmas, 0.5))
    }

    // MARK: - Färg

    /// sRGB (gamma, 0…1) → CIE L*a*b* (D65).
    @inline(__always) static func lab(_ r: Float, _ g: Float, _ b: Float) -> (L: Double, a: Double, b: Double) {
        let lr = Double(HDRImageOps.toLinear(r)), lg = Double(HDRImageOps.toLinear(g)), lb = Double(HDRImageOps.toLinear(b))
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Medel a*/b* i nära neutrala pixlar (chroma < 12, L* 15…90): mäter färgstick.
    static func colorCast(_ image: Image, valid: [Bool]? = nil) -> ColorCast? {
        var sa = 0.0, sb = 0.0, count = 0, total = 0
        for p in stride(from: 0, to: image.width * image.height, by: 2) {
            if let valid, !valid[p] { continue }
            total += 1
            let c = lab(image.pixels[p * 4], image.pixels[p * 4 + 1], image.pixels[p * 4 + 2])
            guard c.L > 15, c.L < 90, (c.a * c.a + c.b * c.b).squareRoot() < 12 else { continue }
            sa += c.a; sb += c.b; count += 1
        }
        guard count >= 100, total > 0 else { return nil }
        return ColorCast(meanA: sa / Double(count), meanB: sb / Double(count), neutralFraction: Double(count) / Double(total))
    }

    // MARK: - ΔE2000

    /// CIEDE2000 (Sharma m.fl., 2005).
    static func deltaE2000(_ l1: (L: Double, a: Double, b: Double), _ l2: (L: Double, a: Double, b: Double)) -> Double {
        let rad = Double.pi / 180
        let c1 = (l1.a * l1.a + l1.b * l1.b).squareRoot(), c2 = (l2.a * l2.a + l2.b * l2.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + 6103515625.0)).squareRoot())
        let a1 = (1 + g) * l1.a, a2 = (1 + g) * l2.a
        let cp1 = (a1 * a1 + l1.b * l1.b).squareRoot(), cp2 = (a2 * a2 + l2.b * l2.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h >= 0 ? h : h + 360
        }
        let hp1 = hue(l1.b, a1), hp2 = hue(l2.b, a2)
        let dLp = l2.L - l1.L, dCp = cp2 - cp1
        var dhp = 0.0
        if cp1 * cp2 != 0 {
            dhp = hp2 - hp1
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (cp1 * cp2).squareRoot() * sin(dhp / 2 * rad)
        let lBar = (l1.L + l2.L) / 2, cpBar = (cp1 + cp2) / 2
        var hpBar = hp1 + hp2
        if cp1 * cp2 != 0 {
            if abs(hp1 - hp2) > 180 { hpBar += hpBar < 360 ? 360 : -360 }
            hpBar /= 2
        }
        let t = 1 - 0.17 * cos((hpBar - 30) * rad) + 0.24 * cos(2 * hpBar * rad)
            + 0.32 * cos((3 * hpBar + 6) * rad) - 0.20 * cos((4 * hpBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hpBar - 275) / 25, 2))
        let cpBar7 = pow(cpBar, 7)
        let rc = 2 * (cpBar7 / (cpBar7 + 6103515625.0)).squareRoot()
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cpBar, sh = 1 + 0.015 * cpBar * t
        let rt = -sin(2 * dTheta * rad) * rc
        let tl = dLp / sl, tc = dCp / sc, th = dHp / sh
        return (tl * tl + tc * tc + th * th + rt * tc * th).squareRoot()
    }

    /// ΔE2000 mellan två registrerade bilder av samma storlek (varannan pixel i båda led). Medel och p95
    /// över pixlar som är giltiga i båda; `windowMask` ger separat medelvärde i/utanför fönstret.
    static func pairMetrics(_ a: Registered, _ b: Registered, windowMask: [Bool]? = nil) -> PairMetrics? {
        guard a.image.width == b.image.width, a.image.height == b.image.height else { return nil }
        let w = a.image.width, h = a.image.height
        var all: [Float] = [], inside: [Float] = [], outside: [Float] = []
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let p = y * w + x
                guard a.valid[p], b.valid[p] else { continue }
                let la = lab(a.image.pixels[p * 4], a.image.pixels[p * 4 + 1], a.image.pixels[p * 4 + 2])
                let lb = lab(b.image.pixels[p * 4], b.image.pixels[p * 4 + 1], b.image.pixels[p * 4 + 2])
                let d = Float(deltaE2000(la, lb))
                all.append(d)
                if let windowMask { if windowMask[p] { inside.append(d) } else { outside.append(d) } }
            }
        }
        guard !all.isEmpty else { return nil }
        func mean(_ v: [Float]) -> Double? { v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count) }
        return PairMetrics(deltaEMean: mean(all) ?? 0, deltaEP95: Double(HDRImageOps.percentile(all, 0.95)),
                           deltaEInsideWindow: mean(inside), deltaEOutsideWindow: mean(outside))
    }

    // MARK: - Samlat

    /// Alla enskilda mått för en registrerad variant. `reference` är medianexponeringen, `dark` den
    /// mörkaste ramen (båda i arbetsstorlek, samma rutnät som `variant.image`).
    static func analyze(_ variant: Registered, reference: Image, dark: Image?, mask: [Bool]? = nil) -> VariantMetrics {
        let img = variant.image
        let clip = clipping(img, valid: variant.valid)
        var windowResult: WindowDetail?
        if let dark {
            let m = mask ?? windowMask(reference: reference, dark: dark)
            windowResult = windowDetail(img, mask: m, dark: dark, valid: variant.valid)
        }
        return VariantMetrics(registration: variant.registration,
                              clippedHighlights: clip.highlights, clippedShadows: clip.shadows,
                              window: windowResult,
                              ghostTileFraction: ghosting(img, reference: reference, valid: variant.valid),
                              noiseSigma: noiseSigma(img, valid: variant.valid),
                              colorCast: colorCast(img, valid: variant.valid),
                              tone: tone(img, valid: variant.valid))
    }
}
