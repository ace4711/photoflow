import Foundation
import Testing
@testable import PhotoFlow

/// Slutgranskning-fynd (hittat medan rök-testet i Del 2 förbereddes):
/// `exportToAddressFolders`'s HDR-block gjorde `continue` (hoppade över
/// gruppen helt) när `calendar.addressFolder` inte hittade en
/// kalendermatchning — till skillnad från ALLA andra filtyper i samma
/// funktion (NEF/DNG/preview), som redan föll tillbaka på "Osorterade". En
/// session utan kalendermatchning (ingen kalenderåtkomst, eller inget event
/// som täcker fototillfället) tappade därmed sina HDR-resultat permanent i
/// `outputDir/hdr/` — de flyttades aldrig till någon adressmapp och syntes
/// aldrig i Lightroom/Finder.
@MainActor
struct PipelineRunnerHDROrphanTests {

    private func makePhoto(id: String) -> PhotoItem {
        PhotoItem(
            id: id, filename: "\(id).NEF", nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
            dngURL: nil, previewURL: nil, exposureTime: "1/125", exposureSeconds: 1.0 / 125.0,
            fNumber: 8.0, iso: 100, dateTime: Date()
        )
    }

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerHDROrphanTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("HDR-resultat hamnar i \"Osorterade\" när ingen kalendermatchning finns, blir inte kvar i hdr/")
    func hdrResults_fallBackToOsorterade_whenNoCalendarMatch() async throws {
        let outputDir = tempOutputDir()
        let hdrDir = outputDir.appendingPathComponent("hdr")
        try FileManager.default.createDirectory(at: hdrDir, withIntermediateDirectories: true)

        let state = PipelineState()
        state.outputDirectory = outputDir
        let photo = makePhoto(id: "DSC_0001")
        state.allPhotos = [photo]
        let group = BracketGroup(
            id: 1, isBracket: true, folderName: "bracket_001",
            photoIDs: [photo.id], fNumber: 8, iso: 100,
            timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 3
        )
        state.bracketGroups = [group]

        FileManager.default.createFile(atPath: hdrDir.appendingPathComponent("hdr_group_1.tiff").path, contents: Data("tiff".utf8))
        FileManager.default.createFile(atPath: hdrDir.appendingPathComponent("hdr_group_1.jpg").path, contents: Data("jpg".utf8))

        let hdrWasEnabled = AppSettings.shared.hdrMergeEnabled
        AppSettings.shared.hdrMergeEnabled = true
        defer { AppSettings.shared.hdrMergeEnabled = hdrWasEnabled }

        let runner = PipelineRunner(state: state)
        // calendarMappings stays empty (default) — simulates no calendar match
        // for any photo, e.g. calendarMatchEnabled == false or no covering event.
        await runner.exportToAddressFolders()

        let extras = AddressFolderLayout.extrasDir(in: outputDir, folderName: "Osorterade")
        let previews = AddressFolderLayout.previewDir(in: outputDir, folderName: "Osorterade")
        #expect(FileManager.default.fileExists(atPath: extras.appendingPathComponent("hdr_group_1.tiff").path))
        #expect(FileManager.default.fileExists(atPath: previews.appendingPathComponent("hdr_group_1.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: hdrDir.appendingPathComponent("hdr_group_1.tiff").path))
        #expect(!FileManager.default.fileExists(atPath: hdrDir.appendingPathComponent("hdr_group_1.jpg").path))
    }
}
