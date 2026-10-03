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

    @Test("allDirs innehåller DNG, preview och extras i den ordningen")
    func allDirs_containsAllThreeInOrder() {
        let dirs = AddressFolderLayout.allDirs(in: outputDir, folderName: "Osorterade")
        #expect(dirs.map(\.lastPathComponent) == ["Osorterade", "Osorterade TITTBILDER", "Osorterade ÖVRIGA"])
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
