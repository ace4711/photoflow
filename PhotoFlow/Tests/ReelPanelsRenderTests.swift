import Foundation
import Testing
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Rendertester för rutklipp (spec v2): en liten film per layout (270×480, 480×270) med syntetiska,
/// enfärgade bilder; pixlarna visar att rätt bild hamnar i rätt ruta, att gutterbandet är svart, att
/// ingångens förskjutning stämmer vid en given tid och att gruppen blandas som en enhet vid övergångar.
/// Sätts miljövariabeln `REEL_PANEL_PNG_DIR` skrivs dessutom exempelbildrutor (med gradientbilder) som PNG.
struct ReelPanelsRenderTests {

    // MARK: - Hjälp

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-panels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Skriver en PNG; `draw` får en kontext med y uppåt. Enfärgad om `draw` är nil.
    private func writePNG(_ name: String, width: Int, height: Int, in dir: URL, draw: (CGContext) -> Void) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func solid(_ name: String, _ w: Int, _ h: Int, _ rgb: (CGFloat, CGFloat, CGFloat), in dir: URL) throws {
        try writePNG(name, width: w, height: h, in: dir) { ctx in
            ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private static let still = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1))

    private func spec(assets: [(String, Int, Int)], clips: [ReelSpec.Clip], easing: ReelSpec.Easing = .linear,
                      output: ReelSpec.Output) -> ReelSpec {
        ReelSpec(
            schema: ReelSpec.schemaName, version: 2, minReaderVersion: 2, id: "t", revision: 1, status: "draft",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            updatedBy: .init(role: "agent", name: nil), property: .init(address: "Test", sessionID: nil, kind: nil),
            assets: assets.map { .init(id: $0.0, sha256: $0.0, width: $0.1, height: $0.2, sources: [.init(kind: .local, path: "\($0.0).png")], analysis: nil) },
            style: .init(defaultTransition: .init(type: .crossfade, direction: nil, duration: 0.4), easing: easing,
                         background: .init(type: "blur", amount: 0.6)),
            timeline: clips, audio: nil, overlays: [], brand: nil, outputs: [output],
            provenance: .init(generator: "test", autoSelection: nil, edits: nil))
    }

    private static let out916 = ReelSpec.Output(id: "v", aspect: "9:16", width: 270, height: 480, fps: 30, encoding: nil)
    private static let out169 = ReelSpec.Output(id: "l", aspect: "16:9", width: 480, height: 270, fps: 30, encoding: nil)

    private func panelClip(_ layout: ReelSpec.PanelLayout, _ panels: [ReelSpec.Panel], duration: Double,
                           gutter: Double? = nil, entrance: ReelSpec.Entrance? = nil,
                           transitionIn: ReelSpec.Transition? = nil) -> ReelSpec.Clip {
        .init(asset: panels[0].asset, duration: duration, fit: .panels, motion: panels[0].motion, transitionIn: transitionIn,
              motionPreset: "custom", layout: layout, panels: panels, gutter: gutter, entrance: entrance)
    }

    private func pixel(_ r: ReelRenderer, _ image: CIImage, _ x: Int, _ y: Int) -> [Int] {
        var buf = [UInt8](repeating: 0, count: 4)
        r.context.render(image, toBitmap: &buf, rowBytes: 4,
                         bounds: CGRect(x: CGFloat(x), y: image.extent.height - CGFloat(y) - 1, width: 1, height: 1),
                         format: .RGBA8, colorSpace: ReelRenderer.sRGB)
        return buf.map(Int.init)
    }

    private func isRed(_ p: [Int]) -> Bool { p[0] > 240 && p[1] < 15 && p[2] < 15 }
    private func isBlue(_ p: [Int]) -> Bool { p[2] > 240 && p[0] < 15 && p[1] < 15 }
    private func isBlack(_ p: [Int]) -> Bool { p[0] < 6 && p[1] < 6 && p[2] < 6 }

    private func render(_ s: ReelSpec, _ dir: URL, at t: Double) -> (ReelRenderer, CIImage) {
        let size = CGSize(width: s.outputs[0].width, height: s.outputs[0].height)
        let r = ReelRenderer(spec: s, specDirectory: dir, maxOutputSize: size)
        return (r, r.renderFrame(at: t, size: size))
    }

    // MARK: - Layouter

    @Test("stack: första bilden uppe, andra nere, svart gutter mitt emellan")
    func stackPlacesImagesAndGutter() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("a1.png", 600, 400, (1, 0, 0), in: dir)
        try solid("a2.png", 600, 400, (0, 0, 1), in: dir)
        let clip = panelClip(.stack, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                             duration: 2, gutter: 0.04)
        let s = spec(assets: [("a1", 600, 400), ("a2", 600, 400)], clips: [clip], output: Self.out916)
        let (r, img) = render(s, dir, at: 1)
        #expect(isRed(pixel(r, img, 135, 100)))
        #expect(isRed(pixel(r, img, 5, 5)) && isRed(pixel(r, img, 265, 225)))
        #expect(isBlue(pixel(r, img, 135, 380)))
        #expect(isBlue(pixel(r, img, 5, 474)))
        // Gutter 0,04 av kortsidan 270 px = 10,8 px, mitt på höjden.
        #expect(isBlack(pixel(r, img, 135, 240)) && isBlack(pixel(r, img, 10, 238)) && isBlack(pixel(r, img, 260, 242)))
        #expect(isRed(pixel(r, img, 135, 230)) && isBlue(pixel(r, img, 135, 251)))
    }

    @Test("side: första bilden till vänster, andra till höger, svart gutter i mitten (16:9)")
    func sidePlacesImagesAndGutter() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("a1.png", 400, 600, (1, 0, 0), in: dir)
        try solid("a2.png", 400, 600, (0, 0, 1), in: dir)
        let clip = panelClip(.side, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                             duration: 2, gutter: 0.04)
        let s = spec(assets: [("a1", 400, 600), ("a2", 400, 600)], clips: [clip], output: Self.out169)
        let (r, img) = render(s, dir, at: 1)
        #expect(isRed(pixel(r, img, 100, 135)) && isRed(pixel(r, img, 2, 2)))
        #expect(isBlue(pixel(r, img, 380, 135)) && isBlue(pixel(r, img, 477, 267)))
        // Kortsidan är höjden 270 px: 0,04 · 270 = 10,8 px brett band kring x = 240.
        #expect(isBlack(pixel(r, img, 240, 100)) && isBlack(pixel(r, img, 236, 5)) && isBlack(pixel(r, img, 244, 260)))
        #expect(isRed(pixel(r, img, 232, 100)) && isBlue(pixel(r, img, 249, 100)))
    }

    @Test("source: montagehalvorna visas var för sig, vänster halva röd och höger blå")
    func sourceHalves() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("m.png", width: 800, height: 600, in: dir) { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 400, y: 0, width: 400, height: 600))
        }
        let left = ReelSpec.UnitRect(x: 0, y: 0, w: 0.5, h: 1), right = ReelSpec.UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        // Mittpunkten för den vänstra rutan ligger i höger halva (0,9) men klampas inom `source`.
        let farRight = ReelSpec.Motion(from: .init(cx: 0.9, cy: 0.5, zoom: 1), to: .init(cx: 0.9, cy: 0.5, zoom: 1))
        let clip = panelClip(.side, [.init(asset: "m", source: left, motion: farRight), .init(asset: "m", source: right, motion: Self.still)],
                             duration: 2, gutter: 0.02)
        let s = spec(assets: [("m", 800, 600)], clips: [clip], output: Self.out169)
        let (r, img) = render(s, dir, at: 1)
        // Hela vänstra rutan (inkl. kanterna) är röd, hela högra blå: ingen blandning av halvorna.
        for (x, y) in [(2, 2), (120, 135), (232, 267), (100, 5)] { #expect(isRed(pixel(r, img, x, y)), "röd vid \(x),\(y)") }
        for (x, y) in [(248, 2), (360, 135), (477, 267), (400, 5)] { #expect(isBlue(pixel(r, img, x, y)), "blå vid \(x),\(y)") }
    }

    @Test("sequence: första halvan av klippet visar vänstra halvan, sedan skjuts den högra in")
    func sequenceShowsHalvesAndPushes() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("m.png", width: 800, height: 600, in: dir) { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 400, y: 0, width: 400, height: 600))
        }
        let left = ReelSpec.UnitRect(x: 0, y: 0, w: 0.5, h: 1), right = ReelSpec.UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let clip = panelClip(.sequence, [.init(asset: "m", source: left, motion: Self.still), .init(asset: "m", source: right, motion: Self.still)],
                             duration: 4)
        let s = spec(assets: [("m", 800, 600)], clips: [clip], output: Self.out916)
        // D = 4, seg = 2, dp = min(0,4, 0,5) = 0,4: skjutningen ligger i [1,8; 2,2). Linjär easing: e = (t − 1,8)/0,4.
        let (r0, early) = render(s, dir, at: 0.5)
        #expect(isRed(pixel(r0, early, 135, 240)) && isRed(pixel(r0, early, 5, 5)) && isRed(pixel(r0, early, 265, 475)))
        let (r1, mid) = render(s, dir, at: 2.0)   // e = 0,5: röd förskjuten −135 px, blå +135 px
        #expect(isRed(pixel(r1, mid, 60, 240)) && isBlue(pixel(r1, mid, 200, 240)))
        let (r2, late) = render(s, dir, at: 3.5)
        #expect(isBlue(pixel(r2, late, 135, 240)) && isBlue(pixel(r2, late, 5, 475)))
    }

    // MARK: - Ingång och övergångar

    @Test("slide: ruta 1 glider in från vänster (stack) vid en given tid, ruta 2 startar senare")
    func slideEntranceOffset() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("a1.png", 600, 400, (1, 0, 0), in: dir)
        try solid("a2.png", 600, 400, (0, 0, 1), in: dir)
        let clip = panelClip(.stack, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                             duration: 3, gutter: 0.006, entrance: .init(type: .slide, stagger: 0.3, duration: 0.6))
        let s = spec(assets: [("a1", 600, 400), ("a2", 600, 400)], clips: [clip], output: Self.out916)
        // t = 0,3 (linjär easing): ruta 1 har q = 0,5 och sitter 135 px till vänster; ruta 2 har inte börjat.
        let (r, img) = render(s, dir, at: 0.3)
        #expect(isRed(pixel(r, img, 60, 100)), "röda rutans högra kant ligger vid x = 135")
        #expect(isBlack(pixel(r, img, 200, 100)), "till höger om den halvvägs inglidna rutan är det svart")
        #expect(isBlack(pixel(r, img, 135, 380)) && isBlack(pixel(r, img, 265, 380)), "ruta 2 ligger utanför ramen")
        // t = 0,6: ruta 1 på plats (q = 1), ruta 2 har q = 0,5 och sitter 135 px till höger.
        let (r2, img2) = render(s, dir, at: 0.6)
        #expect(isRed(pixel(r2, img2, 5, 100)) && isRed(pixel(r2, img2, 265, 100)))
        #expect(isBlue(pixel(r2, img2, 200, 380)) && isBlack(pixel(r2, img2, 60, 380)))
        // Efter ingången: båda på plats.
        let (r3, img3) = render(s, dir, at: 1.2)
        #expect(isRed(pixel(r3, img3, 5, 100)) && isBlue(pixel(r3, img3, 265, 380)))
    }

    @Test("fade: rutorna tonar in var för sig mot svart")
    func fadeEntrance() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("a1.png", 600, 400, (1, 1, 1), in: dir)
        try solid("a2.png", 600, 400, (1, 1, 1), in: dir)
        let clip = panelClip(.stack, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                             duration: 3, entrance: .init(type: .fade, stagger: 0.4, duration: 0.8))
        let s = spec(assets: [("a1", 600, 400), ("a2", 600, 400)], clips: [clip], output: Self.out916)
        let (r, img) = render(s, dir, at: 0.4)   // ruta 1: q = 0,5 → ~128; ruta 2: q = 0 → svart
        let top = pixel(r, img, 135, 100), bottom = pixel(r, img, 135, 380)
        #expect(abs(top[0] - 128) <= 4, "uppe \(top)")
        #expect(isBlack(bottom), "nere \(bottom)")
    }

    @Test("övergång in i ett rutklipp: hela gruppen (inkl. svart gutter) blandas med det utgående")
    func groupCrossfadeIncludesBlackGutter() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("g.png", 600, 400, (0, 1, 0), in: dir)
        try solid("a1.png", 600, 400, (1, 0, 0), in: dir)
        try solid("a2.png", 600, 400, (1, 0, 0), in: dir)
        let g = ReelSpec.Clip(asset: "g", duration: 2, fit: .cover, motion: Self.still)
        let panels = panelClip(.stack, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                               duration: 2, gutter: 0.04, transitionIn: .init(type: .crossfade, direction: nil, duration: 0.5))
        let s = spec(assets: [("g", 600, 400), ("a1", 600, 400), ("a2", 600, 400)], clips: [g, panels], output: Self.out916)
        // Övergången börjar vid 1,5 s och är 0,5 s; linjär easing: t = 1,75 → e = 0,5.
        let (r, img) = render(s, dir, at: 1.75)
        let top = pixel(r, img, 135, 100), gutter = pixel(r, img, 135, 240)
        #expect(abs(top[0] - 128) <= 4 && abs(top[1] - 128) <= 4 && top[2] <= 4, "rutan \(top)")
        #expect(gutter[0] <= 4 && abs(gutter[1] - 128) <= 4 && gutter[2] <= 4, "gutter \(gutter): svart gruppbotten, inte grönt rakt igenom")
    }

    @Test("push ut ur ett rutklipp flyttar hela gruppen")
    func pushMovesWholeGroup() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try solid("a1.png", 600, 400, (1, 0, 0), in: dir)
        try solid("a2.png", 600, 400, (1, 0, 0), in: dir)
        try solid("g.png", 600, 400, (0, 1, 0), in: dir)
        let panels = panelClip(.side, [.init(asset: "a1", source: nil, motion: Self.still), .init(asset: "a2", source: nil, motion: Self.still)],
                               duration: 2, gutter: 0.04)
        let g = ReelSpec.Clip(asset: "g", duration: 2, fit: .cover, motion: Self.still,
                              transitionIn: .init(type: .push, direction: .left, duration: 0.5))
        let s = spec(assets: [("a1", 600, 400), ("a2", 600, 400), ("g", 600, 400)], clips: [panels, g], output: Self.out916)
        let (r, img) = render(s, dir, at: 1.75)   // e = 0,5: rutgruppen −135 px, grönt +135 px
        #expect(isRed(pixel(r, img, 60, 100)))
        #expect(pixel(r, img, 200, 100)[1] > 240)
        #expect(isBlack(pixel(r, img, 2, 100)), "gutterbandet (mitt i ramen) följer med gruppen till vänsterkanten")
    }

    // MARK: - Exempelbildrutor

    /// Skriver exempelbildrutor (gradientbilder) när `REEL_PANEL_PNG_DIR` är satt; annars är testet tomt.
    @Test("exempelbildrutor per layout skrivs som PNG när REEL_PANEL_PNG_DIR är satt")
    func writeSampleFrames() throws {
        guard let target = ProcessInfo.processInfo.environment["REEL_PANEL_PNG_DIR"] else { return }
        let out = URL(fileURLWithPath: target, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Gradientbilder med rutnät och en markering så att utsnitt syns.
        func photo(_ name: String, _ w: Int, _ h: Int, _ hue: (CGFloat, CGFloat, CGFloat)) throws {
            try writePNG(name, width: w, height: h, in: dir) { ctx in
                for i in 0..<h {
                    let f = CGFloat(i) / CGFloat(h)
                    ctx.setFillColor(red: hue.0 * (1 - 0.6 * f), green: hue.1 * (1 - 0.6 * f), blue: hue.2 * (1 - 0.6 * f), alpha: 1)
                    ctx.fill(CGRect(x: 0, y: i, width: w, height: 1))
                }
                ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.5)
                ctx.setLineWidth(CGFloat(w) / 200)
                for k in 1..<8 {
                    ctx.move(to: CGPoint(x: CGFloat(w) * CGFloat(k) / 8, y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(w) * CGFloat(k) / 8, y: CGFloat(h)))
                    ctx.move(to: CGPoint(x: 0, y: CGFloat(h) * CGFloat(k) / 8)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h) * CGFloat(k) / 8))
                }
                ctx.strokePath()
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
                ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.42, y: CGFloat(h) * 0.4, width: CGFloat(w) * 0.16, height: CGFloat(w) * 0.16))
            }
        }
        try photo("k.png", 1500, 1000, (0.9, 0.55, 0.2))
        try photo("l.png", 1500, 1000, (0.2, 0.6, 0.9))
        try photo("m.png", 2000, 1500, (0.3, 0.8, 0.4))   // montage: två stående bilder sida vid sida
        try writePNG("m.png", width: 2000, height: 1500, in: dir) { ctx in
            ctx.setFillColor(red: 0.85, green: 0.45, blue: 0.35, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1500))
            ctx.setFillColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1); ctx.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1500))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
            ctx.fillEllipse(in: CGRect(x: 380, y: 600, width: 240, height: 240)); ctx.fillEllipse(in: CGRect(x: 1380, y: 600, width: 240, height: 240))
        }
        let slow = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.04))
        let left = ReelSpec.UnitRect(x: 0, y: 0, w: 0.5, h: 1), right = ReelSpec.UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let assets = [("k", 1500, 1000), ("l", 1500, 1000), ("m", 2000, 1500)]
        let cases: [(String, ReelSpec.Clip, ReelSpec.Output, [Double])] = [
            ("stack-9x16", panelClip(.stack, [.init(asset: "k", source: nil, motion: slow), .init(asset: "l", source: nil, motion: slow)], duration: 3,
                                     entrance: .init(type: .slide, stagger: 0.3, duration: 0.6)), Self.out916, [0.2, 0.45, 0.7, 2.5]),
            ("side-16x9", panelClip(.side, [.init(asset: "k", source: nil, motion: slow), .init(asset: "l", source: nil, motion: slow)], duration: 3,
                                    entrance: .init(type: .slide, stagger: 0.3, duration: 0.6)), Self.out169, [0.2, 0.45, 0.7, 2.5]),
            ("montage-sequence-9x16", panelClip(.sequence, [.init(asset: "m", source: left, motion: slow), .init(asset: "m", source: right, motion: slow)],
                                                duration: 4), Self.out916, [0.5, 1.9, 2.0, 2.1, 3.5]),
            ("montage-stack-9x16", panelClip(.stack, [.init(asset: "m", source: left, motion: slow), .init(asset: "m", source: right, motion: slow)],
                                             duration: 3, entrance: .init(type: .fade, stagger: 0.3, duration: 0.6)), Self.out916, [0.3, 2.5]),
        ]
        for (name, clip, output, times) in cases {
            let s = spec(assets: assets, clips: [clip], easing: .easeInOut, output: output)
            let size = CGSize(width: output.width, height: output.height)
            let r = ReelRenderer(spec: s, specDirectory: dir, maxOutputSize: size)
            for t in times {
                let image = r.renderFrame(at: t, size: size)
                let png = out.appendingPathComponent("\(name)-t\(String(format: "%.2f", t)).png")
                try r.context.writePNGRepresentation(of: image, to: png, format: .RGBA8, colorSpace: ReelRenderer.sRGB)
            }
        }
    }
}
