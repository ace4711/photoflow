import Foundation
import CoreImage
import CoreGraphics
import Vision
import ImageIO

/// Siffror från bildanalysen — sparas i `enhancement.json` så att man ser
/// *varför* automatiken valde som den gjorde.
nonisolated struct EnhancementAnalysis: Codable, Sendable, Equatable {
    /// Median-luma (gammakodad, 0…1) före någon justering.
    var medianLuma: Double = 0
    /// Andel "neutrala" pixlar (låg mättnad, mellantoner) som vitbalansen bygger på.
    var neutralFraction: Double = 0
    /// Förhållandet mellan kanalernas medelvärden (linjärt) i de neutrala pixlarna, R/G och B/G.
    var neutralRG: Double = 1
    var neutralBG: Double = 1
    /// Percentiler efter vitbalans och exponering (gammakodat): svart = min-kanal p0,1, vit = max-kanal p99,9.
    var blackPercentile: Double = 0
    var whitePercentile: Double = 1
    var p5: Double = 0
    var p95: Double = 1
    var darkFraction: Double = 0
    var brightFraction: Double = 0
    var meanSaturation: Double = 0
    /// Vision-mätt horisontlutning i grader, om någon hittades.
    var horizonDegrees: Double?
    /// Fönstermaskens andel av bilden (viktad, 0…1) när en mask fanns (HDR med window pull).
    /// `nil` = ingen mask — statistiken gäller då hela bilden.
    var windowMaskFraction: Double?
}

/// Automatisk förbättring av färdiga bilder (fastighetsfoto): analyserar en
/// nedskalad kopia, räknar fram explicita `EnhancementParameters` och renderar
/// dem med Core Image.
///
/// ## Färghantering
/// All Core Image-rendering sker i en linjär arbetsrymd (`extendedLinearSRGB`,
/// flyttalsformat). Ordningen i `render`:
///  1. rotation + minimal beskärning (före filtren, så inga kantartefakter),
///  2. vitbalans och exponering som kanalförstärkning i **linjärt** ljus (fysiskt
///     rätt: ett stopp är en faktor 2),
///  3. skuggor/högdagrar (`CIHighlightShadowAdjust`, linjärt) och en klämning till 0…1,
///  4. över till gammakodat (sRGB-kurva) för de perceptuella stegen: nivåer
///     (svart-/vitpunkt), S-kurva, vibrance/mättnad, clarity och slutskärpa —
///     samma domän som `HDRWriter.sharpen` och bildens egna värden,
///  5. tillbaka till linjärt, så att utskriften med `colorSpace: sRGB` ger
///     rätt gammakodade värden i TIFF/JPEG.
/// Analysen sker på samma gammakodade pixlar som slutbilden består av.
///
/// ## Automatiken (alla konstanter är försiktiga: bättre för lite än för mycket)
/// - **Vitbalans**: gray-world över "neutrala" pixlar (mättnad ≤ 0,30, luma
///   0,20…0,85 — inga högdagrar, inga mörka brus-ytor). Korrigeringen tillämpas
///   till 70 % ("wbCorrectionFraction"), skalas med hur stor andel av bilden som
///   är neutral (full vid ≥ 10 %, noll under 2 %) och begränsas till
///   temperatur ±0,25 / tint ±0,12 — aldrig stora färgskiften. Färgade ytor
///   (trägolv, målade väggar) dras därmed inte mot grått.
/// - **Exponering**: median-luman efter vitbalans mot målet 0,46 (gammakodat),
///   80 % av avvikelsen, -0,6…+0,9 EV, med högdagsskydd (98:e percentilen får
///   inte skjutas långt över 1) och en dödzon på ±0,05 EV.
/// - **Svart-/vitpunkt**: percentil 0,1 av min-kanalen resp. 99,9 av max-kanalen
///   (efter exponering) → högst ~0,1 % klipps. Svart ≤ 0,08, vit ≥ 0,90.
/// - **Skuggor/högdagrar** efter andelen mörka (< 0,18) resp. nästan vita (> 0,96) pixlar.
/// - **S-kurva** ≈ 0,08 plus mer ju plattare histogrammet är (p5…p95 under 0,62).
/// - **Vibrance** (inte mättnad) högre ju blekare bilden är; **clarity** 0,30.
/// - **Slutskärpa** låg (0,15) om källan redan skärpts av HDR-steget, annars 0,5.
/// - **Rätning**: bara om bilden är taggad som exteriör (`Request.allowStraighten`)
///   och Vision hittar en horisont med lutning 0,3…3°. I interiörer rapporterar
///   Vision "horisonter" som egentligen är rummets perspektivlinjer (mätt mot 63
///   riktiga bilder: 9 fick en vinkel med confidence 1,0, alla felaktiga och
///   kvantiserade till 1/8°), så där rätas inget automatiskt.
///
/// ## Fönstermask (version 2)
/// HDR-grupper med window pull har en fönstermask (`hdr_masks/hdr_group_N.png`,
/// 0…1, ~1500 px). Finns den:
/// - **Statistiken** (vitbalans, median, p98, svart-/vitpunkt, andelar) viktas med
///   `1 − 2m` (pixlar med m ≥ 0,5 räknas inte alls) — utsikten ska varken dra
///   vitbalansen mot blått eller hålla nere exponeringen/vitpunkten för interiören.
/// - **Tonerna** i masken renderas med en egen variant som blandas in med masken:
///   halva exponeringshöjningen (sänkning behålls), högdagsdämpning minst 0,3,
///   mjuk roll-off ovanför linjärt 0,7 i stället för hård klippning och inga nivåer
///   (svart 0, vit 1) — fönstret klipps inte igen av att interiören lyfts.
/// - **Clarity** multipliceras med `1 − dilaterad mask` (dilaterad med clarity-radien
///   ×2 och mjukad med en halv radie), så ingen halo uppstår vid karmarna.
/// - Masken roteras/beskärs exakt som bilden (horisonträtning).
/// Utan mask är både analysen och renderingen identiska med version 1.
///
/// ## Mäklarstil och lodlinjer (version 3)
/// - Profilen "Mäklarstil" (`EnhancementProfile.look == "broker"`) ersätter exponering,
///   nivåer, skuggor/högdagrar, S-kurva och vibrance med `BrokerLook`: vitbalans som gör
///   neutrala ytor neutrala, brusreducering, en tonkurva mot leveransernas målpercentiler och
///   mättnad per nyans (3D-LUT), lägre clarity och lite textur. I fönstermasken används en
///   svagare kurva. Parametrarna sparas i `EnhancementParameters.look`.
/// - "Räta lodlinjer" (`Request.upright`, alla profiler): `VerticalCorrection` skattar
///   lodlinjernas flyktpunkt i analysbilden och rätar dem (högst 8° lutning, 3° rotation),
///   före allt annat; masken följer med. Ersätter horisonträtningen när den görs.
nonisolated enum EnhancementEngine {
    /// Höjs när algoritmen/renderingen ändras — del av fingerprintet så gamla
    /// förbättringar görs om.
    static let version = 3

    /// Fönstervarianten (se "Fönstermask"): andel av en positiv exponeringshöjning,
    /// lägsta högdagsdämpning och knät (linjärt) för den mjuka roll-offen.
    static let windowExposureFraction = 0.5
    static let windowMinHighlights = 0.3
    static let windowRolloffKnee: Float = 0.7

    /// Kanalförstärkning i stopp per enhet temperatur/tint.
    static let wbStopsPerUnit = 0.5
    static let wbCorrectionFraction = 0.7
    static let maxAutoTemperature = 0.25
    static let maxAutoTint = 0.12
    static let targetMedianLuma = 0.46
    static let analysisMaxDimension = 1024
    static let straightenRange: ClosedRange<Double> = 0.3...3.0

    // MARK: - Analys + parametrar (ren, testbar logik)

    struct Input {
        /// RGBA float32, sRGB-gammakodat, `width * height * 4` värden.
        var pixels: [Float]
        var width: Int
        var height: Int
        /// Vision-mätt horisontlutning i grader (nil = ingen).
        var horizonDegrees: Double?
        /// Källan har redan skärpts (HDR-steget skärper sitt resultat).
        var alreadySharpened: Bool
        /// Fönstermask (0…1, `width * height` värden, samma pixelrutnät som `pixels`).
        /// `nil` = ingen mask (hela bilden räknas).
        var mask: [Float]? = nil
    }

    /// Räknar fram automatikens parametrar och analysen bakom dem.
    static func automaticParameters(_ input: Input) -> (parameters: EnhancementParameters, analysis: EnhancementAnalysis) {
        var analysis = EnhancementAnalysis()
        var p = EnhancementParameters()
        let k = wbStopsPerUnit

        // Pass A: oförändrad bild → neutrala pixlar för vitbalans, median.
        let a = Stats(input, gains: (1, 1, 1))
        if input.mask != nil { analysis.windowMaskFraction = 1 - a.weightFraction }
        analysis.medianLuma = a.percentile(a.lumaHist, 0.5)
        analysis.neutralFraction = a.neutralFraction
        if let mean = a.neutralMeanLinear {
            analysis.neutralRG = mean.r / max(mean.g, 1e-6)
            analysis.neutralBG = mean.b / max(mean.g, 1e-6)
            let lr = log2(max(mean.r, 1e-6)), lg = log2(max(mean.g, 1e-6)), lb = log2(max(mean.b, 1e-6))
            let confidence = min(max((a.neutralFraction - 0.02) / 0.08, 0), 1)
            let scale = wbCorrectionFraction * confidence
            let t = (lb - lr) / (2 * k) * scale
            let n = (lg - (lr + lb) / 2) / k * scale
            p.temperature = min(max(t, -maxAutoTemperature), maxAutoTemperature)
            p.tint = min(max(n, -maxAutoTint), maxAutoTint)
        }

        // Pass B: efter vitbalans → exponering.
        let wb = wbGains(temperature: p.temperature, tint: p.tint)
        let b = Stats(input, gains: wb)
        let median = b.percentile(b.lumaHist, 0.5)
        let medianLinear = Double(Stats.decode(Float(median)))
        let targetLinear = Double(Stats.decode(Float(targetMedianLuma)))
        let rawEV = log2(targetLinear / max(medianLinear, 1e-4))
        let p98Linear = Double(Stats.decode(Float(b.percentile(b.maxHist, 0.98))))
        let highlightCap = log2(1.0 / max(p98Linear, 1e-3)) + 0.6
        var ev = min(max(rawEV * 0.8, -0.6), min(0.9, max(highlightCap, -0.6)))
        if abs(ev) < 0.05 { ev = 0 }
        p.exposureEV = ev

        // Pass C: efter vitbalans + exponering → nivåer, skuggor, kontrast, färg.
        let gain = Float(pow(2.0, ev))
        let c = Stats(input, gains: (wb.r * gain, wb.g * gain, wb.b * gain))
        let black = c.percentile(c.minHist, 0.001)
        let white = c.percentile(c.maxHist, 0.999)
        analysis.blackPercentile = black
        analysis.whitePercentile = white
        p.blackPoint = black < 0.005 ? 0 : min(black, 0.08)
        p.whitePoint = white >= 0.995 ? 1 : max(white, 0.90)

        analysis.p5 = c.percentile(c.lumaHist, 0.05)
        analysis.p95 = c.percentile(c.lumaHist, 0.95)
        analysis.darkFraction = c.darkFraction
        analysis.brightFraction = c.brightFraction
        analysis.meanSaturation = c.meanSaturation

        p.shadows = min(max(0.08 + 1.2 * max(0, c.darkFraction - 0.10), 0), 0.6)
        p.highlights = min(max(0.04 + 2.5 * max(0, c.brightFraction - 0.01), 0), 0.45)
        let spread = analysis.p95 - analysis.p5
        p.contrast = min(max(0.08 + max(0, 0.62 - spread) * 0.8, 0), 0.25)
        p.vibrance = min(max(0.12 + (0.35 - c.meanSaturation), 0), 0.35)
        p.clarity = 0.30
        p.sharpness = input.alreadySharpened ? 0.15 : 0.5

        analysis.horizonDegrees = input.horizonDegrees
        p.rotationDegrees = straightenRotation(forHorizon: input.horizonDegrees)
        return (p.clamped(), analysis)
    }

    /// Vitbalansens kanalförstärkningar (linjärt) för temperatur/tint.
    static func wbGains(temperature: Double, tint: Double) -> (r: Float, g: Float, b: Float) {
        let k = wbStopsPerUnit
        return (Float(pow(2, temperature * k)), Float(pow(2, -tint * k)), Float(pow(2, -temperature * k)))
    }

    /// Rotationen (grader, moturs positivt i Core Image) som rätar en horisont
    /// med lutningen `horizon` (Visions vinkel, grader). 0 utanför 0,3…3°:
    /// mindre märks inte, större är troligen ingen horisont eller ett medvetet
    /// snett motiv och rätas inte automatiskt.
    ///
    /// Tecknet är uppmätt, inte antaget: en syntetisk horisont roterad +2° (moturs
    /// i Core Image) ger Vision-vinkeln -2°, så rättningen är Visions vinkel rakt av.
    static func straightenRotation(forHorizon horizon: Double?) -> Double {
        guard let horizon, straightenRange.contains(abs(horizon)) else { return 0 }
        return horizon
    }

    /// Faktorn som bilden måste förstoras med efter rotation `degrees` för att
    /// den största centrerade rektangeln med samma proportioner ska rymmas i den
    /// roterade bilden utan tomma hörn: `cosθ + sinθ · max(W/H, H/W)`.
    static func cropScale(width: Double, height: Double, rotationDegrees: Double) -> Double {
        let theta = abs(rotationDegrees) * .pi / 180
        return cos(theta) + sin(theta) * max(width / height, height / width)
    }

    /// Histogram- och färgstatistik över pixlarna efter kanalförstärkning `gains` (linjärt).
    private struct Stats {
        static let bins = 1024
        var lumaHist = [Double](repeating: 0, count: bins)
        var minHist = [Double](repeating: 0, count: bins)
        var maxHist = [Double](repeating: 0, count: bins)
        var neutralFraction = 0.0
        var neutralMeanLinear: (r: Double, g: Double, b: Double)?
        var darkFraction = 0.0
        var brightFraction = 0.0
        var meanSaturation = 0.0
        /// Summan av vikterna delat med antalet pixlar (1 utan mask).
        var weightFraction = 1.0

        private static let decodeLUT: [Float] = (0..<4097).map { i in
            let v = Float(i) / 4096
            return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }

        /// sRGB gammakodat → linjärt (uppslagning med linjär interpolation).
        static func decode(_ v: Float) -> Float {
            let x = min(max(v, 0), 1) * 4096
            let i = min(Int(x), 4095)
            let f = x - Float(i)
            return decodeLUT[i] * (1 - f) + decodeLUT[i + 1] * f
        }

        static func encode(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
        }

        /// Pixelns vikt i statistiken ur fönstermasken: 1 utanför, 0 för m ≥ 0,5.
        static func weight(mask m: Float) -> Double {
            Double(min(max(1 - 2 * m, 0), 1))
        }

        init(_ input: EnhancementEngine.Input, gains: (r: Float, g: Float, b: Float)) {
            let count = input.width * input.height
            guard count > 0, input.pixels.count >= count * 4 else { return }
            // Utan mask är varje vikt exakt 1 och summorna blir desamma som heltalsräkning
            // (version 1): heltal i Double är exakta långt över bildstorlekarna här.
            let mask = input.mask.flatMap { $0.count >= count ? $0 : nil }
            var neutral = 0.0
            var sumR = 0.0, sumG = 0.0, sumB = 0.0
            var dark = 0.0, bright = 0.0
            var satSum = 0.0, satCount = 0.0
            var weightSum = 0.0
            let top = Self.bins - 1
            input.pixels.withUnsafeBufferPointer { px in
                for i in 0..<count {
                    let w = mask.map { Self.weight(mask: $0[i]) } ?? 1
                    if w <= 0 { continue }
                    weightSum += w
                    let lr = Self.decode(px[i * 4]) * gains.r
                    let lg = Self.decode(px[i * 4 + 1]) * gains.g
                    let lb = Self.decode(px[i * 4 + 2]) * gains.b
                    let r = Self.encode(lr), g = Self.encode(lg), b = Self.encode(lb)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let mx = max(r, g, b), mn = min(r, g, b)
                    lumaHist[min(Int(luma * Float(top)), top)] += w
                    maxHist[min(Int(mx * Float(top)), top)] += w
                    minHist[min(Int(mn * Float(top)), top)] += w
                    if luma < 0.18 { dark += w }
                    if mx > 0.96 { bright += w }
                    let sat = mx > 0.001 ? (mx - mn) / mx : 0
                    if luma > 0.10 && luma < 0.95 { satSum += Double(sat) * w; satCount += w }
                    if luma > 0.20 && luma < 0.85 && sat <= 0.30 {
                        neutral += w
                        sumR += Double(lr) * w; sumG += Double(lg) * w; sumB += Double(lb) * w
                    }
                }
            }
            weightFraction = weightSum / Double(count)
            // Allt maskat (orimligt, men möjligt): räkna som om bilden vore tom.
            guard weightSum > 0 else { return }
            let total = mask == nil ? Double(count) : weightSum
            neutralFraction = neutral / total
            if neutral > 0 {
                neutralMeanLinear = (sumR / neutral, sumG / neutral, sumB / neutral)
            }
            darkFraction = dark / total
            brightFraction = bright / total
            meanSaturation = satCount > 0 ? satSum / satCount : 0
        }

        /// Percentilen `q` (0…1) ur ett histogram → värde 0…1.
        func percentile(_ hist: [Double], _ q: Double) -> Double {
            let total = hist.reduce(0, +)
            guard total > 0 else { return 0 }
            let target = q * total
            var cumulative = 0.0
            for (i, h) in hist.enumerated() {
                cumulative += h
                if cumulative >= target { return Double(i) / Double(Self.bins - 1) }
            }
            return 1
        }
    }

    // MARK: - Rendering (Core Image)

    /// Arbetsrymd och format: linjärt flyttal, så att mellanstegen inte kvantiseras eller klipps.
    static func makeContext() -> CIContext {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
    }

    /// Tillämpar `parameters` på `source` (en bild med extent från origo; färgtaggad
    /// sRGB). Resultatets extent börjar i origo och är lika stort som källan, eller
    /// minimalt mindre vid rotation (se `cropScale`).
    ///
    /// `windowMask`: fönstermask (gråskala 0…1, vilken storlek som helst — skalas till
    /// källans), laddad *utan* färghantering (`loadMask`). `nil` = version 1-rendering.
    static func render(_ source: CIImage, parameters p: EnhancementParameters, windowMask: CIImage? = nil) -> CIImage {
        var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let sourceExtent = image.extent

        // Masken i källans storlek (samma geometri som bilden före rotationen).
        var mask = windowMask.map { m -> CIImage in
            let moved = m.transformed(by: CGAffineTransform(translationX: -m.extent.minX, y: -m.extent.minY))
            let sx = sourceExtent.width / max(moved.extent.width, 1), sy = sourceExtent.height / max(moved.extent.height, 1)
            return moved.clampedToExtent().transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: sourceExtent)
        }

        // 1a. Rätning av lodlinjer (Mäklarstil/"Räta lodlinjer") — masken följer med exakt.
        if let perspective = p.perspective {
            let w = Int(sourceExtent.width), h = Int(sourceExtent.height)
            image = VerticalCorrection.render(image, correction: perspective, width: w, height: h)
            mask = mask.map { VerticalCorrection.render($0, correction: perspective, width: w, height: h) }
        }
        // 1b. Rotation + minimal beskärning — masken följer med exakt.
        if abs(p.rotationDegrees) > 0.0001 {
            let w = image.extent.width, h = image.extent.height
            let theta = CGFloat(p.rotationDegrees * .pi / 180)
            let transform = CGAffineTransform(translationX: w / 2, y: h / 2)
                .rotated(by: theta)
                .translatedBy(x: -w / 2, y: -h / 2)
            let s = cropScale(width: Double(w), height: Double(h), rotationDegrees: p.rotationDegrees)
            let cropW = (floor(Double(w) / s / 2) * 2), cropH = (floor(Double(h) / s / 2) * 2)
            let rect = CGRect(x: ((Double(w) - cropW) / 2).rounded(.down), y: ((Double(h) - cropH) / 2).rounded(.down),
                              width: cropW, height: cropH)
            func geometry(_ img: CIImage) -> CIImage {
                img.transformed(by: transform).cropped(to: rect)
                    .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            }
            image = geometry(image)
            mask = mask.map { geometry($0.clampedToExtent()) }
        }
        let extent = image.extent
        let longSide = Double(max(extent.width, extent.height))

        // 2–4 (utom clarity/skärpa): toner. Med mask blandas fönstervarianten in.
        let toned: CIImage
        var result: CIImage
        if let look = p.look {
            // Mäklarstil (`BrokerLook`): tonkurva + mättnad som 3D-LUT efter brusreduceringen;
            // i fönstermasken den svagare fönsterkurvan.
            let base = BrokerLook.prepare(image, parameters: p, look: look)
            toned = BrokerLook.applyCube(base, look, window: false)
            result = toned
            if let mask {
                result = BrokerLook.applyCube(base, look, window: true).applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: toned, kCIInputMaskImageKey: mask
                ]).cropped(to: extent)
            }
        } else {
            toned = tones(image, parameters: p, window: false)
            result = toned
        }
        if p.look == nil, let mask {
            let windowToned = tones(image, parameters: p, window: true)
            result = windowToned.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: toned, kCIInputMaskImageKey: mask
            ]).cropped(to: extent)
        }
        if p.clarity > 0 {
            let radius = min(max(longSide / 100, 10), 100)
            let clarified = unsharp(result, extent: extent, radius: radius, intensity: p.clarity * 0.5)
            if let mask {
                // Clarity × (1 − dilaterad mask): utan clarity i och nära fönstret.
                let near = dilatedMask(mask, extent: extent, radius: radius * 2)
                result = result.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clarified, kCIInputMaskImageKey: near
                ]).cropped(to: extent)
            } else {
                result = clarified
            }
        }
        if let look = p.look, look.texture > 0 {
            result = BrokerLook.applyTexture(result, amount: look.texture)
        }
        if p.sharpness > 0 {
            result = unsharp(result, extent: extent, radius: max(0.6, 1.2 * longSide / 8256), intensity: p.sharpness)
        }
        result = clamp01(result)

        // 5. Tillbaka till linjärt för utskrift med colorSpace: sRGB.
        return result.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Steg 2–4 utan clarity och skärpa; resultatet är gammakodat. `window` = fönstervarianten
    /// (se "Fönstermask" i typens dokumentation).
    private static func tones(_ input: CIImage, parameters p: EnhancementParameters, window: Bool) -> CIImage {
        var image = input
        let exposureEV = window && p.exposureEV > 0 ? p.exposureEV * windowExposureFraction : p.exposureEV
        let highlights = window ? max(p.highlights, windowMinHighlights) : p.highlights
        let blackPoint = window ? 0 : p.blackPoint
        let whitePoint = window ? 1 : p.whitePoint

        // 2. Vitbalans + exponering, linjärt.
        let wb = wbGains(temperature: p.temperature, tint: p.tint)
        let ev = Float(pow(2.0, exposureEV))
        image = colorMatrix(image, scale: (CGFloat(wb.r * ev), CGFloat(wb.g * ev), CGFloat(wb.b * ev)), bias: 0)

        // 3. Skuggor/högdagrar (linjärt), klämning till 0…1 (fönstret: mjuk roll-off först).
        if p.shadows != 0 || highlights != 0 {
            let f = CIFilter(name: "CIHighlightShadowAdjust")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(p.shadows, forKey: "inputShadowAmount")
            f.setValue(1 - highlights, forKey: "inputHighlightAmount")
            image = f.outputImage ?? image
        }
        if window { image = rolloff(image) }
        image = clamp01(image)

        // 4. Gammakodat: nivåer, S-kurva, färg.
        image = image.applyingFilter("CILinearToSRGBToneCurve")
        if blackPoint != 0 || whitePoint != 1 {
            let range = max(whitePoint - blackPoint, 0.5)
            let s = CGFloat(1 / range)
            image = clamp01(colorMatrix(image, scale: (s, s, s), bias: CGFloat(-blackPoint / range)))
        }
        if p.contrast > 0 {
            // y = x - a·sin(2πx)/(2π): lutning 1+a i mitten, 1-a i ändarna, monoton för a ≤ 1.
            let pts = [0.0, 0.25, 0.5, 0.75, 1.0].map { x in x - p.contrast * sin(2 * .pi * x) / (2 * .pi) }
            let f = CIFilter(name: "CIToneCurve")!
            f.setValue(image, forKey: kCIInputImageKey)
            for (i, key) in ["inputPoint0", "inputPoint1", "inputPoint2", "inputPoint3", "inputPoint4"].enumerated() {
                f.setValue(CIVector(x: CGFloat(i) * 0.25, y: CGFloat(min(max(pts[i], 0), 1))), forKey: key)
            }
            image = f.outputImage ?? image
        }
        if p.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }
        if p.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1 + p.saturation])
        }
        return image
    }

    /// Mjuk roll-off per kanal (linjärt): identitet upp till knät `k`, därefter
    /// `k + (1−k)·(1 − e^(−(x−k)/(1−k)))` — närmar sig 1 utan hård klippning.
    static func rolloffValue(_ x: Float, knee k: Float = windowRolloffKnee) -> Float {
        x <= k ? x : k + (1 - k) * (1 - expf(-(x - k) / (1 - k)))
    }

    private static let rolloffDomain: Float = 4
    private static let rolloffCurve: Data = {
        let n = 512
        var values = [Float]()
        values.reserveCapacity(n * 3)
        for i in 0..<n {
            let y = rolloffValue(Float(i) / Float(n - 1) * rolloffDomain)
            values.append(contentsOf: [y, y, y])
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    private static func rolloff(_ image: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIColorCurves") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(rolloffCurve, forKey: "inputCurvesData")
        f.setValue(CIVector(x: 0, y: CGFloat(rolloffDomain)), forKey: "inputCurvesDomain")
        f.setValue(CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, forKey: kCIInputColorSpaceKey)
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Masken dilaterad med `radius` px och mjukad med `radius / 4` (för clarity-dämpningen). Görs på en
    /// nedskalad kopia (~512 px) — snabbt även för stora radier.
    private static func dilatedMask(_ mask: CIImage, extent: CGRect, radius: Double) -> CIImage {
        let longSide = Double(max(extent.width, extent.height))
        let f = min(1, 512 / max(longSide, 1))
        let small = mask.clampedToExtent().transformed(by: CGAffineTransform(scaleX: f, y: f))
        let r = max(1, radius * f)
        let grown = small.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r * 0.25])
        return clamp01(grown.transformed(by: CGAffineTransform(scaleX: 1 / f, y: 1 / f)).cropped(to: extent))
    }

    /// Läser en fönstermask (gråskale-PNG) som `CIImage` utan färghantering, så att
    /// värdena används rakt av som blandningsvikter.
    static func loadMask(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.colorSpace: NSNull()])
    }

    /// Fönstermasken nedskalad till `width × height` (0…1, rad 0 = överst) för analysen.
    static func maskPixels(_ url: URL, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).map { Float(bytes[$0]) / 255 }
    }

    private static func colorMatrix(_ image: CIImage, scale: (CGFloat, CGFloat, CGFloat), bias: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale.2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])
    }

    private static func clamp01(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]).cropped(to: extent)
    }

    /// Osharp mask med kanterna förlängda, så bildkanten inte får en ljus/mörk ram.
    private static func unsharp(_ image: CIImage, extent: CGRect, radius: Double, intensity: Double) -> CIImage {
        let f = CIFilter(name: "CIUnsharpMask")!
        f.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        f.setValue(intensity, forKey: kCIInputIntensityKey)
        return f.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Rendering till pixlar

    /// Renderar `image` till RGBA float32, sRGB-gammakodat. `maxDimension` > 0 skalar ned.
    static func renderPixels(_ image: CIImage, context: CIContext, maxDimension: Int = 0) -> (pixels: [Float], width: Int, height: Int)? {
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let long = max(img.extent.width, img.extent.height)
        if maxDimension > 0, long > CGFloat(maxDimension) {
            let scale = CGFloat(maxDimension) / long
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(scale, forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let out = f.outputImage { img = out }
        }
        let extent = img.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(img, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: srgb)
        }
        return (pixels, width, height)
    }

    // MARK: - Horisont (Vision)

    /// Horisontlutning i grader (Vision, `PhotoQualityService.tiltDegrees`-normaliserad) om
    /// Vision hittar en horisont — vanligt saknas den helt i interiörer.
    static func measureHorizon(pixels: [Float], width: Int, height: Int) async -> Double? {
        var rgba8 = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 { rgba8[i * 4 + c] = UInt8((min(max(pixels[i * 4 + c], 0), 1) * 255).rounded()) }
        }
        guard let provider = CGDataProvider(data: Data(rgba8) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        guard let horizon = try? await DetectHorizonRequest().perform(on: cg) else { return nil }
        return PhotoQualityService.tiltDegrees(fromRadians: horizon.angle.converted(to: .radians).value)
    }

    // MARK: - Hela flödet för en bild

    enum Source: Sendable {
        /// Färdig bild på disk (HDR-TIFF, eller en förhandsbild).
        case image(URL)
        /// RAW som renderas med `RAWRenderer` (samma inställningar som HDR-steget).
        case raw(URL, maxDimension: Int)
    }

    struct Request: Sendable {
        var source: Source
        var tiffURL: URL
        var jpegURL: URL
        var profile: EnhancementProfile
        var alreadySharpened: Bool
        /// Fil att kopiera EXIF-grunddata från (datum, kamera, exponering).
        var exifSource: URL
        var exiftoolPath: String?
        /// IPTC/XMP/GPS för TIFF- respektive JPEG-filen när den redan är känd (fas 1b) — skrivs i
        /// samma exiftool-anrop som EXIF-kopian. `nil` = bara EXIF, metadatasteget skriver resten.
        var tiffMetadata: IPTCFileMetadata?
        var jpegMetadata: IPTCFileMetadata?
        /// Tillåt horisonträtning (bara för exteriörbilder, se klassens dokumentation).
        var allowStraighten: Bool = false
        /// Gruppens fönstermask från window pull (`hdr_masks/hdr_group_N.png`), om den finns.
        var windowMaskURL: URL? = nil
        /// Räta lodlinjer (`VerticalCorrection`) när skattningen är säker.
        var upright: Bool = false
        var jpegMaxDimension: Int = 4000
        var jpegQuality: Double = 0.92
    }

    struct Outcome: Sendable {
        var analysis: EnhancementAnalysis
        var autoParameters: EnhancementParameters
        var parameters: EnhancementParameters
        var width: Int
        var height: Int
        /// Sant om metadatan (EXIF + ev. IPTC/XMP/GPS) skrevs utan fel.
        var metadataWritten = false
    }

    enum EngineError: LocalizedError {
        case cannotRead(URL)
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .cannotRead(let url): return "Kunde inte läsa bilden: \(url.lastPathComponent)"
            case .renderFailed: return "Kunde inte rendera den förbättrade bilden."
            }
        }
    }

    /// Källans storlek på disk (för `timings.jsonl`).
    private static func sourceSize(_ source: Source) -> Int64 {
        switch source {
        case .image(let url), .raw(let url, _): return PipelineMetrics.totalSize(of: [url])
        }
    }

    /// Läser `source` till en `CIImage` (sRGB-taggad).
    static func loadImage(_ source: Source) throws -> CIImage {
        switch source {
        case .image(let url):
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw EngineError.cannotRead(url)
            }
            return image
        case .raw(let url, let maxDimension):
            let rendered = try RAWRenderer.render(url: url, whiteBalance: nil, maxDimension: maxDimension)
            let data = rendered.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CIImage(
                bitmapData: data, bytesPerRow: rendered.width * 16,
                size: CGSize(width: rendered.width, height: rendered.height), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        }
    }

    /// Förbättrar en bild och skriver TIFF + JPEG (atomiskt TIFF, via `HDRWriter`).
    ///
    /// `@concurrent`: tung bildbehandling (RAW-rendering, Core Image, pixelräkning)
    /// måste köras utanför huvudtråden — se `HDREngine.merge`.
    @concurrent
    static func enhance(_ request: Request) async throws -> Outcome {
        try Task.checkCancellation()
        let source = try PipelineMetrics.phase("load", bytesIn: sourceSize(request.source)) { try loadImage(request.source) }
        let context = makeContext()

        guard let small = PipelineMetrics.phase("decodeAndDownscale", { renderPixels(source, context: context, maxDimension: analysisMaxDimension) }) else {
            throw EngineError.renderFailed
        }
        try Task.checkCancellation()
        // Fönstermasken (om window pull gav någon): saknas/oläsbar → vanlig rendering.
        let maskURL = request.windowMaskURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let windowMask = maskURL.flatMap { loadMask($0) }
        let analysisMask = windowMask == nil ? nil : maskURL.flatMap { maskPixels($0, width: small.width, height: small.height) }
        let horizon = (request.profile.straighten && request.allowStraighten)
            ? await PipelineMetrics.phaseAsync("horizon") { await measureHorizon(pixels: small.pixels, width: small.width, height: small.height) }
            : nil
        let (auto, analysis) = PipelineMetrics.phase("analysis") {
            automaticParameters(Input(
                pixels: small.pixels, width: small.width, height: small.height,
                horizonDegrees: horizon, alreadySharpened: request.alreadySharpened, mask: analysisMask
            ))
        }
        var final = request.profile.finalParameters(auto: auto)
        if request.profile.look == BrokerLook.profileLookID {
            final = BrokerLook.parameters(base: final, pixels: small.pixels, width: small.width, height: small.height,
                                          mask: analysisMask, taggedExterior: request.allowStraighten)
        }
        if request.upright {
            let focal = VerticalCorrection.focal(fromExifOf: request.exifSource)
            if let perspective = PipelineMetrics.phase("upright", {
                VerticalCorrection.measure(pixels: small.pixels, width: small.width, height: small.height, focal: focal)
            }) {
                final.perspective = perspective
                final.rotationDegrees = 0  // rotationen ingår i lodlinjekorrigeringen
            }
        }

        try Task.checkCancellation()
        let enhanced = render(source, parameters: final, windowMask: analysisMask == nil ? nil : windowMask)
        guard let full = PipelineMetrics.phase("render", { renderPixels(enhanced, context: context) }) else { throw EngineError.renderFailed }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: request.tiffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HDRWriter.write(
            pixels: full.pixels, width: full.width, height: full.height,
            tiffURL: request.tiffURL, jpegURL: request.jpegURL,
            jpegMaxDimension: request.jpegMaxDimension, jpegQuality: request.jpegQuality
        )
        var metadataWritten = false
        if let exiftoolPath = request.exiftoolPath {
            metadataWritten = PipelineMetrics.phase("exif") {
                HDRWriter.writeMetadata(from: request.exifSource,
                                        outputs: [(request.tiffURL, request.tiffMetadata), (request.jpegURL, request.jpegMetadata)],
                                        exiftoolPath: exiftoolPath)
            }
        }
        return Outcome(analysis: analysis, autoParameters: auto, parameters: final, width: full.width, height: full.height,
                       metadataWritten: metadataWritten)
    }
}
