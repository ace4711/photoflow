import Foundation

/// Tonsättning av en **scenlinjär** HDR-bild (radianssammanslagningen i `RadianceMerge`, eller en
/// flyttals-DNG från Lightrooms HDR-sammanslagning) till en gammakodad bild som liknar basramens
/// utdata — det Förbättra/Mäklarstil är inställt för.
///
/// 1. **Exponering ur bildens egen statistik**: en förstärkning som för interiörens medianluminans
///    till `targetMedian` (gammakodat). Fönster och lampor räknas inte (luminans över
///    `excludeAboveMedian` × medianen). En BaselineExposure (DNG) används som prior: statistiken
///    får avvika högst `maxDeviationEV` från den.
/// 2. **Högdagerskuldra** på luminansen: identitet upp till knät, sedan en utökad Reinhard-kurva
///    som når 1 vid vitpunkten (en hög percentil av luminansen). RGB skalas med samma faktor
///    (nyans och mättnad bevaras) och det som ändå hamnar över 1 avmättas mot luminansen tills
///    det ryms (ingen färgförskjutning vid klippning).
/// 3. **Slöja** (`dehaze`): utsikten genom glaset har en additiv slöja (ströljus) som syns som
///    mjölkig utsikt i en linjär rendering (CIRAWFilters kurva döljer den med sin tå). Den dras av
///    i radiansen där det är ljust och strukturerat — utan fönstermask.
///
/// Fönstren görs **inte** mörkare än väggarna: lövverket utanför har ungefär samma radians som
/// väggarna inne (uppmätt i LR-DNG:n för DSC_6385: utsiktens median +1 EV över rummets), så det
/// kräver fönstermasker (prövat med window pull-detekteringen på radiansen: band och gråa rutor).
///
/// Ren `nonisolated enum` utan tillstånd (testas med syntetiska bilder).
nonisolated enum SceneLinearTone {
    struct Options: Sendable, Equatable {
        /// Interiörens medianluma efter tonsättningen (gammakodad). Basramens indata ligger på
        /// 0,4–0,6; Mäklarstilens kurva tar den sedan mot leveransernas 0,685.
        var targetMedian: Float = 0.50
        /// Pixlar ljusare än så här många gånger medianen räknas inte i exponeringen (fönster, lampor).
        var excludeAboveMedian: Float = 6
        /// Knät (linjärt, efter förstärkningen) där skuldran börjar: ≈ gammakodat 0,74.
        var knee: Float = 0.5
        /// Vitpunkten: denna percentil av luminansen (efter förstärkningen) når 1, men minst `minWhite`.
        var whitePercentile: Double = 0.999
        var minWhite: Float = 1.5
        /// Största avvikelse (EV) från priorn (BaselineExposure) när en sådan finns.
        var maxDeviationEV: Double = 3
        /// Förstärkningens absoluta gränser (EV).
        var minEV: Double = -4
        var maxEV: Double = 8
        /// Slöjborttagning i radiansen (`dehaze`): andel av den skattade slöjan som dras av (0 = av).
        var dehazeStrength: Float = 0.9
        /// Grindar: struktur (lokal std av log2-luminans, EV), ljushet (lokalt medel över interiörens
        /// median, EV) och slöjans andel av det lokala medlet.
        var dehazeTexture: ClosedRange<Float> = 0.15...0.35
        var dehazeBrightEV: ClosedRange<Float> = 0...1
        var dehazeVeil: ClosedRange<Float> = 0.12...0.30

        init() {}
    }

    struct Info: Sendable, Equatable, Codable {
        /// Förstärkningen (EV) som tillämpades före skuldran.
        var gainEV: Double
        /// Interiörens medianluminans (linjär) före förstärkningen.
        var medianLinear: Double
        /// Vitpunkten (linjär luminans efter förstärkningen).
        var white: Double
        /// Priorn (BaselineExposure) om den fanns.
        var priorEV: Double?
        /// Andel av bilden där slöjan togs bort.
        var dehazedFraction: Double = 0
    }

    @inline(__always) static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Glest urval av luminansen (linjär, ≥ 0).
    static func sampleLuminance(_ pixels: [Float], width: Int, height: Int, maxSamples: Int = 250_000) -> [Float] {
        let count = width * height
        let step = max(1, count / maxSamples)
        var values: [Float] = []
        values.reserveCapacity(count / step + 1)
        var i = 0
        while i < count {
            values.append(max(luminance(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]), 0))
            i += step
        }
        return values
    }

    /// Interiörens medianluminans: medianen av pixlarna under `excludeAboveMedian` × medianen.
    static func interiorMedian(_ samples: [Float], excludeAboveMedian: Float) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let limit = median * excludeAboveMedian
        var hi = sorted.count
        while hi > 1 && sorted[hi - 1] > limit { hi -= 1 }
        return sorted[hi / 2]
    }

    /// Förstärkningen (EV) som för `medianLinear` till `targetMedian` (gammakodat), inom gränserna.
    static func gainEV(medianLinear: Float, priorEV: Double?, options: Options) -> Double {
        let target = Double(HDRImageOps.toLinear(options.targetMedian))
        var ev = log2(target / Double(max(medianLinear, 1e-7)))
        if let priorEV {
            ev = min(max(ev, priorEV - options.maxDeviationEV), priorEV + options.maxDeviationEV)
        }
        return min(max(ev, options.minEV), options.maxEV)
    }

    /// Skuldran på luminansen (linjärt): identitet till `knee`, därefter utökad Reinhard på
    /// överskottet så att `white` → 1 med lutningen 1 i knät (kontinuerlig och monoton).
    @inline(__always) static func shoulder(_ x: Float, knee k: Float, white w: Float) -> Float {
        guard x > k else { return x }
        let span = 1 - k
        let u = (x - k) / span
        let uw = max((w - k) / span, 1e-3)
        return k + span * min(u * (1 + u / (uw * uw)) / (1 + u), 1)
    }

    /// Tonsätter `linear` (RGBA, scenlinjärt, valfri skala) → RGBA gammakodat 0…1.
    static func apply(linear: [Float], width: Int, height: Int, priorEV: Double? = nil,
                      options: Options = Options()) -> (pixels: [Float], info: Info) {
        var pixels = linear
        let info = applyInPlace(&pixels, width: width, height: height, priorEV: priorEV, options: options)
        return (pixels, info)
    }

    /// Som `apply`, men skriver resultatet i samma buffert (sparar två fullstora kopior i HDR-steget).
    static func applyInPlace(_ linear: inout [Float], width: Int, height: Int, priorEV: Double? = nil,
                             options: Options = Options()) -> Info {
        let samples = sampleLuminance(linear, width: width, height: height)
        let median = interiorMedian(samples, excludeAboveMedian: options.excludeAboveMedian)
        let dehazed = dehaze(&linear, width: width, height: height, interiorMedian: median, options: options)
        let ev = gainEV(medianLinear: median, priorEV: priorEV, options: options)
        let gain = Float(pow(2.0, ev))
        let white = max(HDRImageOps.percentile(samples, options.whitePercentile) * gain, options.minWhite)
        let knee = min(options.knee, white * 0.9)

        linear.withUnsafeMutableBufferPointer { buf in
            let px = HDRImageOps.Shared(buf)
            let rows = 64
            DispatchQueue.concurrentPerform(iterations: (height + rows - 1) / rows) { block in
                let y0 = block * rows, y1 = min(height, y0 + rows)
                for i in (y0 * width)..<(y1 * width) {
                    let p = i * 4
                    var r = max(px[p], 0) * gain, g = max(px[p + 1], 0) * gain, b = max(px[p + 2], 0) * gain
                    let y = luminance(r, g, b)
                    if y > knee {
                        let s = shoulder(y, knee: knee, white: white) / y
                        r *= s; g *= s; b *= s
                    }
                    // Över 1 i någon kanal: avmätta mot luminansen tills den ryms.
                    let mx = max(r, g, b)
                    if mx > 1 {
                        let ly = min(luminance(r, g, b), 1)
                        let t = mx - ly > 1e-6 ? (1 - ly) / (mx - ly) : 0
                        r = ly + (r - ly) * t; g = ly + (g - ly) * t; b = ly + (b - ly) * t
                    }
                    px[p] = HDRImageOps.toGamma(min(r, 1))
                    px[p + 1] = HDRImageOps.toGamma(min(g, 1))
                    px[p + 2] = HDRImageOps.toGamma(min(b, 1))
                    px[p + 3] = 1
                }
            }
        }
        return Info(gainEV: ev, medianLinear: Double(median), white: Double(white), priorEV: priorEV, dehazedFraction: dehazed)
    }

    /// Tar bort slöjan (strålningsslöja från glaset, ströljus i objektivet) i radiansen, linjärt:
    /// `R − V` per kanal, där V = mörka kanalens prior (lokalt minimum av min-kanalen, kantbevarande
    /// utjämnat med log-luminansen som guide). Verkar bara där det finns struktur (lövverk — släta
    /// väggar har inga mörka pixlar och skulle annars mörkna), där det är ljust (lokalt medel minst
    /// ungefär interiörens median: utsikten, inte mönstrade textilier i rummet) och där slöjan är en
    /// tydlig andel av ljuset. Ingen mask: V är mjuk och följer karmarnas kanter.
    /// Returnerar andelen av bilden som påverkades.
    @discardableResult
    static func dehaze(_ linear: inout [Float], width: Int, height: Int, interiorMedian: Float,
                       options: Options = Options(), dimension: Int = 1500) -> Double {
        guard options.dehazeStrength > 0, width > 16, height > 16 else { return 0 }
        let s = HDRImageOps.scaledSize(width: width, height: height, maxDimension: dimension)
        let small = HDRImageOps.scaleRGBA(linear, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let n = s.width * s.height
        var minC = [Float](repeating: 0, count: n), y = [Float](repeating: 0, count: n)
        var logY = [Float](repeating: 0, count: n), logSq = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = max(small[i * 4], 0), g = max(small[i * 4 + 1], 0), b = max(small[i * 4 + 2], 0)
            minC[i] = min(r, g, b)
            y[i] = luminance(r, g, b)
            logY[i] = log2f(max(y[i], 1e-7))
            logSq[i] = logY[i] * logY[i]
        }
        let scale = Double(max(s.width, s.height)) / 1600
        let patch = max(2, Int((7 * scale).rounded()))
        let dark = HDRImageOps.morph(ExposureFusion.Plane(width: s.width, height: s.height, data: minC), radius: patch, dilate: false)
        let guide = ExposureFusion.Plane(width: s.width, height: s.height, data: logY)
        let coeffs = HDRImageOps.guidedCoefficients(guide: guide, input: dark, radius: patch * 2, eps: 0.05)
        let meanY = HDRImageOps.boxMean(ExposureFusion.Plane(width: s.width, height: s.height, data: y), radius: patch * 2)
        let meanLog = HDRImageOps.boxMean(guide, radius: patch)
        let meanLogSq = HDRImageOps.boxMean(ExposureFusion.Plane(width: s.width, height: s.height, data: logSq), radius: patch)
        let medianLog = log2f(max(interiorMedian, 1e-7))
        var q = [Float](repeating: 0, count: n), veil = [Float](repeating: 0, count: n)
        func ramp(_ x: Float, _ r: ClosedRange<Float>) -> Float { min(max((x - r.lowerBound) / max(r.upperBound - r.lowerBound, 1e-4), 0), 1) }
        for i in 0..<n {
            let v = max(coeffs.a.data[i] * logY[i] + coeffs.b.data[i], 0)
            let sd = max(meanLogSq.data[i] - meanLog.data[i] * meanLog.data[i], 0).squareRoot()
            let texture = ramp(sd, options.dehazeTexture)
            let bright = ramp(log2f(max(meanY.data[i], 1e-7)) - medianLog, options.dehazeBrightEV)
            let strong = ramp(v / max(meanY.data[i], 1e-7), options.dehazeVeil)
            q[i] = texture * bright * strong
            veil[i] = min(v, meanY.data[i])
        }
        // Mjuka övergångar (två boxpass ≈ gauss).
        let soft = HDRImageOps.boxMean(HDRImageOps.boxMean(ExposureFusion.Plane(width: s.width, height: s.height, data: q), radius: patch * 2), radius: patch * 2)
        var vq = [Float](repeating: 0, count: n)
        var touched = 0
        for i in 0..<n {
            vq[i] = options.dehazeStrength * soft.data[i] * veil[i]
            if soft.data[i] > 0.1 { touched += 1 }
        }
        guard touched > 0 else { return 0 }
        let full = HDRImageOps.bilinear(ExposureFusion.Plane(width: s.width, height: s.height, data: vq), toWidth: width, toHeight: height)
        linear.withUnsafeMutableBufferPointer { oBuf in
            full.data.withUnsafeBufferPointer { vBuf in
                let o = HDRImageOps.Shared(oBuf), vv = HDRImageOps.Shared(vBuf)
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    for x in 0..<width {
                        let p = row * width + x
                        let v = vv[p]
                        guard v > 0 else { continue }
                        for c in 0..<3 { o[p * 4 + c] = max(o[p * 4 + c] - v, 0) }
                    }
                }
            }
        }
        return Double(touched) / Double(n)
    }
}
