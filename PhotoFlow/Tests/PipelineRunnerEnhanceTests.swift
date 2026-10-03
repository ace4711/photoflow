import Foundation
import Testing
@testable import PhotoFlow

/// Sortering och urval för "Förbättra bilder": filer i `enhanced/` flyttas till
/// `<adress> FÖRBÄTTRADE/` även när sorteringen i övrigt hoppas över.
@MainActor
struct PipelineRunnerEnhanceTests {

    private func makePhoto(id: String) -> PhotoItem {
        PhotoItem(
            id: id, filename: "\(id).NEF", nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
            dngURL: nil, previewURL: nil, exposureTime: "1/125", exposureSeconds: 1.0 / 125.0,
            fNumber: 8.0, iso: 100, dateTime: Date()
        )
    }

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerEnhanceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    @Test("Förbättrade filer flyttas till FÖRBÄTTRADE även när sorteringen hoppas över; nyare ersätter äldre")
    func enhancedFiles_movedEvenWhenSortingSkipped() async throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let staging = AddressFolderLayout.enhancedStagingDir(in: outputDir)

        let state = PipelineState()
        state.outputDirectory = outputDir
        let bracketPhoto = makePhoto(id: "DSC_0001")
        let singlePhoto = makePhoto(id: "DSC_0009")
        state.allPhotos = [bracketPhoto, singlePhoto]
        state.bracketGroups = [
            BracketGroup(id: 1, isBracket: true, folderName: "bracket_001", photoIDs: [bracketPhoto.id], fNumber: 8, iso: 100,
                         timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 3),
            BracketGroup(id: 2, isBracket: false, folderName: "single_002", photoIDs: [singlePhoto.id], fNumber: 8, iso: 100,
                         timeStart: "10:05", timeEnd: "10:05", exposureRangeStops: 0)
        ]
        write("ny", to: staging.appendingPathComponent("hdr_group_1_enh.tiff"))
        write("ny", to: staging.appendingPathComponent("hdr_group_1_enh.jpg"))
        write("ny", to: staging.appendingPathComponent("DSC_0009_enh.tiff"))
        write("ny", to: staging.appendingPathComponent("DSC_0009_enh.jpg"))
        write("annat", to: staging.appendingPathComponent("anteckning.txt"))

        // Äldre version i adressmappen, och en metadatamarkör som ska rensas.
        let enhancedDir = AddressFolderLayout.enhancedDir(in: outputDir, folderName: "Osorterade")
        write("gammal", to: enhancedDir.appendingPathComponent("hdr_group_1_enh.tiff"))
        write("{}", to: outputDir.appendingPathComponent("metadata_written.json"))

        // Sorteringen "redan gjord": markör med rätt antal, inget manifest-record.
        write(#"{"photos_sorted": 2}"#, to: outputDir.appendingPathComponent("files_sorted.json"))

        // HDR avstängt: flytten får inte bero på HDR-inställningen.
        let hdrWasEnabled = AppSettings.shared.hdrMergeEnabled
        AppSettings.shared.hdrMergeEnabled = false
        defer { AppSettings.shared.hdrMergeEnabled = hdrWasEnabled }

        let runner = PipelineRunner(state: state)
        await runner.exportToAddressFolders()

        let fm = FileManager.default
        for name in ["hdr_group_1_enh.tiff", "hdr_group_1_enh.jpg", "DSC_0009_enh.tiff", "DSC_0009_enh.jpg"] {
            #expect(fm.fileExists(atPath: enhancedDir.appendingPathComponent(name).path), "\(name) saknas i FÖRBÄTTRADE")
            #expect(!fm.fileExists(atPath: staging.appendingPathComponent(name).path), "\(name) ligger kvar i enhanced/")
        }
        let replaced = try String(contentsOf: enhancedDir.appendingPathComponent("hdr_group_1_enh.tiff"), encoding: .utf8)
        #expect(replaced == "ny")
        #expect(fm.fileExists(atPath: staging.appendingPathComponent("anteckning.txt").path))
        #expect(!fm.fileExists(atPath: outputDir.appendingPathComponent("metadata_written.json").path))
        #expect(enhancedDir.lastPathComponent == "Osorterade FÖRBÄTTRADE")
    }

    @Test("locateEnhancedFiles hittar filer i enhanced/ och FÖRBÄTTRADE; enhanced/ vinner")
    func locateEnhancedFiles() throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        write("a", to: AddressFolderLayout.enhancedDir(in: outputDir, folderName: "Gatan 1").appendingPathComponent("DSC_0001_enh.jpg"))
        write("a", to: AddressFolderLayout.enhancedDir(in: outputDir, folderName: "Gatan 1").appendingPathComponent("hdr_group_4_enh.tiff"))
        write("b", to: AddressFolderLayout.enhancedStagingDir(in: outputDir).appendingPathComponent("hdr_group_4_enh.tiff"))
        write("x", to: AddressFolderLayout.enhancedStagingDir(in: outputDir).appendingPathComponent("hdr_group_4.tiff"))
        let found = AddressFolderLayout.locateEnhancedFiles(in: outputDir)
        #expect(Set(found.keys) == ["DSC_0001", "hdr_group_4"])
        #expect(found["hdr_group_4"]?.first?.deletingLastPathComponent().lastPathComponent == "enhanced")
    }

    @Test("Exteriör = taggen Exteriör utan Interiör")
    func isExterior() {
        func photo(_ tags: [String]) -> PhotoItem {
            var p = makePhoto(id: "DSC_0001")
            p.aiTags = tags
            return p
        }
        #expect(PipelineRunner.isExterior([photo(["Exteriör", "Fasad"])]))
        #expect(!PipelineRunner.isExterior([photo(["Interiör", "Kök"])]))
        #expect(!PipelineRunner.isExterior([photo(["Exteriör", "Interiör"])]))
        #expect(!PipelineRunner.isExterior([photo([])]))
        #expect(PipelineRunner.isExterior([photo(["Exteriör"]), photo(["Trädgård"])]))
    }

    @Test("Urval: HDR-TIFF per bracket, DNG/förhandsbild per singel; avvisade och saknade källor hoppas över")
    func enhanceJobs_selection() throws {
        let outputDir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let dng = outputDir.appendingPathComponent("dng/DSC_0009.dng")
        let preview = outputDir.appendingPathComponent("previews/DSC_0010.jpg")
        write("d", to: dng)
        write("p", to: preview)
        // HDR-filen har redan sorterats till ÖVRIGA.
        write("t", to: AddressFolderLayout.extrasDir(in: outputDir, folderName: "Gatan 1").appendingPathComponent("hdr_group_1.tiff"))

        func photo(_ id: String, dng: URL? = nil, preview: URL? = nil, rejected: Bool = false) -> PhotoItem {
            var p = PhotoItem(id: id, filename: "\(id).NEF", nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"), dngURL: dng,
                              previewURL: preview, exposureTime: "1/125", exposureSeconds: 0.008, fNumber: 8, iso: 100, dateTime: Date())
            p.rejected = rejected
            return p
        }
        let photos = [photo("DSC_0001"), photo("DSC_0009", dng: dng), photo("DSC_0010", preview: preview),
                      photo("DSC_0011", rejected: true), photo("DSC_0012"), photo("DSC_0020"), photo("DSC_0021", rejected: true)]
        let state = PipelineState()
        state.outputDirectory = outputDir
        state.allPhotos = photos
        func group(_ id: Int, bracket: Bool, _ ids: [String]) -> BracketGroup {
            BracketGroup(id: id, isBracket: bracket, folderName: "g\(id)", photoIDs: ids, fNumber: 8, iso: 100,
                         timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 0)
        }
        state.bracketGroups = [
            group(1, bracket: true, ["DSC_0001"]),                       // HDR finns
            group(2, bracket: false, ["DSC_0009", "DSC_0010", "DSC_0011", "DSC_0012"]),
            group(3, bracket: true, ["DSC_0020"]),                       // ingen HDR-fil
            group(4, bracket: true, ["DSC_0021"])                        // alla avvisade
        ]
        let runner = PipelineRunner(state: state)
        let (jobs, rejected, noSource) = runner.enhanceJobs(outputDir: outputDir)
        #expect(jobs.map(\.key) == ["hdr_group_1", "DSC_0009", "DSC_0010"])
        #expect(jobs.map(\.kind) == [.hdr, .dng, .preview])
        #expect(rejected == 2)       // singeln DSC_0011 + bracket-gruppen 4
        #expect(noSource == 2)       // DSC_0012 (ingen DNG/förhandsbild) + grupp 3 (ingen HDR)

        // Fingerprintet ändras med profilen men inte mellan anrop.
        let a = runner.enhanceFingerprint(job: jobs[0], profile: .automatic)
        #expect(a == runner.enhanceFingerprint(job: jobs[0], profile: .automatic))
        #expect(a != runner.enhanceFingerprint(job: jobs[0], profile: .neutral))
    }

    @Test("Fingerprintet ändras inte när metadatasteget skriver till källfilen (bara när NEF:erna eller inställningarna ändras)")
    func fingerprint_stableAcrossMetadataWrites() throws {
        let dir = tempOutputDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nef = dir.appendingPathComponent("DSC_0001.NEF")
        let hdr = dir.appendingPathComponent("hdr_group_1.tiff")
        write("råfil", to: nef)
        write("hdr-pixlar", to: hdr)
        let runner = PipelineRunner(state: PipelineState())
        let job = PipelineRunner.EnhanceJob(key: "hdr_group_1", kind: .hdr, source: hdr, label: "HDR grupp 1", identity: [nef])
        let before = runner.enhanceFingerprint(job: job, profile: .automatic)

        // Metadatasteget skriver EXIF/GPS i HDR-filen: ny storlek och ny ändringstid.
        write("hdr-pixlar + exif + gps, längre fil", to: hdr)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: hdr.path)
        #expect(runner.enhanceFingerprint(job: job, profile: .automatic) == before)

        // Ändrad indata (en annan exponering i sammanslagningen) ger nytt fingerprint.
        let other = dir.appendingPathComponent("DSC_0002.NEF")
        write("annan råfil", to: other)
        var changed = job
        changed.identity = [nef, other]
        #expect(runner.enhanceFingerprint(job: changed, profile: .automatic) != before)
    }
}
