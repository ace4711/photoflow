import Foundation

/// "Lightroom-lik framkallning" (HDR v8, docs/plan-hdr-v8-framkallning.md): tonsätter en
/// **scenlinjär** radiansbild (`RadianceMerge`) med **lokal** tonkompression i stället för
/// `SceneLinearTone`s globala skuldra.
///
/// 1. **Bas/detalj i log-luminans**: `l = log2(Y)`. Basen är ett kantbevarande guided filter av `l`
///    (räknat på en nedskalad bild; koefficienterna `a`, `b` interpoleras bilinjärt och tillämpas på
///    fullupplöst `l` — "fast guided filter"), detaljen är `l − bas`. Stora ljushetssprång (fönster
///    mot vägg, 3–6 EV) hamnar i basen, textur (löv, kakel, tyg) i detaljen.
/// 2. **Kompression av basen** runt bildens mitt (EV relativt målmedianen): högdagrar över
///    `highlightStart` närmar sig `highlightStart + highlightRange` (exponentiell skuldra, lutning 1 i
///    knät), skuggor under 0 närmar sig `−shadowRange`. Detaljen läggs tillbaka förstärkt
///    (`detail`, "Texture/Clarity") — utsikten behåller sin struktur fast basen trycks ihop, och rummet
///    blir inte platt som med en global kurva.
/// 3. **Svart- och vitpunkt**: en mjuk tå drar av `blackClip`-percentilen (riktiga svärtor, som LR:s
///    Blacks −22) och en utökad Reinhard-skuldra för `whiteClip`-percentilen till 1 (små klippta
///    kärnor i sol och lampor i stället för stora halos, som LR:s Whites +15).
/// 4. **Global kontrast** i gammakodat (mild S-kurva runt `contrastPivot`) och **vibrance/mättnad**.
/// 5. **Färg**: luminansen ändras genom att RGB skalas med samma faktor (kulören och mättnaden
///    bevaras, himlen förblir blå när den trycks ned); det som hamnar över 1 avmättas mot luminansen.
///
/// Exponeringen kalibreras så att hela bildens medianluma efter tonsättningen blir `targetMedian`
/// (Lightroom Auto: medianluma ≈ 0,47 i testsetet), med bisektion på en nedskalad bild som går genom
/// exakt samma kurvor.
///
/// Ren `nonisolated enum` utan tillstånd (testas med syntetiska bilder).
nonisolated enum SceneLinearLocalTone {
    typealias Plane = ExposureFusion.Plane

    struct Options: Sendable, Equatable {
        /// Hela bildens medianluma efter tonsättningen (gammakodad).
        var targetMedian: Float = 0.47
        /// Basens arbetsupplösning (lång sida) och guided filtrets radie som andel av den.
        var baseDimension = 1024
        var baseRadiusFraction: Float = 0.03
        /// Guided filtrets eps i (EV)²: variation under ≈ √eps EV räknas som detalj.
        var baseEps: Float = 0.25
        /// Basens högdagerskuldra (EV över målmedianen): knä och största tillägg ovanför knät.
        var highlightStart: Float = 0.7
        var highlightRange: Float = 1.6
        /// Basens skuggtak (EV under målmedianen): skuggorna närmar sig −shadowRange.
        var shadowRange: Float = 4.5
        /// Detaljförstärkning (1 = oförändrad).
        var detail: Float = 1.25
        /// Under så här många EV under medianen tonas detaljförstärkningen ut (brus i djupa skuggor).
        var detailShadowEV: ClosedRange<Float> = -5 ... -3
        /// Andel pixlar som får bli helt svarta resp. når 1.
        var blackClip: Double = 0.002
        var whiteClip: Double = 0.004
        /// Vitpunktens tak: basens kompressionstak (`highlightStart + highlightRange`) plus så här många
        /// EV — fönster och himmel hamnar under vitt med detaljen kvar, i stället för att percentilen
        /// lägger dem på 1 när de är en stor del av bilden.
        var whiteMarginEV: Float = 0.5
        /// Skuldrans knä (linjär luminans) före vitpunkten.
        var shoulderKnee: Float = 0.6
        /// Global S-kurva i gammakodat: styrka och vändpunkt.
        var contrast: Float = 0.18
        var contrastPivot: Float = 0.45
        /// Mättnad (multiplikativ, 1 = oförändrad) och vibrance (extra för omättade färger).
        var saturation: Float = 1.03
        var vibrance: Float = 0.15
        /// Exponeringens gränser (EV, relativt interiörens median → 18 % grå).
        var maxCalibrationEV: Float = 3
        /// Färgkantsdämpning (LR: Defringe) i ljusa partier: lila/magenta (min(R,B) > G) dras mot
        /// neutralt där basen ligger `defringeEV` över 18 % grå — objektivets färgkanter runt utblåst
        /// himmel bakom löv syns först när fönstren inte längre klipps. 0 = av.
        var defringe: Float = 1
        var defringeEV: ClosedRange<Float> = 1.0 ... 2.0
        /// Slöjborttagning i radiansen före tonsättningen (`SceneLinearTone.dehaze`, utsikten genom
        /// glaset): andel av den skattade slöjan. 0 = av.
        var dehaze: Float = 0
        /// Mättnadsexponent där basen tryckts ned (1,5 EV över `highlightStart` och uppåt): 1 = kromat bevaras.
        var highlightSaturation: Float = 0.7

        init() {}

        /// Sätter en parameter efter namn (utvärdering: `photoflow-cli hdr --tone nyckel=värde`).
        /// Returnerar false för okända nycklar.
        mutating func set(_ key: String, _ value: Double) -> Bool {
            let f = Float(value)
            switch key {
            case "targetMedian": targetMedian = f
            case "baseDimension": baseDimension = Int(value)
            case "baseRadiusFraction": baseRadiusFraction = f
            case "baseEps": baseEps = f
            case "highlightStart": highlightStart = f
            case "highlightRange": highlightRange = f
            case "shadowRange": shadowRange = f
            case "detail": detail = f
            case "blackClip": blackClip = value
            case "whiteClip": whiteClip = value
            case "whiteMarginEV": whiteMarginEV = f
            case "shoulderKnee": shoulderKnee = f
            case "contrast": contrast = f
            case "contrastPivot": contrastPivot = f
            case "saturation": saturation = f
            case "vibrance": vibrance = f
            case "defringe": defringe = f
            case "dehaze": dehaze = f
            case "highlightSaturation": highlightSaturation = f
            default: return false
            }
            return true
        }
    }

    struct Info: Sendable, Equatable, Codable {
        /// Förstärkningen (EV) som lades på före tonsättningen (log2 av multiplikatorn på radiansen).
        var gainEV: Double
        /// Svartpunkt och vitpunkt (linjär luminans efter lokalkompressionen).
        var black: Double
        var white: Double
        /// Medianluma (gammakodad) som kalibreringen uppnådde på den nedskalade bilden.
        var calibratedMedian: Double
        /// Basens omfång före och efter kompressionen (EV, p1–p99.5).
        var baseRangeEV: Double
        var compressedRangeEV: Double
    }

    // MARK: - Kurvorna (per pixel, rena)

    /// Basens kompression (EV relativt målmedianen): lutning 1 i [0, hs], exponentiella asymptoter utanför.
    @inline(__always) static func compressBase(_ b: Float, highlightStart hs: Float, highlightRange hr: Float, shadowRange sr: Float) -> Float {
        if b > hs { return hs + hr * (1 - expf(-(b - hs) / max(hr, 1e-3))) }
        if b < 0 { return -sr * (1 - expf(b / max(sr, 1e-3))) }
        return b
    }

    /// Mjuk tå: `x − k(1 − e^{−x/k})` — 0 i 0, lutning 0 i 0, närmar sig `x − k` (svartpunkten dras av).
    @inline(__always) static func toe(_ x: Float, black k: Float) -> Float {
        guard k > 1e-7 else { return max(x, 0) }
        let xc = max(x, 0)
        return xc - k * (1 - expf(-xc / k))
    }

    /// Mild S-kurva i gammakodat runt `pivot` (monoton för `strength` ≤ 0,5): oförändrad i 0, pivot och 1.
    @inline(__always) static func sCurve(_ v: Float, strength k: Float, pivot p: Float) -> Float {
        let c = min(max(v, 0), 1)
        // Två halvor med samma form: t ∈ [0,1] inom halvan, f(t) = t + k·t(1−t)·(±1).
        if c < p {
            let t = c / max(p, 1e-4)
            return p * (t - k * t * (1 - t))
        } else {
            let t = (c - p) / max(1 - p, 1e-4)
            return p + (1 - p) * (t + k * t * (1 - t))
        }
    }

    /// Hela luminanskedjan för en pixel: log-luminans `l` (EV relativt 18 % grå efter förstärkning) och
    /// basen `base` (samma skala) → linjär luminans före svart/vit (`Y'`).
    @inline(__always) static func localLuminance(l: Float, base: Float, options o: Options) -> Float {
        let cb = compressBase(base, highlightStart: o.highlightStart, highlightRange: o.highlightRange, shadowRange: o.shadowRange)
        let lo = o.detailShadowEV.lowerBound, hi = o.detailShadowEV.upperBound
        let t = min(max((base - lo) / max(hi - lo, 1e-3), 0), 1)
        let gain = 1 + (o.detail - 1) * t * t * (3 - 2 * t)
        return midGray * exp2f(cb + gain * (l - base))
    }

    /// Från `Y'` (linjär) till slutlig gammakodad luma: tå, skuldra, gamma, S-kurva.
    @inline(__always) static func finishLuma(_ y: Float, black: Float, white: Float, options o: Options) -> Float {
        let toed = toe(y, black: black)
        let w = max(toe(white, black: black), 1e-4)
        let knee = min(o.shoulderKnee, w * 0.9)
        let shoulder = toed > knee ? SceneLinearTone.shoulder(toed, knee: knee, white: w) : toed
        return sCurve(HDRImageOps.toGamma(min(shoulder, 1)), strength: o.contrast, pivot: o.contrastPivot)
    }

    /// 18 % grå: där basens kompression har sin nollpunkt.
    static let midGray: Float = 0.18

    // MARK: - Basen

    /// Guided filter-koefficienter för log-luminansen på en nedskalad bild. `logSmall` är log2-luminansen.
    static func baseCoefficients(logSmall: Plane, options: Options) -> (a: Plane, b: Plane) {
        let radius = max(2, Int((Float(max(logSmall.width, logSmall.height)) * options.baseRadiusFraction).rounded()))
        return HDRImageOps.guidedCoefficients(guide: logSmall, input: logSmall, radius: radius, eps: options.baseEps)
    }

    @inline(__always) static func logLuminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        log2f(max(SceneLinearTone.luminance(max(r, 0), max(g, 0), max(b, 0)), 1e-6))
    }

    // MARK: - Tonsättning

    /// Tonsätter `linear` (RGBA, scenlinjärt, valfri skala) → RGBA gammakodat 0…1, i samma buffert.
    ///
    /// - Parameter clipCeiling: radiansens tak (den mörkaste ramens klippnivå i bildens skala, `1 / kvot`).
    ///   Pixlar nära taket är klippta i alla ramar; där en kanal klippt före de andra blir kulören fel
    ///   (rosa kanter runt utblåst himmel) — de avmättas mot max-kanalen (vitt) när de närmar sig taket.
    @discardableResult
    static func applyInPlace(_ linear: inout [Float], width: Int, height: Int, clipCeiling: Float? = nil,
                             options o: Options = Options()) -> Info {
        guard width > 0, height > 0 else { return Info(gainEV: 0, black: 0, white: 1, calibratedMedian: 0, baseRangeEV: 0, compressedRangeEV: 0) }
        // 0. Slöjan i utsikten (strålningsslöja/ströljus) dras av i radiansen.
        if o.dehaze > 0 {
            let s0 = HDRImageOps.scaledSize(width: width, height: height, maxDimension: 1000)
            let probe = HDRImageOps.scaleRGBA(linear, width: width, height: height, toWidth: s0.width, toHeight: s0.height)
            let med = SceneLinearTone.interiorMedian(SceneLinearTone.sampleLuminance(probe, width: s0.width, height: s0.height),
                                                     excludeAboveMedian: 6)
            var dh = SceneLinearTone.Options()
            dh.dehazeStrength = o.dehaze
            SceneLinearTone.dehaze(&linear, width: width, height: height, interiorMedian: med, options: dh)
        }
        // 1. Nedskalad bild: log-luminans, guided filter-koefficienter, kalibrering.
        let s = HDRImageOps.scaledSize(width: width, height: height, maxDimension: o.baseDimension)
        let small = HDRImageOps.scaleRGBA(linear, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let sn = s.width * s.height
        var logSmall = [Float](repeating: 0, count: sn)
        for i in 0..<sn { logSmall[i] = logLuminance(small[i * 4], small[i * 4 + 1], small[i * 4 + 2]) }
        let samplesLin = SceneLinearTone.sampleLuminance(small, width: s.width, height: s.height, maxSamples: 200_000)
        let interior = SceneLinearTone.interiorMedian(samplesLin, excludeAboveMedian: 6)
        // Förstärkning så att interiörens median hamnar på 18 % grå (startpunkt för kalibreringen).
        let startOffset = log2f(midGray / max(interior, 1e-7))

        let coeffs = baseCoefficients(logSmall: Plane(width: s.width, height: s.height, data: logSmall), options: o)
        // Glest urval för kalibreringen (l och bas, i log2 utan förstärkning).
        let step = max(1, sn / 120_000)
        var calL: [Float] = [], calB: [Float] = []
        calL.reserveCapacity(sn / step + 1); calB.reserveCapacity(sn / step + 1)
        var i = 0
        while i < sn {
            calL.append(logSmall[i])
            calB.append(coeffs.a.data[i] * logSmall[i] + coeffs.b.data[i])
            i += step
        }
        // En förstärkning (EV) → svartpunkt, vitpunkt och resulterande medianluma.
        func evaluate(_ offset: Float) -> (black: Float, white: Float, median: Float) {
            let shift = offset - log2f(midGray)
            var ys = [Float](repeating: 0, count: calL.count)
            for k in 0..<calL.count { ys[k] = localLuminance(l: calL[k] + shift, base: calB[k] + shift, options: o) }
            let sorted = ys.sorted()
            func pct(_ q: Double) -> Float { sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * q)))] }
            let black = pct(o.blackClip)
            let ceiling = midGray * exp2f(o.highlightStart + o.highlightRange + o.whiteMarginEV)
            let white = max(min(pct(1 - o.whiteClip), ceiling), black * 4 + 0.05)
            let median = finishLuma(pct(0.5), black: black, white: white, options: o)
            return (black, white, median)
        }
        var lo = startOffset - o.maxCalibrationEV, hi = startOffset + o.maxCalibrationEV
        var offset = startOffset
        var result = evaluate(offset)
        for _ in 0..<14 {
            if result.median < o.targetMedian { lo = offset } else { hi = offset }
            offset = (lo + hi) / 2
            result = evaluate(offset)
        }
        let black = result.black, white = result.white
        let shift = offset - log2f(midGray)   // l + shift = EV relativt 18 % grå efter förstärkningen
        var bases = calB.map { $0 + shift }
        bases.sort()
        func pct(_ v: [Float], _ q: Double) -> Float { v[min(v.count - 1, max(0, Int(Double(v.count - 1) * q)))] }
        let rangeBefore = pct(bases, 0.995) - pct(bases, 0.01)
        let comp = { (b: Float) in compressBase(b, highlightStart: o.highlightStart, highlightRange: o.highlightRange, shadowRange: o.shadowRange) }
        let rangeAfter = comp(pct(bases, 0.995)) - comp(pct(bases, 0.01))

        // 2. Full upplösning: basen ur de bilinjärt samplade koefficienterna, sedan hela kedjan per pixel.
        let sw = s.width, sh = s.height
        let sx = Float(sw) / Float(width), sy = Float(sh) / Float(height)
        let vib = o.vibrance, sat = o.saturation
        let dfr = min(max(o.defringe, 0), 1), dfLo = o.defringeEV.lowerBound, dfHi = max(o.defringeEV.upperBound, o.defringeEV.lowerBound + 0.01)
        let ceilLo = (clipCeiling ?? .infinity) * 0.70, ceilHi = (clipCeiling ?? .infinity) * 0.92
        linear.withUnsafeMutableBufferPointer { buf in
            coeffs.a.data.withUnsafeBufferPointer { aBuf in
                coeffs.b.data.withUnsafeBufferPointer { bBuf in
                    let px = HDRImageOps.Shared(buf), ca = HDRImageOps.Shared(aBuf), cb = HDRImageOps.Shared(bBuf)
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
                        let y0 = min(Int(fy), sh - 1), y1 = min(y0 + 1, sh - 1)
                        let ty = fy - Float(y0)
                        for x in 0..<width {
                            let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                            let x0 = min(Int(fx), sw - 1), x1 = min(x0 + 1, sw - 1)
                            let tx = fx - Float(x0)
                            let i00 = y0 * sw + x0, i01 = y0 * sw + x1, i10 = y1 * sw + x0, i11 = y1 * sw + x1
                            let a = (ca[i00] * (1 - tx) + ca[i01] * tx) * (1 - ty) + (ca[i10] * (1 - tx) + ca[i11] * tx) * ty
                            let b = (cb[i00] * (1 - tx) + cb[i01] * tx) * (1 - ty) + (cb[i10] * (1 - tx) + cb[i11] * tx) * ty
                            let p = (y * width + x) * 4
                            var r = max(px[p], 0), g = max(px[p + 1], 0), bl = max(px[p + 2], 0)
                            let m0 = max(r, g, bl)
                            if m0 > ceilLo {
                                let u = min((m0 - ceilLo) / (ceilHi - ceilLo), 1)
                                let t = u * u * (3 - 2 * u)
                                r += (m0 - r) * t; g += (m0 - g) * t; bl += (m0 - bl) * t
                            }
                            var yIn = max(SceneLinearTone.luminance(r, g, bl), 1e-6)
                            let l = log2f(yIn)
                            let base = a * l + b
                            if dfr > 0 {
                                let m = min(r, bl) - g
                                if m > 0 {
                                    let u = min(max((base + shift - dfLo) / (dfHi - dfLo), 0), 1)
                                    let k = dfr * u * u * (3 - 2 * u)
                                    if k > 0 {
                                        // Avmätta mot luminansen (luminansen behålls) — mer ju större
                                        // magentaandelen är av pixelns kroma.
                                        let chroma = max(r, g, bl) - min(r, g, bl)
                                        let share = min(2 * m / max(chroma, 1e-6), 1)
                                        let t = k * share
                                        r += (yIn - r) * t; g += (yIn - g) * t; bl += (yIn - bl) * t
                                        yIn = max(SceneLinearTone.luminance(r, g, bl), 1e-6)
                                    }
                                }
                            }
                            let yLocal = localLuminance(l: l + shift, base: base + shift, options: o)
                            let outGamma = finishLuma(yLocal, black: black, white: white, options: o)
                            let yOut = HDRImageOps.toLinear(outGamma)
                            // Färgkorrigering (Mantiuk/Schlick): (C/Y)^s · Y'. s = 1 bevarar kromat helt;
                            // där basen tryckts ned (fönster, himmel) ger s < 1 mindre mättnad —
                            // annars blir sammanpressade högdagrar neonfärgade.
                            let hb = base + shift - o.highlightStart
                            let su = min(max(hb / 1.5, 0), 1)
                            let sExp = 1 + (o.highlightSaturation - 1) * su * su * (3 - 2 * su)
                            if sExp < 0.999 {
                                r = powf(r / yIn, sExp); g = powf(g / yIn, sExp); bl = powf(bl / yIn, sExp)
                                let yn = max(SceneLinearTone.luminance(r, g, bl), 1e-6)
                                let k = yOut / yn
                                r *= k; g *= k; bl *= k
                            } else {
                                let k = yOut / yIn
                                r *= k; g *= k; bl *= k
                            }
                            // Över 1: avmätta mot luminansen tills det ryms (ingen kulörförskjutning).
                            let mx = max(r, g, bl)
                            if mx > 1 {
                                let ly = min(SceneLinearTone.luminance(r, g, bl), 1)
                                let t = mx - ly > 1e-6 ? (1 - ly) / (mx - ly) : 0
                                r = ly + (r - ly) * t; g = ly + (g - ly) * t; bl = ly + (bl - ly) * t
                            }
                            var gr = HDRImageOps.toGamma(min(r, 1)), gg = HDRImageOps.toGamma(min(g, 1)), gb = HDRImageOps.toGamma(min(bl, 1))
                            // Mättnad och vibrance i gammakodat, runt pixelns luma.
                            let gmax = max(gr, gg, gb), gmin = min(gr, gg, gb)
                            if gmax > 1e-4 {
                                let s0 = (gmax - gmin) / gmax
                                var f = sat + vib * (1 - s0) * (1 - s0)
                                let gl = SceneLinearTone.luminance(gr, gg, gb)
                                // Taket: ingen kanal under 0 eller över 1.
                                let up = gmax - gl > 1e-5 ? (1 - gl) / (gmax - gl) : f
                                let down = gl - gmin > 1e-5 ? gl / (gl - gmin) : f
                                f = min(f, up, down)
                                gr = gl + (gr - gl) * f; gg = gl + (gg - gl) * f; gb = gl + (gb - gl) * f
                            }
                            px[p] = min(max(gr, 0), 1); px[p + 1] = min(max(gg, 0), 1); px[p + 2] = min(max(gb, 0), 1)
                            px[p + 3] = 1
                        }
                    }
                }
            }
        }
        return Info(gainEV: Double(offset),
                    black: Double(black), white: Double(white), calibratedMedian: Double(result.median),
                    baseRangeEV: Double(rangeBefore), compressedRangeEV: Double(rangeAfter))
    }

    static func apply(linear: [Float], width: Int, height: Int, options: Options = Options()) -> (pixels: [Float], info: Info) {
        var pixels = linear
        let info = applyInPlace(&pixels, width: width, height: height, options: options)
        return (pixels, info)
    }
}
