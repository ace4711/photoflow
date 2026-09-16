import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `PipelineRunner.cullCandidates` (Slutgranskning, se
/// FORBATTRINGAR.md): the shared basename-matching + ownership guard used by
/// `deleteRejectedFiles` and `moveRejectedToFolder` before they ever remove or
/// move a file. Builds a real temp directory with the exact "traps" called
/// out in the review brief:
///   - a file whose basename is a numeric extension of the target
///     ("DSC_00011" must never match "DSC_0001")
///   - a file with the same basename but a foreign extension the app never
///     creates, placed by hand
///   - an unrelated sibling folder outside outputDir
@MainActor
struct PipelineRunnerCullSafetyTests {

    private func makeTrapDirectory() throws -> (outputDir: URL, addressDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineRunnerCullSafetyTests-\(UUID().uuidString)")
        let outputDir = root.appendingPathComponent("output")
        let addressDir = outputDir.appendingPathComponent("Testvägen 1 ÖVRIGA")
        try FileManager.default.createDirectory(at: addressDir, withIntermediateDirectories: true)

        // Real NEF sits OUTSIDE outputDir, like a real card/input folder would.
        let originalsDir = root.appendingPathComponent("input-not-outputdir")
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        let originalNEF = originalsDir.appendingPathComponent("DSC_0001.NEF")
        FileManager.default.createFile(atPath: originalNEF.path, contents: Data("nef".utf8))

        // The photo we're rejecting: a symlink to the original, exactly what
        // exportToAddressFolders creates.
        try FileManager.default.createSymbolicLink(
            at: addressDir.appendingPathComponent("DSC_0001.NEF"),
            withDestinationURL: originalNEF)

        // Trap 1: a DIFFERENT photo whose basename merely starts with the same
        // digits ("DSC_00011" vs "DSC_0001") — must never be treated as a match.
        let otherOriginal = originalsDir.appendingPathComponent("DSC_00011.NEF")
        FileManager.default.createFile(atPath: otherOriginal.path, contents: Data("nef2".utf8))
        try FileManager.default.createSymbolicLink(
            at: addressDir.appendingPathComponent("DSC_00011.NEF"),
            withDestinationURL: otherOriginal)

        // Trap 2: a real (non-symlink) file with the SAME basename but a
        // foreign extension the app never creates — e.g. a PSD the user
        // dropped into the ÖVRIGA folder by hand.
        FileManager.default.createFile(
            atPath: addressDir.appendingPathComponent("DSC_0001.psd").path,
            contents: Data("psd".utf8))

        // The app's own XMP sidecar for the rejected photo — SHOULD match.
        FileManager.default.createFile(
            atPath: addressDir.appendingPathComponent("DSC_0001.xmp").path,
            contents: Data("<x/>".utf8))

        // Trap 3: an unrelated sibling folder outside outputDir, in case a
        // future bug ever pointed `dir` there.
        let foreignDir = root.appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreignDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: foreignDir.appendingPathComponent("DSC_0001.dng").path,
            contents: Data("dng".utf8))

        return (outputDir, addressDir)
    }

    @Test("Bara den rätta symlänken och dess .xmp-sidecar matchar — inte DSC_00011, inte en främmande .psd")
    func cullCandidates_matchesOnlyExactBasenameAndOwnedFiles() throws {
        let (outputDir, addressDir) = try makeTrapDirectory()

        let candidates = PipelineRunner.cullCandidates(in: addressDir, photoBase: "DSC_0001", outputDir: outputDir)
        let names = Set(candidates.map(\.lastPathComponent))

        #expect(names == ["DSC_0001.NEF", "DSC_0001.xmp"])
        #expect(!names.contains("DSC_00011.NEF"))
        #expect(!names.contains("DSC_0001.psd"))
    }

    @Test("En mapp utanför outputDir ger aldrig kandidater, även om den råkar innehålla en matchande fil")
    func cullCandidates_refusesDirectoryOutsideOutputDir() throws {
        let (outputDir, _) = try makeTrapDirectory()
        let foreignDir = outputDir.deletingLastPathComponent().appendingPathComponent("input-not-outputdir")

        let candidates = PipelineRunner.cullCandidates(in: foreignDir, photoBase: "DSC_0001", outputDir: outputDir)
        #expect(candidates.isEmpty)
    }

    @Test("Tom/obefintlig mapp ger tom lista, kraschar inte")
    func cullCandidates_missingDirectory_returnsEmpty() {
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerCullSafetyTests-missing-\(UUID().uuidString)")
        let missing = outputDir.appendingPathComponent("does-not-exist")
        #expect(PipelineRunner.cullCandidates(in: missing, photoBase: "DSC_0001", outputDir: outputDir).isEmpty)
    }
}
