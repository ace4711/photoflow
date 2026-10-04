import Foundation
import Testing
@testable import PhotoFlow

/// Kedjningen HDR → Förbättra: en omsammanslagning i granskningen förbättrar gruppen direkt
/// (där den förbättrade filen redan ligger), och steget "Förbättra bilder" gör om en
/// förbättring som är äldre än HDR-filen (`hdr.json`s `mergedAt`).
@MainActor
@Suite(.serialized)
struct HDRReEnhanceTests {

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HDRReEnhanceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// En liten syntetisk HDR (gradient) som riktig TIFF + JPEG i `hdr/`.
    private func writeHDR(groupId: Int, in outputDir: URL) throws {
        let w = 96, h = 64
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                pixels[p] = 0.2 + 0.5 * Float(x) / Float(w)
                pixels[p + 1] = 0.25 + 0.4 * Float(y) / Float(h)
                pixels[p + 2] = 0.3
            }
        }
        let dir = outputDir.appendingPathComponent("hdr")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try HDRWriter.write(pixels: pixels, width: w, height: h,
                            tiffURL: dir.appendingPathComponent("hdr_group_\(groupId).tiff"),
                            jpegURL: dir.appendingPathComponent("hdr_group_\(groupId).jpg"))
    }

    private func makeState(outputDir: URL) -> PipelineState {
        let state = PipelineState()
        state.outputDirectory = outputDir
        let photo = PhotoItem(id: "DSC_0001", filename: "DSC_0001.NEF", nefURL: URL(fileURLWithPath: "/tmp/DSC_0001.NEF"),
                              dngURL: nil, previewURL: nil, exposureTime: "1/125", exposureSeconds: 1.0 / 125,
                              fNumber: 8, iso: 100, dateTime: Date())
        state.allPhotos = [photo]
        state.bracketGroups = [BracketGroup(id: 1, isBracket: true, folderName: "bracket_001", photoIDs: [photo.id], fNumber: 8,
                                            iso: 100, timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 3)]
        return state
    }

    private func withEnhanceEnabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let was = AppSettings.shared.enhanceEnabled
        AppSettings.shared.enhanceEnabled = true
        defer { AppSettings.shared.enhanceEnabled = was }
        return try await body()
    }

    @Test("Förbättringen är inaktuell när HDR:en skrevs om efter den")
    func staleRule() {
        let t = Date()
        #expect(PipelineRunner.enhancementIsStale(enhancedAt: t, hdrMergedAt: t.addingTimeInterval(5)))
        #expect(!PipelineRunner.enhancementIsStale(enhancedAt: t, hdrMergedAt: t.addingTimeInterval(-5)))
        #expect(!PipelineRunner.enhancementIsStale(enhancedAt: t, hdrMergedAt: nil))
    }

    @Test("Efter omsammanslagning förbättras gruppen igen där den förbättrade filen redan ligger")
    func reEnhance_rewritesDeliveredFile() async throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        try writeHDR(groupId: 1, in: outputDir)
        // Den förra förbättringen ligger redan sorterad i FÖRBÄTTRADE.
        let delivered = AddressFolderLayout.enhancedDir(in: outputDir, folderName: "Storgatan 1")
        try FileManager.default.createDirectory(at: delivered, withIntermediateDirectories: true)
        for name in ["hdr_group_1_enh.tiff", "hdr_group_1_enh.jpg"] {
            try Data("gammal".utf8).write(to: delivered.appendingPathComponent(name))
        }
        let state = makeState(outputDir: outputDir)
        let runner = PipelineRunner(state: state)

        let rewritten = await withEnhanceEnabled { await runner.reEnhanceHDRGroup(1) }

        #expect(rewritten.map(\.lastPathComponent).sorted() == ["hdr_group_1_enh.jpg", "hdr_group_1_enh.tiff"])
        #expect(rewritten.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "Storgatan 1 FÖRBÄTTRADE" })
        let tiffData = try Data(contentsOf: delivered.appendingPathComponent("hdr_group_1_enh.tiff"))
        #expect(tiffData.count > 1000) // en riktig bild, inte den gamla platshållaren
        #expect(state.bracketGroups[0].enhancedPreviewURL?.lastPathComponent == "hdr_group_1_enh.jpg")
        #expect(EnhancementLog.load(from: outputDir)?.entries["hdr_group_1"] != nil)
        // Inget skrevs i enhanced/ (den levererade filen byttes ut).
        #expect(!FileManager.default.fileExists(atPath: AddressFolderLayout.enhancedStagingDir(in: outputDir)
            .appendingPathComponent("hdr_group_1_enh.tiff").path))
    }

    @Test("Utan tidigare förbättring görs ingen förbättring vid omsammanslagning (steget tar den)")
    func reEnhance_skipsWhenNeverEnhanced() async throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        try writeHDR(groupId: 1, in: outputDir)
        let state = makeState(outputDir: outputDir)
        let runner = PipelineRunner(state: state)
        let rewritten = await withEnhanceEnabled { await runner.reEnhanceHDRGroup(1) }
        #expect(rewritten.isEmpty)
        #expect(state.bracketGroups[0].enhancedPreviewURL == nil)
    }

    @Test("Steget Förbättra gör om en HDR-grupp vars HDR skrevs om efter förbättringen")
    func enhanceStep_redoesWhenHDRIsNewer() async throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        try writeHDR(groupId: 1, in: outputDir)
        let state = makeState(outputDir: outputDir)
        let runner = PipelineRunner(state: state)

        _ = try await withEnhanceEnabled { try await runner.runEnhancePhotos() }
        let first = try #require(EnhancementLog.load(from: outputDir)?.entries["hdr_group_1"])

        // Oförändrat: hoppas över.
        _ = try await withEnhanceEnabled { try await runner.runEnhancePhotos() }
        #expect(EnhancementLog.load(from: outputDir)?.entries["hdr_group_1"]?.date == first.date)

        // HDR:en görs om (t.ex. ny motorversion) efter förbättringen → förbättras igen.
        var hdrLog = HDRLog()
        hdrLog.entries["hdr_group_1"] = HDRLog.Entry(engineVersion: HDREngine.version, fingerprint: "x",
                                                     mergedAt: first.date.addingTimeInterval(1))
        hdrLog.save(to: outputDir)
        // Platshållare: syns det en riktig bild efteråt så gjordes förbättringen om.
        let enhancedTIFF = AddressFolderLayout.enhancedStagingDir(in: outputDir).appendingPathComponent("hdr_group_1_enh.tiff")
        try Data("x".utf8).write(to: enhancedTIFF)
        _ = try await withEnhanceEnabled { try await runner.runEnhancePhotos() }
        #expect(try Data(contentsOf: enhancedTIFF).count > 1000)
    }
}
