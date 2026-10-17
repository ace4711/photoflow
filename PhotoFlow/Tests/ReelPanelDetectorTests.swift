import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Skarvdetektering för montage (R6b) på syntetiska bilder: två olika halvor med och utan skarvlinje,
/// vanliga bilder med dörrkarm, fönsterbåge och rumshörn mitt i bilden som inte får träffa, en
/// symmetrisk bild, fel proportioner, och laddning från fil. Verkliga bilder mäts med `photoflow-cli reel-panels`.
struct ReelPanelDetectorTests {

    // MARK: - Syntetiska bilder

    /// Deterministisk slumpföljd (LCG), så att testerna inte är nyckfulla.
    private struct Lcg {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// En mjuk "rumsliknande" bild: bilinjärt slumpfält (10 × 7 punkter, 40...215) plus tre horisontella
    /// band (golvlist, taklist, horisont) och lite brus. Rader uppifrån och ned.
    private func scene(width w: Int, height h: Int, seed: UInt64) -> [UInt8] {
        var rng = Lcg(state: seed &* 7919 &+ 13)
        let gw = 10, gh = 7
        let grid = (0..<(gw * gh)).map { _ in 40 + rng.next() * 175 }
        let bands = (0..<3).map { _ in (row: Int(rng.next() * Double(h - 12)) + 4, delta: (rng.next() - 0.5) * 90) }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = Double(y) / Double(h - 1) * Double(gh - 1)
            let y0 = min(Int(fy), gh - 2), ty = fy - Double(y0)
            for x in 0..<w {
                let fx = Double(x) / Double(w - 1) * Double(gw - 1)
                let x0 = min(Int(fx), gw - 2), tx = fx - Double(x0)
                let a = grid[y0 * gw + x0], b = grid[y0 * gw + x0 + 1]
                let c = grid[(y0 + 1) * gw + x0], d = grid[(y0 + 1) * gw + x0 + 1]
                var v = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                for band in bands where abs(y - band.row) <= 2 { v += band.delta }
                v += (rng.next() - 0.5) * 4
                out[y * w + x] = UInt8(min(max(v, 0), 255))
            }
        }
        return out
    }

    /// Montage: två olika bilder, stående (3:4) var, med en ränna av färgen `gutterValue` (`gutter` px).
    private func montage(left: UInt64 = 1, right: UInt64 = 2, height h: Int = 600, gutter: Int = 0,
                         gutterValue: UInt8 = 255) -> (pixels: [UInt8], width: Int, height: Int) {
        let hw = h * 3 / 4
        let w = hw * 2 + gutter
        let l = scene(width: hw, height: h, seed: left), r = scene(width: hw, height: h, seed: right)
        var p = [UInt8](repeating: gutterValue, count: w * h)
        for y in 0..<h {
            for x in 0..<hw { p[y * w + x] = l[y * hw + x]; p[y * w + hw + gutter + x] = r[y * hw + x] }
        }
        return (p, w, h)
    }

    private func detect(_ m: (pixels: [UInt8], width: Int, height: Int)) -> ReelPanelDetector.Detection? {
        ReelPanelDetector.detect(luma: m.pixels, width: m.width, height: m.height)
    }

    // MARK: - Träffar

    @Test("Montage med bred vit ränna: två halvor, rännan klippt bort")
    func whiteGutter() throws {
        let m = montage(gutter: 12)
        let d = try #require(detect(m))
        #expect(d.kind == .gutter && d.panels.count == 2)
        let l = d.panels[0], r = d.panels[1]
        #expect(l.x == 0 && l.y == 0 && l.h == 1 && r.y == 0 && r.h == 1)
        let seam = 450.0 / Double(m.width)       // rännan börjar här
        let end = 462.0 / Double(m.width)
        #expect(l.x + l.w <= seam + 0.001 && l.x + l.w > seam - 0.01)
        #expect(r.x >= end - 0.001 && r.x < end + 0.01 && abs(r.x + r.w - 1) < 1e-9)
    }

    @Test("Ränna i svart och i grått känns också igen, även smal (2 px)")
    func otherGutters() {
        for (value, px) in [(UInt8(0), 8), (UInt8(128), 8), (UInt8(255), 2), (UInt8(0), 3)] {
            let d = detect(montage(gutter: px, gutterValue: value))
            #expect(d?.kind == .gutter, "ränna \(value) \(px) px")
        }
    }

    @Test("Montage utan någon linje: skarven hittas på kantens plats")
    func noGutter() throws {
        var found = 0
        for seed in 1...6 {
            let m = montage(left: UInt64(seed), right: UInt64(seed + 20))
            if let d = detect(m) {
                found += 1
                #expect(d.kind == .edge && d.panels.count == 2)
                #expect(abs(d.panels[0].w - 0.5) < 0.01 && abs(d.panels[1].x - 0.5) < 0.01)
            }
        }
        #expect(found >= 5, "skarv utan ränna hittades i \(found) av 6")
    }

    @Test("Tunn vit linje (1 px) mellan halvorna känns igen")
    func thinLine() {
        var found = 0
        for seed in 1...6 where detect(montage(left: UInt64(seed), right: UInt64(seed + 30), gutter: 1)) != nil { found += 1 }
        #expect(found >= 5)
    }

    // MARK: - Falska träffar

    /// En vanlig bild: samma scen över hela bredden (3:2), så att de horisontella banden fortsätter över mitten.
    private func plain(seed: UInt64, width w: Int = 900, height h: Int = 600) -> [UInt8] { scene(width: w, height: h, seed: seed) }

    @Test("Vanliga bilder utan något i mitten ger ingen träff")
    func plainImages() {
        for seed in 1...12 {
            #expect(ReelPanelDetector.detect(luma: plain(seed: UInt64(seed)), width: 900, height: 600) == nil, "bild \(seed)")
        }
    }

    @Test("Dörrkarm mitt i bilden (mörk list genom nästan hela höjden): ingen träff")
    func doorFrame() {
        for seed in 1...8 {
            var p = plain(seed: UInt64(seed))
            for y in 30..<600 { for x in 446..<462 { p[y * 900 + x] = 25 } }
            #expect(ReelPanelDetector.detect(luma: p, width: 900, height: 600) == nil, "dörrkarm \(seed)")
        }
    }

    @Test("Fönsterbåge: ljus eller mörk list med ljusfall och brus genom hela höjden i mitten: ingen träff")
    func windowMullion() {
        for seed in 1...8 {
            var rng = Lcg(state: UInt64(seed) &* 31)
            for (value, barWidth) in [(240.0, 24), (232.0, 12), (30.0, 36)] {
                var p = plain(seed: UInt64(seed))
                for y in 0..<600 {
                    for x in (450 - barWidth / 2)..<(450 + barWidth / 2) {
                        // Ljusfall uppifrån och ned och brus: en verklig list är aldrig helt platt.
                        let shade: Double = value - 18.0 * Double(y) / 600.0
                        let noisy: Double = shade + (rng.next() - 0.5) * 8.0
                        p[y * 900 + x] = UInt8(min(max(noisy, 0.0), 255.0))
                    }
                }
                #expect(ReelPanelDetector.detect(luma: p, width: 900, height: 600) == nil, "båge \(seed) \(value) \(barWidth)")
            }
        }
    }

    @Test("Rumshörn i mitten: två väggar med olika ljus, golv och list som fortsätter: ingen träff")
    func roomCorner() {
        for seed in 1...8 {
            var p = plain(seed: UInt64(seed))
            // Höger vägg 35 gråsteg mörkare, med skarp lodrät kant genom hela höjden.
            for y in 0..<600 { for x in 450..<900 { p[y * 900 + x] = UInt8(max(Int(p[y * 900 + x]) - 35, 0)) } }
            #expect(ReelPanelDetector.detect(luma: p, width: 900, height: 600) == nil, "hörn \(seed)")
        }
    }

    @Test("Symmetrisk bild (högra halvan är den vänstras spegelbild): ingen träff")
    func symmetric() {
        let hw = 450, h = 600
        let half = scene(width: hw, height: h, seed: 5)
        var p = [UInt8](repeating: 0, count: hw * 2 * h)
        for y in 0..<h { for x in 0..<hw { p[y * hw * 2 + x] = half[y * hw + x]; p[y * hw * 2 + hw * 2 - 1 - x] = half[y * hw + x] } }
        #expect(ReelPanelDetector.detect(luma: p, width: hw * 2, height: h) == nil)
    }

    @Test("Enfärgad och nästan enfärgad bild: ingen träff")
    func flat() {
        #expect(ReelPanelDetector.detect(luma: [UInt8](repeating: 255, count: 900 * 600), width: 900, height: 600) == nil)
        #expect(ReelPanelDetector.detect(luma: [UInt8](repeating: 0, count: 900 * 600), width: 900, height: 600) == nil)
        // Vit bild med ett mörkt föremål långt från mitten.
        var p = [UInt8](repeating: 255, count: 900 * 600)
        for y in 100..<500 { for x in 100..<200 { p[y * 900 + x] = 30 } }
        #expect(ReelPanelDetector.detect(luma: p, width: 900, height: 600) == nil)
    }

    @Test("Fel proportioner: stående bild, kvadrat och panorama är aldrig montage")
    func geometry() {
        let portrait = scene(width: 600, height: 900, seed: 3)
        #expect(ReelPanelDetector.detect(luma: portrait, width: 600, height: 900) == nil)
        let square = scene(width: 600, height: 600, seed: 3)
        #expect(ReelPanelDetector.detect(luma: square, width: 600, height: 600) == nil)
        // Panorama 3:1 med en ränna i mitten: halvorna är liggande, inget montage av stående bilder.
        let w = 1800, h = 600, g = 12
        let l = scene(width: (w - g) / 2, height: h, seed: 1), r = scene(width: (w - g) / 2, height: h, seed: 2)
        var p = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<((w - g) / 2) { p[y * w + x] = l[y * ((w - g) / 2) + x]; p[y * w + (w - g) / 2 + g + x] = r[y * ((w - g) / 2) + x] } }
        #expect(ReelPanelDetector.detect(luma: p, width: w, height: h) == nil)
        // Liggande halvor (3:2-bilder sida vid sida i en 3:1-bild) är inte stående.
        #expect(ReelPanelDetector.measure(luma: p, width: w, height: h).geometryOK == false)
    }

    @Test("Halvor som ligger snett (en smal vänster halva) accepteras bara om båda är stående och minst 30 %")
    func unevenHalves() {
        // Ränna vid 41 %: vänster 41 % × 1,5 = 0,615 stående, höger 59 % × 1,5 = 0,885 stående.
        let w = 900, h = 600, g = 10, left = 364
        let l = scene(width: left, height: h, seed: 1), r = scene(width: w - left - g, height: h, seed: 2)
        var p = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<left { p[y * w + x] = l[y * left + x] }
            for x in 0..<(w - left - g) { p[y * w + left + g + x] = r[y * (w - left - g) + x] }
        }
        let d = ReelPanelDetector.detect(luma: p, width: w, height: h)
        #expect(d?.kind == .gutter)
        if let d { #expect(d.panels[0].w < 0.42 && d.panels[1].x > 0.4) }
    }

    @Test("Mått: ränna ger closeness ≥ 1, en vanlig bild långt under 1")
    func measurements() {
        let hit = ReelPanelDetector.measure(luma: montage(gutter: 12).pixels, width: 912, height: 600)
        #expect(hit.geometryOK && hit.gutterWidth > 0.01 && hit.closeness >= 1)
        let miss = ReelPanelDetector.measure(luma: plain(seed: 4), width: 900, height: 600)
        #expect(miss.gutterWidth == 0 && miss.closeness < 0.95)
    }

    // MARK: - Fil

    private func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) {
        var data = pixels
        let ctx = data.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test("Från fil: ett montage ger två rutor, en vanlig bild en tom lista, en saknad fil nil")
    func fromFile() throws {
        let dir = try ObjektfilmTestKit.tempDir("PanelDetector")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = montage(gutter: 12)
        let montageURL = dir.appendingPathComponent("montage.png")
        writePNG(m.pixels, width: m.width, height: m.height, to: montageURL)
        let plainURL = dir.appendingPathComponent("vanlig.png")
        writePNG(plain(seed: 2), width: 900, height: 600, to: plainURL)
        let panels = try #require(ReelPanelDetector.panels(url: montageURL))
        #expect(panels.count == 2)
        #expect(try #require(ReelPanelDetector.panels(url: plainURL)).isEmpty)
        #expect(ReelPanelDetector.panels(url: dir.appendingPathComponent("saknas.png")) == nil)
    }
}
