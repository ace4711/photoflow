import Foundation
import Testing
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Tester för `ReelImageCache` (Regi R3): nyckel, uppslag av större bild, LRU-tak och att
/// förhandsvisningens upprepade `setSpec` inte laddar om bilderna. Mätningen skrivs ut med `print`.
struct ReelImageCacheTests {

    nonisolated private func makeImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Cache med en laddare som skapar en grå bild och räknar anrop per längsta sida.
    private func countingCache(maxBytes: Int = 100_000_000) -> (ReelImageCache, Counter) {
        let counter = Counter()
        let cache = ReelImageCache(maxBytes: maxBytes) { [self] _, edge in
            counter.add(edge)
            return makeImage(edge, edge * 2 / 3)
        }
        return (cache, counter)
    }

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var edges: [Int] = []
        nonisolated func add(_ e: Int) { lock.lock(); edges.append(e); lock.unlock() }
    }

    private let url = URL(fileURLWithPath: "/tmp/x.jpg")

    @Test("Samma bild och storlek laddas en gång; mindre eller lika begäran träffar cachen")
    func hits() {
        let (cache, counter) = countingCache()
        _ = cache.image(id: "a", url: url, minLongEdge: 1000, originalLongEdge: 6000)
        _ = cache.image(id: "a", url: url, minLongEdge: 1000, originalLongEdge: 6000)
        _ = cache.image(id: "a", url: url, minLongEdge: 640, originalLongEdge: 6000)
        #expect(cache.loadCount == 1)
        #expect(counter.edges == [1536])   // 1000 + 50 % marginal, avrundat uppåt till 256
        // Större behov laddar om en gång och ersätter den mindre.
        _ = cache.image(id: "a", url: url, minLongEdge: 2000, originalLongEdge: 6000)
        #expect(cache.loadCount == 2 && cache.stats.count == 1)
        // Annan bild = egen post. Aldrig över originalet.
        _ = cache.image(id: "b", url: url, minLongEdge: 5000, originalLongEdge: 800)
        #expect(counter.edges.last == 800)
        _ = cache.image(id: "b", url: url, minLongEdge: 5000, originalLongEdge: 800)
        #expect(cache.loadCount == 3)
    }

    @Test("Taket i byte kastar minst använda bilden först")
    func lruEviction() {
        let one = 1536 * (1536 * 2 / 3) * 4
        let (cache, _) = countingCache(maxBytes: one * 2 + one / 2)   // rymmer två
        for id in ["a", "b"] { _ = cache.image(id: id, url: url, minLongEdge: 1000, originalLongEdge: 6000) }
        _ = cache.image(id: "a", url: url, minLongEdge: 1000, originalLongEdge: 6000)   // a är nyast
        _ = cache.image(id: "c", url: url, minLongEdge: 1000, originalLongEdge: 6000)   // kastar b
        #expect(cache.stats.count == 2 && cache.stats.bytes <= cache.maxBytes)
        let before = cache.loadCount
        _ = cache.image(id: "a", url: url, minLongEdge: 1000, originalLongEdge: 6000)
        #expect(cache.loadCount == before)
        _ = cache.image(id: "b", url: url, minLongEdge: 1000, originalLongEdge: 6000)
        #expect(cache.loadCount == before + 1)
    }

    // MARK: - Förhandsvisning

    private func writePNG(_ name: String, width: Int, height: Int, shade: UInt8, in dir: URL) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(shade) / 255, green: 0.4, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Fem cover-klipp à 1 s utan övergång (5 s), 1080×1920.
    private func makeSpec(zoomEnd: Double = 1.1) -> ReelSpec {
        let assets = (1...5).map { i in
            ReelSpec.Asset(id: "a\(i)", sha256: "s\(i)", width: 3000, height: 2000,
                           sources: [.init(kind: .local, path: "b\(i).png")], analysis: nil)
        }
        let motion = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: zoomEnd))
        let clips = assets.map { ReelSpec.Clip(asset: $0.id, duration: 1, fit: .cover, motion: motion, transitionIn: nil) }
        return ReelSpec(
            schema: ReelSpec.schemaName, version: 1, minReaderVersion: 1, id: "t", revision: 1, status: "draft",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            updatedBy: .init(role: "agent", name: nil), property: .init(address: "T", sessionID: nil, kind: nil),
            assets: assets,
            style: .init(defaultTransition: .init(type: .cut, direction: nil, duration: 0), easing: .linear,
                         background: .init(type: "black", amount: nil)),
            timeline: clips, audio: nil, overlays: [],  brand: nil,
            outputs: [.init(id: "o", aspect: "9:16", width: 1080, height: 1920, fps: 30,
                            encoding: .init(codec: "h264", bitrateMbps: 2, audio: "aac-silent"))],
            provenance: .init(generator: "test", autoSelection: nil, edits: nil))
    }

    @Test("30 setSpec + renderFrame med 5 bilder laddar bilderna högst en gång per bild")
    func repeatedSetSpecDoesNotReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Källbilderna är 3000×2000 i specen men små på disk: det är laddningarna som räknas.
        for i in 1...5 { try writePNG("b\(i).png", width: 600, height: 400, shade: UInt8(40 * i), in: dir) }
        let size = CGSize(width: 360, height: 640)
        let output = CGSize(width: 1080, height: 1920)

        func run(shared: Bool) -> (seconds: Double, loads: Int) {
            let cache = ReelImageCache()
            let context = ReelRenderer.makeContext()
            var loads = 0
            let start = Date()
            for n in 0..<30 {
                // Som ReelPreviewModel.setSpec: ny renderare per ändring (zoomen dras något).
                let spec = makeSpec(zoomEnd: 1.05 + Double(n) * 0.001)
                let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: output,
                                            cache: shared ? cache : nil, context: shared ? context : nil)
                let t = Double(n % 5) + 0.5
                let image = renderer.renderFrame(at: t, size: size)
                #expect(renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: size)) != nil)
                if !shared { loads += renderer.cache.loadCount }
            }
            return (Date().timeIntervalSince(start), shared ? cache.loadCount : loads)
        }
        let without = run(shared: false)
        let with = run(shared: true)
        print("MÄTNING 30 setSpec + renderFrame, 5 bilder: utan delad cache \(String(format: "%.0f", without.seconds * 1000)) ms (\(without.loads) laddningar), med delad cache \(String(format: "%.0f", with.seconds * 1000)) ms (\(with.loads) laddningar)")
        #expect(with.loads == 5)
        #expect(without.loads == 30)
    }

    @Test("ReelPreviewModel.setSpec laddar inte om bilden vid ändrad rörelse")
    func previewModelSharesCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...5 { try writePNG("b\(i).png", width: 600, height: 400, shade: UInt8(40 * i), in: dir) }
        let cache = ReelImageCache()
        let preview = ReelPreviewModel(cache: cache)
        for n in 0..<8 {
            let before = preview.frame
            preview.setSpec(makeSpec(zoomEnd: 1.05 + Double(n) * 0.01), specDirectory: dir)
            for _ in 0..<200 where preview.frame === before {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(preview.frame != nil)
        }
        // Tiden är 0: bara första klippets bild behövs, och den laddades en gång.
        #expect(cache.loadCount == 1)
        preview.stop()
    }
}
