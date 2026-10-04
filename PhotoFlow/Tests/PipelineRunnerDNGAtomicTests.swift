import Foundation
import Testing
@testable import PhotoFlow

/// Fas 1a (#7): DNG-konverteraren skriver till `dng/.partial/`, och bara färdiga filer
/// direkt i `dng/` räknas av hoppa-över-logiken.
@MainActor
struct PipelineRunnerDNGAtomicTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerDNGAtomicTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, _ content: String = "x") {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("En halvfärdig DNG i .partial räknas inte som klar")
    func partialFile_isNotCounted() {
        let dng = tempDir()
        touch(dng.appendingPathComponent("DSC_0001.dng"))
        touch(dng.appendingPathComponent(".partial/DSC_0002.dng"))

        #expect(PipelineRunner.completedDNGNames(in: dng) == ["dsc_0001"])
    }

    @Test("Symlänkar och andra filtyper i dng/ räknas inte")
    func symlinksAndOtherFiles_areNotCounted() throws {
        let dng = tempDir()
        let real = tempDir().appendingPathComponent("DSC_0009.dng")
        touch(real)
        try FileManager.default.createSymbolicLink(at: dng.appendingPathComponent("DSC_0009.dng"), withDestinationURL: real)
        touch(dng.appendingPathComponent("DSC_0003.dng"))
        touch(dng.appendingPathComponent("notes.txt"))

        #expect(PipelineRunner.completedDNGNames(in: dng) == ["dsc_0003"])
    }

    @Test("promotePartialDNGs flyttar färdiga filer till dng/ och tömmer .partial")
    func promote_movesFiles() throws {
        let dng = tempDir()
        let partial = dng.appendingPathComponent(PipelineRunner.dngPartialDirName)
        touch(partial.appendingPathComponent("DSC_0002.dng"), "ny")
        touch(partial.appendingPathComponent("DSC_0004.dng"), "ny")
        touch(dng.appendingPathComponent("DSC_0002.dng"), "gammal")

        let moved = try PipelineRunner.promotePartialDNGs(from: partial, to: dng)

        #expect(moved.count == 2)
        #expect(PipelineRunner.completedDNGNames(in: dng) == ["dsc_0002", "dsc_0004"])
        #expect(try String(contentsOf: dng.appendingPathComponent("DSC_0002.dng"), encoding: .utf8) == "ny")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: partial.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test("cleanDNGPartial tar bort rester men rör färdiga filer")
    func clean_removesPartialOnly() {
        let dng = tempDir()
        touch(dng.appendingPathComponent("DSC_0001.dng"))
        touch(dng.appendingPathComponent(".partial/DSC_0002.dng"))

        PipelineRunner.cleanDNGPartial(in: dng)

        #expect(!FileManager.default.fileExists(atPath: dng.appendingPathComponent(".partial").path))
        #expect(PipelineRunner.completedDNGNames(in: dng) == ["dsc_0001"])
    }
}
