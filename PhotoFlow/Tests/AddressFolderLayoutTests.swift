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
