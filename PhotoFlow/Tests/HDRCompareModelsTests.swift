import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PhotoFlow

/// Manifest, betyg, blindläge, sammanfattning och mått-cache för HDR-jämförelsen.
struct HDRCompareModelsTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdrcompare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func writePNG(_ f: (Int, Int) -> Float, to url: URL, width: Int = 320, height: Int = 240) throws {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(min(max(f(x, y), 0), 1) * 255)
                let o = (y * width + x) * 4
                px[o] = v; px[o + 1] = v; px[o + 2] = v
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    func scene(_ x: Int, _ y: Int) -> Float {
        let fx = Float(x), fy = Float(y)
        var v: Float = 0.45 + 0.15 * sinf(fx * 0.05) * cosf(fy * 0.04) + 0.08 * sinf(fx * 0.21 + fy * 0.13)
        if ((x / 24) + (y / 20)) % 3 == 0 { v += 0.12 }
        return v
    }

    // MARK: - Manifest

    @Test func manifestLasesOchTolerarObjektOchNullVarianter() throws {
        let json = """
        { "version": 1, "created": "2026-10-18", "extra": 1, "groups": [
          { "id": "chronas-01", "source": "Chronas väg 7", "groupId": 1, "category": "interior-window",
            "frames": [{"file": "nef/a.NEF", "exposureSeconds": 0.1}, {"file": "nef/b.NEF"}],
            "photographerReference": "ref/a.jpg",
            "variants": { "pf-radiance": "out/pf.tiff", "lr-auto": {"path": "out/lr.tiff"}, "lr-dng": null } },
          { "id": "x", "frames": [], "variants": {} } ] }
        """
        let m = try JSONDecoder().decode(HDRCompareManifest.self, from: Data(json.utf8))
        #expect(m.groups.count == 2)
        let g = m.groups[0]
        #expect(g.variants == ["pf-radiance": "out/pf.tiff", "lr-auto": "out/lr.tiff"])
        #expect(g.frames[1].exposureSeconds == nil)
        #expect(g.allImages["ref"] == "ref/a.jpg")
        #expect(g.orderedVariantIDs == ["pf-radiance", "lr-auto", "ref"])
    }

    @Test func standardparetFallerTillbakaNarLRSaknas() {
        var g = HDRCompareManifest.Group(id: "g", variants: ["pf-radiance": "a", "lr-auto": "b", "pf-fusion": "c"])
        #expect(g.defaultPair()?.a == "pf-radiance" && g.defaultPair()?.b == "lr-auto")
        g.variants["lr-auto"] = nil
        g.photographerReference = "r.jpg"
        #expect(g.defaultPair()?.b == "ref")
        g.photographerReference = nil
        #expect(g.defaultPair()?.b == "pf-fusion")
        g.variants = ["pf-radiance": "a"]
        #expect(g.defaultPair() == nil)
        g.variants = ["lr-auto": "x", "pf-fusion": "y"]
        #expect(g.defaultPair()?.a == "lr-auto" || g.defaultPair()?.a == "pf-fusion")
        // Tillgänglighet filtrerar bort varianter vars fil saknas.
        g.variants = ["pf-radiance": "a", "lr-auto": "b", "pf-fusion": "c"]
        #expect(g.defaultPair(available: ["pf-radiance", "pf-fusion"])?.b == "pf-fusion")
    }

    // MARK: - Blindläge

    @Test func blindordningenArStabilOchBlandad() {
        let ids = (1...40).map { "grupp-\($0)" }
        let a = ids.map { HDRCompareBlind.isSwapped(seed: 42, groupId: $0) }
        let b = ids.map { HDRCompareBlind.isSwapped(seed: 42, groupId: $0) }
        #expect(a == b)
        let swapped = a.filter { $0 }.count
        #expect(swapped > 8 && swapped < 32, "\(swapped) av 40 bytte plats")
        let other = ids.map { HDRCompareBlind.isSwapped(seed: 7, groupId: $0) }
        #expect(other != a)
    }

    // MARK: - Betyg

    func verdict(_ gid: String, _ l: String, _ r: String, _ c: HDRCompareChoice, aspects: [String] = []) -> HDRCompareVerdict {
        HDRCompareVerdict(groupId: gid, left: l, right: r, blind: true, seed: 1, verdict: c, aspects: aspects, note: "", ratedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func betygSparasAtomisktOchLasesTillbaka() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = dir.appendingPathComponent("manifest.json")
        var file = HDRCompareVerdictStore.load(forManifest: manifest)
        #expect(file.verdicts.isEmpty && file.blindSeed != 0)
        file.upsert(verdict("a", "pf-radiance", "lr-auto", .left, aspects: ["window"]))
        file.upsert(verdict("a", "lr-auto", "pf-radiance", .tie))  // samma par, andra ordning: ersätter
        file.upsert(verdict("b", "pf-radiance", "lr-auto", .right))
        try HDRCompareVerdictStore.save(file, forManifest: manifest)
        let back = HDRCompareVerdictStore.load(forManifest: manifest)
        #expect(back == file)
        #expect(back.verdicts.count == 2)
        #expect(back.verdict(groupId: "a", pair: ["pf-radiance", "lr-auto"])?.verdict == .tie)
        #expect(back.verdict(groupId: "b", pair: ["pf-radiance", "lr-auto"])?.winner == "lr-auto")
        // Inga kvarglömda temporärfiler.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "verdicts.json" }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Sammanfattning

    @Test func sammanfattningRaknarVinstLikaForlustPerKategoriOchAspekt() {
        let manifest = HDRCompareManifest(version: 1, created: nil, groups: [
            .init(id: "a", category: "interior-window"), .init(id: "b", category: "interior-window"),
            .init(id: "c", category: "exterior"), .init(id: "d", category: "exterior"),
        ])
        let verdicts = [
            verdict("a", "pf-radiance", "lr-auto", .left),                                   // vinst
            verdict("b", "lr-auto", "pf-radiance", .left, aspects: ["window", "color"]),     // förlust
            verdict("c", "pf-radiance", "lr-auto", .tie),                                    // lika
            verdict("d", "pf-radiance", "lr-auto", .right, aspects: ["window"]),             // förlust
            verdict("d", "pf-fusion", "lr-auto", .left),                                     // rör inte subject
            verdict("zzz", "pf-radiance", "lr-auto", .left),                                 // okänd grupp
        ]
        let r = HDRCompareSummary.compute(manifest: manifest, verdicts: verdicts, metrics: nil)
        #expect(r.total == .init(wins: 1, ties: 1, losses: 2))
        #expect(r.ratedGroups == 4 && r.totalGroups == 4)
        #expect(r.byOpponent["lr-auto"] == .init(wins: 1, ties: 1, losses: 2))
        #expect(r.byCategory.first { $0.category == "interior-window" }?.tally == .init(wins: 1, ties: 0, losses: 1))
        #expect(r.byCategory.first { $0.category == "exterior" }?.tally == .init(wins: 0, ties: 1, losses: 1))
        #expect(r.aspectsWhenLosing.first?.aspect == "window" && r.aspectsWhenLosing.first?.count == 2)
        let md = HDRCompareSummary.markdown(r)
        #expect(md.contains("1 vinster, 1 lika, 2 förluster"))
        #expect(md.contains("Interiör med fönster"))
        #expect(md.contains("Fönster: 2"))
    }

    // MARK: - Mått-cache

    @Test func runnerFyllerMetricsJsonOchAnvanderCachen() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        try writePNG({ scene($0, $1) }, to: dir.appendingPathComponent("out/pf.png"))
        try writePNG({ scene($0 - 4, $1 - 2) * 0.9 }, to: dir.appendingPathComponent("out/lr.png"))
        let manifest = HDRCompareManifest(version: 1, created: nil, groups: [
            .init(id: "g1", category: "interior", variants: ["pf-radiance": "out/pf.png", "lr-auto": "out/lr.png", "pf-fusion": "out/saknas.png"]),
        ])
        let url = dir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: url)

        let file = await HDRCompareRunner.compute(manifest: manifest, manifestURL: url)
        let g = try #require(file.groups["g1"])
        #expect(Set(g.keys) == ["pf-radiance", "lr-auto"])
        let pf = try #require(g["pf-radiance"])
        #expect(pf.metrics.tone.medianLuma > 0.3)
        #expect(pf.vsLR != nil, "ΔE saknas, registrering \(String(describing: pf.metrics.registration))")
        #expect(g["lr-auto"]?.vsLR == nil)

        let cached = try #require(HDRCompareMetricsFile.load(forManifest: url))
        #expect(cached == file)

        // Cachen används när inget ändrats: ändrad fil på disk ändrar inte resultatet förrän signaturen byts.
        let marker = HDRCompareMetricsFile.VariantResult(metrics: pf.metrics, vsLR: nil, vsRef: nil)
        var tampered = cached
        tampered.groups["g1"]?["pf-radiance"] = marker
        try tampered.save(forManifest: url)
        let again = await HDRCompareRunner.compute(manifest: manifest, manifestURL: url)
        #expect(again.groups["g1"]?["pf-radiance"]?.vsLR == nil)
        let forced = await HDRCompareRunner.compute(manifest: manifest, manifestURL: url, force: true)
        #expect(forced.groups["g1"]?["pf-radiance"]?.vsLR != nil)

        // Sammanfattningen tar emot måtten.
        let summary = HDRCompareSummary.compute(manifest: manifest, verdicts: [], metrics: forced)
        #expect(summary.metrics.map(\.variant) == ["pf-radiance", "lr-auto"])
    }
}
