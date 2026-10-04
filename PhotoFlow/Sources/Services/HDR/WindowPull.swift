import Foundation

/// "Window pull": fönsterutsikten tas från bracketens mörkaste exponering i stället
/// för ur Mertens-fusionen, som bara kan snitta klippta ramar (grå, utfrätta fönster)
/// när den mörka ramen saknas eller väger lätt. Se `docs/plan-hdr-fonster.md`, avsnitt 2.
///
/// Gången (allt efter fusionen, före skärpningen):
/// 1. **Detektering** på ~1500 px: pixlar som är klippta i referensen (medianexponeringen)
///    men informativa i den mörka ramen och mycket ljusare än interiören. Morfologi
///    (öppning, stängning) och komponentfiltrering: små fläckar, lampor och himmel
///    (stor yta mot överkanten) sorteras bort.
/// 2. **Kantmedveten mask**: guided filter med den mörka ramens luma som guide (snabb
///    variant: koefficienter på ~3000 px, tillämpade på full upplösning), sedan
///    dilatation 1–2 px så att överstrålningen kring karmen ersätts.
/// 3. **Spökskydd**: i ett band kring maskkanten dras masken in där referensen och den
///    (exponeringsmatchade) mörka ramen skiljer sig — rörelse eller kvarvarande förskjutning.
/// 4. **Blandning**: den mörka ramen exponeringsmatchas (gain i linjärt ljus så att
///    fönstrets median hamnar kring `targetMedian`, med tak för p99) och blandas in:
///    `ut = (1 − m·s)·fusion + m·s·mörkMatchad`. Hela fönstret kommer därmed från en ram.
///
/// Ren `nonisolated enum` utan tillstånd: anropas från `HDREngine.merge` (redan utanför
/// huvudaktören) och från tester med syntetiska bilder.
nonisolated enum WindowPull {
    typealias Plane = ExposureFusion.Plane

    struct Options: Sendable, Equatable {
        var enabled = true
        /// 0…1 — hur mycket av den mörka ramen som blandas in i masken.
        var strength: Float = 0.85
        /// Justerar fönstrets målljushet i EV (inställningen "Fönsterljushet").
        var brightnessEV: Float = 0
        /// Ta med lampor och himmel (annars sorteras de bort).
        var includeLampsAndSky = false

        // Konstanter (justerade mot testmängden, se docs/plan-hdr-fonster.md avsnitt 3).
        var detectDimension = 1500
        var guideDimension = 3000
        /// Referensen räknas som klippt från denna max-kanal.
        var referenceClip: Float = 0.96
        /// Den mörka ramen räknas som informativ upp till denna max-kanal …
        var darkInformativeMax: Float = 0.95
        /// … och från denna luma.
        var darkMinLuma: Float = 0.08
        /// Scenluminansen måste vara minst så här många gånger interiörens median.
        var sceneRatio: Float = 4
        /// Fönstrets mål-median (gammakodad luma) efter exponeringsmatchningen.
        var targetMedian: Float = 0.66
        /// Högsta tillåtna p99 (max-kanal) i masken efter matchningen.
        var maxP99: Float = 0.97
        /// Största upp- respektive nedjustering av den mörka ramen, i EV.
        var maxGainEV: Float = 2
        var minGainEV: Float = -1
        /// Komponenter mindre än denna andel av bilden slängs.
        var minComponentFraction: Double = 0.0005
        /// Guided filter: radie som andel av långsidan och regularisering.
        var guidedRadiusFraction: Double = 0.0015
        var guidedEps: Float = 1e-2
        /// Dilatation efter guided filter (px vid 6000 px långsida).
        var dilatePixels: Double = 1.5
        /// Längsta avstånd (px vid 6000 px långsida) som masken får sprida sig utanför
        /// den detekterade ytan.
        var maxSpreadPixels: Double = 4
        /// Spökskyddsbandets halvbredd (px vid 6000 px långsida) och tröskel (gammaluma).
        var ghostBandPixels: Double = 32
        var ghostThreshold: Float = 0.12
        /// Minsta textur (medel |Laplace| av mörka ramens luma på ~1500 px) för ett fönster,
        /// och för en färgstark komponent (kroma över `coloredSurfaceChroma`).
        var minTexture: Float = 0.02
        var minTextureColored: Float = 0.045
        var coloredSurfaceChroma: Float = 0.25
        /// Komponenter vars överkant ligger under denna andel av bildhöjden är golv/reflexer.
        var floorTop: Double = 0.55

        init(enabled: Bool = true, strength: Float = 0.85, brightnessEV: Float = 0, includeLampsAndSky: Bool = false) {
            self.enabled = enabled
            self.strength = strength
            self.brightnessEV = brightnessEV
            self.includeLampsAndSky = includeLampsAndSky
        }
    }

    /// Sammanfattning per grupp — sparas i `hdr.json` (fönsterstatistik).
    struct Stats: Codable, Sendable, Equatable {
        var applied: Bool = false
        /// Varför inget drogs in (t.ex. "inga fönster", "mörka ramen inte mörkare").
        var reason: String?
        /// Maskens andel av bilden (m ≥ 0,5).
        var maskFraction: Double = 0
        var components: Int = 0
        var smallDropped: Int = 0
        var lampsDropped: Int = 0
        var skyDropped: Int = 0
        /// Ljusa ytor inne i rummet (solbelyst vägg/golv) som inte drogs in.
        var surfacesDropped: Int = 0
        /// Den mörka ramens exponering relativt referensen (negativ = mörkare), uppmätt.
        var darkToReferenceEV: Double = 0
        /// Gain som lades på den mörka ramen, i EV.
        var gainEV: Double = 0
        /// Andel av masken som spökskyddet drog in.
        var ghostFraction: Double = 0
        var seconds: Double = 0
    }

    struct Result {
        var pixels: [Float]
        /// Slutlig mask (utan styrka) på ~`detectDimension` px — sparas som PNG.
        var mask: Plane
        /// Masken på full upplösning (för mått i felsökningsläget).
        var fullMask: Plane?
        var stats: Stats
        var gain: Float
        /// Kandidatkomponenterna med beslut (felsökning).
        var components: [ComponentInfo] = []
    }

    // MARK: - Huvudfunktion

    /// - Parameters:
    ///   - fused: fusionens resultat (RGBA, full upplösning).
    ///   - reference: referensexponeringen (medianen), registrerad.
    ///   - dark: den mörkaste exponeringen, registrerad mot referensen.
    ///   - keepFullMask: behåll masken i full upplösning (felsökning/mått).
    static func apply(fused: [Float], reference: [Float], dark: [Float], width: Int, height: Int,
                      options: Options, keepFullMask: Bool = false) -> Result {
        let started = Date()
        var stats = Stats()
        var components: [ComponentInfo] = []
        let longSide = max(width, height)
        let emptySize = HDRImageOps.scaledSize(width: width, height: height, maxDimension: options.detectDimension)
        func noPull(_ reason: String) -> Result {
            stats.reason = reason
            stats.seconds = Date().timeIntervalSince(started)
            return Result(pixels: fused, mask: Plane(width: emptySize.width, height: emptySize.height,
                                                     data: [Float](repeating: 0, count: emptySize.width * emptySize.height)),
                          fullMask: nil, stats: stats, gain: 1, components: components)
        }
        guard options.enabled, options.strength > 0, width > 8, height > 8 else { return noPull("avstängd") }

        // 1. Guide- och detekteringsupplösning.
        let g = HDRImageOps.scaledSize(width: width, height: height, maxDimension: options.guideDimension)
        let refG = HDRImageOps.scaleRGBA(reference, width: width, height: height, toWidth: g.width, toHeight: g.height)
        let darkG = HDRImageOps.scaleRGBA(dark, width: width, height: height, toWidth: g.width, toHeight: g.height)
        let s = HDRImageOps.scaledSize(width: g.width, height: g.height, maxDimension: options.detectDimension)
        let refS = HDRImageOps.scaleRGBA(refG, width: g.width, height: g.height, toWidth: s.width, toHeight: s.height)
        let darkS = HDRImageOps.scaleRGBA(darkG, width: g.width, height: g.height, toWidth: s.width, toHeight: s.height)

        let fusedS = HDRImageOps.scaleRGBA(fused, width: width, height: height, toWidth: s.width, toHeight: s.height)
        let detection = detect(reference: refS, dark: darkS, fused: fusedS, width: s.width, height: s.height, options: options)
        stats.surfacesDropped = detection.surfaces
        components = detection.components
        stats.darkToReferenceEV = -Double(log2(max(detection.ratio, 1e-3)))
        stats.components = detection.kept
        stats.smallDropped = detection.small
        stats.lampsDropped = detection.lamps
        stats.skyDropped = detection.sky
        guard detection.ratio >= 1.4 else { return noPull("mörka ramen är inte mörkare än referensen") }
        guard detection.mask.data.contains(where: { $0 > 0 }) else { return noPull("inga fönster hittades") }

        // 2. Kantmedveten mask: guided filter (snabb variant) med mörka ramens luma som guide.
        let guideG = HDRImageOps.lumaPlane(darkG, width: g.width, height: g.height)
        let maskG = HDRImageOps.bilinear(detection.mask, toWidth: g.width, toHeight: g.height)
        let factor = Double(longSide) / Double(max(g.width, g.height))
        let radiusG = max(2, Int((options.guidedRadiusFraction * Double(longSide) / factor).rounded()))
        let coeffs = HDRImageOps.guidedCoefficients(guide: guideG, input: maskG, radius: radiusG, eps: options.guidedEps)
        let aFull = HDRImageOps.bilinear(coeffs.a, toWidth: width, toHeight: height)
        let bFull = HDRImageOps.bilinear(coeffs.b, toWidth: width, toHeight: height)
        // Tak: guided filter-svansen får inte nå längre än `maxSpreadPixels` utanför den
        // detekterade masken — annars mörknar karmen närmast glaset (uppmätt "pull-halo"
        // 15–18 px innan taket fanns).
        let spreadG = max(1, Int((options.maxSpreadPixels * Double(longSide) / 6000 / factor).rounded()))
        let limitG = HDRImageOps.morph(Plane(width: g.width, height: g.height, data: maskG.data.map { $0 >= 0.5 ? 1 : 0 }),
                                       radius: spreadG, dilate: true)
        let limitFull = HDRImageOps.bilinear(limitG, toWidth: width, toHeight: height)
        var mask = [Float](repeating: 0, count: width * height)
        dark.withUnsafeBufferPointer { dBuf in
            mask.withUnsafeMutableBufferPointer { mBuf in
                let d = HDRImageOps.Shared(dBuf), m = HDRImageOps.Shared(mBuf)
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let p = y * width + x
                        let lum = HDRImageOps.luma(d[p * 4], d[p * 4 + 1], d[p * 4 + 2])
                        m[p] = min(max(aFull.data[p] * lum + bFull.data[p], 0), 1, limitFull.data[p])
                    }
                }
            }
        }
        // Brus från guided filter långt från fönstren: allt under 2 % räknas som 0.
        for i in 0..<mask.count where mask[i] < 0.02 { mask[i] = 0 }
        var fullMask = Plane(width: width, height: height, data: mask)
        let dilateRadius = max(1, Int((options.dilatePixels * Double(longSide) / 6000).rounded()))
        fullMask = HDRImageOps.morph(fullMask, radius: dilateRadius, dilate: true)

        // 3. Spökskydd i bandet kring maskkanten (på guideupplösningen).
        let ghost = ghostMap(reference: refG, dark: darkG, mask: maskG, ratio: detection.ratio,
                             bandRadius: max(2, Int((options.ghostBandPixels * Double(longSide) / 6000 / factor).rounded())),
                             options: options)
        if ghost.count > 0 {
            let ghostFull = HDRImageOps.bilinear(ghost.map, toWidth: width, toHeight: height)
            var before = 0.0, removed = 0.0
            for i in 0..<fullMask.data.count where fullMask.data[i] > 0 {
                let m = fullMask.data[i]
                let reduced = m * (1 - min(max(ghostFull.data[i], 0), 1))
                before += Double(m)
                removed += Double(m - reduced)
                fullMask.data[i] = reduced
            }
            stats.ghostFraction = before > 0 ? removed / before : 0
        }

        // 4. Exponeringsmatchning av den mörka ramen inom masken.
        let maskSmallFinal = HDRImageOps.scale(fullMask, toWidth: s.width, toHeight: s.height)
        let gain = matchGain(dark: darkS, mask: maskSmallFinal, options: options)
        stats.gainEV = Double(log2(gain))

        // 5. Blandning.
        let strength = min(max(options.strength, 0), 1)
        var out = fused
        var maskCount = 0
        for v in fullMask.data where v >= 0.5 { maskCount += 1 }
        out.withUnsafeMutableBufferPointer { oBuf in
            dark.withUnsafeBufferPointer { dBuf in
                fullMask.data.withUnsafeBufferPointer { mBuf in
                    let o = HDRImageOps.Shared(oBuf), d = HDRImageOps.Shared(dBuf), m = HDRImageOps.Shared(mBuf)
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for x in 0..<width {
                            let p = y * width + x
                            let w = m[p] * strength
                            guard w > 1e-4 else { continue }
                            for c in 0..<3 {
                                let matched = matchedValue(d[p * 4 + c], gain: gain)
                                o[p * 4 + c] = (1 - w) * o[p * 4 + c] + w * matched
                            }
                        }
                    }
                }
            }
        }

        stats.applied = maskCount > 0
        stats.maskFraction = Double(maskCount) / Double(width * height)
        if !stats.applied { stats.reason = "masken blev tom efter förfining" }
        stats.seconds = Date().timeIntervalSince(started)
        let savedMask = HDRImageOps.scale(fullMask, toWidth: emptySize.width, toHeight: emptySize.height)
        return Result(pixels: out, mask: Plane(width: savedMask.width, height: savedMask.height, data: savedMask.data.map { min(max($0, 0), 1) }),
                      fullMask: keepFullMask ? fullMask : nil, stats: stats, gain: gain, components: components)
    }

    /// Den mörka ramens värde efter gain i linjärt ljus, med mjuk axel över 0,9 så att
    /// enstaka toppar inte klipps hårt.
    @inline(__always) static func matchedValue(_ v: Float, gain: Float) -> Float {
        let y = HDRImageOps.toGamma(HDRImageOps.toLinear(v) * gain)
        let knee: Float = 0.9
        guard y > knee else { return y }
        return knee + (1 - knee) * (1 - expf(-(y - knee) / (1 - knee)))
    }

    /// Hela den mörka ramen exponeringsmatchad (felsökningsbild "mörkMatchad").
    static func matchedDark(_ dark: [Float], gain: Float) -> [Float] {
        var out = dark
        let pixelCount = out.count / 4
        out.withUnsafeMutableBufferPointer { oBuf in
            let o = HDRImageOps.Shared(oBuf)
            DispatchQueue.concurrentPerform(iterations: pixelCount / 65536 + 1) { chunk in
                let start = chunk * 65536, end = min(pixelCount, start + 65536)
                guard start < end else { return }
                for p in start..<end { for c in 0..<3 { o[p * 4 + c] = matchedValue(o[p * 4 + c], gain: gain) } }
            }
        }
        return out
    }

    // MARK: - Detektering

    /// En kandidatkomponent och varför den togs med eller sorterades bort (felsökning).
    struct ComponentInfo: Codable, Sendable, Equatable {
        var fraction: Double
        /// Ruta i andelar av bilden: x0, y0, x1, y1.
        var box: [Double]
        var rectangularity: Double
        /// Mörka ramens medelluma, kroma (max − min) och textur (medel |Laplace|) i komponenten.
        var darkLuma: Double
        var darkChroma: Double
        var darkTexture: Double
        /// Andel av rutan som är klippt även i mörka ramen.
        var coreClipped: Double
        /// Fusionens medianluma i en ring utanför komponenten, och komponentens median efter
        /// exponeringsmatchningen.
        var ringLuma: Double
        var matchedLuma: Double
        var verdict: String
    }

    struct Detection {
        var mask: Plane
        /// Linjär ljuskvot referens/mörk ram (uppmätt).
        var ratio: Float
        var kept = 0, small = 0, lamps = 0, sky = 0, surfaces = 0
        var components: [ComponentInfo] = []
    }

    static func detect(reference: [Float], dark: [Float], fused: [Float], width: Int, height: Int, options: Options) -> Detection {
        let n = width * height
        var refMax = [Float](repeating: 0, count: n), refLuma = [Float](repeating: 0, count: n)
        var darkMax = [Float](repeating: 0, count: n), darkLuma = [Float](repeating: 0, count: n)
        var darkChroma = [Float](repeating: 0, count: n), fusedLuma = [Float](repeating: 0, count: n)
        for p in 0..<n {
            refMax[p] = max(reference[p * 4], reference[p * 4 + 1], reference[p * 4 + 2])
            refLuma[p] = HDRImageOps.luma(reference[p * 4], reference[p * 4 + 1], reference[p * 4 + 2])
            darkMax[p] = max(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2])
            darkLuma[p] = HDRImageOps.luma(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2])
            darkChroma[p] = darkMax[p] - min(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2])
            fusedLuma[p] = HDRImageOps.luma(fused[p * 4], fused[p * 4 + 1], fused[p * 4 + 2])
        }

        // Ljuskvoten referens/mörk i linjärt ljus, uppmätt där båda är välexponerade.
        var ratios: [Float] = []
        var interior: [Float] = []
        ratios.reserveCapacity(n / 4)
        for p in 0..<n {
            if refMax[p] < options.referenceClip { interior.append(HDRImageOps.toLinear(refLuma[p])) }
            guard refMax[p] > 0.15, refMax[p] < 0.85, darkMax[p] > 0.03, darkMax[p] < 0.85 else { continue }
            let ld = HDRImageOps.toLinear(darkLuma[p])
            guard ld > 1e-4 else { continue }
            ratios.append(HDRImageOps.toLinear(refLuma[p]) / ld)
        }
        let ratio = ratios.count >= 200 ? HDRImageOps.percentile(ratios, 0.5) : 4
        let interiorMedian = max(HDRImageOps.percentile(interior, 0.5), 1e-4)

        // Kandidatpixlar.
        var cand = [Float](repeating: 0, count: n)
        var clippedBoth = [Float](repeating: 0, count: n)
        for p in 0..<n {
            guard refMax[p] >= options.referenceClip else { continue }
            if darkMax[p] > options.darkInformativeMax { clippedBoth[p] = 1; continue }
            guard darkLuma[p] >= options.darkMinLuma else { continue }
            let scene = HDRImageOps.toLinear(darkLuma[p]) * ratio
            if scene >= options.sceneRatio * interiorMedian { cand[p] = 1 }
        }

        // Morfologi: öppning ~3 px, stängning ~9 px (vid 1500 px), sedan hålfyllnad så att
        // mörkare partier i utsikten (träd, tak) inte blir hål — hela fönstret från en ram.
        let scale = Double(max(width, height)) / 1500
        let openR = max(1, Int((1.0 * scale).rounded()))
        let closeR = max(1, Int((4.0 * scale).rounded()))
        var plane = Plane(width: width, height: height, data: cand)
        plane = HDRImageOps.morph(HDRImageOps.morph(plane, radius: openR, dilate: false), radius: openR, dilate: true)
        plane = HDRImageOps.morph(HDRImageOps.morph(plane, radius: closeR, dilate: true), radius: closeR, dilate: false)
        plane.data = fillHoles(plane.data, width: width, height: height)

        // Komponenter.
        let (labels, count) = labelComponents(plane.data, width: width, height: height)
        var detection = Detection(mask: Plane(width: width, height: height, data: [Float](repeating: 0, count: n)), ratio: ratio)
        guard count > 0 else { return detection }
        var area = [Int](repeating: 0, count: count + 1)
        var minX = [Int](repeating: Int.max, count: count + 1), maxX = [Int](repeating: -1, count: count + 1)
        var minY = [Int](repeating: Int.max, count: count + 1), maxY = [Int](repeating: -1, count: count + 1)
        var darkSum = [Double](repeating: 0, count: count + 1), chromaSum = [Double](repeating: 0, count: count + 1)
        var textureSum = [Double](repeating: 0, count: count + 1)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let l = Int(labels[p])
                guard l > 0 else { continue }
                area[l] += 1
                minX[l] = min(minX[l], x); maxX[l] = max(maxX[l], x)
                minY[l] = min(minY[l], y); maxY[l] = max(maxY[l], y)
                darkSum[l] += Double(darkLuma[p])
                chromaSum[l] += Double(darkChroma[p])
                if x > 0, y > 0, x < width - 1, y < height - 1 {
                    let lap = 4 * darkLuma[p] - darkLuma[p - 1] - darkLuma[p + 1] - darkLuma[p - width] - darkLuma[p + width]
                    textureSum[l] += Double(abs(lap))
                }
            }
        }
        // Integralbild av "klippt även i mörka ramen" för snabba summor per komponents ruta.
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += Double(clippedBoth[y * width + x])
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + rowSum
            }
        }
        func clippedIn(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let W = width + 1
            return integral[(y1 + 1) * W + x1 + 1] - integral[y0 * W + x1 + 1] - integral[(y1 + 1) * W + x0] + integral[y0 * W + x0]
        }

        var keep = [Bool](repeating: false, count: count + 1)
        var infos = [ComponentInfo?](repeating: nil, count: count + 1)
        for l in 1...count {
            let fraction = Double(area[l]) / Double(n)
            if fraction < options.minComponentFraction { detection.small += 1; continue }
            let boxW = maxX[l] - minX[l] + 1, boxH = maxY[l] - minY[l] + 1
            let meanDark = darkSum[l] / Double(area[l])
            let core = clippedIn(minX[l], minY[l], maxX[l], maxY[l])
            var info = ComponentInfo(
                fraction: fraction,
                box: [Double(minX[l]) / Double(width), Double(minY[l]) / Double(height),
                      Double(maxX[l] + 1) / Double(width), Double(maxY[l] + 1) / Double(height)],
                rectangularity: Double(area[l]) / Double(boxW * boxH), darkLuma: meanDark,
                darkChroma: chromaSum[l] / Double(area[l]), darkTexture: textureSum[l] / Double(area[l]),
                coreClipped: core / Double(boxW * boxH), ringLuma: 0, matchedLuma: 0, verdict: "fönster")
            // Lampa: liten, och antingen en klippt kärna även i mörka ramen (ringen runt
            // glödtråden/skärmen är det som blev kandidat) eller platt nästan vit.
            let isLamp = fraction < 0.006 && (core >= 0.1 * Double(area[l]) || meanDark >= 0.7)
            // Himmel: stor yta som når överkanten och spänner över mycket av bredden.
            let isSky = minY[l] <= max(1, height / 100) && fraction >= 0.08 && Double(boxW) >= 0.4 * Double(width)
            if isLamp && !options.includeLampsAndSky {
                detection.lamps += 1; info.verdict = "lampa"
            } else if isSky && !options.includeLampsAndSky {
                detection.sky += 1; info.verdict = "himmel"
            } else {
                keep[l] = true
            }
            infos[l] = info
        }

        // Ljusa ytor inne i rummet ser ut som fönster i ljusvillkoren: solbelyst vägg eller
        // golv, blanka reflexer. Två enkla kännetecken, uppmätta på testmängden:
        //  - utsikten har detaljer (träd, hus, spröjsar) — en slät vägg har nästan ingen textur
        //    i den mörka ramen (vit vägg ≤ 0,011, fönster 0,03–0,18). Färgstarka ytor (solbelyst
        //    träpanel: textur 0,034 men kroma 0,33) kräver mer textur än utsikter (kroma ≤ 0,18);
        //  - ett fönster börjar aldrig i bildens nedre del — solfläckar och reflexer på golvet gör.
        // Fusionens luma i en ring runt komponenten och den matchade medianen sparas för felsökning.
        func maskOf(_ selected: [Bool]) -> Plane {
            var data = [Float](repeating: 0, count: n)
            for p in 0..<n where labels[p] > 0 && selected[Int(labels[p])] { data[p] = 1 }
            return Plane(width: width, height: height, data: data)
        }
        for l in 1...count where keep[l] {
            guard let info = infos[l] else { continue }
            if info.darkTexture < Double(options.minTexture)
                || (info.darkTexture < Double(options.minTextureColored) && info.darkChroma > Double(options.coloredSurfaceChroma)) {
                keep[l] = false; detection.surfaces += 1; infos[l]?.verdict = "slät yta"
            } else if info.box[1] > options.floorTop {
                keep[l] = false; detection.surfaces += 1; infos[l]?.verdict = "golv/reflex"
            }
        }
        let gain = matchGain(dark: dark, mask: maskOf(keep), options: options)
        for l in 1...count where infos[l] != nil && infos[l]!.verdict != "lampa" && infos[l]!.verdict != "himmel" {
            var single = [Bool](repeating: false, count: count + 1)
            single[l] = true
            let compMask = maskOf(single)
            let inner = HDRImageOps.morph(compMask, radius: max(1, Int((2 * scale).rounded())), dilate: true)
            let outer = HDRImageOps.morph(compMask, radius: max(2, Int((8 * scale).rounded())), dilate: true)
            var ring: [Float] = [], inside: [Float] = []
            for y in max(0, minY[l] - 12)...min(height - 1, maxY[l] + 12) {
                for x in max(0, minX[l] - 12)...min(width - 1, maxX[l] + 12) {
                    let p = y * width + x
                    if compMask.data[p] > 0.5 { inside.append(darkLuma[p]) }
                    else if outer.data[p] > 0.5 && inner.data[p] < 0.5 && labels[p] == 0 { ring.append(fusedLuma[p]) }
                }
            }
            infos[l]?.ringLuma = Double(HDRImageOps.percentile(ring, 0.5))
            infos[l]?.matchedLuma = Double(matchedValue(HDRImageOps.percentile(inside, 0.5), gain: gain))
        }
        for l in 1...count where keep[l] { detection.kept += 1 }
        detection.mask = maskOf(keep)
        // Partier av fönstret som är klippta även i den mörka ramen (frostat glas, bländande
        // himmel) hör till fönstret: växer masken in i dem. Annars gick maskkanten mitt i en
        // jämnvit yta utan någon kant att följa, och övergången blev trappstegsformad.
        var queue: [Int] = []
        queue.reserveCapacity(n / 8)
        for p in 0..<n where detection.mask.data[p] > 0.5 { queue.append(p) }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            let x = p % width, y = p / width
            for dy in -1...1 {
                let ny = y + dy
                guard ny >= 0, ny < height else { continue }
                for dx in -1...1 {
                    let nx = x + dx
                    guard nx >= 0, nx < width else { continue }
                    let q = ny * width + nx
                    if clippedBoth[q] > 0.5 && detection.mask.data[q] < 0.5 {
                        detection.mask.data[q] = 1
                        queue.append(q)
                    }
                }
            }
        }
        detection.components = infos.compactMap { $0 }
        return detection
    }

    /// Fyller hål: bakgrundsområden (0) som inte når bildkanten blir 1.
    static func fillHoles(_ binary: [Float], width: Int, height: Int) -> [Float] {
        let inverse = binary.map { $0 > 0.5 ? Float(0) : 1 }
        let (labels, count) = labelComponents(inverse, width: width, height: height)
        guard count > 1 else { return binary }
        var touchesBorder = [Bool](repeating: false, count: count + 1)
        for x in 0..<width {
            touchesBorder[Int(labels[x])] = true
            touchesBorder[Int(labels[(height - 1) * width + x])] = true
        }
        for y in 0..<height {
            touchesBorder[Int(labels[y * width])] = true
            touchesBorder[Int(labels[y * width + width - 1])] = true
        }
        var out = binary
        for p in 0..<(width * height) where labels[p] > 0 && !touchesBorder[Int(labels[p])] { out[p] = 1 }
        return out
    }

    /// 8-grannskap, iterativ flodfyllning. Returnerar etiketter (0 = bakgrund) och antal.
    static func labelComponents(_ binary: [Float], width: Int, height: Int) -> (labels: [Int32], count: Int) {
        var labels = [Int32](repeating: 0, count: width * height)
        var count: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(width * height) where binary[start] > 0.5 && labels[start] == 0 {
            count += 1
            labels[start] = count
            stack.append(start)
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width, dx != 0 || dy != 0 else { continue }
                        let q = ny * width + nx
                        if binary[q] > 0.5 && labels[q] == 0 {
                            labels[q] = count
                            stack.append(q)
                        }
                    }
                }
            }
        }
        return (labels, Int(count))
    }

    // MARK: - Spökskydd

    /// Spökkarta (0…1) på guideupplösningen: i bandet ±`bandRadius` kring maskkanten,
    /// där referensen inte är klippt och skiljer sig från den mörka ramen uppskalad till
    /// referensens exponering. `count` = antal spökpixlar.
    static func ghostMap(reference: [Float], dark: [Float], mask: Plane, ratio: Float, bandRadius: Int,
                         options: Options) -> (map: Plane, count: Int) {
        let w = mask.width, h = mask.height, n = w * h
        let binary = Plane(width: w, height: h, data: mask.data.map { $0 >= 0.5 ? 1 : 0 })
        let outer = HDRImageOps.morph(binary, radius: bandRadius, dilate: true)
        let inner = HDRImageOps.morph(binary, radius: bandRadius, dilate: false)
        var ghost = [Float](repeating: 0, count: n)
        var count = 0
        for p in 0..<n where outer.data[p] > 0.5 && inner.data[p] < 0.5 {
            let rMax = max(reference[p * 4], reference[p * 4 + 1], reference[p * 4 + 2])
            guard rMax < options.referenceClip - 0.02 else { continue }
            let rLum = HDRImageOps.luma(reference[p * 4], reference[p * 4 + 1], reference[p * 4 + 2])
            let dLum = HDRImageOps.luma(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2])
            let predicted = min(HDRImageOps.toGamma(HDRImageOps.toLinear(dLum) * ratio), 1)
            guard predicted < 0.98 else { continue }
            if abs(rLum - predicted) > options.ghostThreshold { ghost[p] = 1; count += 1 }
        }
        guard count > 0 else { return (Plane(width: w, height: h, data: ghost), 0) }
        // Mjuka upp kartan lite så att indragningen inte får hårda kanter.
        let spread = HDRImageOps.boxMean(HDRImageOps.morph(Plane(width: w, height: h, data: ghost), radius: 1, dilate: true), radius: 2)
        return (spread, count)
    }

    // MARK: - Exponeringsmatchning

    /// Gain (linjär faktor) för den mörka ramen: fönstrets median → `targetMedian · 2^brightnessEV`,
    /// men p99 av max-kanalen ≤ `maxP99`, och inom [minGainEV, maxGainEV].
    static func matchGain(dark: [Float], mask: Plane, options: Options) -> Float {
        var lumas: [Float] = [], maxes: [Float] = []
        for p in 0..<(mask.width * mask.height) where mask.data[p] >= 0.5
            && max(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2]) <= options.darkInformativeMax {
            // Klippta partier (frostat glas, bländande himmel) säger inget om exponeringen.
            lumas.append(HDRImageOps.luma(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2]))
            maxes.append(max(dark[p * 4], dark[p * 4 + 1], dark[p * 4 + 2]))
        }
        guard lumas.count >= 20 else { return 1 }
        let median = max(HDRImageOps.toLinear(HDRImageOps.percentile(lumas, 0.5)), 1e-5)
        let p99 = max(HDRImageOps.toLinear(HDRImageOps.percentile(maxes, 0.99)), 1e-5)
        let target = min(options.targetMedian * powf(2, options.brightnessEV), 0.9)
        let gainTarget = HDRImageOps.toLinear(target) / median
        let gainCap = HDRImageOps.toLinear(options.maxP99) / p99
        let gain = min(gainTarget, gainCap)
        return min(max(gain, powf(2, options.minGainEV)), powf(2, options.maxGainEV))
    }
}
