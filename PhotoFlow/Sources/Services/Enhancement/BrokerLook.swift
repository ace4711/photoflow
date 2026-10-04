import Foundation
import CoreImage

/// "Mäklarstil": härmar redigerarens leveranser (uppmätt på parade bilder, se
/// `docs/plan-maklarstil.md`). I stället för fasta reglage normaliseras varje bild
/// mot leveransernas *målstatistik*, som visade sig vara mycket konsekvent mellan
/// bilder (ljus, luftig "high key"):
/// - **Tonkurva** genom bildens luma-percentiler (1, 5, 25, 50, 75, 95, 99 %) mot
///   målpercentilerna (`targetPercentiles`), monoton kubisk (Fritsch–Carlson), med
///   taket `whiteCeiling` (leveranserna klipper nästan aldrig: p99 ≈ 0,96).
///   Kurvan verkar på luminansen och skalar RGB med samma faktor (nyans och
///   mättnad bevaras), med en mjuk övergång till per-kanal nära klippning.
/// - **Vitbalans**: neutrala ytor (även ljusa väggar) dras helt till neutralt.
/// - **Mättnad**: lägre än neutral rendering (×0,85), gult/orange ytterligare
///   sänkt, blått något höjt (`hueSaturation`, i Lab-krominans).
/// - **Brus**: luminans-NR (`CINoiseReduction`) och kraftig krominans-NR
///   (oskärpa på färgkanalerna i YCbCr, luminansen orörd).
/// - Mindre clarity än Automatisk, lite textur.
/// - **Exteriörer** (taggade, eller mycket grönska/himmel, `exteriorWeight`) blandas mot ett
///   eget recept: mörkare toner, klarare färger, knappt någon NR, mer textur och skärpa.
/// - **Fönstermasken**: kurvan 70 % mot målet, tak 0,99 och interiörens (varma) vitbalans.
/// Allt sparas som explicita `LookParameters` i `enhancement.json`.
nonisolated struct LookParameters: Codable, Sendable, Equatable {
    /// Tonkurvans stödpunkter (gammakodad luma in → ut), strikt växande x.
    var curveX: [Double]
    var curveY: [Double]
    /// Kurvan i fönstermasken (svagare, se `BrokerLook.windowStrength`).
    var windowCurveY: [Double]
    /// Global mättnadsfaktor (1 = oförändrad).
    var saturation: Double
    /// Faktor per nyansband (Lab-nyansvinkel, ordning som `BrokerLook.hueCenters`).
    var hueSaturation: [Double]
    /// Luminans-NR 0…1 och krominans-NR 0…1.
    var noiseReduction: Double
    var chromaNoiseReduction: Double
    /// Lokal kontrast med liten radie (Lightrooms "Textur"), 0…1.
    var texture: Double
    /// 0 = interiörrecept, 1 = exteriörrecept (blandas linjärt), se `BrokerLook.exteriorWeight`.
    var exteriorWeight: Double = 0
    /// Fönstervariantens b*-tillägg (varmare utsikt, Förbättra v4). `nil` i äldre loggar = 0.
    var windowWarmth: Double? = nil
}

nonisolated enum BrokerLook {
    static let profileLookID = "broker"

    /// Percentiler (andel) och leveransernas mål för gammakodad luma.
    /// Median över träningsparen (se planen): interiörer är ljusare och har ljusare skuggor än
    /// exteriörer; taket (p95/p99) är detsamma.
    static let percentileLevels: [Double] = [0.01, 0.05, 0.25, 0.50, 0.75, 0.95, 0.99]
    static let targetPercentiles: [Double] = [0.095, 0.209, 0.482, 0.685, 0.801, 0.905, 0.963]
    static let exteriorTargetPercentiles: [Double] = [0.042, 0.129, 0.335, 0.568, 0.742, 0.886, 0.957]
    static let whiteCeiling = 0.97
    /// Andel av vägen mot målet (1 = hela).
    static let curveStrength = 1.0
    /// Fönsterkurvans andel av vägen mot målet: leveransernas utsikt är ljus (median ≈ 0,86,
    /// ~1,08 × väggarna), se planen.
    static let windowStrength = 0.35
    /// Förbättra v4: utsikten mättare än resten (× 1,5 × 0,8 = 1,2 mot neutral rendering) —
    /// leveransernas utsikt är ren, mörkgrön och mättad (krominans 8,2 mot vår 5,8 med × 0,8).
    static let windowSaturation = 1.5
    /// Kontrastpressning kring fönstrets median: prövad (× 0,8 gav lägre ΔE i fönstret) men
    /// förkastad efter visuell granskning — utsikten ska ha naturlig kontrast. 1 = av.
    static let windowContrast = 1.0
    static let windowLift = 0.0
    /// Fönstret får nå 0,99 (leveranserna klipper lite i utsikten) och värms något
    /// (b* +2: leveransernas utsikt har interiörens vitbalans, b* ≈ +2 mot vår −0,3).
    static let windowCeiling = 0.99
    static let windowWarmth = 2.0
    /// Största höjning/sänkning en stödpunkt får (skydd mot extrema bilder, t.ex. kvällsbilder).
    static let maxLift = 0.30
    static let maxDrop = 0.20

    /// Lab-nyansvinklar (grader) för banden röd, orange, gul, grön, cyan, blå, lila, magenta.
    static let hueCenters: [Double] = [30, 55, 85, 135, 200, 265, 305, 345]
    static let hueSaturation: [Double] = [1.0, 0.9, 0.8, 1.0, 1.0, 1.0, 1.0, 1.0]
    static let saturation = 0.80
    /// Mättnadsfaktor för ljusa ytor (L* ≥ 85, mjuk övergång från 60) i interiörer, Förbättra v4:
    /// 0,8 gav ΔE 7,62 → 7,32 (träning, interiörer) i prototypen; exteriörer orörda.
    static let highlightSaturation = 0.8
    static let noiseReduction = 0.5
    static let chromaNoiseReduction = 0.8
    static let texture = 0.15
    /// Clarity i Mäklarstil (Automatisk använder 0,30 — leveranserna har mindre mellanskalekontrast).
    static let clarity = 0.10
    /// Exteriörreceptet: klarare färger (lila dämpat), knappt någon brusreducering, mer
    /// textur/clarity och skärpa (leveranserna är tydligt skarpare ute).
    static let exteriorHueSaturation: [Double] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.7, 1.0]
    static let exteriorSaturation = 1.10
    static let exteriorNoiseReduction = 0.1
    static let exteriorChromaNoiseReduction = 0.3
    static let exteriorTexture = 0.25
    static let exteriorClarity = 0.15
    static let exteriorExtraSharpness = 0.3

    // MARK: - Interiör eller exteriör

    /// Andel "utomhuspixlar" i en gammakodad RGBA-bild: grönska (nyans 60…170°, mättnad > 0,25,
    /// luma 0,08…0,85) plus himmel i övre halvan (nyans 190…250°, mättnad > 0,12, luma > 0,4).
    /// Uppmätt: interiörer < 0,04, balkonger 0,07…0,11, exteriörer 0,26…0,54.
    static func outdoorScore(pixels: [Float], width: Int, height: Int) -> Double {
        let count = width * height
        guard count > 0, pixels.count >= count * 4 else { return 0 }
        var hits = 0
        for i in 0..<count {
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx > 1e-4, mx > mn else { continue }
            let sat = (mx - mn) / mx
            var hue: Float
            if mx == r { hue = 60 * (g - b) / (mx - mn) } else if mx == g { hue = 120 + 60 * (b - r) / (mx - mn) } else { hue = 240 + 60 * (r - g) / (mx - mn) }
            if hue < 0 { hue += 360 }
            let y = HDRImageOps.luma(r, g, b)
            if hue > 60 && hue < 170 && sat > 0.25 && y > 0.08 && y < 0.85 { hits += 1; continue }
            if i / width < height / 2 && hue > 190 && hue < 250 && sat > 0.12 && y > 0.4 { hits += 1 }
        }
        return Double(hits) / Double(count)
    }

    /// Exteriörvikt 0…1: 1 för bilder taggade som exteriör, annars rampen 0,08…0,25 i `outdoorScore`
    /// (balkonger med utsikt får en del av exteriörreceptet).
    static func exteriorWeight(outdoorScore: Double, taggedExterior: Bool) -> Double {
        taggedExterior ? 1 : min(max((outdoorScore - 0.08) / 0.17, 0), 1)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func lerp(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { zip(a, b).map { lerp($0, $1, t) } }

    // MARK: - Vitbalans

    static let wbFraction = 1.0
    /// Leveransernas vita väggar är nästan neutrala men en aning varma (b* ≈ +1,3…1,9); 0,12 gav
    /// minst ΔE och väggarnas b* som leveransernas (Δb* ≈ 0) över alla 51 par.
    static let warmth = 0.12
    static let maxTemperature = 0.5
    static let maxTint = 0.25

    /// Temperatur/tint (samma enheter som `EnhancementParameters`) som gör de neutrala
    /// ytorna neutrala: gray-world över pixlar med luma 0,30…0,92 och mättnad ≤ 0,25
    /// (även ljusa väggar, till skillnad från Automatisk), viktade med `1 − 2m` i masken.
    static func whiteBalance(pixels: [Float], width: Int, height: Int, mask: [Float]?) -> (temperature: Double, tint: Double, neutralFraction: Double) {
        let count = width * height
        guard count > 0, pixels.count >= count * 4 else { return (0, 0, 0) }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0, total = 0.0
        for i in 0..<count {
            let w = mask.map { Double(min(max(1 - 2 * $0[i], 0), 1)) } ?? 1
            if w <= 0 { continue }
            total += w
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx > 0.001 ? (mx - mn) / mx : 0
            guard y > 0.30, y < 0.92, sat <= 0.25 else { continue }
            sr += Double(HDRImageOps.toLinear(r)) * w
            sg += Double(HDRImageOps.toLinear(g)) * w
            sb += Double(HDRImageOps.toLinear(b)) * w
            n += w
        }
        guard total > 0, n > 0 else { return (0, 0, 0) }
        let fraction = n / total
        let k = EnhancementEngine.wbStopsPerUnit
        let lr = log2(max(sr / n, 1e-6)), lg = log2(max(sg / n, 1e-6)), lb = log2(max(sb / n, 1e-6))
        let confidence = min(max((fraction - 0.02) / 0.08, 0), 1)
        let scale = wbFraction * confidence
        let t = min(max((lb - lr) / (2 * k) * scale, -maxTemperature), maxTemperature)
        let tint = min(max((lg - (lr + lb) / 2) / k * scale, -maxTint), maxTint)
        return (t, tint, fraction)
    }

    // MARK: - Tonkurva (ren)

    /// Stödpunkter för kurvan från bildens percentiler: (0,0), varje percentil flyttad
    /// `strength` mot målet (högst `maxLift` upp / `maxDrop` ned), och (1, tak).
    /// Strikt växande x och y.
    static func curve(sourcePercentiles s: [Double], targets t: [Double] = targetPercentiles,
                      strength: Double = curveStrength, ceiling: Double = whiteCeiling) -> (x: [Double], y: [Double]) {
        var xs: [Double] = [0], ys: [Double] = [0]
        for (sv, tv) in zip(s, t) {
            let target = sv + (tv - sv) * strength
            let y = min(max(target, sv - maxDrop), sv + maxLift)
            xs.append(sv); ys.append(y)
        }
        xs.append(1); ys.append(ceiling)
        for i in 1..<xs.count {
            xs[i] = max(xs[i], xs[i - 1] + 1e-3)
            ys[i] = max(ys[i], ys[i - 1] + 1e-4)
        }
        // x får inte passera 1 (komprimera vid behov), y inte taket.
        if xs[xs.count - 1] > 1 {
            let scale = 1 / xs[xs.count - 1]
            xs = xs.map { $0 * scale }
        }
        ys = ys.map { min($0, ceiling) }
        return (xs, ys)
    }

    /// Monoton kubisk interpolation (Fritsch–Carlson) genom (xs, ys); utanför: ändvärdena.
    static func evaluate(x: [Double], y: [Double], at v: Double) -> Double {
        let n = x.count
        guard n >= 2 else { return v }
        if v <= x[0] { return y[0] }
        if v >= x[n - 1] { return y[n - 1] }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / max(x[i + 1] - x[i], 1e-9) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 {
            m[i] = 0; m[i + 1] = 0
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / sqrt(s)
                m[i] = tau * a * d[i]; m[i + 1] = tau * b * d[i]
            }
        }
        var k = 0
        while k < n - 2 && v > x[k + 1] { k += 1 }
        let h = x[k + 1] - x[k]
        let t = (v - x[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[k] + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * y[k + 1] + (t3 - t2) * h * m[k + 1]
    }

    /// Luma-percentiler (gammakodat) efter vitbalansförstärkningen `gains` (linjärt).
    static func lumaPercentiles(pixels: [Float], width: Int, height: Int, gains: (r: Float, g: Float, b: Float),
                                levels: [Double] = percentileLevels) -> [Double] {
        let count = width * height
        guard count > 0, pixels.count >= count * 4 else { return levels }
        let bins = 2048
        var hist = [Double](repeating: 0, count: bins)
        for i in 0..<count {
            let r = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4]) * gains.r)
            let g = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4 + 1]) * gains.g)
            let b = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4 + 2]) * gains.b)
            let y = min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1)
            hist[min(Int(y * Float(bins - 1)), bins - 1)] += 1
        }
        let total = Double(count)
        return levels.map { q in
            var c = 0.0
            for (i, h) in hist.enumerated() {
                c += h
                if c >= q * total { return Double(i) / Double(bins - 1) }
            }
            return 1
        }
    }

    /// Median av gammakodad luma (efter `gains`) i fönstermasken (m ≥ 0,5); `nil` om masken är
    /// nästan tom (< 200 pixlar).
    static func windowMedian(pixels: [Float], width: Int, height: Int, mask: [Float], gains: (r: Float, g: Float, b: Float)) -> Double? {
        let count = width * height
        guard count > 0, pixels.count >= count * 4, mask.count >= count else { return nil }
        var values: [Float] = []
        for i in 0..<count where mask[i] >= 0.5 {
            let r = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4]) * gains.r)
            let g = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4 + 1]) * gains.g)
            let b = HDRImageOps.toGamma(HDRImageOps.toLinear(pixels[i * 4 + 2]) * gains.b)
            values.append(min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1))
        }
        guard values.count >= 200 else { return nil }
        return Double(HDRImageOps.percentile(values, 0.5))
    }

    /// Mäklarstilens parametrar för en bild (efter vitbalans `gains`).
    static func lookParameters(sourcePercentiles: [Double], exteriorWeight e: Double = 0,
                               windowMedian: Double? = nil) -> LookParameters {
        let targets = lerp(targetPercentiles, exteriorTargetPercentiles, e)
        let main = curve(sourcePercentiles: sourcePercentiles, targets: targets)
        let window = curve(sourcePercentiles: sourcePercentiles, targets: targets, strength: windowStrength)
        // Fönsterkurvan utvärderas i huvudkurvans x-punkter, så att båda delar stödpunkter.
        var windowY = main.x.map { evaluate(x: window.x, y: window.y, at: $0) }
        if let windowMedian {
            let pivot = evaluate(x: window.x, y: window.y, at: windowMedian)
            windowY = zip(main.x, windowY).map { x, y in windowCompress(x: x, y: y, pivot: pivot) }
            for i in 1..<windowY.count { windowY[i] = max(windowY[i], windowY[i - 1] + 1e-4) }
            windowY = windowY.map { min($0, windowCeiling) }
        }
        return LookParameters(curveX: main.x, curveY: main.y, windowCurveY: windowY,
                              saturation: lerp(saturation, exteriorSaturation, e),
                              hueSaturation: lerp(hueSaturation, exteriorHueSaturation, e),
                              noiseReduction: lerp(noiseReduction, exteriorNoiseReduction, e),
                              chromaNoiseReduction: lerp(chromaNoiseReduction, exteriorChromaNoiseReduction, e),
                              texture: lerp(texture, exteriorTexture, e), exteriorWeight: e,
                              windowWarmth: windowMedian == nil ? nil : windowWarmth)
    }

    /// Fönsterkurvans värde efter kontrastpressningen kring `pivot` (utvärdet vid fönstrets median)
    /// och lyftet; under ~0,35 i indata blandas den mjukt tillbaka mot den opressade kurvan så att
    /// mörka partier i masken inte blir grå. Monoton när `y` är det (pressningen ≥ y under pivoten).
    static func windowCompress(x: Double, y: Double, pivot: Double) -> Double {
        let pressed = pivot + windowContrast * (y - pivot) + windowLift
        let t = min(max((x - 0.1) / 0.25, 0), 1)
        let w = t * t * (3 - 2 * t)
        return min(y + (pressed - y) * w, windowCeiling)
    }

    // MARK: - Färgtransform (ren): kurva på luminans + mättnad per nyans

    /// Hela looken för en gammakodad pixel → gammakodad pixel (0…1).
    static func lookColor(_ r: Double, _ g: Double, _ b: Double, curveX: [Double], curveY: [Double],
                          saturation: Double, hueSaturation: [Double]) -> (Double, Double, Double) {
        lookColor(r, g, b, curve: { evaluate(x: curveX, y: curveY, at: $0) }, saturation: saturation, hueSaturation: hueSaturation)
    }

    /// Som ovan med kurvan som funktion (t.ex. en tät tabell, se `cubeData`).
    static func lookColor(_ r: Double, _ g: Double, _ b: Double, curve: (Double) -> Double,
                          saturation: Double, hueSaturation: [Double], highlightSaturation: Double = 1,
                          warmth: Double = 0, ceiling: Double = 1) -> (Double, Double, Double) {
        // 1. Tonkurva på luma, RGB skalas med samma faktor; nära klippning blandas per-kanal-kurvan in.
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let fy = curve(y)
        let ratio = fy / max(y, 1e-4)
        var (r1, g1, b1) = (r * ratio, g * ratio, b * ratio)
        let over = min(max((max(r1, g1, b1) - 0.98) / 0.1, 0), 1)
        if over > 0 {
            let pr = curve(r), pg = curve(g), pb = curve(b)
            r1 = r1 * (1 - over) + pr * over; g1 = g1 * (1 - over) + pg * over; b1 = b1 * (1 - over) + pb * over
        }
        r1 = min(max(r1, 0), 1); g1 = min(max(g1, 0), 1); b1 = min(max(b1, 0), 1)
        // 2. Mättnad i Lab: krominansen skalas med global faktor × nyansbandets faktor.
        //    Ljusa ytor (L* 60 → 85) får dessutom `highlightSaturation`: leveransernas tak och väggar
        //    är nästan neutrala även där lampor och solljus ger ett färgstick.
        var lab = Lab.fromSRGB(r1, g1, b1)
        let h = min(max((lab.l - 60) / 25, 0), 1)
        let f = saturation * hueFactor(a: lab.a, b: lab.b, factors: hueSaturation) * (1 + (highlightSaturation - 1) * h * h * (3 - 2 * h))
        if abs(f - 1) > 1e-6 || warmth != 0 {
            lab.a *= f; lab.b = lab.b * f + warmth
            let out = lab.toSRGB()
            return (min(max(out.0, 0), ceiling), min(max(out.1, 0), ceiling), min(max(out.2, 0), ceiling))
        }
        return (min(r1, ceiling), min(g1, ceiling), min(b1, ceiling))
    }

    /// Nyansbandets faktor: triangelvikter (±45°) kring `hueCenters`; utanför alla band 1.
    static func hueFactor(a: Double, b: Double, factors: [Double]) -> Double {
        guard factors.count == hueCenters.count else { return 1 }
        let h = (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        var wsum = 0.0, fsum = 0.0
        for (i, c) in hueCenters.enumerated() {
            let d = abs((h - c + 540).truncatingRemainder(dividingBy: 360) - 180)
            let w = max(0, 1 - d / 45)
            wsum += w; fsum += w * factors[i]
        }
        return wsum > 0.01 ? fsum / wsum : 1
    }

    /// CIE Lab (D65) från/till gammakodad sRGB.
    struct Lab {
        var l: Double, a: Double, b: Double

        private static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        private static func gam(_ v: Double) -> Double { let c = max(v, 0); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        private static let white = (x: 0.950456, y: 1.0, z: 1.088754)
        private static func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        private static func fi(_ t: Double) -> Double { t > 0.206893 ? t * t * t : (t - 16.0 / 116) / 7.787 }

        static func fromSRGB(_ r: Double, _ g: Double, _ b: Double) -> Lab {
            let R = lin(r), G = lin(g), B = lin(b)
            let x = (0.412453 * R + 0.357580 * G + 0.180423 * B) / white.x
            let y = (0.212671 * R + 0.715160 * G + 0.072169 * B) / white.y
            let z = (0.019334 * R + 0.119193 * G + 0.950227 * B) / white.z
            let fx = f(x), fy = f(y), fz = f(z)
            return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
        }

        func toSRGB() -> (Double, Double, Double) {
            let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
            let x = Lab.fi(fx) * Lab.white.x, y = Lab.fi(fy) * Lab.white.y, z = Lab.fi(fz) * Lab.white.z
            let R = 3.240479 * x - 1.537150 * y - 0.498535 * z
            let G = -0.969256 * x + 1.875992 * y + 0.041556 * z
            let B = 0.055648 * x - 0.204043 * y + 1.057311 * z
            return (Lab.gam(R), Lab.gam(G), Lab.gam(B))
        }
    }

    // MARK: - Rendering (Core Image)

    /// 65³: noggrannare i den branta delen av kurvan (skuggorna) än 33³.
    static let cubeSize = 65

    /// 3D-LUT (RGBA float32) för `CIColorCube` med looken; `window` = fönsterkurvan.
    static func cubeData(_ p: LookParameters, window: Bool) -> Data {
        let n = cubeSize
        let ys = window ? p.windowCurveY : p.curveY
        let saturation = window ? p.saturation * windowSaturation : p.saturation
        let warmth = window ? (p.windowWarmth ?? 0) : 0
        let highlightSaturation = window ? 1 : lerp(self.highlightSaturation, 1, p.exteriorWeight)
        // Kurvan som tät tabell (linjär interpolation) — snabbt och tillräckligt exakt.
        let tableSize = 4096
        let table = (0...tableSize).map { evaluate(x: p.curveX, y: ys, at: Double($0) / Double(tableSize)) }
        let curve: (Double) -> Double = { v in
            let x = min(max(v, 0), 1) * Double(tableSize)
            let i = min(Int(x), tableSize - 1)
            let f = x - Double(i)
            return table[i] * (1 - f) + table[i + 1] * f
        }
        var values = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let (r, g, b) = lookColor(Double(ri) / Double(n - 1), Double(gi) / Double(n - 1), Double(bi) / Double(n - 1),
                                              curve: curve, saturation: saturation, hueSaturation: p.hueSaturation,
                                              highlightSaturation: highlightSaturation, warmth: warmth,
                                              ceiling: window ? windowCeiling : 1)
                    let o = ((bi * n + gi) * n + ri) * 4
                    values[o] = Float(r); values[o + 1] = Float(g); values[o + 2] = Float(b); values[o + 3] = 1
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Tillämpar looken på en gammakodad bild (värden 0…1).
    static func applyCube(_ image: CIImage, _ p: LookParameters, window: Bool) -> CIImage {
        guard let f = CIFilter(name: "CIColorCube") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(cubeSize, forKey: "inputCubeDimension")
        f.setValue(cubeData(p, window: window), forKey: "inputCubeData")
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Brusreducering på en gammakodad bild: luminans med `CINoiseReduction`, krominans
    /// genom oskärpa på Cb/Cr (radie efter upplösningen) med luminansen orörd.
    static func reduceNoise(_ image: CIImage, luminance: Double, chroma: Double) -> CIImage {
        let extent = image.extent
        var out = image
        let longSide = Double(max(extent.width, extent.height))
        if luminance > 0 {
            out = out.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.04 * luminance,
                "inputSharpness": 0.2
            ]).cropped(to: extent)
        }
        if chroma > 0 {
            // YCbCr (BT.709, gammakodat), Cb/Cr förskjutna +0,5 så att allt är ≥ 0.
            let ycc = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: -0.1146, y: -0.3854, z: 0.5, w: 0),
                "inputBVector": CIVector(x: 0.5, y: -0.4542, z: -0.0458, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0.5, z: 0.5, w: 0)
            ])
            let radius = max(1.0, 5 * chroma * longSide / 6000)
            let blurred = ycc.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            // Y från originalet (Cb/Cr nollade), Cb/Cr från den oskarpa (Y nollad) → max per kanal.
            let yOnly = ycc.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let cOnly = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let merged = yOnly.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: cOnly])
            out = merged.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 1.5748, w: 0),
                "inputGVector": CIVector(x: 1, y: -0.1873, z: -0.4681, w: 0),
                "inputBVector": CIVector(x: 1, y: 1.8556, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -1.5748 * 0.5, y: (0.1873 + 0.4681) * 0.5, z: -1.8556 * 0.5, w: 0)
            ]).cropped(to: extent)
        }
        return out
    }

    // MARK: - Koppling till EnhancementEngine

    /// Slutparametrar för Mäklarstil: profilens parametrar som grund, men vitbalansen från
    /// `whiteBalance`, ingen exponering/nivåer/skuggor/högdagrar/S-kurva/vibrance (tonkurvan
    /// och mättnaden i `look` gör det) och lägre clarity. Rotation och skärpa behålls.
    static func parameters(base: EnhancementParameters, pixels: [Float], width: Int, height: Int, mask: [Float]?,
                           taggedExterior: Bool = false) -> EnhancementParameters {
        var p = base
        let wb = whiteBalance(pixels: pixels, width: width, height: height, mask: mask)
        p.temperature = wb.temperature + warmth
        p.tint = wb.tint
        p.exposureEV = 0
        p.blackPoint = 0
        p.whitePoint = 1
        p.shadows = 0
        p.highlights = 0
        p.contrast = 0
        p.vibrance = 0
        p.saturation = 0
        let e = exteriorWeight(outdoorScore: outdoorScore(pixels: pixels, width: width, height: height), taggedExterior: taggedExterior)
        p.clarity = lerp(clarity, exteriorClarity, e)
        p.sharpness = min(p.sharpness + exteriorExtraSharpness * e, EnhancementParameters.Key.sharpness.range.upperBound)
        let gains = EnhancementEngine.wbGains(temperature: p.temperature, tint: p.tint)
        p.look = lookParameters(sourcePercentiles: lumaPercentiles(pixels: pixels, width: width, height: height, gains: gains),
                                exteriorWeight: e,
                                windowMedian: mask.flatMap { windowMedian(pixels: pixels, width: width, height: height, mask: $0, gains: gains) })
        return p
    }

    /// Vitbalans + exponering (linjärt), klämning, över till gammakodat och brusreducering.
    /// Resultatet är gammakodat och går in i `applyCube`.
    static func prepare(_ input: CIImage, parameters p: EnhancementParameters, look: LookParameters) -> CIImage {
        let extent = input.extent
        let wb = EnhancementEngine.wbGains(temperature: p.temperature, tint: p.tint)
        let ev = Float(pow(2.0, p.exposureEV))
        var image = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(wb.r * ev), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(wb.g * ev), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(wb.b * ev), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        image = clamp01(image).applyingFilter("CILinearToSRGBToneCurve")
        image = reduceNoise(clamp01(image), luminance: look.noiseReduction, chroma: look.chromaNoiseReduction)
        return clamp01(image).cropped(to: extent)
    }

    /// Textur: osharp mask med liten radie (~1/800 av långsidan), kanterna förlängda.
    static func applyTexture(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let extent = image.extent
        let radius = max(2.0, Double(max(extent.width, extent.height)) / 800)
        return image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius, kCIInputIntensityKey: amount
        ]).cropped(to: extent)
    }

    private static func clamp01(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]).cropped(to: extent)
    }
}
