import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Tester för `ReelImageAnalyzer`. Foundation Models används aldrig (`describe: false`).
struct ReelImageAnalyzerTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelImageAnalyzerTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ljust motiv på mörk bakgrund, till höger i bilden.
    private func writeTestImage(to url: URL) throws {
        let w = 800, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.4, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 520, y: 200, width: 200, height: 200))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("Ljust motiv på mörk bakgrund ger saliency kring motivet, luminans och storlek")
    func saliencyAroundSubject() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("motiv.jpg")
        try writeTestImage(to: file)

        let items = try await ReelImageAnalyzer.analyze(urls: [file], cacheDirectory: nil, describe: false)
        let a = try #require(items.first?.analysis)
        #expect(a.width == 800 && a.height == 600)
        #expect(a.sha256.count == 64)
        #expect(!a.saliencyBoxes.isEmpty)
        let focus = try #require(a.focus)
        #expect(focus.x > 0.5, "fokus.x = \(focus.x)")
        let sw = try #require(a.salientWidth)
        #expect(sw > 0 && sw < 0.8, "salientWidth = \(sw)")
        let lum = try #require(a.meanLuminance)
        #expect(lum < 0.3)
        #expect(a.featureVector?.isEmpty == false)
        #expect(a.room == nil)
    }

    @Test("Cache: andra körningen återanvänder allt och skriver filen atomiskt")
    func cacheReused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("motiv.jpg")
        try writeTestImage(to: file)
        let cacheDir = dir.appendingPathComponent("FILM")

        let first = try await ReelImageAnalyzer.analyze(urls: [file], cacheDirectory: cacheDir, describe: false)
        var cache = ReelImageAnalyzer.loadCache(from: cacheDir)
        #expect(cache.count == 1)
        #expect(cache[first[0].analysis.sha256] == first[0].analysis)

        // Manipulera cachen: om andra körningen analyserade om skulle värdet skrivas över.
        let sha = first[0].analysis.sha256
        cache[sha]?.qualityScore = 0.123
        ReelImageAnalyzer.saveCache(cache, to: cacheDir)
        let second = try await ReelImageAnalyzer.analyze(urls: [file], cacheDirectory: cacheDir, describe: false)
        #expect(second[0].analysis.qualityScore == 0.123)

        // Omdöpt fil med samma innehåll hittar samma post.
        let renamed = dir.appendingPathComponent("annat-namn.jpg")
        try FileManager.default.copyItem(at: file, to: renamed)
        let third = try await ReelImageAnalyzer.analyze(urls: [renamed], cacheDirectory: cacheDir, describe: false)
        #expect(third[0].analysis.qualityScore == 0.123)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("reel_analysis.json.tmp").path))
    }

    @Test("Filer som inte är bilder utelämnas")
    func nonImagesSkipped() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("anteckning.jpg")
        try Data("inte en bild".utf8).write(to: text)
        let items = try await ReelImageAnalyzer.analyze(urls: [text], cacheDirectory: nil, describe: false)
        #expect(items.isEmpty)
    }

    @Test("Cachen bevarar EXIF-datum (heltalssekunder) vid skrivning och läsning")
    func cacheKeepsExifDate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let a = ReelImageAnalysis(sha256: "ab", width: 10, height: 10, qualityScore: 0.5, isUtility: false,
                                  horizonAngleDegrees: nil, sharpness: 1, featurePrint: Data([1, 2, 3, 4]),
                                  saliencyBoxes: [], focus: nil, salientWidth: nil, meanLuminance: 0.5,
                                  exifDate: date, room: "Kök", category: "Interiör", features: ["x"], caption: nil)
        ReelImageAnalyzer.saveCache(["ab": a], to: dir)
        #expect(ReelImageAnalyzer.loadCache(from: dir)["ab"] == a)
    }

    @Test("Cache med fel version ignoreras")
    func wrongVersionIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"version":999,"analyses":{}}"#.utf8).write(to: dir.appendingPathComponent("reel_analysis.json"))
        #expect(ReelImageAnalyzer.loadCache(from: dir).isEmpty)
    }

    @Test("Motivbredd är unionen av boxarnas x-intervall, fokus areaviktad")
    func salientWidthAndFocus() {
        typealias B = ReelImageAnalysis.Box
        let boxes = [B(x: 0.1, y: 0.1, width: 0.3, height: 0.3), B(x: 0.3, y: 0.1, width: 0.3, height: 0.3),
                     B(x: 0.8, y: 0.5, width: 0.1, height: 0.1)]
        #expect(abs(ReelImageAnalyzer.salientWidth(of: boxes)! - 0.6) < 1e-9)
        #expect(ReelImageAnalyzer.salientWidth(of: []) == nil)
        let f = ReelImageAnalyzer.focus(of: [B(x: 0.2, y: 0.2, width: 0.2, height: 0.2)])!
        #expect(abs(f.x - 0.3) < 1e-9 && abs(f.y - 0.3) < 1e-9)
    }

    @Test("ai_tags-reserv matchar preview-namnet men inte en annan bild")
    func aiTagsFallbackMatching() {
        let tags: [String: AITagsStore.Entry] = [
            "DSC_1234": .init(tags: [], description: "a", category: "Interiör", mlRoom: "Kök"),
            "DSC_123": .init(tags: [], description: "b", category: "Interiör", mlRoom: "Hall"),
        ]
        #expect(ReelImageAnalyzer.fallbackEntry(forFilename: "DSC_1234-HDR.jpg", in: tags)?.mlRoom == "Kök")
        #expect(ReelImageAnalyzer.fallbackEntry(forFilename: "DSC_1234.jpg", in: tags)?.mlRoom == "Kök")
        #expect(ReelImageAnalyzer.fallbackEntry(forFilename: "DSC_123_x.jpg", in: tags)?.mlRoom == "Hall")
        #expect(ReelImageAnalyzer.fallbackEntry(forFilename: "DSC_12.jpg", in: tags) == nil)
        #expect(ReelImageAnalyzer.fallbackEntry(forFilename: "hdr_group_1.jpg", in: tags) == nil)
    }

    @Test("EXIF-datum tolkas")
    func exifDate() {
        let d = ReelImageAnalyzer.parseExifDate("2026:10:03 19:45:10")!
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
        #expect(c.year == 2026 && c.month == 10 && c.day == 3 && c.hour == 19)
        #expect(ReelImageAnalyzer.parseExifDate("skräp") == nil)
    }
}
