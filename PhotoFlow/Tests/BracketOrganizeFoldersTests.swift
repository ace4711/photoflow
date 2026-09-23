import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `PipelineRunner.organizeGroupsIntoFolders`, the Swift replacement
/// for the embedded Python `organizeGroupsPython()` script. The old script
/// built NEF source paths as `source_dir/filename` (`os.path.join`), which
/// silently produced no symlink at all when NEFs lived in a subfolder of the
/// input directory (a real layout: SD cards mount subfolders like
/// `101NCZ_8/DSC_1807.NEF`) — `organizeGroupsIntoFolders` takes a
/// filename->URL lookup instead (built the same way `loadBracketGroups`
/// builds its NEF lookup, via a recursive `findNEFFiles` scan), so it works
/// regardless of subfolder depth.
struct BracketOrganizeFoldersTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoflow-organize-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeGroup(id: Int, isBracket: Bool, files: [String]) -> BracketGroupResult {
        BracketGroupResult(
            groupId: id, isBracket: isBracket, imageCount: files.count, files: files,
            exposures: files.map { _ in "1" }, fnumber: 8.0, iso: 400,
            timeStart: "10:00:00", timeEnd: "10:00:00",
            dateStart: "2026-01-01 10:00:00", dateEnd: "2026-01-01 10:00:00",
            datetimes: files.map { _ in "2026-01-01 10:00:00" },
            exposureRangeStops: 1.0, suggestedHDRIndices: Array(0..<files.count),
            uniqueExposureLevels: 1
        )
    }

    @Test("Bracket-mapp får rätt namn och innehåller symlänkar till NEF (absolut) och DNG (relativ) i en undermapp")
    func bracketFolder_symlinksNEFFromSubfolder() throws {
        // NEF lives on a separate "input"/SD-card root, entirely OUTSIDE the
        // output tree — exactly like a real session, and the case that
        // determines the NEF symlink must stay absolute (see
        // `FileSafety.createLink`). `root` below plays the OUTPUT tree.
        let inputRoot = makeTempDir()
        let root = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: inputRoot)
            try? FileManager.default.removeItem(at: root)
        }

        // NEF lives under a subfolder, like a real SD card's DCIM layout —
        // this is exactly the case the old `source_dir/filename` path broke on.
        let subfolder = inputRoot.appendingPathComponent("101NCZ_8")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let nefURL = subfolder.appendingPathComponent("DSC_1807.NEF")
        try Data("fake nef".utf8).write(to: nefURL)

        let dngDir = root.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        let dngURL = dngDir.appendingPathComponent("DSC_1807.dng")
        try Data("fake dng".utf8).write(to: dngURL)

        let groupsDir = root.appendingPathComponent("bracket_groups")
        try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

        let group = makeGroup(id: 1, isBracket: true, files: ["DSC_1807.NEF"])
        PipelineRunner.organizeGroupsIntoFolders(
            groups: [group], nefLookup: [nefURL.lastPathComponent: nefURL],
            dngDir: dngDir, groupsDir: groupsDir, outputDir: root
        )

        let expectedFolder = groupsDir.appendingPathComponent("bracket_001_HDR_1exp")
        #expect(FileManager.default.fileExists(atPath: expectedFolder.path))

        let nefLink = expectedFolder.appendingPathComponent("DSC_1807.NEF")
        let dngLink = expectedFolder.appendingPathComponent("DSC_1807.dng")
        // `fileExists` follows the symlink — both must resolve to a real file.
        #expect(FileManager.default.fileExists(atPath: nefLink.path))
        #expect(FileManager.default.fileExists(atPath: dngLink.path))
        // NEF target is outside `root` (the output tree) → absolute destination.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: nefLink.path)) == nefURL.path)
        // DNG target is inside `root` → relative destination, so the group
        // folder stays valid if `root` is moved/archived as a whole.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dngLink.path)) == "../../dng/DSC_1807.dng")
    }

    @Test("Single-mapp får rätt namn (single_NNN_Nimg)")
    func singleFolder_hasExpectedName() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dngDir = root.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        let groupsDir = root.appendingPathComponent("bracket_groups")
        try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

        let group = makeGroup(id: 7, isBracket: false, files: ["DSC_0001.NEF", "DSC_0002.NEF"])
        PipelineRunner.organizeGroupsIntoFolders(
            groups: [group], nefLookup: [:], dngDir: dngDir, groupsDir: groupsDir, outputDir: root
        )

        let expectedFolder = groupsDir.appendingPathComponent("single_007_2img")
        #expect(FileManager.default.fileExists(atPath: expectedFolder.path))
    }

    @Test("Saknad NEF i lookup skapar ingen symlänk men kraschar inte")
    func missingNEFInLookup_doesNotCrash() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dngDir = root.appendingPathComponent("dng")
        try FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
        let groupsDir = root.appendingPathComponent("bracket_groups")
        try FileManager.default.createDirectory(at: groupsDir, withIntermediateDirectories: true)

        let group = makeGroup(id: 2, isBracket: false, files: ["DSC_9999.NEF"])
        PipelineRunner.organizeGroupsIntoFolders(
            groups: [group], nefLookup: [:], dngDir: dngDir, groupsDir: groupsDir, outputDir: root
        )

        let expectedFolder = groupsDir.appendingPathComponent("single_002_1img")
        #expect(FileManager.default.fileExists(atPath: expectedFolder.path))
        let nefLink = expectedFolder.appendingPathComponent("DSC_9999.NEF")
        #expect(!FileManager.default.fileExists(atPath: nefLink.path))
    }
}
