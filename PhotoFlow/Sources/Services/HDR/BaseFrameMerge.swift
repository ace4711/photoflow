import Foundation

/// "Basram" (HDREngine v6): i stället för Mertens-fusion väljs en ljus exponering som bas,
/// och bara dess klippta högdagrar ersätts — pixel för pixel — av mörkare exponeringar
/// exponeringsmatchade i linjärt ljus. Toppen pressas sedan med en mjuk skuldra.
///
/// Varför: redigerarens leveranser förklaras bättre av en enda exponering med en global
/// tonkurva än av vår fusion (medelfel 0,031 mot 0,042 i luma utanför fönstren, 37
/// bracketgrupper). Fusionens grova pyramidnivåer blandar mörka ramar in i ljusa tak och
/// väggar nära fönster och lampor — "skuggan i taket" — och mättar färger. En basram har
/// varken haloeffekter eller skuggor; fönstren tas sedan från den mörkaste ramen (`WindowPull`).
///
/// Ramarna renderas utan RAW-filtrets tonkurva (`boostAmount = 0`): då är exponeringarna
/// proportionella i linjärt ljus (matchningen blir exakt) och ljusa partier som fönster blir
/// inte mjölkiga av kurvans högdagerskompression. Mellantonerna sätts i Förbättra.
///
/// Ren `nonisolated enum` utan tillstånd (testas med syntetiska bilder).
nonisolated enum BaseFrameMerge {
    typealias Plane = ExposureFusion.Plane

    struct Options: Sendable, Equatable {
        /// Basramen: den ljusaste exponeringen vars medianluma (gammakodad, linjär rendering)
        /// är högst så här. Uppmätt: leveransernas källramar har median 0,4–0,6 i den renderingen.
        var maxBaseMedian: Float = 0.6
        /// Högdageråtervinning: andelen från den mörkare ramen går mjukt från 0 vid
        /// `recoverStart` till 1 vid `recoverEnd` (max-kanal, gammakodad).
        var recoverStart: Float = 0.85
        var recoverEnd: Float = 0.97
        /// Vikterna kantbevarande utjämnade (guided filter med basens luma som guide) på
        /// ~`weightDimension` px, radie som andel av långsidan.
        var weightDimension = 1600
        var weightRadiusFraction: Double = 0.0025
        var weightEps: Float = 1e-3
        /// Skuldra på resultatet (gammakodat): identitet till `shoulderStart`, sedan mjukt mot 1.
        var shoulderStart: Float = 0.8

        init() {}
    }

    struct Result {
        var pixels: [Float]
        /// Index (i de sorterade, mörkast först) för basramen.
        var baseIndex: Int
        /// Uppmätta ljuskvoter bas/mörkare ram för de ramar som användes.
        var ratios: [Float]
    }

    /// Medianluma (gammakodad) på ett glest urval av pixlarna.
    static func medianLuma(_ pixels: [Float], width: Int, height: Int) -> Float {
        let count = width * height
        let step = max(1, count / 200_000)
        var values: [Float] = []
        values.reserveCapacity(count / step + 1)
        var i = 0
        while i < count {
            values.append(HDRImageOps.luma(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]))
            i += step
        }
        return HDRImageOps.percentile(values, 0.5)
    }

    /// Basramens index bland medianerna (sorterade mörkast först): den ljusaste med median
    /// ≤ `maxMedian`, annars den mörkaste.
    static func baseIndex(medians: [Float], maxMedian: Float) -> Int {
        var best = 0
        for (i, m) in medians.enumerated() where m <= maxMedian { best = i }
        return best
    }

    /// Ljuskvoten (linjärt) mellan en ljusare och en mörkare ram: median av lumakvoten där
    /// båda är välexponerade. 2 om underlaget är för litet.
    static func exposureRatio(bright: [Float], dark: [Float], count: Int) -> Float {
        let step = max(1, count / 300_000)
        var ratios: [Float] = []
        var i = 0
        while i < count {
            let p = i * 4
            let bMax = max(bright[p], bright[p + 1], bright[p + 2]), dMax = max(dark[p], dark[p + 1], dark[p + 2])
            if bMax < 0.9, bMax > 0.05, dMax > 0.03, dMax < 0.9 {
                let lb = HDRImageOps.toLinear(HDRImageOps.luma(bright[p], bright[p + 1], bright[p + 2]))
                let ld = HDRImageOps.toLinear(HDRImageOps.luma(dark[p], dark[p + 1], dark[p + 2]))
                if ld > 1e-4 { ratios.append(lb / ld) }
            }
            i += step
        }
        guard ratios.count >= 100 else { return 2 }
        return max(HDRImageOps.percentile(ratios, 0.5), 1)
    }

    /// Mjuk vikt för högdageråtervinningen (smoothstep).
    @inline(__always) static func recoveryWeight(_ maxChannel: Float, start: Float, end: Float) -> Float {
        let t = min(max((maxChannel - start) / max(end - start, 1e-4), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Skuldra i gammakodat: identitet till `start`, därefter `start + (1 − start)(1 − e^(−(y−start)/(1−start)))`.
    @inline(__always) static func shoulder(_ y: Float, start k: Float) -> Float {
        guard y > k else { return y }
        return k + (1 - k) * (1 - expf(-(y - k) / (1 - k)))
    }

    /// - Parameter images: registrerade exponeringar (RGBA, gammakodade, linjär rendering),
    ///   sorterade mörkast först.
    static func merge(images: [[Float]], width: Int, height: Int, options: Options = Options()) -> Result {
        let count = width * height
        guard images.count > 1 else {
            return Result(pixels: images.first ?? [], baseIndex: 0, ratios: [])
        }
        let medians = images.map { medianLuma($0, width: width, height: height) }
        let b = baseIndex(medians: medians, maxMedian: options.maxBaseMedian)
        let base = images[b]

        // Linjärt resultat (relativt basens exponering) och aktuell max-kanal (gammakodad).
        var linear = [Float](repeating: 0, count: count * 3)
        var current = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let p = i * 4
            linear[i * 3] = HDRImageOps.toLinear(base[p])
            linear[i * 3 + 1] = HDRImageOps.toLinear(base[p + 1])
            linear[i * 3 + 2] = HDRImageOps.toLinear(base[p + 2])
            current[i] = max(base[p], base[p + 1], base[p + 2])
        }

        // Guide för vikterna: basens luma på ~weightDimension px.
        let small = HDRImageOps.scaledSize(width: width, height: height, maxDimension: options.weightDimension)
        let guide = HDRImageOps.lumaPlane(HDRImageOps.scaleRGBA(base, width: width, height: height, toWidth: small.width, toHeight: small.height),
                                          width: small.width, height: small.height)
        let radius = max(1, Int((options.weightRadiusFraction * Double(max(small.width, small.height))).rounded()))

        var ratios: [Float] = []
        var cumulative: Float = 1
        var d = b - 1
        while d >= 0 {
            // Klippt andel kvar? Annars är vi klara.
            var clipped = 0
            for i in stride(from: 0, to: count, by: 16) where current[i] > options.recoverStart { clipped += 1 }
            if clipped * 16 < count / 2000 { break }
            let ratio = exposureRatio(bright: images[d + 1], dark: images[d], count: count)
            cumulative *= ratio
            ratios.append(ratio)
            // Vikter: mjuk tröskel på aktuell max-kanal, kantbevarande utjämnad.
            let weightSmall = HDRImageOps.scale(Plane(width: width, height: height,
                                                      data: current.map { recoveryWeight($0, start: options.recoverStart, end: options.recoverEnd) }),
                                                toWidth: small.width, toHeight: small.height)
            let coeffs = HDRImageOps.guidedCoefficients(guide: guide, input: weightSmall, radius: radius, eps: options.weightEps)
            let aFull = HDRImageOps.bilinear(coeffs.a, toWidth: width, toHeight: height)
            let bFull = HDRImageOps.bilinear(coeffs.b, toWidth: width, toHeight: height)
            let dark = images[d]
            for i in 0..<count {
                let p = i * 4
                let lum = HDRImageOps.luma(base[p], base[p + 1], base[p + 2])
                // Utjämnad vikt, men aldrig mindre än den råa där basen är helt klippt.
                let raw = recoveryWeight(current[i], start: options.recoverStart, end: options.recoverEnd)
                var w = min(max(aFull.data[i] * lum + bFull.data[i], 0), 1)
                if raw >= 0.999 { w = 1 }
                guard w > 1e-4 else { continue }
                for c in 0..<3 {
                    let v = HDRImageOps.toLinear(dark[p + c]) * cumulative
                    linear[i * 3 + c] = (1 - w) * linear[i * 3 + c] + w * v
                }
                current[i] = (1 - w) * current[i] + w * max(dark[p], dark[p + 1], dark[p + 2])
            }
            d -= 1
        }

        // Tillbaka till gammakodat (värden > 1 tillåts före skuldran) och skuldra.
        var out = base
        for i in 0..<count {
            let p = i * 4
            for c in 0..<3 {
                let l = linear[i * 3 + c]
                let g = l <= 1 ? HDRImageOps.toGamma(l) : 1.055 * powf(l, 1 / 2.4) - 0.055
                out[p + c] = min(shoulder(g, start: options.shoulderStart), 1)
            }
        }
        return Result(pixels: out, baseIndex: b, ratios: ratios)
    }
}
