import Foundation
import CoreGraphics
import ImageIO

/// Känner igen ett montage: två stående bilder som fotografen satt ihop sida vid sida till en
/// liggande bild (plan 8.4 punkt 1). Ren och testbar: arbetar på en gråskalekopia (`[UInt8]`), och
/// `panels(url:)` är bara en tunn laddare ovanpå.
///
/// Metoden (kopian är högst `maxPixels` bred, ca 1200 px, så en hel bild kostar ca 3 ms plus
/// avkodningen, ~30-60 ms):
///
/// 1. **Geometri först.** Bilden ska vara liggande men inte panorama (bredd/höjd 1,1...2,0), och
///    båda halvorna ska vara stående (bredd/höjd ≤ `maxHalfAspect`) och minst 30 % av bredden var.
/// 2. **Skarv med ränna (gutter).** Fotografens montageverktyg lägger en vit (eller svart) ränna
///    mellan halvorna. Den ger några intilliggande kolumner (mitten ±10 %) där *hela höjden* har
///    samma färg: standardavvikelsen längs kolumnen ≤ 2,5 gråsteg och medelvärdet inom ±6 av
///    rännans. En sådan kolumn finns inte i ett fotografi (fönster, dörrar och hörn har
///    alltid något annat i någon rad), och 0 av 754 vanliga bilder hade en. Rännan måste vara minst
///    2 px (0,15 % av bredden) och högst 8 %. Halvorna är det som ligger på var sida om rännan.
/// 3. **Skarv utan ränna.** Annars letar vi efter en lodrät kant i mitten (44-56 %) som är:
///    - *genomgående*: i minst 62 % av raderna är steget mellan två kolumner minst 3 gråsteg och
///      minst 1,5 gånger så stort som radens egen textur i närheten (kolumnerna 4-14 px bort);
///    - *en ensam kant*: ingen andra lika genomgående kant ≥ 4 px bort inom ±6 % (en list, en dörrkarm
///      eller en fönsterbåge har två kanter);
///    - *två oberoende bilder*: de lodräta gradienterna (var horisontella linjer ligger: golvlist,
///      taklist, horisont) i remsorna närmast skarven på var sida är okorrelerade (|ρ| ≤ 0,2). I en
///      sammanhängande scen fortsätter linjerna över en kant (fönsterbåge, dörrkarm, rumshörn:
///      ρ 0,36-0,85 bland de verkliga bilderna); i två sammansatta bilder är ρ slumpmässig (±0,1).
///
/// Mätningar (se commitmeddelandet och `docs/plan-bildspelsredigerare.md`): båda Chronas-montagen
/// träffas som ränna (1,0 %); 663 liggande vanliga bilder ger noll träffar; av 400 syntetiska
/// montage utan ränna (verkliga bilder ihopsatta) träffas drygt 90 %.
nonisolated enum ReelPanelDetector {

    static let maxPixels = 1200
    /// Geometri.
    static let maxHalfAspect = 0.95
    static let minHalfWidth = 0.3
    static let aspectRange = 1.1...2.0
    /// Ränna.
    static let gutterRange = 0.40...0.60
    static let gutterMaxColumnStd = 2.5
    static let gutterMeanTolerance = 6.0
    static let gutterMinPixels = 2
    static let gutterMaxWidth = 0.08
    /// Både halvorna ska ha innehåll (standardavvikelse i gråsteg).
    static let minHalfStd = 6.0
    /// Skarv utan ränna.
    static let edgeRange = 0.44...0.56
    static let edgeMinCoverage = 0.65
    static let edgeMaxRho = 0.2
    /// Remsorna närmast skarven måste ha struktur i höjdled (standardavvikelse hos de summerade
    /// lodräta gradienterna, gråsteg), annars går korrelationen inte att avgöra. En platt remsa vid en
    /// full höjds kant är precis vad en fönsterbåge, en dörrkarm eller en pelare ger: då är det ingen skarv.
    static let minStripStd = 4.0
    /// Rutornas kant dras in så här mycket (andel av bredden) från rännan, mot en kantsmetad kolumn.
    static let gutterInset = 0.0015

    nonisolated enum Kind: String, Sendable, Equatable { case gutter, edge }

    /// Råa mått för en bild (för tester, kalibrering och rapport över nästan-träffar).
    nonisolated struct Measurement: Sendable, Equatable {
        /// Geometrin tillåter ett montage (liggande, inte panorama).
        var geometryOK = false
        /// Bredaste rännan (andel av bredden) och dess mitt (0...1); 0 om ingen.
        var gutterWidth = 0.0
        var gutterCenter = 0.0
        /// Bästa kantens täckning (andel rader), läge (0...1), lodrät korrelation mellan remsorna.
        var edgeCoverage = 0.0
        var edgeX = 0.0
        var edgeRho = 0.0
        /// Näst bästa kantens täckning (minst 4 px från den bästa): hög = en list med två kanter, inte en skarv.
        var edgeRunnerUp = 0.0
        /// Mått på hur nära en träff bilden är: ≥ 1 = träff. Rännan: bredd / minsta bredd. Kanten: det
        /// sämsta av täckning / minimum och maxkorrelation / |ρ|. Bara bilder där geometrin går.
        var closeness = 0.0
    }

    nonisolated struct Detection: Sendable, Equatable {
        var kind: Kind
        /// Källrektanglar (vänster, höger) i bildkoordinater.
        var panels: [ReelSpec.UnitRect]
        var measurement: Measurement
    }

    // MARK: - Detektering

    /// Mäter och bestämmer. `luma` är raderna uppifrån och ned, `width * height` byte.
    static func detect(luma: [UInt8], width: Int, height: Int) -> Detection? {
        let m = measure(luma: luma, width: width, height: height)
        return decide(m, luma: luma, width: width, height: height)
    }

    static func panels(luma: [UInt8], width: Int, height: Int) -> [ReelSpec.UnitRect] {
        detect(luma: luma, width: width, height: height)?.panels ?? []
    }

    /// Laddar en nedskalad gråskalekopia (orienteringen tillämpad) och detekterar. Nil om bilden
    /// inte går att läsa; tom lista = inget montage.
    static func panels(url: URL) -> [ReelSpec.UnitRect]? {
        guard let gray = loadLuma(url: url) else { return nil }
        return panels(luma: gray.pixels, width: gray.width, height: gray.height)
    }

    static func measure(url: URL) -> Measurement? {
        guard let gray = loadLuma(url: url) else { return nil }
        return measure(luma: gray.pixels, width: gray.width, height: gray.height)
    }

    // MARK: - Mätning

    static func measure(luma p: [UInt8], width w: Int, height h: Int) -> Measurement {
        var m = Measurement()
        guard w >= 64, h >= 32, p.count >= w * h else { return m }
        let aspect = Double(w) / Double(h)
        guard aspectRange.contains(aspect) else { return m }
        m.geometryOK = true

        // Ränna: kolumner med (nästan) konstant färg genom hela höjden.
        let gx0 = Int(Double(w) * gutterRange.lowerBound), gx1 = min(Int(Double(w) * gutterRange.upperBound), w - 1)
        let colStats = columnStats(p, w: w, h: h, from: gx0, to: gx1)
        var x = gx0
        while x <= gx1 {
            if colStats[x - gx0].std <= gutterMaxColumnStd {
                var e = x
                while e + 1 <= gx1, colStats[e + 1 - gx0].std <= gutterMaxColumnStd,
                      abs(colStats[e + 1 - gx0].mean - colStats[x - gx0].mean) <= gutterMeanTolerance { e += 1 }
                let run = Double(e - x + 1) / Double(w)
                if run > m.gutterWidth { m.gutterWidth = run; m.gutterCenter = Double(x + e + 1) / 2 / Double(w) }
                x = e + 1
            } else {
                x += 1
            }
        }

        // Kant utan ränna.
        let span = 14
        let ex0 = Int(Double(w) * edgeRange.lowerBound), ex1 = Int(Double(w) * edgeRange.upperBound)
        let lo = max(2, ex0 - span), hi = min(w - 3, ex1 + span)
        guard hi > lo, ex1 > ex0 else { return finish(m, width: w) }
        // steg[b - lo][y] = |medel(kolumn b..b+1) - medel(kolumn b-2..b-1)|
        let cols = hi - lo + 1
        var step = [Float](repeating: 0, count: cols * h)
        for b in lo...hi {
            let base = (b - lo) * h
            for y in 0..<h {
                let r = y * w
                let l = Float(p[r + b - 2]) + Float(p[r + b - 1])
                let rr = Float(p[r + b]) + Float(p[r + b + 1])
                step[base + y] = abs(rr - l) / 2
            }
        }
        var best = ex0, bestCoverage = -1.0
        var coverage = [Double](repeating: 0, count: ex1 - ex0 + 1)
        for b in ex0...ex1 {
            var hit = 0
            for y in 0..<h {
                var noise: Float = 0
                for d in 4...span { noise += step[(b - d - lo) * h + y] + step[(b + d - lo) * h + y] }
                noise /= Float(2 * (span - 3))
                let s = step[(b - lo) * h + y]
                if s >= 3, s >= 1.5 * (noise + 1) { hit += 1 }
            }
            let c = Double(hit) / Double(h)
            coverage[b - ex0] = c
            if c > bestCoverage { bestCoverage = c; best = b }
        }
        // Andra kanten (≥ 4 px bort): en list, en karm eller en fönsterbåge har två kanter genom hela höjden.
        for b in ex0...ex1 where abs(b - best) >= 4 { m.edgeRunnerUp = max(m.edgeRunnerUp, coverage[b - ex0]) }
        m.edgeCoverage = bestCoverage
        m.edgeX = Double(best) / Double(w)
        m.edgeRho = verticalCorrelation(p, w: w, h: h, seam: best)
        return finish(m, width: w)
    }

    private static func finish(_ measurement: Measurement, width w: Int) -> Measurement {
        var m = measurement
        let gutter = m.gutterWidth / max(Double(gutterMinPixels) / Double(w), 1e-9)
        let rho = max(abs(m.edgeRho), 0.01)
        let edge = min(m.edgeCoverage / edgeMinCoverage, edgeMaxRho / rho,
                       m.edgeRunnerUp > 0 ? edgeMinCoverage / m.edgeRunnerUp : .infinity)
        m.closeness = max(gutter, edge)
        return m
    }

    /// Medelvärde och standardavvikelse längs varje kolumn i [from, to].
    private static func columnStats(_ p: [UInt8], w: Int, h: Int, from: Int, to: Int) -> [(mean: Double, std: Double)] {
        var out: [(mean: Double, std: Double)] = []
        out.reserveCapacity(max(to - from + 1, 0))
        guard to >= from else { return out }
        for x in from...to {
            var s = 0.0, q = 0.0
            for y in 0..<h { let v = Double(p[y * w + x]); s += v; q += v * v }
            let mean = s / Double(h)
            out.append((mean, sqrt(max(0, q / Double(h) - mean * mean))))
        }
        return out
    }

    /// Pearson-korrelation mellan de lodräta gradienterna (summerade över 8 kolumner) just till
    /// vänster och just till höger om skarven vid kolumn `seam`. Är någon remsa platt (`minStripStd`) går
    /// det inte att avgöra och svaret är 1 (räknas som sammanhängande, alltså ingen skarv).
    private static func verticalCorrelation(_ p: [UInt8], w: Int, h: Int, seam: Int) -> Double {
        let strip = 8
        guard seam - strip >= 0, seam + strip <= w, h > 2 else { return 0 }
        var gl = [Double](repeating: 0, count: h - 1), gr = gl
        for y in 0..<(h - 1) {
            var a = 0.0, b = 0.0
            for x in 1...strip {
                a += Double(p[(y + 1) * w + seam - x]) - Double(p[y * w + seam - x])
                b += Double(p[(y + 1) * w + seam + x - 1]) - Double(p[y * w + seam + x - 1])
            }
            gl[y] = a; gr[y] = b
        }
        let n = Double(h - 1)
        let ml = gl.reduce(0, +) / n, mr = gr.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for y in 0..<(h - 1) {
            let a = gl[y] - ml, b = gr[y] - mr
            sxy += a * b; sxx += a * a; syy += b * b
        }
        guard sqrt(sxx / n) >= minStripStd, sqrt(syy / n) >= minStripStd else { return 1 }
        return sxy / sqrt(sxx * syy)
    }

    // MARK: - Beslut

    private static func decide(_ m: Measurement, luma p: [UInt8], width w: Int, height h: Int) -> Detection? {
        guard m.geometryOK else { return nil }
        let aspect = Double(w) / Double(h)
        func halvesOK(_ leftEnd: Double, _ rightStart: Double) -> Bool {
            let lw = leftEnd, rw = 1 - rightStart
            guard lw >= minHalfWidth, rw >= minHalfWidth else { return false }
            return lw * aspect / 1 <= maxHalfAspect && rw * aspect <= maxHalfAspect
        }
        func hasContent(_ x0: Int, _ x1: Int) -> Bool {
            guard x1 > x0 else { return false }
            var s = 0.0, q = 0.0
            let n = Double((x1 - x0) * h)
            for y in 0..<h { for x in x0..<x1 { let v = Double(p[y * w + x]); s += v; q += v * v } }
            let mean = s / n
            return sqrt(max(0, q / n - mean * mean)) >= minHalfStd
        }

        if m.gutterWidth * Double(w) >= Double(gutterMinPixels), m.gutterWidth <= gutterMaxWidth {
            // Rännans kanter: mitten ± halva bredden.
            let start = m.gutterCenter - m.gutterWidth / 2, end = m.gutterCenter + m.gutterWidth / 2
            if halvesOK(start, end), hasContent(0, Int(start * Double(w))), hasContent(Int(end * Double(w)), w) {
                let l = ReelSpec.UnitRect(x: 0, y: 0, w: start - gutterInset, h: 1)
                let r = ReelSpec.UnitRect(x: end + gutterInset, y: 0, w: 1 - end - gutterInset, h: 1)
                return Detection(kind: .gutter, panels: [l, r], measurement: m)
            }
        }
        if m.edgeCoverage >= edgeMinCoverage, m.edgeRunnerUp < edgeMinCoverage, abs(m.edgeRho) <= edgeMaxRho,
           halvesOK(m.edgeX, m.edgeX) {
            let b = Int((m.edgeX * Double(w)).rounded())
            if hasContent(0, b), hasContent(b, w) {
                let l = ReelSpec.UnitRect(x: 0, y: 0, w: m.edgeX, h: 1)
                let r = ReelSpec.UnitRect(x: m.edgeX, y: 0, w: 1 - m.edgeX, h: 1)
                return Detection(kind: .edge, panels: [l, r], measurement: m)
            }
        }
        return nil
    }

    // MARK: - Laddning

    nonisolated struct Gray: Sendable {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// Gråskalekopia med längsta sida `maxPixels`, orienteringen tillämpad (som i uppspelningen).
    static func loadLuma(url: URL) -> Gray? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Gray(width: w, height: h, pixels: pixels) : nil
    }
}
