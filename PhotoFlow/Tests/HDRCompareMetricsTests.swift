import Foundation
import Testing
@testable import PhotoFlow

/// `HDRCompareMetrics` på syntetiska bilder med kända egenskaper.
struct HDRCompareMetricsTests {
    typealias M = HDRCompareMetrics
    let w = 640, h = 480

    /// Deterministiskt pseudoslumptal i 0…1 ur heltalskoordinater.
    func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Float {
        var v = UInt64(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ seed &* 83492791)
        v = (v ^ (v >> 13)) &* 0x5bd1e995
        v = v ^ (v >> 15)
        return Float(v & 0xFFFF) / 65535
    }

    /// Normalfördelat brus (Box–Muller) ur två hashar.
    func gauss(_ x: Int, _ y: Int, seed: Int = 1) -> Float {
        let u1 = max(hash(x, y, seed), 1e-5), u2 = hash(x, y, seed + 7)
        return (-2 * logf(u1)).squareRoot() * cosf(2 * .pi * u2)
    }

    func make(_ f: (Int, Int) -> (Float, Float, Float)) -> M.Image {
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = f(x, y)
                let o = (y * w + x) * 4
                px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
            }
        }
        return M.Image(width: w, height: h, pixels: px)
    }

    /// Scen med mycket struktur (sinusar + rutor) som Vision kan registrera.
    func scene(_ x: Int, _ y: Int) -> Float {
        let fx = Float(x), fy = Float(y)
        var v: Float = 0.45 + 0.15 * sinf(fx * 0.05) * cosf(fy * 0.04) + 0.08 * sinf(fx * 0.21 + fy * 0.13)
        if ((x / 24) + (y / 20)) % 3 == 0 { v += 0.12 }
        if x > 200 && x < 330 && y > 120 && y < 260 { v = 0.15 + 0.1 * sinf(fx * 0.3) }
        return min(max(v, 0), 1)
    }

    // MARK: - Registrering

    @Test func registreringenRattarEnForskjutning() throws {
        let ref = make { x, y in let v = scene(x, y); return (v, v, v) }
        let moved = make { x, y in let v = scene(x - 7, y - 3); return (v, v, v) }
        let result = M.registered(moved, to: ref)
        let reg = try #require(result.registration)
        #expect(reg.ok, "kvarvarande förskjutning \(reg.residualPixels)")
        // Jämför mitten (bort från kanten som saknar täckning).
        var diff: Float = 0, n: Float = 0
        for y in 40..<(h - 40) {
            for x in 40..<(w - 40) where result.valid[y * w + x] {
                diff += abs(result.image.pixels[(y * w + x) * 4] - ref.pixels[(y * w + x) * 4]); n += 1
            }
        }
        #expect(n > 0 && diff / n < 0.02, "medelavvikelse \(diff / max(n, 1))")
    }

    @Test func registreringMotSigSjalvAlltidOk() throws {
        let ref = make { x, y in let v = scene(x, y); return (v, v, v) }
        let reg = try #require(M.register(floating: ref, reference: ref))
        #expect(reg.ok)
        #expect(reg.residualPixels < 1)
    }

    // MARK: - Klippning och ton

    @Test func klippningRaknarHogdagrarOchSkuggor() {
        // Vänster fjärdedel vit, nästa fjärdedel svart, resten mellangrå.
        let img = make { x, _ in
            if x < w / 4 { return (1, 1, 1) }
            if x < w / 2 { return (0, 0, 0) }
            return (0.5, 0.5, 0.5)
        }
        let c = M.clipping(img)
        #expect(abs(c.highlights - 0.25) < 0.005)
        #expect(abs(c.shadows - 0.25) < 0.005)
    }

    @Test func klippningRaknarEnKanalSomHogdag() {
        let img = make { _, _ in (0.99, 0.4, 0.4) }
        #expect(M.clipping(img).highlights == 1)
    }

    @Test func tonGerMedianOchPercentiler() {
        // Luma jämnt fördelad 0…1 i x-led.
        let img = make { x, _ in let v = Float(x) / Float(w - 1); return (v, v, v) }
        let t = M.tone(img)
        #expect(abs(t.medianLuma - 0.5) < 0.02)
        #expect(abs(t.p5 - 0.05) < 0.02)
        #expect(abs(t.p95 - 0.95) < 0.02)
    }

    @Test func lokalKontrastArHogreForTexturanSlatBild() {
        let flat = make { _, _ in (0.5, 0.5, 0.5) }
        let textured = make { x, y in let v: Float = (x / 4 + y / 4) % 2 == 0 ? 0.3 : 0.7; return (v, v, v) }
        #expect(M.tone(flat).localContrast < 0.001)
        #expect(M.tone(textured).localContrast > 0.1)
    }

    // MARK: - Fönsterdetalj

    @Test func fonsterdetaljMaskOchStruktur() throws {
        let window = { (x: Int, y: Int) in x >= 400 && x < 560 && y >= 80 && y < 280 }
        // Referens: klippt fönster. Mörk ram: strukturerat fönster (ränder), mörk interiör.
        let ref = make { x, y in window(x, y) ? (1, 1, 1) : (0.5, 0.5, 0.5) }
        let dark = make { x, y in
            if window(x, y) { let v: Float = (x / 3) % 2 == 0 ? 0.35 : 0.6; return (v, v, v) }
            return (0.03, 0.03, 0.03)
        }
        let mask = M.windowMask(reference: ref, dark: dark)
        let inside = mask.enumerated().filter { $0.element }.count
        #expect(abs(Double(inside) - 160 * 200) / (160 * 200) < 0.05)

        // Bra variant: behåller fönstrets struktur. Dålig: helt klippt.
        let good = make { x, y in
            if window(x, y) { let v: Float = (x / 3) % 2 == 0 ? 0.6 : 0.8; return (v, v, v) }
            return (0.5, 0.5, 0.5)
        }
        let bad = ref
        let g = try #require(M.windowDetail(good, mask: mask, dark: dark))
        let b = try #require(M.windowDetail(bad, mask: mask, dark: dark))
        #expect(g.clippedFraction < 0.01)
        #expect(b.clippedFraction > 0.99)
        #expect(g.structureCorrelation > 0.8)
        #expect(g.lumaSpread > b.lumaSpread)
    }

    @Test func fonsterdetaljSaknasNarMaskenArTom() {
        let img = make { _, _ in (0.5, 0.5, 0.5) }
        let mask = [Bool](repeating: false, count: w * h)
        #expect(M.windowDetail(img, mask: mask, dark: img) == nil)
    }

    // MARK: - Spöken

    @Test func spokenHittasNarEnRutaFarEnAnnanStruktur() throws {
        let ref = make { x, y in let v = scene(x, y); return (v, v, v) }
        // Samma bild men ett 128×128-block med helt annat mönster (ett "spöke").
        let ghosted = make { x, y in
            if x >= 192 && x < 320 && y >= 288 && y < 416 { let v = 0.2 + 0.5 * hash(x / 2, y / 2); return (v, v, v) }
            let v = scene(x, y); return (v, v, v)
        }
        let clean = try #require(M.ghosting(ref, reference: ref))
        #expect(clean == 0)
        let frac = try #require(M.ghosting(ghosted, reference: ref))
        // 16 av 300 rutor (32 px) ligger i blocket.
        #expect(frac > 0.03 && frac < 0.09, "andel \(frac)")
    }

    // MARK: - Brus

    @Test func brusSigmaStammerMedKantVarde() throws {
        for sigma: Float in [0.01, 0.03] {
            let img = make { x, y in
                let v = 0.15 + sigma * gauss(x, y)
                return (v, v, v)
            }
            let est = try #require(M.noiseSigma(img))
            #expect(abs(Float(est) - sigma) / sigma < 0.15, "σ \(sigma) uppskattades till \(est)")
        }
    }

    @Test func brusIgnorerarStruktureradeOchLjusaDelar() {
        // Hela bilden ljus (luma 0,6): inga mörka rutor att mäta i.
        let bright = make { x, y in let v = 0.6 + 0.02 * gauss(x, y); return (v, v, v) }
        #expect(M.noiseSigma(bright) == nil)
    }

    // MARK: - Färg

    @Test func fargstickMatsIDeNeutralaPixlarna() throws {
        let neutral = make { _, _ in (0.5, 0.5, 0.5) }
        let warm = make { _, _ in (0.53, 0.5, 0.46) }
        let n = try #require(M.colorCast(neutral))
        let c = try #require(M.colorCast(warm))
        #expect(abs(n.meanA) < 0.1 && abs(n.meanB) < 0.1)
        #expect(c.meanB > 3, "b* \(c.meanB)")
        #expect(c.meanA > n.meanA)
    }

    @Test func starktFargadeBilderHarIngetNeutraltUnderlag() {
        let red = make { _, _ in (0.9, 0.1, 0.1) }
        #expect(M.colorCast(red) == nil)
    }

    // MARK: - ΔE2000

    @Test func deltaE2000MotSharmasTestpar() {
        // Pär 1 och 2 ur Sharma, Wu & Dalal (2005), tabell 1.
        let d1 = M.deltaE2000((50, 2.6772, -79.7751), (50, 0, -82.7485))
        #expect(abs(d1 - 2.0425) < 0.001)
        let d2 = M.deltaE2000((50, 3.1571, -77.2803), (50, 0, -82.7485))
        #expect(abs(d2 - 2.8615) < 0.001)
        let d3 = M.deltaE2000((50, 2.5, 0), (50, 0, -2.5))
        #expect(abs(d3 - 4.3065) < 0.001)
    }

    @Test func labAvVitOchSvart() {
        let white = M.lab(1, 1, 1), black = M.lab(0, 0, 0)
        #expect(abs(white.L - 100) < 0.1 && abs(white.a) < 0.1 && abs(white.b) < 0.1)
        #expect(abs(black.L) < 0.1)
    }

    @Test func parmattIdentiskaBilderGerNollOchSkillnadGerNagot() throws {
        let a = make { x, y in let v = scene(x, y); return (v, v, v) }
        let b = make { x, y in let v = scene(x, y); return (v * 0.8, v, v) }
        let valid = [Bool](repeating: true, count: w * h)
        let ra = M.Registered(image: a, valid: valid, registration: nil)
        let rb = M.Registered(image: b, valid: valid, registration: nil)
        let same = try #require(M.pairMetrics(ra, ra))
        #expect(same.deltaEMean == 0 && same.deltaEP95 == 0)
        let mask = (0..<(w * h)).map { ($0 % w) < w / 2 }
        let diff = try #require(M.pairMetrics(ra, rb, windowMask: mask))
        #expect(diff.deltaEMean > 1)
        #expect(diff.deltaEP95 >= diff.deltaEMean)
        #expect(diff.deltaEInsideWindow != nil && diff.deltaEOutsideWindow != nil)
    }

    @Test func parmattHoppaOverOgiltigaPixlar() throws {
        let a = make { _, _ in (0.5, 0.5, 0.5) }
        let b = make { _, _ in (0.9, 0.9, 0.9) }
        let none = [Bool](repeating: false, count: w * h)
        #expect(M.pairMetrics(.init(image: a, valid: none, registration: nil), .init(image: b, valid: none, registration: nil)) == nil)
    }

    // MARK: - Samlat

    @Test func analyzeFyllerIFaltenFranEnBild() {
        let ref = make { x, y in let v = scene(x, y); return (v, v, v) }
        let dark = make { x, y in let v = scene(x, y) * 0.2; return (v, v, v) }
        let reg = M.Registered(image: ref, valid: [Bool](repeating: true, count: w * h), registration: nil)
        let m = M.analyze(reg, reference: ref, dark: dark)
        #expect(m.ghostTileFraction == 0)
        #expect(m.colorCast != nil)
        #expect(m.tone.medianLuma > 0.3)
        // Metrikerna kan skrivas som JSON (metrics.json).
        #expect((try? JSONEncoder().encode(m)) != nil)
    }
}
