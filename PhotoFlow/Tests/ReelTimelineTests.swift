import Foundation
import CoreGraphics
import Testing
@testable import PhotoFlow

/// Tester för `ReelTimeline`: tid, easing, utsnitt, lager under övergångar och
/// mot den delade vektorfilen (`Fixtures/Reel/timeline-vectors.json`).
struct ReelTimelineTests {

    static let vertical = CGSize(width: 1080, height: 1920)
    static let square = CGSize(width: 1080, height: 1080)
    static let wide = CGSize(width: 1920, height: 1080)

    static func example() throws -> ReelSpec {
        try ReelSpec.decode(from: try ReelSpecCodingTests.exampleData())
    }

    static func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    static func approx(_ r: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ tol: Double = 1e-9) -> Bool {
        approx(Double(r.minX), x, tol) && approx(Double(r.minY), y, tol)
            && approx(Double(r.width), w, tol) && approx(Double(r.height), h, tol)
    }

    /// Liten spec för enskilda övergångar: två 3:2-klipp à 4 s.
    static func twoClips(_ transition: ReelSpec.Transition?, easing: ReelSpec.Easing = .linear,
                         fit: ReelSpec.Fit = .cover, background: ReelSpec.Background = .init(type: "blur", amount: 0.6)) throws -> ReelSpec {
        var spec = try example()
        spec.assets = Array(spec.assets.prefix(2))
        spec.style.easing = easing
        spec.style.background = background
        let motion = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1))
        spec.timeline = [
            .init(asset: "a1", duration: 4, fit: .cover, motion: motion, transitionIn: nil),
            .init(asset: "a2", duration: 4, fit: fit, motion: motion, transitionIn: transition),
        ]
        return spec
    }

    // MARK: Tid

    @Test("Planens exempel: klippstarter och total längd 12,1 s")
    func exampleTiming() throws {
        let spec = try Self.example()
        let starts = ReelTimeline.clipStarts(spec)
        let expected = [0, 2.5, 4.6, 6.7, 8.7]
        #expect(starts.count == 5)
        for (a, b) in zip(starts, expected) { #expect(Self.approx(a, b)) }
        #expect(Self.approx(ReelTimeline.totalDuration(spec), 12.1))
    }

    @Test("Första klippets transitionIn ignoreras")
    func firstTransitionIgnored() throws {
        var spec = try Self.example()
        spec.timeline[0].transitionIn = .init(type: .crossfade, direction: nil, duration: 1.5)
        #expect(ReelTimeline.clipStarts(spec)[0] == 0)
        #expect(ReelTimeline.clipStarts(spec) == ReelTimeline.clipStarts(try Self.example()))
        #expect(Self.approx(ReelTimeline.totalDuration(spec), 12.1))
    }

    @Test("Klipp utan transitionIn använder style.defaultTransition")
    func defaultTransitionApplies() throws {
        let spec = try Self.example()
        #expect(spec.timeline[2].transitionIn == nil)
        #expect(ReelTimeline.transition(spec, at: 2)?.duration == 0.5)
        #expect(ReelTimeline.transition(spec, at: 0) == nil)
    }

    @Test("Övergången ligger inom båda klippens längd; cut ger inget överlapp")
    func transitionOverlapAndCut() throws {
        let fade = try Self.twoClips(.init(type: .crossfade, direction: nil, duration: 1))
        #expect(ReelTimeline.clipStarts(fade) == [0, 3])
        #expect(ReelTimeline.totalDuration(fade) == 7)

        let cut = try Self.twoClips(.init(type: .cut, direction: nil, duration: 1))
        #expect(ReelTimeline.clipStarts(cut) == [0, 4])
        #expect(ReelTimeline.totalDuration(cut) == 8)

        // För lång övergång begränsas till det kortaste klippet.
        let long = try Self.twoClips(.init(type: .crossfade, direction: nil, duration: 9))
        #expect(ReelTimeline.clipStarts(long) == [0, 0])
        #expect(ReelTimeline.totalDuration(long) == 4)
    }

    @Test("Tom tidslinje ger 0 s och inga lager")
    func emptyTimeline() throws {
        var spec = try Self.example()
        spec.timeline = []
        #expect(ReelTimeline.clipStarts(spec).isEmpty)
        #expect(ReelTimeline.totalDuration(spec) == 0)
        #expect(ReelTimeline.state(at: 1, spec: spec, outputSize: Self.vertical).isEmpty)
    }

    // MARK: Easing och interpolation

    @Test("Smoothstep och linjär easing")
    func easingValues() {
        #expect(ReelTimeline.easing(.easeInOut, 0) == 0)
        #expect(ReelTimeline.easing(.easeInOut, 1) == 1)
        #expect(Self.approx(ReelTimeline.easing(.easeInOut, 0.5), 0.5))
        #expect(Self.approx(ReelTimeline.easing(.easeInOut, 0.25), 0.15625))
        #expect(Self.approx(ReelTimeline.easing(.easeInOut, 0.75), 0.84375))
        #expect(ReelTimeline.easing(.easeInOut, -3) == 0)
        #expect(ReelTimeline.easing(.easeInOut, 3) == 1)
        #expect(ReelTimeline.easing(.linear, 0.3) == 0.3)
        #expect(ReelTimeline.easing(.linear, 2) == 1)
    }

    @Test("Zoom interpoleras geometriskt, mittpunkten linjärt")
    func geometricZoom() {
        let m = ReelSpec.Motion(from: .init(cx: 0.2, cy: 0.4, zoom: 1), to: .init(cx: 0.8, cy: 0.6, zoom: 4))
        let mid = ReelTimeline.interpolate(m, e: 0.5)
        #expect(Self.approx(mid.zoom, 2))          // sqrt(4), inte 2,5
        #expect(Self.approx(mid.cx, 0.5))
        #expect(Self.approx(mid.cy, 0.5))
        #expect(Self.approx(ReelTimeline.interpolate(m, e: 0).zoom, 1))
        #expect(Self.approx(ReelTimeline.interpolate(m, e: 1).zoom, 4))
    }

    // MARK: Utsnitt

    @Test("Cover-utsnitt för en 3:2-bild i 9:16, 1:1 och 16:9")
    func coverAllAspects() {
        let img = CGSize(width: 6000, height: 4000)
        let center = CGPoint(x: 0.5, y: 0.5)
        // 9:16: höjden räcker, bredden = (9/16)/(3/2) = 0,375
        let v = ReelTimeline.cropRect(imageSize: img, frameAspect: 9.0 / 16, center: center, zoom: 1)
        #expect(Self.approx(v, 0.3125, 0, 0.375, 1))
        // 1:1: bredd = 1 / 1,5
        let s = ReelTimeline.cropRect(imageSize: img, frameAspect: 1, center: center, zoom: 1)
        #expect(Self.approx(s, 1.0 / 6, 0, 2.0 / 3, 1))
        // 16:9: bredden räcker, höjd = 1,5/(16/9) = 0,84375
        let w = ReelTimeline.cropRect(imageSize: img, frameAspect: 16.0 / 9, center: center, zoom: 1)
        #expect(Self.approx(w, 0, (1 - 0.84375) / 2, 1, 0.84375))
    }

    @Test("Zoom krymper utsnittet, och det klampas inom bilden vid zoom 1,0 med center i hörn")
    func clamping() {
        let img = CGSize(width: 6000, height: 4000)
        let a = 9.0 / 16
        let tl = ReelTimeline.cropRect(imageSize: img, frameAspect: a, center: CGPoint(x: 0, y: 0), zoom: 1)
        #expect(Self.approx(tl, 0, 0, 0.375, 1))
        let br = ReelTimeline.cropRect(imageSize: img, frameAspect: a, center: CGPoint(x: 1, y: 1), zoom: 1)
        #expect(Self.approx(br, 0.625, 0, 0.375, 1))
        let wideTL = ReelTimeline.cropRect(imageSize: img, frameAspect: 16.0 / 9, center: CGPoint(x: 0, y: 0), zoom: 1)
        #expect(Self.approx(wideTL, 0, 0, 1, 0.84375))
        let wideBR = ReelTimeline.cropRect(imageSize: img, frameAspect: 16.0 / 9, center: CGPoint(x: 1, y: 1), zoom: 1)
        #expect(Self.approx(wideBR, 0, 0.15625, 1, 0.84375))

        let z2 = ReelTimeline.cropRect(imageSize: img, frameAspect: a, center: CGPoint(x: 0.5, y: 0.5), zoom: 2)
        #expect(Self.approx(z2, 0.40625, 0.25, 0.1875, 0.5))
        let z2corner = ReelTimeline.cropRect(imageSize: img, frameAspect: a, center: CGPoint(x: 1, y: 0), zoom: 2)
        #expect(Self.approx(z2corner, 1 - 0.1875, 0, 0.1875, 0.5))
        // zoom < 1 behandlas som 1
        let under = ReelTimeline.cropRect(imageSize: img, frameAspect: a, center: CGPoint(x: 0.5, y: 0.5), zoom: 0.5)
        #expect(Self.approx(under, 0.3125, 0, 0.375, 1))
    }

    @Test("Utsnittet ligger alltid inom [0,1]² längs hela exemplet i alla format")
    func cropsStayInsideImage() throws {
        let spec = try Self.example()
        let total = ReelTimeline.totalDuration(spec)
        for size in [Self.vertical, Self.square, Self.wide] {
            var t = 0.0
            while t <= total {
                for l in ReelTimeline.state(at: t, spec: spec, outputSize: size) {
                    #expect(l.crop.minX >= -1e-12 && l.crop.maxX <= 1 + 1e-12)
                    #expect(l.crop.minY >= -1e-12 && l.crop.maxY <= 1 + 1e-12)
                }
                t += 0.05
            }
        }
    }

    // MARK: Lager

    @Test("Utanför övergångar syns ett lager med full opacitet; rörelsen följer easing")
    func singleLayerMotion() throws {
        var spec = try Self.example()
        spec.timeline[0].motion = .init(from: .init(cx: 0.3, cy: 0.5, zoom: 1), to: .init(cx: 0.7, cy: 0.5, zoom: 1))
        // t = 0: början
        let l0 = try #require(ReelTimeline.state(at: 0, spec: spec, outputSize: Self.vertical).first)
        #expect(ReelTimeline.state(at: 0, spec: spec, outputSize: Self.vertical).count == 1)
        #expect(l0.asset == "a1" && l0.opacity == 1 && l0.offset == .zero)
        // Exemplets bild är 6048×4024 (inte exakt 3:2), så utsnittets bredd följer bildförhållandet.
        let w0 = (9.0 / 16.0) / (6048.0 / 4024.0)
        #expect(Self.approx(l0.crop, 0.3 - w0 / 2, 0, w0, 1))
        // t = 1,25: p = 1,25/3 av klippets 3 s, före övergången vid 2,5
        let t = 1.25
        let e = ReelTimeline.easing(.easeInOut, t / 3)
        let l = try #require(ReelTimeline.state(at: t, spec: spec, outputSize: Self.vertical).first)
        #expect(Self.approx(Double(l.crop.midX), 0.3 + 0.4 * e))
        #expect(l.fit == .cover && l.dest == CGRect(x: 0, y: 0, width: 1, height: 1) && l.backdrop == nil)
    }

    @Test("Tid utanför tidslinjen klampas")
    func timeClamped() throws {
        let spec = try Self.example()
        let before = ReelTimeline.state(at: -5, spec: spec, outputSize: Self.vertical)
        let first = ReelTimeline.state(at: 0, spec: spec, outputSize: Self.vertical)
        #expect(before == first)
        let after = ReelTimeline.state(at: 999, spec: spec, outputSize: Self.vertical)
        let end = ReelTimeline.state(at: 12.1, spec: spec, outputSize: Self.vertical)
        #expect(after == end)
        #expect(after.first?.asset == "a5")
    }

    @Test("Crossfade: utgående under, inkommande ovanpå med opacitet e")
    func crossfade() throws {
        let spec = try Self.twoClips(.init(type: .crossfade, direction: nil, duration: 1))
        // övergång 3...4
        let start = ReelTimeline.state(at: 3, spec: spec, outputSize: Self.vertical)
        #expect(start.map(\.asset) == ["a1"])             // inkommande har opacitet 0 och utelämnas
        let mid = ReelTimeline.state(at: 3.5, spec: spec, outputSize: Self.vertical)
        #expect(mid.map(\.asset) == ["a1", "a2"])
        #expect(mid.map(\.z) == [0, 1])
        #expect(mid[0].opacity == 1)
        #expect(Self.approx(mid[1].opacity, 0.5))          // linjär easing
        let quarter = ReelTimeline.state(at: 3.25, spec: spec, outputSize: Self.vertical)
        #expect(Self.approx(quarter[1].opacity, 0.25))
        // Vid övergångens slut (4 s) har a2 tagit över helt.
        let end = ReelTimeline.state(at: 4, spec: spec, outputSize: Self.vertical)
        #expect(end.map(\.asset) == ["a2"] && end[0].opacity == 1)

        let eased = try Self.twoClips(.init(type: .crossfade, direction: nil, duration: 1), easing: .easeInOut)
        let q = ReelTimeline.state(at: 3.25, spec: eased, outputSize: Self.vertical)
        #expect(Self.approx(q[1].opacity, 0.15625))
    }

    @Test("Cut: aldrig mer än ett lager")
    func cutHasNoOverlap() throws {
        let spec = try Self.twoClips(.init(type: .cut, direction: nil, duration: 0.5))
        for t in stride(from: 0.0, through: 8.0, by: 0.25) {
            let layers = ReelTimeline.state(at: t, spec: spec, outputSize: Self.vertical)
            #expect(layers.count == 1)
            #expect(layers[0].opacity == 1)
            #expect(layers[0].asset == (t < 4 ? "a1" : "a2"))
        }
    }

    @Test("Push: utgående glider ut, inkommande glider in, i alla fyra riktningar")
    func pushOffsets() throws {
        let cases: [(ReelSpec.Direction, Double, Double)] = [(.left, -1, 0), (.right, 1, 0), (.up, 0, -1), (.down, 0, 1)]
        for (dir, dx, dy) in cases {
            let spec = try Self.twoClips(.init(type: .push, direction: dir, duration: 1))
            let l = ReelTimeline.state(at: 3.25, spec: spec, outputSize: Self.vertical)   // e = 0,25
            #expect(l.count == 2)
            #expect(l[0].asset == "a1" && l[1].asset == "a2")
            #expect(l[0].opacity == 1 && l[1].opacity == 1)
            #expect(Self.approx(Double(l[0].offset.x), dx * 0.25) && Self.approx(Double(l[0].offset.y), dy * 0.25))
            #expect(Self.approx(Double(l[1].offset.x), dx * -0.75) && Self.approx(Double(l[1].offset.y), dy * -0.75))
        }
        let spec = try Self.twoClips(.init(type: .push, direction: .left, duration: 1))
        let first = ReelTimeline.state(at: 3, spec: spec, outputSize: Self.vertical)
        #expect(first[1].offset == CGPoint(x: 1, y: 0))   // e = 0: inkommande står en hel ram åt höger
        let done = ReelTimeline.state(at: 4, spec: spec, outputSize: Self.vertical)
        #expect(done.count == 1 && done[0].offset == .zero)
    }

    @Test("fadeThroughBlack: utgående tonar ut första halvan, inkommande in andra")
    func fadeThroughBlack() throws {
        let spec = try Self.twoClips(.init(type: .fadeThroughBlack, direction: nil, duration: 1))
        // övergång 3...4, mitt vid 3,5
        let a = ReelTimeline.state(at: 3, spec: spec, outputSize: Self.vertical)
        #expect(a.map(\.asset) == ["a1"] && a[0].opacity == 1)
        let b = ReelTimeline.state(at: 3.25, spec: spec, outputSize: Self.vertical)
        #expect(b.map(\.asset) == ["a1"])
        #expect(Self.approx(b[0].opacity, 0.5))            // 1 − linjär(0,5)
        let mid = ReelTimeline.state(at: 3.5, spec: spec, outputSize: Self.vertical)
        #expect(mid.isEmpty)                                // helt svart
        let c = ReelTimeline.state(at: 3.75, spec: spec, outputSize: Self.vertical)
        #expect(c.map(\.asset) == ["a2"])
        #expect(Self.approx(c[0].opacity, 0.5))
        let d = ReelTimeline.state(at: 4, spec: spec, outputSize: Self.vertical)
        #expect(d.map(\.asset) == ["a2"] && Self.approx(d[0].opacity, 1))

        let eased = try Self.twoClips(.init(type: .fadeThroughBlack, direction: nil, duration: 1), easing: .easeInOut)
        let e = ReelTimeline.state(at: 3.125, spec: eased, outputSize: Self.vertical)   // q = 0,125, 2q = 0,25
        #expect(Self.approx(e[0].opacity, 1 - 0.15625))
    }

    @Test("contain-blur: hela bilden i en centrerad ruta, suddig cover-bakgrund med σ enligt formeln")
    func containBlurGeometry() throws {
        let spec = try Self.example()
        // Klipp 5 (a5, contain-blur) börjar vid 8,7; övergången (0,6 s) är klar vid 9,3.
        let size = Self.vertical
        let layers = ReelTimeline.state(at: 9.5, spec: spec, outputSize: size)
        let l = try #require(layers.last)
        #expect(l.fit == .containBlur)
        // 3:2-bild i 9:16: bredd fyller ramen, höjd = (9/16)/(3/2) = 0,375
        #expect(Self.approx(l.dest, 0, (1 - 0.375) / 2, 1, 0.375, 2e-3))   // bilden är 6048×4024, ≈ 3:2
        // p = 0,8/3,4, zoom 1 → 1,06 geometriskt; utsnittet = 1/z kvadratiskt i bildens normaliserade koordinater
        let e = ReelTimeline.easing(.easeInOut, 0.8 / 3.4)
        let z = pow(1.06, e)
        #expect(Self.approx(Double(l.crop.width), 1 / z) && Self.approx(Double(l.crop.height), 1 / z))
        let backdrop = try #require(l.backdrop)
        #expect(Self.approx(backdrop.sigma, 0.6 * 0.05 * 1920))   // 57,6 px
        #expect(Self.approx(backdrop.crop, 0.3125, 0, 0.375, 1, 2e-3))   // cover vid zoom 1, center (0,5; 0,45) klampad
    }

    @Test("contain-blur vid zoom 1 visar hela bilden oavsett mittpunkt; svart bakgrund ger ingen suddig kopia")
    func containBlurFullAndBlack() throws {
        var spec = try Self.twoClips(nil, fit: .containBlur, background: .init(type: "black", amount: nil))
        spec.timeline[0].fit = .containBlur
        spec.timeline[0].motion = .init(from: .init(cx: 0.1, cy: 0.9, zoom: 1), to: .init(cx: 0.1, cy: 0.9, zoom: 1))
        let l = try #require(ReelTimeline.state(at: 1, spec: spec, outputSize: Self.square).first)
        #expect(l.crop == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(l.backdrop == nil)
        // 3:2 i 1:1: bredd 1, höjd 2/3
        #expect(Self.approx(l.dest, 0, 1.0 / 6, 1, 2.0 / 3, 2e-3))
        // Stående bild i 16:9: höjden fyller ramen
        let portrait = ReelTimeline.containRect(imageSize: CGSize(width: 4000, height: 6000), frameAspect: 16.0 / 9)
        let pw: Double = (2.0 / 3.0) / (16.0 / 9.0)
        let px: Double = (1.0 - pw) / 2.0
        #expect(Self.approx(portrait, px, 0, pw, 1))
    }

    // MARK: Delad vektorfil

    struct Rect: Decodable { var x, y, w, h: Double }
    struct Offset: Decodable { var x, y: Double }
    struct Backdrop: Decodable { var crop: Rect; var sigma: Double }
    struct Layer: Decodable {
        var asset: String; var fit: String; var crop: Rect; var dest: Rect
        var opacity: Double; var offset: Offset; var z: Int; var backdrop: Backdrop?
    }
    struct StateCase: Decodable { var t: Double; var outputSize: [Double]; var layers: [Layer] }
    struct Timeline: Decodable {
        var name: String; var specFile: String?; var spec: ReelSpec?
        var clipStarts: [Double]; var totalDuration: Double; var states: [StateCase]
    }
    struct CropCase: Decodable { var imageSize: [Double]; var frameAspect: Double; var center: [Double]; var zoom: Double; var expected: Rect }
    struct EasingCase: Decodable { var type: String; var p: Double; var expected: Double }
    struct Vectors: Decodable {
        var tolerance: Double; var easing: [EasingCase]; var cropRects: [CropCase]; var timelines: [Timeline]
    }

    @Test("timeline-vectors.json stämmer med implementationen")
    func sharedVectors() throws {
        let data = try Data(contentsOf: ReelSpecCodingTests.fixturesDir.appendingPathComponent("timeline-vectors.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let v = try decoder.decode(Vectors.self, from: data)
        let tol = v.tolerance
        #expect(!v.timelines.isEmpty && !v.cropRects.isEmpty && !v.easing.isEmpty)

        for c in v.easing {
            let kind = try #require(ReelSpec.Easing(rawValue: c.type))
            #expect(Self.approx(ReelTimeline.easing(kind, c.p), c.expected, tol), "easing \(c.type) p=\(c.p)")
        }
        for c in v.cropRects {
            let r = ReelTimeline.cropRect(imageSize: CGSize(width: c.imageSize[0], height: c.imageSize[1]),
                                          frameAspect: c.frameAspect,
                                          center: CGPoint(x: c.center[0], y: c.center[1]), zoom: c.zoom)
            #expect(Self.approx(r, c.expected.x, c.expected.y, c.expected.w, c.expected.h, tol), "crop \(c)")
        }
        for tl in v.timelines {
            let spec: ReelSpec
            if let file = tl.specFile {
                spec = try ReelSpec.decode(from: try Data(contentsOf: ReelSpecCodingTests.fixturesDir.appendingPathComponent(file)))
            } else {
                spec = try #require(tl.spec)
            }
            let starts = ReelTimeline.clipStarts(spec)
            #expect(starts.count == tl.clipStarts.count, "\(tl.name)")
            for (a, b) in zip(starts, tl.clipStarts) { #expect(Self.approx(a, b, tol), "\(tl.name) start") }
            #expect(Self.approx(ReelTimeline.totalDuration(spec), tl.totalDuration, tol), "\(tl.name) total")

            for s in tl.states {
                let size = CGSize(width: s.outputSize[0], height: s.outputSize[1])
                let layers = ReelTimeline.state(at: s.t, spec: spec, outputSize: size)
                let label = "\(tl.name) t=\(s.t) \(Int(size.width))x\(Int(size.height))"
                #expect(layers.count == s.layers.count, "\(label): antal lager")
                for (l, e) in zip(layers, s.layers) {
                    #expect(l.asset == e.asset && l.fit.rawValue == e.fit && l.z == e.z, "\(label)")
                    #expect(Self.approx(l.opacity, e.opacity, tol), "\(label): opacitet")
                    #expect(Self.approx(Double(l.offset.x), e.offset.x, tol) && Self.approx(Double(l.offset.y), e.offset.y, tol), "\(label): offset")
                    #expect(Self.approx(l.crop, e.crop.x, e.crop.y, e.crop.w, e.crop.h, tol), "\(label): crop")
                    #expect(Self.approx(l.dest, e.dest.x, e.dest.y, e.dest.w, e.dest.h, tol), "\(label): dest")
                    #expect((l.backdrop == nil) == (e.backdrop == nil), "\(label): backdrop")
                    if let b = l.backdrop, let eb = e.backdrop {
                        #expect(Self.approx(b.sigma, eb.sigma, tol), "\(label): sigma")
                        #expect(Self.approx(b.crop, eb.crop.x, eb.crop.y, eb.crop.w, eb.crop.h, tol), "\(label): backdrop-crop")
                    }
                }
            }
        }
    }
}
