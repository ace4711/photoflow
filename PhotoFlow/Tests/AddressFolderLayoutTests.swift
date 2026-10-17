import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `AddressFolderLayout`, which centralizes the address-folder naming
/// scheme. A previous bug had `writeIPTCMetadata` look for a non-existent
/// "<address> DNG" folder — DNG symlinks actually live directly in "<address>"
/// with no suffix, same as `exportToAddressFolders` creates them.
struct AddressFolderLayoutTests {

    private let outputDir = URL(fileURLWithPath: "/tmp/photoflow-output")

    @Test("DNG-mappen har inget suffix")
    func dngDir_hasNoSuffix() {
        let dir = AddressFolderLayout.dngDir(in: outputDir, folderName: "Lindvägen 12, Tyresö")
        #expect(dir.lastPathComponent == "Lindvägen 12, Tyresö")
    }

    @Test("Preview-mappen har suffixet TITTBILDER")
    func previewDir_hasTittbilderSuffix() {
        let dir = AddressFolderLayout.previewDir(in: outputDir, folderName: "Lindvägen 12, Tyresö")
        #expect(dir.lastPathComponent == "Lindvägen 12, Tyresö TITTBILDER")
    }

    @Test("Övriga-mappen har suffixet ÖVRIGA")
    func extrasDir_hasOvrigaSuffix() {
        let dir = AddressFolderLayout.extrasDir(in: outputDir, folderName: "Lindvägen 12, Tyresö")
        #expect(dir.lastPathComponent == "Lindvägen 12, Tyresö ÖVRIGA")
    }

    @Test("allDirs innehåller DNG, preview, extras och förbättrade i den ordningen")
    func allDirs_containsAllInOrder() {
        let dirs = AddressFolderLayout.allDirs(in: outputDir, folderName: "Osorterade")
        #expect(dirs.map(\.lastPathComponent) == ["Osorterade", "Osorterade TITTBILDER", "Osorterade ÖVRIGA", "Osorterade FÖRBÄTTRADE"])
    }

    @Test("Färdiga- och film-mapparna har suffixen FÄRDIGA och FILM")
    func finishedAndReelDirs() {
        #expect(AddressFolderLayout.finishedDir(in: outputDir, folderName: "Lindvägen 12").lastPathComponent == "Lindvägen 12 FÄRDIGA")
        #expect(AddressFolderLayout.reelDir(in: outputDir, folderName: "Lindvägen 12").lastPathComponent == "Lindvägen 12 FILM")
    }

    @Test("Filmens utmapp ligger bredvid källmappen, med adressen om den kan härledas")
    func reelDirForSource() {
        let finished = URL(fileURLWithPath: "/x/Objekt/Lindvägen 12 FÄRDIGA", isDirectory: true)
        #expect(AddressFolderLayout.reelDir(forSource: finished).path == "/x/Objekt/Lindvägen 12 FILM")
        let other = URL(fileURLWithPath: "/x/Objekt/Export", isDirectory: true)
        #expect(AddressFolderLayout.reelDir(forSource: other).path == "/x/Objekt/Export FILM")
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Lindvägen 12 FÄRDIGA") == "Lindvägen 12")
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Lindvägen 12") == nil)
        // Pipelinens förslag görs av FÖRBÄTTRADE: filmen hör hemma i <adress> FILM, inte "… FÖRBÄTTRADE FILM".
        let enhanced = URL(fileURLWithPath: "/x/Objekt/Lindvägen 12 FÖRBÄTTRADE", isDirectory: true)
        #expect(AddressFolderLayout.reelDir(forSource: enhanced).path == "/x/Objekt/Lindvägen 12 FILM")
        #expect(AddressFolderLayout.addressName(fromSourceDir: "Lindvägen 12 FÖRBÄTTRADE") == "Lindvägen 12")
        #expect(AddressFolderLayout.addressName(fromSourceDir: "Lindvägen 12 TITTBILDER") == "Lindvägen 12")
        #expect(AddressFolderLayout.addressName(fromSourceDir: "Lindvägen 12 red") == "Lindvägen 12")
        #expect(AddressFolderLayout.addressName(fromSourceDir: "Export") == nil)
        // Fotografens färdiga mappar räknas fortfarande inte som FÖRBÄTTRADE.
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Lindvägen 12 FÖRBÄTTRADE") == nil)
    }

    @Test("<adress> red räknas som färdiga bilder, FÄRDIGA vinner, filmmappen blir <adress> FILM")
    func redFolderIsFinished() throws {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("FinishedRed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: out) }
        try fm.createDirectory(at: out.appendingPathComponent("Chronas väg 7 RED"), withIntermediateDirectories: true)
        // Bara red finns (valfritt skiftläge).
        #expect(AddressFolderLayout.finishedDir(in: out, folderName: "Chronas väg 7").lastPathComponent == "Chronas väg 7 RED")
        // Båda finns: FÄRDIGA vinner.
        try fm.createDirectory(at: out.appendingPathComponent("Chronas väg 7 FÄRDIGA"), withIntermediateDirectories: true)
        #expect(AddressFolderLayout.finishedDir(in: out, folderName: "Chronas väg 7").lastPathComponent == "Chronas väg 7 FÄRDIGA")
        // Ingen finns: FÄRDIGA-sökvägen (som inte finns).
        let none = AddressFolderLayout.finishedDir(in: out, folderName: "Annan 1")
        #expect(none.lastPathComponent == "Annan 1 FÄRDIGA" && !fm.fileExists(atPath: none.path))

        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Chronas väg 7 red") == "Chronas väg 7")
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Chronas väg 7 Red") == "Chronas väg 7")
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Chronas väg 7 färdiga") == "Chronas väg 7")
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Redaktionen") == nil)
        #expect(AddressFolderLayout.addressName(fromFinishedDir: "Chronas väg 7 reduced") == nil)
        #expect(AddressFolderLayout.addressName(fromFinishedDir: " red") == nil)
        let red = URL(fileURLWithPath: "/x/Objekt/Chronas väg 7 red", isDirectory: true)
        #expect(AddressFolderLayout.reelDir(forSource: red).path == "/x/Objekt/Chronas väg 7 FILM")
    }

    @Test("Historiken öppnar <adress> red när FÄRDIGA saknas")
    func launchRequestFindsRed() throws {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("LaunchRed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: out) }
        try fm.createDirectory(at: out.appendingPathComponent("Gatan 1 red"), withIntermediateDirectories: true)
        let request = ReelLaunchRequest.forSession(outputDirectory: out, address: "Gatan 1")
        #expect(request.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } == "Gatan 1 red")
        let none = ReelLaunchRequest.forSession(outputDirectory: out, address: "Annan 2")
        #expect(none.sourcePath == nil)
    }

    @Test("Kurerad källa: allt utom pipelinens FÖRBÄTTRADE och TITTBILDER")
    func curatedSource() {
        func curated(_ name: String) -> Bool {
            AddressFolderLayout.isCuratedSource(URL(fileURLWithPath: "/x/\(name)", isDirectory: true))
        }
        #expect(curated("Chronas väg 7 FÄRDIGA") && curated("Chronas väg 7 red") && curated("Export"))
        #expect(!curated("Chronas väg 7 FÖRBÄTTRADE") && !curated("Chronas väg 7 TITTBILDER"))
    }

}

struct HDRLocatorTests {
    @Test("Hittar HDR i hdr/ och i adressmapparna; hdr/ vinner vid dubblett")
    func locatesSortedAndUnsortedHDR() throws {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("HDRLocator-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: out) }
        for dir in ["hdr", "Gatan 1 ÖVRIGA", "Gatan 1 TITTBILDER", "Gatan 1"] {
            try fm.createDirectory(at: out.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for path in ["Gatan 1 ÖVRIGA/hdr_group_3.tiff", "Gatan 1 TITTBILDER/hdr_group_3.jpg",
                     "Gatan 1 ÖVRIGA/hdr_group_5.tiff", "hdr/hdr_group_5.tiff", "hdr/hdr_group_7.jpg",
                     "Gatan 1/hdr_group_9.tiff"] {
            fm.createFile(atPath: out.appendingPathComponent(path).path, contents: Data())
        }
        let found = AddressFolderLayout.locateHDRFiles(in: out)
        #expect(found[3]?.tiff?.lastPathComponent == "hdr_group_3.tiff")
        #expect(found[3]?.tiff?.deletingLastPathComponent().lastPathComponent == "Gatan 1 ÖVRIGA")
        #expect(found[3]?.jpeg?.deletingLastPathComponent().lastPathComponent == "Gatan 1 TITTBILDER")
        #expect(found[5]?.tiff?.deletingLastPathComponent().lastPathComponent == "hdr")
        #expect(found[7]?.tiff == nil && found[7]?.jpeg != nil)
        #expect(found[9] == nil)  // DNG-mappen (utan suffix) innehåller inga HDR-filer
    }
}
