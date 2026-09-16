import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `PipelineRunner.cullExiftoolArguments` (Fas 4, "markera"-läget för
/// `AppSettings.cullAction`): writes `XMP:Rating` (3 = accepted, -1 = Lightroom
/// Classic's "Rejected" flag) instead of deleting/moving files. Uses the same
/// NEF-symlink-vs-real-file split as `PipelineRunnerMetadataTests`.
@MainActor
struct PipelineRunnerCullingTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerCullingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Rating values

    @Test("Accepterad bild får Rating=3, ingen Urgency")
    func accepted_getsRatingThree() {
        let dng = URL(fileURLWithPath: "/tmp/x.dng")
        let args = PipelineRunner.cullExiftoolArguments(for: dng, accepted: true)
        #expect(args.contains("-XMP:Rating=3"))
        #expect(!args.contains { $0.hasPrefix("-XMP-photoshop:Urgency") })
    }

    @Test("Avvisad bild får Rating=-1 (Lightrooms Rejected-flagga) och Urgency=8")
    func rejected_getsRatingMinusOneAndUrgency() {
        let dng = URL(fileURLWithPath: "/tmp/x.dng")
        let args = PipelineRunner.cullExiftoolArguments(for: dng, accepted: false)
        #expect(args.contains("-XMP:Rating=-1"))
        #expect(args.contains("-XMP-photoshop:Urgency=8"))
    }

    // MARK: - DNG/JPEG → in place

    @Test("DNG skrivs in place, symlänken bevaras")
    func dng_writesInPlace() {
        let dir = tempDir()
        let dng = dir.appendingPathComponent("DSC_0001.dng")
        let args = PipelineRunner.cullExiftoolArguments(for: dng, accepted: true)
        #expect(args.first == "-overwrite_original_in_place")
        #expect(args.last == "-execute")
        #expect(args[args.count - 2] == dng.path)
    }

    // MARK: - NEF → sidecar (aldrig röra symlänken till originalet)

    @Test("NEF utan befintlig sidecar skriver ny .xmp via -o, rör aldrig NEF-filen")
    func nef_noExistingSidecar_usesDashOToCreateSidecar() {
        let dir = tempDir()
        let nef = dir.appendingPathComponent("DSC_0002.nef")
        let args = PipelineRunner.cullExiftoolArguments(for: nef, accepted: false)

        #expect(!args.contains("-overwrite_original"))
        #expect(!args.contains("-overwrite_original_in_place"))
        #expect(args.contains("-o"))
        let sidecarPath = dir.appendingPathComponent("DSC_0002.xmp").path
        #expect(args.suffix(3) == [sidecarPath, nef.path, "-execute"])
    }

    @Test("NEF med befintlig sidecar skriver direkt till .xmp-filen med -overwrite_original")
    func nef_existingSidecar_overwritesSidecarDirectly() {
        let dir = tempDir()
        let nef = dir.appendingPathComponent("DSC_0003.nef")
        let sidecar = dir.appendingPathComponent("DSC_0003.xmp")
        FileManager.default.createFile(atPath: sidecar.path, contents: nil)

        let args = PipelineRunner.cullExiftoolArguments(for: nef, accepted: true)

        #expect(args.first == "-overwrite_original")
        #expect(!args.contains("-o"))
        #expect(args[args.count - 2] == sidecar.path)
        #expect(!args.contains(nef.path))
    }
}
