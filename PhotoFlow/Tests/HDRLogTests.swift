import Foundation
import Testing
@testable import PhotoFlow

/// `hdr.json` (`HDRLog`): när en grupp görs om, adoption av befintliga HDR, fingerprint;
/// samt EV-sorteringen och medianreferensen i `HDREngine`.
@MainActor
struct HDRLogTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HDRLogTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(version: Int = HDREngine.version, fingerprint: String = "abc") -> HDRLog.Entry {
        HDRLog.Entry(engineVersion: version, fingerprint: fingerprint)
    }

    // MARK: - Beslut

    @Test("Saknad fil görs alltid; befintlig fil utan post adopteras i stället för att göras om")
    func missingFileMerges_existingWithoutEntryIsAdopted() {
        #expect(HDRLog.decide(fileExists: false, entry: nil, fingerprint: "abc", currentVersion: 3, policy: .never, force: false)
                == .merge(reason: "ny"))
        #expect(HDRLog.decide(fileExists: false, entry: entry(), fingerprint: "abc", currentVersion: 3, policy: .never, force: false)
                == .merge(reason: "filen saknas"))
        #expect(HDRLog.decide(fileExists: true, entry: nil, fingerprint: "abc", currentVersion: 3, policy: .always, force: false)
                == .adopt)
    }

    @Test("Ändrat fingerprint gör om — utom när original-NEF:erna inte kan läsas")
    func changedFingerprint() {
        #expect(HDRLog.decide(fileExists: true, entry: entry(fingerprint: "old"), fingerprint: "new", currentVersion: 3,
                              policy: .never, force: false) == .merge(reason: "ändrade indata eller inställningar"))
        #expect(HDRLog.decide(fileExists: true, entry: entry(fingerprint: "old"), fingerprint: "new", currentVersion: 3,
                              policy: .never, force: false, identityComplete: false) == .skip)
        #expect(HDRLog.decide(fileExists: true, entry: entry(), fingerprint: "abc", currentVersion: 3, policy: .never, force: false)
                == .skip)
    }

    @Test("Äldre motorversion: Aldrig (och Fråga tills dialogen finns) låter filen vara, Alltid gör om")
    func olderEngineVersion_followsPolicy() {
        let old = entry(version: 2)
        #expect(HDRLog.decide(fileExists: true, entry: old, fingerprint: "abc", currentVersion: 3, policy: .never, force: false) == .skip)
        #expect(HDRLog.decide(fileExists: true, entry: old, fingerprint: "abc", currentVersion: 3, policy: .ask, force: false) == .skip)
        #expect(HDRLog.decide(fileExists: true, entry: old, fingerprint: "abc", currentVersion: 3, policy: .always, force: false)
                == .merge(reason: "motorn uppdaterad (v2 → v3)"))
        // "Kör om steget" gör alltid om.
        #expect(HDRLog.decide(fileExists: true, entry: entry(), fingerprint: "abc", currentVersion: 3, policy: .never, force: true)
                == .merge(reason: "kör om steget"))
    }

    @Test("Inställningen: okänt värde tolkas som Aldrig")
    func redoPolicyParsing() {
        #expect(HDRLog.RedoPolicy(setting: "always") == .always)
        #expect(HDRLog.RedoPolicy(setting: "never") == .never)
        #expect(HDRLog.RedoPolicy(setting: "") == .never)
    }

    // MARK: - Fingerprint

    @Test("Fingerprintet ändras med NEF-identiteten och med fönsterinställningarna")
    func fingerprint_dependsOnIdentityAndWindowSettings() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("DSC_0001.NEF"), b = dir.appendingPathComponent("DSC_0002.NEF")
        try Data(repeating: 1, count: 10).write(to: a)
        try Data(repeating: 2, count: 20).write(to: b)
        func fp(_ ids: [URL], _ pull: WindowPull.Options = WindowPull.Options(), engine: String = "coreImage") -> String {
            HDRLog.fingerprint(identity: ids, engine: engine, maxDimension: 6000, align: true, sharpen: true, windowPull: pull)
        }
        let base = fp([a, b])
        #expect(base == fp([b, a])) // ordningen spelar ingen roll
        #expect(base != fp([a]))
        #expect(base != fp([a, b], WindowPull.Options(enabled: false)))
        #expect(base != fp([a, b], WindowPull.Options(strength: 0.5)))
        #expect(base != fp([a, b], WindowPull.Options(brightnessEV: 0.5)))
        #expect(base != fp([a, b], WindowPull.Options(includeLampsAndSky: true)))
        // OpenCV-motorn har ingen window pull — inställningen påverkar inte dess fingerprint.
        #expect(fp([a, b], engine: "opencv") == fp([a, b], WindowPull.Options(strength: 0.3), engine: "opencv"))
    }

    @Test("hdr.json sparas och läses tillbaka")
    func saveAndLoad() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var log = HDRLog()
        var stats = WindowPull.Stats()
        stats.applied = true
        stats.maskFraction = 0.12
        log.entries[HDRLog.key(groupId: 7)] = HDRLog.Entry(
            engineVersion: 3, fingerprint: "f", frames: ["DSC_1.NEF", "DSC_2.NEF"], manualSelection: true,
            reference: "DSC_2.NEF", windowSource: "DSC_0.NEF", window: stats, mergedAt: Date(timeIntervalSince1970: 1_000_000))
        log.save(to: dir)
        let loaded = HDRLog.load(from: dir)
        #expect(loaded?.entries["hdr_group_7"]?.window?.maskFraction == 0.12)
        #expect(loaded?.entries["hdr_group_7"]?.manualSelection == true)
        #expect(loaded?.entries["hdr_group_7"]?.mergedAt == Date(timeIntervalSince1970: 1_000_000))
    }

    // MARK: - Adoption i HDR-steget

    @Test("HDR-steget adopterar befintliga HDR utan hdr.json och gör inte om dem")
    func runHDRMerge_adoptsExistingFiles() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("in"), output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for name in ["DSC_0001", "DSC_0002", "DSC_0003"] {
            try Data(repeating: 7, count: 100).write(to: input.appendingPathComponent("\(name).NEF"))
        }
        // Sorterad leverans: TIFF i ÖVRIGA, JPEG i TITTBILDER.
        let tiff = output.appendingPathComponent("Storgatan 1 ÖVRIGA/hdr_group_1.tiff")
        let jpeg = output.appendingPathComponent("Storgatan 1 TITTBILDER/hdr_group_1.jpg")
        for url in [tiff, jpeg] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("gammal".utf8).write(to: url)
        }
        let groups: [String: Any] = ["groups": [[
            "group_id": 1, "is_bracket": true, "files": ["DSC_0001.NEF", "DSC_0002.NEF", "DSC_0003.NEF"],
            "exposures": ["1/8", "1/30", "1/125"], "suggested_hdr_indices": [1, 2],
            "datetimes": ["2026-10-02 10:00:00", "2026-10-02 10:00:01", "2026-10-02 10:00:02"]
        ]]]
        try JSONSerialization.data(withJSONObject: groups).write(to: output.appendingPathComponent("bracket_groups.json"))

        let state = PipelineState()
        state.inputDirectory = input
        state.outputDirectory = output
        let runner = PipelineRunner(state: state)
        let engineWas = AppSettings.shared.hdrEngine
        AppSettings.shared.hdrEngine = "coreImage"
        defer { AppSettings.shared.hdrEngine = engineWas }
        try await runner.runHDRMerge()

        let log = try #require(HDRLog.load(from: output))
        let entry = try #require(log.entries["hdr_group_1"])
        #expect(entry.adopted)
        #expect(entry.engineVersion == HDRLog.legacyEngineVersion)
        #expect(entry.mergedAt == nil)
        #expect(entry.frames == ["DSC_0002.NEF", "DSC_0003.NEF"])
        // Filerna rördes inte.
        #expect(try String(contentsOf: tiff, encoding: .utf8) == "gammal")
        #expect(try String(contentsOf: jpeg, encoding: .utf8) == "gammal")

        // Andra körningen: posten finns, fingerprintet stämmer → inget görs, posten oförändrad.
        try await runner.runHDRMerge()
        #expect(HDRLog.load(from: output)?.entries["hdr_group_1"] == entry)
    }

    // MARK: - EV-sortering och referens

    @Test("Exponeringarna sorteras mörkast först oavsett tagningsordning; referensen är medianen")
    func framesSortedByExposure_referenceIsMedian() {
        func frame(_ name: String, _ seconds: Double) -> HDREngine.Frame {
            HDREngine.Frame(url: URL(fileURLWithPath: "/tmp/\(name).dng"), exposureSeconds: seconds)
        }
        // Nikons ordning 0 / − / +.
        let nikon = [frame("mid", 1.0 / 30), frame("dark", 1.0 / 125), frame("bright", 1.0 / 8)]
        let ordered = HDREngine.orderedFrames(nikon)
        #expect(ordered.map { $0.url.lastPathComponent } == ["dark.dng", "mid.dng", "bright.dng"])
        #expect(ordered[HDREngine.referenceIndex(count: ordered.count)].url.lastPathComponent == "mid.dng")

        // Fem ramar: medianen är den tredje.
        let five = [frame("e", 1), frame("a", 1.0 / 250), frame("c", 1.0 / 30), frame("b", 1.0 / 60), frame("d", 1.0 / 8)]
        let sorted5 = HDREngine.orderedFrames(five)
        #expect(sorted5[HDREngine.referenceIndex(count: 5)].url.lastPathComponent == "c.dng")

        // Okänd exponeringstid: ordningen behålls.
        let unknown = [frame("x", 0), frame("y", 1.0 / 30)]
        #expect(HDREngine.orderedFrames(unknown) == unknown)
    }

    @Test("Fönsterkällan är gruppens mörkaste exponering")
    func windowSource_isDarkest() {
        let frames = [
            HDREngine.Frame(url: URL(fileURLWithPath: "/tmp/a.dng"), exposureSeconds: 1.0 / 30),
            HDREngine.Frame(url: URL(fileURLWithPath: "/tmp/b.dng"), exposureSeconds: 1.0 / 500),
            HDREngine.Frame(url: URL(fileURLWithPath: "/tmp/c.dng"), exposureSeconds: 1.0 / 8)
        ]
        #expect(HDREngine.windowSource(among: frames)?.url.lastPathComponent == "b.dng")
    }
}
