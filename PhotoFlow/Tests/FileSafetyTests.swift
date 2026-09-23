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

    // MARK: - createLink

    @Test("Mål inuti outputDir får en relativ länk som fortfarande löser rätt EFTER att hela outputmappen flyttats")
    func createLink_targetInsideOutputDir_survivesMovingWholeOutputFolder() throws {
        // Bygger en hel "session" (adressmapp + dng-staging) under en
        // parent-mapp, precis som `exportToAddressFolders` gör, sedan flyttar
        // HELA parent-mappen — exakt scenariot från den skarpa körningen mot
        // `/Users/fredrik/Desktop/lint/OUTPUT` (se FORBATTRINGAR.md).
        let parent = tempDir()
        let output = parent.appendingPathComponent("OUTPUT")
        let dngDir = output.appendingPathComponent("dng")
        let addressDir = output.appendingPathComponent("Testgatan 1")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addressDir, withIntermediateDirectories: true)

        let dngFile = dngDir.appendingPathComponent("DSC_0001.dng")
        FileManager.default.createFile(atPath: dngFile.path, contents: Data("dng".utf8))
        let link = addressDir.appendingPathComponent("DSC_0001.dng")

        try FileSafety.createLink(at: link, to: dngFile, outputDir: output)

        let destination = try #require(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        #expect(!destination.hasPrefix("/"), "målet ligger inuti outputDir — länken ska vara relativ, inte absolut")
        #expect(destination == "../dng/DSC_0001.dng")

        // Flytta HELA outputmappen (och därmed dng/ och adressmappen
        // tillsammans) till en ny plats.
        let movedOutput = parent.appendingPathComponent("OUTPUT-arkiverad")
        try FileManager.default.moveItem(at: output, to: movedOutput)

        let movedLink = movedOutput.appendingPathComponent("Testgatan 1/DSC_0001.dng")
        #expect(FileManager.default.fileExists(atPath: movedLink.path), "länken ska fortfarande peka på rätt fil efter flytten")
        let resolvedContent = try Data(contentsOf: movedLink)
        #expect(resolvedContent == Data("dng".utf8))
    }

    @Test("Mål utanför outputDir (original-NEF på SD-kortet) får en absolut länk")
    func createLink_targetOutsideOutputDir_getsAbsoluteLink() throws {
        let output = tempDir()
        let sdCard = FileManager.default.temporaryDirectory.appendingPathComponent("FileSafetyTests-sdcard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sdCard, withIntermediateDirectories: true)
        let nefFile = sdCard.appendingPathComponent("DSC_0001.NEF")
        FileManager.default.createFile(atPath: nefFile.path, contents: Data("nef".utf8))

        let extrasDir = output.appendingPathComponent("Testgatan 1 ÖVRIGA")
        try FileManager.default.createDirectory(at: extrasDir, withIntermediateDirectories: true)
        let link = extrasDir.appendingPathComponent("DSC_0001.NEF")

        try FileSafety.createLink(at: link, to: nefFile, outputDir: output)

        let destination = try #require(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        #expect(destination == nefFile.standardizedFileURL.path)
    }

    @Test("createLink är idempotent: att kalla den två gånger med samma mål ändrar ingenting")
    func createLink_isIdempotent() throws {
        let output = tempDir()
        let dngDir = output.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        let dngFile = dngDir.appendingPathComponent("DSC_0001.dng")
        FileManager.default.createFile(atPath: dngFile.path, contents: Data("dng".utf8))
        let addressDir = output.appendingPathComponent("Testgatan 1")
        try FileManager.default.createDirectory(at: addressDir, withIntermediateDirectories: true)
        let link = addressDir.appendingPathComponent("DSC_0001.dng")

        try FileSafety.createLink(at: link, to: dngFile, outputDir: output)
        // Andra anropet ska inte kasta (t.ex. "file already exists") eller
        // ändra länken.
        try FileSafety.createLink(at: link, to: dngFile, outputDir: output)

        let destination = try #require(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        #expect(destination == "../dng/DSC_0001.dng")
    }

    @Test("assertInsideOutput godkänner både relativa och absoluta länkar som createLink skapar")
    func assertInsideOutput_acceptsLinksCreatedByCreateLink() throws {
        // Gallringens säkerhetsspärr kontrollerar VÄGEN till länken (var den
        // LIGGER), inte vart den PEKAR — se `FileSafety.assertInsideOutput`s
        // kommentar. Den kontrollen får inte sluta känna igen länkar som
        // `createLink` skapar, oavsett om destinationen blev relativ eller
        // absolut.
        let output = tempDir()
        let dngDir = output.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        let dngFile = dngDir.appendingPathComponent("DSC_0001.dng")
        FileManager.default.createFile(atPath: dngFile.path, contents: Data("dng".utf8))

        let sdCard = FileManager.default.temporaryDirectory.appendingPathComponent("FileSafetyTests-sdcard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sdCard, withIntermediateDirectories: true)
        let nefFile = sdCard.appendingPathComponent("DSC_0001.NEF")
        FileManager.default.createFile(atPath: nefFile.path, contents: Data("nef".utf8))

        let addressDir = output.appendingPathComponent("Testgatan 1")
        let extrasDir = output.appendingPathComponent("Testgatan 1 ÖVRIGA")
        try FileManager.default.createDirectory(at: addressDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extrasDir, withIntermediateDirectories: true)

        let relativeLink = addressDir.appendingPathComponent("DSC_0001.dng")
        let absoluteLink = extrasDir.appendingPathComponent("DSC_0001.NEF")
        try FileSafety.createLink(at: relativeLink, to: dngFile, outputDir: output)
        try FileSafety.createLink(at: absoluteLink, to: nefFile, outputDir: output)

        // Bägge länkarna (vägen TILL dem, inte var de pekar) ska godkännas.
        try FileSafety.assertInsideOutput(relativeLink, outputDir: output)
        try FileSafety.assertInsideOutput(absoluteLink, outputDir: output)
        #expect(FileSafety.isSymlink(relativeLink))
        #expect(FileSafety.isSymlink(absoluteLink))
        #expect(FileSafety.isCullManaged(relativeLink))
        #expect(FileSafety.isCullManaged(absoluteLink))
    }
}
