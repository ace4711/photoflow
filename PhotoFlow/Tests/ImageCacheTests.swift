import Foundation
import AppKit
import Testing
@testable import PhotoFlow

/// Tests for `ImageCache` (Fas 5) — the two-tier NSCache wrapper that backs
/// `LocalImageView`/`LocalThumbnailView`/`ProgressiveImageView`. Uses tiny
/// real JPEGs on disk (ImageIO needs a real, decodable file) rather than
/// mocking `ImageLoader`, since `ImageLoader` is a pure/stateless enum with
/// no injection point — same approach as `RAWRendererTests` for the parts
/// that need real image data.
@MainActor
struct ImageCacheTests {

    /// Writes a tiny (4x4) solid-color JPEG to a temp file and returns its URL.
    private func makeTestImage() -> URL {
        let size = 4
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = rep.representation(using: .jpeg, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheTests-\(UUID().uuidString).jpg")
        try! data.write(to: url)
        return url
    }

    @Test("store/image roundtrip per nivå, nivåerna delar inte cache")
    func storeAndRetrieve_perTier() {
        ImageCache.shared.clear()
        let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist-for-store.jpg")
        let image = NSImage(size: NSSize(width: 10, height: 10))

        #expect(ImageCache.shared.image(for: url, tier: .thumbnail) == nil)
        #expect(ImageCache.shared.image(for: url, tier: .fullSize) == nil)

        ImageCache.shared.store(image, for: url, tier: .thumbnail)
        #expect(ImageCache.shared.image(for: url, tier: .thumbnail) != nil)
        // Samma URL i den andra nivån ska fortfarande vara tom — nivåerna är
        // separata cachar, inte en delad nyckelrymd.
        #expect(ImageCache.shared.image(for: url, tier: .fullSize) == nil)

        ImageCache.shared.clear()
    }

    @Test("clear() tömmer båda nivåerna")
    func clear_emptiesBothTiers() {
        let url = URL(fileURLWithPath: "/tmp/clear-test.jpg")
        let image = NSImage(size: NSSize(width: 5, height: 5))
        ImageCache.shared.store(image, for: url, tier: .thumbnail)
        ImageCache.shared.store(image, for: url, tier: .fullSize)

        ImageCache.shared.clear()

        #expect(ImageCache.shared.image(for: url, tier: .thumbnail) == nil)
        #expect(ImageCache.shared.image(for: url, tier: .fullSize) == nil)
    }

    @Test("prefetch laddar en riktig fil i bakgrunden och lägger den i rätt nivå")
    func prefetch_populatesCache() async {
        ImageCache.shared.clear()
        let url = makeTestImage()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ImageCache.shared.image(for: url, tier: .thumbnail) == nil)

        ImageCache.shared.prefetch(url: url, tier: .thumbnail, maxDimension: 200)

        // Förhämtningen körs i en detached bakgrundsuppgift — vänta in den
        // (pollning i stället för ett fast `sleep` för att inte vara flaky
        // under belastning).
        var attempts = 0
        while ImageCache.shared.image(for: url, tier: .thumbnail) == nil && attempts < 100 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        #expect(ImageCache.shared.image(for: url, tier: .thumbnail) != nil)
        ImageCache.shared.clear()
    }

    @Test("prefetch av en fil som inte finns kraschar inte och lämnar cachen tom")
    func prefetch_missingFile_doesNothing() async {
        ImageCache.shared.clear()
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jpg")

        ImageCache.shared.prefetch(url: url, tier: .fullSize, maxDimension: 2400)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(ImageCache.shared.image(for: url, tier: .fullSize) == nil)
    }

    @Test("prefetch(url: nil) är en no-op")
    func prefetch_nilURL_isNoOp() async {
        ImageCache.shared.prefetch(url: nil, tier: .thumbnail, maxDimension: 200)
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Inget att verifiera utöver att det inte kraschar/hänger.
    }
}
