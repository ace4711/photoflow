import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Tester för `ReelRenderer`: export till mp4 (längd, fps, codec, ljudspår), bildrutor
/// och blandning i sRGB. Bilderna är enfärgade PNG:er som skrivs till en temporär mapp.
struct ReelRendererTests {

    // MARK: - Hjälp

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Skriver en enfärgad sRGB-PNG.
    private func writePNG(_ name: String, width: Int, height: Int, rgb: (UInt8, UInt8, UInt8), in dir: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Specen: två statiska cover-klipp (1,2 s) med 0,4 s crossfade = 2,0 s totalt.
    private func makeSpec(files: [(name: String, width: Int, height: Int)], fit: ReelSpec.Fit = .cover, transition: Double = 0.4,
                          output: ReelSpec.Output = .init(id: "t", aspect: "9:16", width: 270, height: 480, fps: 30,
                                                          encoding: .init(codec: "h264", bitrateMbps: 2, audio: "aac-silent"))) -> ReelSpec {
        let key = ReelSpec.MotionKey(cx: 0.5, cy: 0.5, zoom: 1)
        let assets = files.enumerated().map { i, f in
            ReelSpec.Asset(id: "a\(i + 1)", sha256: "\(i)", width: f.width, height: f.height,
                           sources: [.init(kind: .local, path: f.name)], analysis: nil)
        }
        let clips = assets.map { ReelSpec.Clip(asset: $0.id, duration: 1.2, fit: fit, motion: .init(from: key, to: key), transitionIn: nil) }
        return ReelSpec(
            schema: ReelSpec.schemaName, version: 1, minReaderVersion: 1, id: "test", revision: 1, status: "draft",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            updatedBy: .init(role: "agent", name: nil), property: .init(address: "Test", sessionID: nil, kind: nil),
            assets: assets,
            style: .init(defaultTransition: .init(type: .crossfade, direction: nil, duration: transition),
                         easing: .easeInOut, background: .init(type: "blur", amount: 0.6)),
            timeline: clips, audio: nil, overlays: [], brand: nil, outputs: [output],
            provenance: .init(generator: "test", autoSelection: nil, edits: nil))
    }

    /// Pixel (x, y från överkanten) som sRGB 8-bitars RGBA.
    private func pixel(_ renderer: ReelRenderer, _ image: CIImage, x: Int, y: Int) -> [Int] {
        var buf = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: CGFloat(x), y: image.extent.height - CGFloat(y) - 1, width: 1, height: 1)
        renderer.context.render(image, toBitmap: &buf, rowBytes: 4, bounds: rect, format: .RGBA8, colorSpace: ReelRenderer.sRGB)
        return buf.map(Int.init)
    }

    // MARK: - Export

    @Test("Export ger H.264-mp4 med rätt längd, fps, upplösning och ett ljudspår")
    func exportProducesExpectedVideo() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("rod.png", width: 600, height: 400, rgb: (255, 0, 0), in: dir)
        try writePNG("bla.png", width: 400, height: 600, rgb: (0, 0, 255), in: dir)
        let spec = makeSpec(files: [("rod.png", 600, 400), ("bla.png", 400, 600)])
        #expect(ReelTimeline.totalDuration(spec) == 2.0)

        let out = dir.appendingPathComponent("film.mp4")
        let progressBox = Box()
        try await ReelRenderer.export(spec: spec, specDirectory: dir, output: spec.outputs[0], to: out) { progressBox.set($0) }
        #expect(progressBox.value == 1)

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.0) <= 1.0 / 30 + 0.001, "längd \(duration)")

        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 270, height: 480))
        let fps = try await video.load(.nominalFrameRate)
        #expect(abs(fps - 30) < 0.5)
        let formats = try await video.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)

        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)

        // Ingen temporärfil kvar.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("Avbruten export lämnar varken målfil eller temporärfil")
    func cancelledExportCleansUp() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("rod.png", width: 600, height: 400, rgb: (255, 0, 0), in: dir)
        let spec = makeSpec(files: [("rod.png", 600, 400)])
        let out = dir.appendingPathComponent("film.mp4")
        let task = Task { try await ReelRenderer.export(spec: spec, specDirectory: dir, output: spec.outputs[0], to: out) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".mp4") || $0.contains(".tmp") }
        #expect(remaining.isEmpty)
    }

    @Test("Saknad bildfil ger ett fel direkt")
    func missingAssetFails() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = makeSpec(files: [("finns-inte.png", 600, 400)])
        await #expect(throws: ReelRenderError.self) {
            try await ReelRenderer.export(spec: spec, specDirectory: dir, output: spec.outputs[0],
                                          to: dir.appendingPathComponent("x.mp4"))
        }
    }

    // MARK: - Bildrutor

    @Test("renderFrame har rätt storlek och visar första bilden vid t = 0")
    func firstFrame() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("rod.png", width: 600, height: 400, rgb: (255, 0, 0), in: dir)
        try writePNG("bla.png", width: 400, height: 600, rgb: (0, 0, 255), in: dir)
        let spec = makeSpec(files: [("rod.png", 600, 400), ("bla.png", 400, 600)])
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: 270, height: 480))
        let image = renderer.renderFrame(at: 0, size: CGSize(width: 270, height: 480))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 270, height: 480))
        let p = pixel(renderer, image, x: 135, y: 240)
        #expect(abs(p[0] - 255) <= 2 && p[1] <= 2 && p[2] <= 2)
        // Samma kod ger en annan storlek för en förhandsvisning.
        #expect(renderer.renderFrame(at: 0, size: CGSize(width: 90, height: 160)).extent.size == CGSize(width: 90, height: 160))
    }

    @Test("Mitt i en crossfade är bilden en blandning av de två bilderna")
    func crossfadeMidFrameIsBlend() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("rod.png", width: 600, height: 400, rgb: (255, 0, 0), in: dir)
        try writePNG("bla.png", width: 400, height: 600, rgb: (0, 0, 255), in: dir)
        let spec = makeSpec(files: [("rod.png", 600, 400), ("bla.png", 400, 600)])
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: 270, height: 480))
        // Övergången börjar vid 0,8 s och är 0,4 s: t = 1,0 ger e = 0,5.
        let p = pixel(renderer, renderer.renderFrame(at: 1.0, size: CGSize(width: 270, height: 480)), x: 100, y: 200)
        #expect(p[0] > 60 && p[0] < 200, "röd \(p[0])")
        #expect(p[2] > 60 && p[2] < 200, "blå \(p[2])")
        #expect(abs(p[0] + p[2] - 255) <= 6)
    }

    @Test("Blandningen sker i sRGB-värden: svart/vitt ger ~128 i mitten, inte ~188 (linjärt)")
    func crossfadeBlendsInSRGB() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("svart.png", width: 600, height: 400, rgb: (0, 0, 0), in: dir)
        try writePNG("vit.png", width: 600, height: 400, rgb: (255, 255, 255), in: dir)
        let spec = makeSpec(files: [("svart.png", 600, 400), ("vit.png", 600, 400)])
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: 270, height: 480))
        let p = pixel(renderer, renderer.renderFrame(at: 1.0, size: CGSize(width: 270, height: 480)), x: 100, y: 200)
        #expect(abs(p[0] - 128) <= 3, "värde \(p[0])")
    }

    @Test("contain-blur ritar hela bilden i mitten och suddig bakgrund runt om; fadeThroughBlack är svart i mitten")
    func containBlurAndFadeThroughBlack() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG("gron.png", width: 600, height: 400, rgb: (0, 200, 0), in: dir)
        try writePNG("rod.png", width: 600, height: 400, rgb: (255, 0, 0), in: dir)
        var spec = makeSpec(files: [("gron.png", 600, 400), ("rod.png", 600, 400)], fit: .containBlur)
        spec.style.defaultTransition = .init(type: .fadeThroughBlack, direction: nil, duration: 0.4)
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: 270, height: 480))
        let size = CGSize(width: 270, height: 480)
        let center = pixel(renderer, renderer.renderFrame(at: 0, size: size), x: 135, y: 240)
        #expect(center[1] > 190 && center[0] < 5)
        // Bakgrunden (överkant) är samma färg suddad, alltså också grön, och inte svart.
        let top = pixel(renderer, renderer.renderFrame(at: 0, size: size), x: 135, y: 5)
        #expect(top[1] > 150, "bakgrund \(top)")
        let mid = pixel(renderer, renderer.renderFrame(at: 1.0, size: size), x: 135, y: 240)
        #expect(mid[0] <= 2 && mid[1] <= 2 && mid[2] <= 2, "mitt \(mid)")
    }

    @Test("Bildladdningen skalas ned men aldrig över originalet")
    func requiredLongEdge() throws {
        let dir = try makeDirectory()
        let spec = makeSpec(files: [("a.png", 6000, 4000), ("b.png", 300, 200)])
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: 1080, height: 1920))
        let big = renderer.requiredLongEdge(for: spec.assets[0])
        #expect(big < 6000 && big >= 2880, "\(big)")   // 1920 / (4000-basutsnitt) ≈ 4 000 px lång sida
        #expect(renderer.requiredLongEdge(for: spec.assets[1]) == 300)
    }
}

/// Trådsäker behållare för progress från en `@Sendable`-callback.
private nonisolated final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
}
