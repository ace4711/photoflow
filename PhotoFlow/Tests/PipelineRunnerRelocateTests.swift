import Foundation
import CoreLocation
import Testing
@testable import PhotoFlow

/// Omsorteringen i sorteringssteget (PipelineRunner+Relocate.swift): en redan sorterad session där
/// bilder hamnat i fel adressmapp rättas upp — felplacerade länkar, sidecars, HDR- och förbättrade
/// filer flyttas till rätt mapp, inget original eller unik fil raderas.
@MainActor
struct PipelineRunnerRelocateTests {
    private let fm = FileManager.default
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempDir(_ name: String) -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func link(_ url: URL, to target: URL, outputDir: URL) throws {
        try FileSafety.createLink(at: url, to: target, outputDir: outputDir)
    }

    private func isLink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }

    /// Två adresser: A (t0…t0+600) och B (t0+602…t0+1200). DSC_0001 (t0+700) hör till B men ligger
    /// sorterad i A, som den gamla regeln gjorde; DSC_0002 (t0+100) hör till A och ligger rätt.
    private func makeSession() throws -> (runner: PipelineRunner, state: PipelineState, out: URL, input: URL) {
        let out = tempDir("RelocateOut")
        let input = tempDir("RelocateIn")
        let state = PipelineState()
        state.outputDirectory = out
        state.correctedCoordinates["A"] = CLLocationCoordinate2D(latitude: 59.1, longitude: 18.1)
        state.correctedCoordinates["B"] = CLLocationCoordinate2D(latitude: 59.2, longitude: 18.2)

        var photos: [PhotoItem] = []
        for (name, offset) in [("DSC_0001", 700.0), ("DSC_0002", 100.0)] {
            let nef = input.appendingPathComponent("\(name).NEF")
            try write(nef, "raw \(name)")
            let dng = out.appendingPathComponent("dng/\(name).dng")
            try write(dng, "dng \(name)")
            let preview = out.appendingPathComponent("previews/\(name).jpg")
            try write(preview, "jpg \(name)")
            photos.append(PhotoItem(id: name, filename: "\(name).NEF", nefURL: nef, dngURL: dng, previewURL: preview,
                                    exposureTime: "1/125", exposureSeconds: 1.0 / 125.0, fNumber: 8, iso: 100,
                                    dateTime: t0.addingTimeInterval(offset)))
        }
        state.allPhotos = photos
        state.bracketGroups = [BracketGroup(id: 1, isBracket: true, folderName: "bracket_001", photoIDs: ["DSC_0001"],
                                            fNumber: 8, iso: 100, timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 3)]
        let runner = PipelineRunner(state: state)
        runner.calendarMappings = [
            (address: "A", eventTitle: "", photoDateRange: t0...t0.addingTimeInterval(600)),
            (address: "B", eventTitle: "", photoDateRange: t0.addingTimeInterval(602)...t0.addingTimeInterval(1200)),
        ]

        // Så som den gamla regeln sorterade: båda bilderna i A.
        for photo in photos {
            try link(out.appendingPathComponent("A/\(photo.displayName).dng"), to: photo.dngURL!, outputDir: out)
            try link(out.appendingPathComponent("A TITTBILDER/\(photo.displayName).jpg"), to: photo.previewURL!, outputDir: out)
            try link(out.appendingPathComponent("A ÖVRIGA/\(photo.filename)"), to: photo.nefURL, outputDir: out)
        }
        try write(out.appendingPathComponent("A ÖVRIGA/DSC_0001.xmp"), "<x:Rating>-1</x:Rating>")
        try write(out.appendingPathComponent("A ÖVRIGA/hdr_group_1.tiff"), "hdr tiff")
        try write(out.appendingPathComponent("A TITTBILDER/hdr_group_1.jpg"), "hdr jpg")
        try write(out.appendingPathComponent("A FÖRBÄTTRADE/hdr_group_1_enh.jpg"), "enh hdr")
        try write(out.appendingPathComponent("A FÖRBÄTTRADE/DSC_0001_enh.jpg"), "enh gammal")
        try write(out.appendingPathComponent("B FÖRBÄTTRADE/DSC_0001_enh.jpg"), "enh ny")  // konflikt: annan fil
        try write(out.appendingPathComponent("A ÖVRIGA/DSC_0001.psd"), "användarens fil")   // riktig fil, rörs inte
        try write(out.appendingPathComponent("A FÄRDIGA/DSC_0001.jpg"), "lightroom-export")  // FÄRDIGA rörs inte
        // Länk i Gallrade/ ("flytta"-läget) för den felplacerade bilden — och redan en länk i B (dubblett).
        try link(out.appendingPathComponent("A TITTBILDER/Gallrade/DSC_0001.jpg"), to: photos[0].previewURL!, outputDir: out)
        try link(out.appendingPathComponent("B/DSC_0001.dng"), to: photos[0].dngURL!, outputDir: out)

        var stamps = MetadataStamps()
        stamps.files["A ÖVRIGA/hdr_group_1.tiff"] = .init(fingerprint: "gammal", inode: 1)
        stamps.files["A ÖVRIGA/DSC_0002.NEF"] = .init(fingerprint: "orörd", inode: 2)
        stamps.save(to: out)
        return (runner, state, out, input)
    }

    @Test("Omsorteringen flyttar felplacerade länkar, sidecar, HDR och förbättrade filer, och raderar inget unikt")
    func relocation_movesMisplacedFiles() async throws {
        let (runner, state, out, input) = try makeSession()
        defer { try? fm.removeItem(at: out); try? fm.removeItem(at: input) }

        await runner.exportToAddressFolders()

        let p = { (path: String) in out.appendingPathComponent(path) }
        // DSC_0001 ligger nu i B, inte i A.
        #expect(isLink(p("B/DSC_0001.dng")))
        #expect(!isLink(p("A/DSC_0001.dng")) && !fm.fileExists(atPath: p("A/DSC_0001.dng").path))
        #expect(isLink(p("B TITTBILDER/DSC_0001.jpg")))
        #expect(!isLink(p("A TITTBILDER/DSC_0001.jpg")))
        #expect(isLink(p("B ÖVRIGA/DSC_0001.NEF")))
        #expect(!isLink(p("A ÖVRIGA/DSC_0001.NEF")))
        #expect(read(p("B ÖVRIGA/DSC_0001.xmp")) == "<x:Rating>-1</x:Rating>")  // gallringsbeslutet följer med
        #expect(!fm.fileExists(atPath: p("A ÖVRIGA/DSC_0001.xmp").path))
        #expect(isLink(p("B TITTBILDER/Gallrade/DSC_0001.jpg")))
        #expect(!isLink(p("A TITTBILDER/Gallrade/DSC_0001.jpg")))
        // Länken pekar fortfarande rätt (relativ länk mellan syskonmappar).
        #expect(read(p("B TITTBILDER/DSC_0001.jpg")) == "jpg DSC_0001")
        #expect(read(p("B ÖVRIGA/DSC_0001.NEF")) == "raw DSC_0001")
        // HDR och förbättrade (unika) flyttade, inte kopierade eller raderade.
        #expect(read(p("B ÖVRIGA/hdr_group_1.tiff")) == "hdr tiff")
        #expect(read(p("B TITTBILDER/hdr_group_1.jpg")) == "hdr jpg")
        #expect(read(p("B FÖRBÄTTRADE/hdr_group_1_enh.jpg")) == "enh hdr")
        #expect(!fm.fileExists(atPath: p("A ÖVRIGA/hdr_group_1.tiff").path))
        // Konflikt: båda förbättrade filerna finns kvar.
        #expect(read(p("A FÖRBÄTTRADE/DSC_0001_enh.jpg")) == "enh gammal")
        #expect(read(p("B FÖRBÄTTRADE/DSC_0001_enh.jpg")) == "enh ny")
        // Användarens filer och FÄRDIGA orörda, original orörda.
        #expect(read(p("A ÖVRIGA/DSC_0001.psd")) == "användarens fil")
        #expect(read(p("A FÄRDIGA/DSC_0001.jpg")) == "lightroom-export")
        #expect(read(input.appendingPathComponent("DSC_0001.NEF")) == "raw DSC_0001")
        #expect(read(p("dng/DSC_0001.dng")) == "dng DSC_0001")
        // DSC_0002 ligger kvar i A.
        #expect(isLink(p("A/DSC_0002.dng")) && isLink(p("A ÖVRIGA/DSC_0002.NEF")))
        #expect(!isLink(p("B/DSC_0002.dng")))
        // Stämplarna för flyttade filer är borta (de får ny metadata), övriga kvar.
        let stamps = MetadataStamps.load(from: out)
        #expect(stamps.files["A ÖVRIGA/hdr_group_1.tiff"] == nil)
        #expect(stamps.files["B ÖVRIGA/hdr_group_1.tiff"] == nil)
        #expect(stamps.files["A ÖVRIGA/DSC_0002.NEF"]?.fingerprint == "orörd")
        // Varje flytt loggas.
        let log = state.stepStatuses[.moveToFolders]?.logEntries.map(\.text) ?? []
        #expect(log.contains { $0.contains("Flyttad: A ÖVRIGA/hdr_group_1.tiff → B ÖVRIGA/hdr_group_1.tiff") })
        #expect(log.contains { $0.contains("Lämnad kvar: A FÖRBÄTTRADE/DSC_0001_enh.jpg") })
        #expect(log.contains { $0.contains("dubblett borttagen: A/DSC_0001.dng") })

        // En andra körning (samma fingerprint) gör ingenting mer.
        let before = try fm.contentsOfDirectory(atPath: p("B ÖVRIGA").path).sorted()
        await runner.exportToAddressFolders()
        #expect(try fm.contentsOfDirectory(atPath: p("B ÖVRIGA").path).sorted() == before)
    }

    @Test("Omsorteringen körs inte utan kalendermatchningar (allt skulle annars flyttas till Osorterade)")
    func relocation_skippedWithoutMappings() async throws {
        let (runner, _, out, input) = try makeSession()
        defer { try? fm.removeItem(at: out); try? fm.removeItem(at: input) }
        runner.calendarMappings = []
        await runner.exportToAddressFolders()
        #expect(isLink(out.appendingPathComponent("A ÖVRIGA/DSC_0001.NEF")))
        #expect(fm.fileExists(atPath: out.appendingPathComponent("A ÖVRIGA/hdr_group_1.tiff").path))
    }

    @Test("En avvisad bild får inga nya länkar vid omsortering i \"radera\"-läget, och hamnar i Gallrade/ i \"flytta\"-läget")
    func resort_respectsExecutedCullDecisions() async throws {
        let saved = AppSettings.shared.cullAction
        defer { AppSettings.shared.cullAction = saved }
        for action in ["radera", "flytta"] {
            let (runner, state, out, input) = try makeSession()
            defer { try? fm.removeItem(at: out); try? fm.removeItem(at: input) }
            AppSettings.shared.cullAction = action
            // DSC_0001 avvisades och raderades ur A innan regeln ändrades.
            for path in ["A/DSC_0001.dng", "A TITTBILDER/DSC_0001.jpg", "A ÖVRIGA/DSC_0001.NEF", "A TITTBILDER/Gallrade/DSC_0001.jpg", "B/DSC_0001.dng"] {
                try fm.removeItem(at: out.appendingPathComponent(path))
            }
            state.allPhotos[0].rejected = true
            await runner.exportToAddressFolders()
            let main = isLink(out.appendingPathComponent("B ÖVRIGA/DSC_0001.NEF"))
            let culled = isLink(out.appendingPathComponent("B ÖVRIGA/Gallrade/DSC_0001.NEF"))
            #expect(!main, "\(action)")
            #expect(culled == (action == "flytta"), "\(action)")
        }
    }

    @Test("En flyttad fil får en ny stämpel: stämpeln bygger på den relativa sökvägen")
    func movedFile_stampDoesNotMatchAtNewPath() throws {
        let out = tempDir("RelocateStamp")
        defer { try? fm.removeItem(at: out) }
        let oldFile = out.appendingPathComponent("A ÖVRIGA/hdr_group_1.tiff")
        try write(oldFile, "x")
        let meta = IPTCFileMetadata(address: "A", eventTitle: "", description: "A")
        var stamps = MetadataStamps()
        stamps.record(oldFile, meta: meta, outputDir: out)
        #expect(stamps.matches(oldFile, meta: meta, outputDir: out))
        let newFile = out.appendingPathComponent("B ÖVRIGA/hdr_group_1.tiff")
        try fm.createDirectory(at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: oldFile, to: newFile)
        // Samma inod, men ingen stämpel på den nya sökvägen — och B:s metadata är dessutom en annan.
        #expect(!stamps.matches(newFile, meta: meta, outputDir: out))
        #expect(!stamps.matches(newFile, meta: IPTCFileMetadata(address: "B", eventTitle: "", description: "B"), outputDir: out))
    }

    @Test("Sorteringens fingerprint ändras med regelversionen och med kalenderintervallen")
    func sortFingerprint_includesRuleAndRanges() async throws {
        let (runner, state, out, input) = try makeSession()
        defer { try? fm.removeItem(at: out); try? fm.removeItem(at: input) }
        await runner.exportToAddressFolders()
        let first = state.pendingStepFingerprints[.moveToFolders]
        #expect(first != nil)
        runner.calendarMappings[1].photoDateRange = t0.addingTimeInterval(650)...t0.addingTimeInterval(1200)
        await runner.exportToAddressFolders()
        #expect(state.pendingStepFingerprints[.moveToFolders] != first)
        #expect(PipelineRunner.sortRuleVersion == "2")
    }
}
