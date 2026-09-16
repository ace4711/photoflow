import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `FileSafety` (Slutgranskning, se FORBATTRINGAR.md): the central
/// guard used by every destructive filesystem call (`deleteRejectedFiles`,
/// `moveRejectedToFolder`, `resortAddressFolder`) to make sure it can never
/// touch anything outside the app's own output directory, and the
/// "which files are ours to touch" predicate used by the culling steps.
struct FileSafetyTests {

    private func tempDir(_ name: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSafetyTests-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - assertInsideOutput

    @Test("Godkänner outputDir självt och riktiga undermappar/filer")
    func assertInsideOutput_acceptsOutputDirAndDescendants() throws {
        let output = tempDir()
        try FileSafety.assertInsideOutput(output, outputDir: output)
        try FileSafety.assertInsideOutput(output.appendingPathComponent("Adressen ÖVRIGA"), outputDir: output)
        try FileSafety.assertInsideOutput(output.appendingPathComponent("a/b/c.dng"), outputDir: output)
    }

    @Test("Kastar för en helt orelaterad mapp")
    func assertInsideOutput_rejectsUnrelatedDirectory() {
        let output = tempDir()
        let outsider = FileManager.default.temporaryDirectory.appendingPathComponent("nagon-annanstans")
        #expect(throws: FileSafety.UnsafePathError.self) {
            try FileSafety.assertInsideOutput(outsider, outputDir: output)
        }
    }

    @Test("Kastar för outputDirs förälder via \"..\" (path traversal)")
    func assertInsideOutput_rejectsDotDotEscape() {
        let output = tempDir()
        let escaped = output.appendingPathComponent("..")
        #expect(throws: FileSafety.UnsafePathError.self) {
            try FileSafety.assertInsideOutput(escaped, outputDir: output)
        }
    }

    @Test("En syskonmapp med gemensamt prefix ska INTE räknas som \"inuti\" (ingen bar prefix-jämförelse)")
    func assertInsideOutput_rejectsSiblingWithSharedPrefix_notJustStringPrefix() {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow-out")
        let sibling = FileManager.default.temporaryDirectory.appendingPathComponent("photoflow-out-EVIL")
        #expect(throws: FileSafety.UnsafePathError.self) {
            try FileSafety.assertInsideOutput(sibling, outputDir: output)
        }
    }

    // MARK: - isSymlink / isCullManaged

    @Test("Symlänk känns igen som symlänk, vanlig fil gör det inte")
    func isSymlink_distinguishesLinkFromRegularFile() throws {
        let dir = tempDir()
        let target = dir.appendingPathComponent("original.NEF")
        FileManager.default.createFile(atPath: target.path, contents: Data("x".utf8))
        let link = dir.appendingPathComponent("DSC_0001.NEF")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let regular = dir.appendingPathComponent("DSC_0002.dng")
        FileManager.default.createFile(atPath: regular.path, contents: Data("y".utf8))

        #expect(FileSafety.isSymlink(link))
        #expect(!FileSafety.isSymlink(regular))
    }

    @Test("isCullManaged: symlänkar och .xmp-sidecars är \"våra\", en främmande fil med samma basnamn är det inte")
    func isCullManaged_symlinksAndXMPAreManaged_foreignRealFileIsNot() throws {
        let dir = tempDir()
        let target = dir.appendingPathComponent("original.NEF")
        FileManager.default.createFile(atPath: target.path, contents: Data("x".utf8))
        let link = dir.appendingPathComponent("DSC_0001.NEF")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let sidecar = dir.appendingPathComponent("DSC_0001.xmp")
        FileManager.default.createFile(atPath: sidecar.path, contents: Data("<x/>".utf8))
        // "Fällan" ur uppgiften: en fil med SAMMA basnamn men annan ändelse som
        // användaren själv lagt i adressmappen (t.ex. en redigerad .psd) —
        // ska aldrig räknas som appens egen fil.
        let foreign = dir.appendingPathComponent("DSC_0001.psd")
        FileManager.default.createFile(atPath: foreign.path, contents: Data("z".utf8))

        #expect(FileSafety.isCullManaged(link))
        #expect(FileSafety.isCullManaged(sidecar))
        #expect(!FileSafety.isCullManaged(foreign))
    }
}
