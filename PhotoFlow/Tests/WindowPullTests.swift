import Foundation
import Testing
@testable import PhotoFlow

/// `WindowPull` med syntetiska bilder: en interiör (luma 0,45 i referensen, 4 EV mörkare i
/// den mörka ramen) och ett fönster som är klippt i referensen men har struktur i den mörka
/// ramen. Fusionen simuleras som referensen med ett grått, nästan klippt fönster.
struct WindowPullTests {
    let width = 600, height = 400
    /// Den mörka ramen är 4 EV (16×) mörkare än referensen.
    let ratio: Float = 16

    struct Rect {
        var x0: Int, y0: Int, x1: Int, y1: Int
        func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
    }

    let window = Rect(x0: 380, y0: 60, x1: 540, y1: 260)

    /// Interiörens värde i den mörka ramen, exakt 4 EV under referensen.
    func darkInterior(_ v: Float) -> Float {
        HDRImageOps.toGamma(HDRImageOps.toLinear(v) / ratio)
    }

    /// Utsikt med struktur: lodräta ränder (period 4) och grönaktig ton.
    func view(_ x: Int, _ y: Int, flat: Bool = false) -> (Float, Float, Float) {
        let v: Float = flat ? 0.45 : ((x / 2) % 2 == 0 ? 0.39 : 0.51)
        return (v * 0.85, v, v * 0.8)
    }

    struct Scene {
        var reference: [Float]
        var dark: [Float]
        var fused: [Float]
    }

    /// Bygger en scen; `extra` får ändra varje pixel (ref, mörk, fusion).
    func makeScene(windows: [Rect]? = nil, flatView: Bool = false,
                   extra: ((Int, Int, inout (Float, Float, Float), inout (Float, Float, Float), inout (Float, Float, Float)) -> Void)? = nil) -> Scene {
        let windows = windows ?? [window]
        var ref = [Float](repeating: 1, count: width * height * 4)
        var dark = ref, fused = ref
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                // Interiör med svag struktur så att ljuskvoten går att mäta.
                let base: Float = 0.45 + 0.05 * Float((x / 8 + y / 8) % 2)
                var r: (Float, Float, Float) = (base, base, base)
                var d: (Float, Float, Float) = (darkInterior(base), darkInterior(base), darkInterior(base))
                var f = r
                if windows.contains(where: { $0.contains(x, y) }) {
                    r = (1, 1, 1)
                    d = view(x, y, flat: flatView)
                    f = (0.95, 0.95, 0.95)
                }
                extra?(x, y, &r, &d, &f)
                ref[p] = r.0; ref[p + 1] = r.1; ref[p + 2] = r.2
                dark[p] = d.0; dark[p + 1] = d.1; dark[p + 2] = d.2
                fused[p] = f.0; fused[p + 1] = f.1; fused[p + 2] = f.2
            }
        }
        return Scene(reference: ref, dark: dark, fused: fused)
    }

    func luma(_ pixels: [Float], _ x: Int, _ y: Int) -> Float {
        let p = (y * width + x) * 4
        return HDRImageOps.luma(pixels[p], pixels[p + 1], pixels[p + 2])
    }

    func run(_ scene: Scene, options: WindowPull.Options = WindowPull.Options()) -> WindowPull.Result {
        WindowPull.apply(fused: scene.fused, reference: scene.reference, dark: scene.dark,
                         width: width, height: height, options: options, keepFullMask: true)
    }

    /// Andel pixlar i `rect` (minus en kant på `inset` px) med någon kanal ≥ 0,98.
    func clippedFraction(_ pixels: [Float], in rect: Rect, inset: Int = 4) -> Double {
        var clipped = 0, total = 0
        for y in (rect.y0 + inset)..<(rect.y1 - inset) {
            for x in (rect.x0 + inset)..<(rect.x1 - inset) {
                let p = (y * width + x) * 4
                total += 1
                if max(pixels[p], pixels[p + 1], pixels[p + 2]) >= 0.98 { clipped += 1 }
            }
        }
        return Double(clipped) / Double(total)
    }

    @Test("Fönster klippt i de ljusa ramarna hämtas från den mörka ramen; interiören rörs inte")
    func clippedWindow_isPulledFromDarkFrame() {
        let scene = makeScene()
        let result = run(scene)
        #expect(result.stats.applied)
        #expect(result.stats.components == 1)
        // Masken täcker fönstret (~13 % av bilden) men inte mycket mer.
        #expect(result.stats.maskFraction > 0.11 && result.stats.maskFraction < 0.17)
        #expect(abs(result.stats.darkToReferenceEV + 4) < 0.2)
        // Fönstrets mitt: utsiktens ränder syns (inte längre platt grått) och inget är klippt.
        let a = luma(result.pixels, 460, 160), b = luma(result.pixels, 462, 160)
        #expect(abs(a - b) > 0.08)
        #expect(clippedFraction(result.pixels, in: window) < 0.02)
        // Fönstrets median hamnar kring målet 0,66 (styrka 85 % → lite fusion kvar).
        let mid = (luma(result.pixels, 460, 160) + luma(result.pixels, 462, 160)) / 2
        #expect(mid > 0.55 && mid < 0.85)
        // Långt från fönstret: exakt som fusionen.
        for (x, y) in [(50, 350), (200, 200), (590, 390)] {
            #expect(luma(result.pixels, x, y) == luma(scene.fused, x, y))
        }
    }

    @Test("Fönsterljushet höjer fönstret, styrka 0 eller avstängt gör ingenting")
    func brightnessAndStrength() {
        let scene = makeScene()
        let normal = run(scene)
        var brighter = WindowPull.Options()
        brighter.brightnessEV = 0.5
        let bright = run(scene, options: brighter)
        #expect(bright.gain > normal.gain)
        #expect(luma(bright.pixels, 460, 160) > luma(normal.pixels, 460, 160))

        var off = WindowPull.Options()
        off.enabled = false
        #expect(run(scene, options: off).pixels == scene.fused)
        var zero = WindowPull.Options()
        zero.strength = 0
        #expect(run(scene, options: zero).pixels == scene.fused)
    }

    @Test("En lampa (klippt även i mörka ramen) dras inte in")
    func lamp_isLeftAlone() {
        let lampCore = Rect(x0: 100, y0: 80, x1: 112, y1: 92)
        let lampHalo = Rect(x0: 94, y0: 74, x1: 118, y1: 98)
        let scene = makeScene(windows: []) { x, y, r, d, f in
            if lampCore.contains(x, y) {
                r = (1, 1, 1); d = (1, 1, 1); f = (1, 1, 1)
            } else if lampHalo.contains(x, y) {
                // Mjuk glorian: avtar från kärnan utåt (en riktig lampa har inga skarpa kanter).
                let dist = Float(max(abs(x - 106), abs(y - 86)) - 6) / 6
                let v = 0.85 - 0.5 * dist
                r = (1, 1, 1); d = (v, v * 0.97, v * 0.9); f = (0.97, 0.97, 0.97)
            }
        }
        let result = run(scene)
        #expect(!result.stats.applied)
        #expect(result.stats.lampsDropped == 1)
        #expect(result.pixels == scene.fused)

        var include = WindowPull.Options()
        include.includeLampsAndSky = true
        // Med lampor påslaget är det inte längre en lampa som stoppar den (men den släta
        // glorian kan fortfarande sorteras bort som yta) — bara att den inte räknas som lampa.
        #expect(run(scene, options: include).stats.lampsDropped == 0)
    }

    @Test("Himmel (stor yta mot överkanten) dras inte in utom med 'även lampor och himmel'")
    func sky_isLeftAloneUnlessIncluded() {
        let sky = Rect(x0: 0, y0: 0, x1: 600, y1: 90)
        let scene = makeScene(windows: [sky])
        let result = run(scene)
        #expect(!result.stats.applied)
        #expect(result.stats.skyDropped == 1)
        #expect(result.pixels == scene.fused)

        var include = WindowPull.Options()
        include.includeLampsAndSky = true
        let withSky = run(scene, options: include)
        #expect(withSky.stats.applied)
        #expect(clippedFraction(withSky.pixels, in: Rect(x0: 0, y0: 0, x1: 600, y1: 90)) < 0.02)
    }

    @Test("En slät ljus yta (solbelyst vägg) är inget fönster")
    func smoothSurface_isNotAWindow() {
        let scene = makeScene(flatView: true)
        let result = run(scene)
        #expect(!result.stats.applied)
        #expect(result.stats.surfacesDropped == 1)
        #expect(result.pixels == scene.fused)
    }

    @Test("Rörelse i kantbandet drar in masken (spökskydd)")
    func motionInEdgeBand_shrinksMask() {
        // En ljus sak som bara finns i referensen, tvärs över fönstrets högra kant.
        let moved = Rect(x0: 532, y0: 120, x1: 552, y1: 200)
        let clean = run(makeScene())
        let ghosted = run(makeScene { x, y, r, _, f in
            if moved.contains(x, y) && x >= 540 { r = (0.8, 0.8, 0.8); f = (0.8, 0.8, 0.8) }
        })
        #expect(clean.stats.ghostFraction == 0)
        #expect(ghosted.stats.ghostFraction > 0)
        // Masken precis innanför kanten vid rörelsen är lägre än på samma rad i den rena scenen.
        let cleanMask = clean.fullMask!.data[150 * width + 539]
        let ghostMask = ghosted.fullMask!.data[150 * width + 539]
        #expect(ghostMask < cleanMask - 0.1)
    }

    @Test("Ingen mörk ram (den 'mörka' är lika ljus som referensen) → ingen pull")
    func noDarkFrame_noPull() {
        let scene = makeScene()
        let result = WindowPull.apply(fused: scene.fused, reference: scene.reference, dark: scene.reference,
                                      width: width, height: height, options: WindowPull.Options())
        #expect(!result.stats.applied)
        #expect(result.stats.reason != nil)
        #expect(result.pixels == scene.fused)
    }

    @Test("Masken sparas i ~1500 px och mellan 0 och 1")
    func savedMask_isNormalized() {
        let result = run(makeScene())
        #expect(result.mask.width == width && result.mask.height == height)
        #expect(result.mask.data.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(result.mask.data[160 * width + 460] > 0.9)
        #expect(result.mask.data[350 * width + 50] == 0)
    }

    @Test("Hålfyllnad: mörkare partier mitt i fönstret blir en del av fönstret")
    func fillHoles_fillsEnclosedOnly() {
        // 10×10 med en ring (hål i mitten) och en öppen U-form mot kanten.
        let w = 10, h = 10
        var binary = [Float](repeating: 0, count: w * h)
        for y in 1...5 { for x in 1...5 where x == 1 || x == 5 || y == 1 || y == 5 { binary[y * w + x] = 1 } }
        for y in 6..<10 { binary[y * w + 7] = 1; binary[y * w + 9] = 1 }
        let filled = WindowPull.fillHoles(binary, width: w, height: h)
        #expect(filled[3 * w + 3] == 1) // hålet i ringen
        #expect(filled[9 * w + 8] == 0) // U:et når kanten — inget hål
        #expect(filled[0] == 0)
    }

    @Test("Mertens-vikterna straffar delvis klippta pixlar")
    func fusion_penalizesPartiallyClippedPixels() throws {
        let w = 32, h = 32
        // Bild A: delvis klippt (röd kanal 1,0) — hög mättnad, så utan straff väger den tungt.
        var a = [Float](repeating: 1, count: w * h * 4), b = a
        for p in 0..<(w * h) {
            a[p * 4] = 1.0; a[p * 4 + 1] = 0.75; a[p * 4 + 2] = 0.55
            b[p * 4] = 0.62; b[p * 4 + 1] = 0.5; b[p * 4 + 2] = 0.42
        }
        // Lite struktur så att kontrastvikten inte är noll.
        for y in 0..<h { for x in 0..<w where (x + y) % 2 == 0 { for c in 0..<3 { a[(y * w + x) * 4 + c] -= 0.02; b[(y * w + x) * 4 + c] -= 0.02 } } }
        let penalized = try ExposureFusion.fuse(images: [a, b], width: w, height: h)
        let plain = try ExposureFusion.fuse(images: [a, b], width: w, height: h,
                                            options: ExposureFusion.Options(clipPenalty: nil))
        let center = (16 * w + 16) * 4
        // Med straffet hamnar resultatet närmare den oklippta bilden B.
        #expect(abs(penalized[center] - b[center]) < abs(plain[center] - b[center]))
        #expect(penalized[center] < 0.98)
    }

    @Test("Exponeringsmatchning före registrering: histogrammatchningen är monoton och träffar referensen")
    func histogramMatching() {
        let reference = (0..<1000).map { Float($0) / 999 }
        let dark = reference.map { $0 * 0.2 }
        let matched = HDRAlignment.matchHistogram(dark, to: reference)
        #expect(zip(matched, matched.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs(matched[500] - reference[500]) < 0.02)
        #expect(abs(matched[900] - reference[900]) < 0.02)
    }
}
