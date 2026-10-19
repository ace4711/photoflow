import Foundation
import Testing
import CoreGraphics
@testable import PhotoFlow

/// HDR-motorn "Lightroom Classic": trigger, statustolkning, utfilsmappning och reservval
/// (ingen riktig Lightroom behövs).
@MainActor
struct LightroomRenderTests {

    private let jobs: [LightroomRender.Job] = [
        .init(groupId: 3, files: ["/o/lr_staging/group_3/a.NEF", "/o/lr_staging/group_3/b.NEF"], outputPath: "/o/hdr/hdr_group_3.tiff"),
        .init(groupId: 7, files: ["/o/lr_staging/group_7/c.NEF", "/o/lr_staging/group_7/d.NEF", "/o/lr_staging/group_7/e.NEF"],
              outputPath: "/o/Adress 1/hdr_group_7.tiff"),
    ]

    private func statusJSON(_ results: [[String: Any]], state: String = "complete", version: String? = "1.5",
                            current: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["status": state, "results": results]
        if let version { object["plugin_version"] = version }
        if let current { object["current"] = current }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Trigger

    @Test("Triggern: läget render, en post per grupp med exakt output_path och mappen som output_dir")
    func triggerPayload_mapsOutputPaths() throws {
        let payload = LightroomRender.triggerPayload(jobs: jobs)
        #expect(payload["mode"] as? String == "render")
        #expect(payload["export_format"] as? String == "TIFF")
        #expect(payload["headless"] as? Bool == false)
        #expect(payload["cleanup_catalog"] as? Bool == true)
        let groups = try #require(payload["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups[0]["group_id"] as? Int == 3)
        #expect(groups[0]["output_path"] as? String == "/o/hdr/hdr_group_3.tiff")
        #expect(groups[0]["output_dir"] as? String == "/o/hdr")
        #expect(groups[1]["output_path"] as? String == "/o/Adress 1/hdr_group_7.tiff")
        #expect((groups[1]["files"] as? [String])?.count == 3)
        // Måste vara serialiserbar JSON.
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test("Mellanlagringsmappen är per grupp under outputmappen")
    func stagingDirectory() {
        let dir = LightroomRender.stagingDirectory(outputDir: URL(fileURLWithPath: "/o"), groupId: 12)
        #expect(dir.path == "/o/lr_staging/group_12")
    }

    // MARK: - Status

    @Test("Statusen tolkas: resultat, version och aktuell grupp")
    func parseStatus() throws {
        let data = statusJSON([
            ["group_id": 3, "status": "ok", "message": "HDR klar", "export": "/o/hdr/hdr_group_3.tiff", "seconds": 42],
            ["group_id": 7, "status": "error", "message": "Ingen ny -HDR.dng"],
        ], state: "running", current: ["group_id": 9, "index": 3, "total": 5])
        let status = try #require(LightroomRender.parseStatus(data: data))
        #expect(status.state == "running" && !status.isComplete)
        #expect(status.pluginVersion == "1.5")
        #expect(status.results.count == 2)
        #expect(status.results[0] == .init(groupId: 3, status: "ok", message: "HDR klar", export: "/o/hdr/hdr_group_3.tiff", seconds: 42))
        #expect(status.results[1].export == nil)
        #expect(status.currentGroupId == 9 && status.currentIndex == 3 && status.total == 5)
    }

    @Test("En halvskriven eller trasig statusfil ger nil, inte ett fel")
    func parseStatus_garbage() {
        #expect(LightroomRender.parseStatus(data: Data("{\"status\":\"run".utf8)) == nil)
        #expect(LightroomRender.parseStatus(data: Data()) == nil)
    }

    @Test("lr_done.json: klar bara vid status complete")
    func doneParsing() {
        #expect(LightroomRender.isDone(doneData: Data(#"{"status":"complete","groups":2,"ok":2,"mode":"render"}"#.utf8)))
        #expect(!LightroomRender.isDone(doneData: Data(#"{"status":"running"}"#.utf8)))
        #expect(!LightroomRender.isDone(doneData: nil))
        #expect(!LightroomRender.isDone(doneData: Data("nonsens".utf8)))
    }

    @Test("Pluginversioner jämförs numeriskt")
    func versionComparison() {
        #expect(LightroomRender.versionAtLeast("1.5"))
        #expect(LightroomRender.versionAtLeast("1.10"))
        #expect(LightroomRender.versionAtLeast("2.0"))
        #expect(!LightroomRender.versionAtLeast("1.4"))
        #expect(!LightroomRender.versionAtLeast(nil))
    }

    // MARK: - Utfall och reserv

    @Test("Utfall: ok + giltig fil = rendered; fel, saknat svar och ogiltig fil = failed")
    func outcomes_mixed() throws {
        let status = try #require(LightroomRender.parseStatus(data: statusJSON([
            ["group_id": 3, "status": "ok", "message": "", "export": "/o/hdr/hdr_group_3.tiff"],
            ["group_id": 7, "status": "error", "message": "Merge kunde inte klickas"],
        ])))
        let outcomes = LightroomRender.outcomes(jobs: jobs, status: status) { _ in true }
        #expect(outcomes[3] == .rendered)
        #expect(outcomes[7] == .failed("Merge kunde inte klickas"))

        let invalid = LightroomRender.outcomes(jobs: jobs, status: status) { _ in false }
        #expect(invalid[3]?.isRendered == false)

        let extra = LightroomRender.Job(groupId: 9, files: ["x", "y"], outputPath: "/o/hdr/hdr_group_9.tiff")
        let missing = LightroomRender.outcomes(jobs: jobs + [extra], status: status) { _ in true }
        #expect(missing[9]?.isRendered == false)
    }

    @Test("Utfall: saknad status och för gammalt plugin ger reserv för alla grupper")
    func outcomes_noStatusOrOldPlugin() throws {
        let none = LightroomRender.outcomes(jobs: jobs, status: nil) { _ in true }
        #expect(none.values.allSatisfy { !$0.isRendered })

        let old = try #require(LightroomRender.parseStatus(data: statusJSON([
            ["group_id": 3, "status": "ok", "message": "HDR utlöst för 3 foton"],
            ["group_id": 7, "status": "ok", "message": "HDR utlöst för 3 foton"],
        ], version: "1.4")))
        let oldOutcomes = LightroomRender.outcomes(jobs: jobs, status: old) { _ in true }
        #expect(LightroomRender.fallbackGroupIds(jobs: jobs, outcomes: oldOutcomes) == [3, 7])
    }

    @Test("Tidsgräns: statusen är inte klar, grupper utan resultat blir reserv men färdiga behålls")
    func outcomes_timedOut() throws {
        let partial = try #require(LightroomRender.parseStatus(data: statusJSON([
            ["group_id": 3, "status": "ok", "message": "", "export": "/o/hdr/hdr_group_3.tiff"],
        ], state: "running")))
        let outcomes = LightroomRender.outcomes(jobs: jobs, status: partial) { _ in true }
        #expect(LightroomRender.fallbackGroupIds(jobs: jobs, outcomes: outcomes) == [7])
        if case .failed(let reason) = outcomes[7] { #expect(reason.contains("tidsgräns")) } else { Issue.record("förväntade failed") }
    }

    @Test("Tidsgränsen växer med antal grupper")
    func timeoutScalesWithGroups() {
        #expect(LightroomRender.overallTimeoutSeconds(groupCount: 20) > LightroomRender.overallTimeoutSeconds(groupCount: 2))
        #expect(LightroomRender.overallTimeoutSeconds(groupCount: 1) >= 300)
    }

    // MARK: - Filvalidering

    @Test("Bildvalidering: saknad, för liten och trasig fil underkänns, en riktig TIFF godkänns")
    func imageValidation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomRenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!LightroomRender.isValidImage(atPath: dir.appendingPathComponent("saknas.tiff").path))
        let small = dir.appendingPathComponent("small.tiff")
        try Data(repeating: 0, count: 100).write(to: small)
        #expect(!LightroomRender.isValidImage(atPath: small.path))
        let junk = dir.appendingPathComponent("junk.tiff")
        try Data(repeating: 7, count: 200_000).write(to: junk)
        #expect(!LightroomRender.isValidImage(atPath: junk.path))

        let width = 200, height = 150
        let pixels = (0..<(width * height * 4)).map { Float($0 % 255) / 255 }
        let cg = try HDRWriter.makeRGB16CGImage(pixels: pixels, width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let good = dir.appendingPathComponent("good.tiff")
        try HDRWriter.writeTIFFDirect(cg, to: good)
        #expect(LightroomRender.isValidImage(atPath: good.path))

        // JPEG-förhandsvisningen av exporten.
        let jpeg = dir.appendingPathComponent("good.jpg")
        try HDRWriter.writeJPEG(fromImageAt: good, to: jpeg, maxDimension: 100, quality: 0.9)
        #expect(FileManager.default.fileExists(atPath: jpeg.path))
    }

    // MARK: - Fingerprint, förbättring, förflygning

    @Test("Fingerprintet skiljer Lightroom från Core Image men ignorerar Core Image-inställningar")
    func fingerprint_engineSwitch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomRenderFP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("DSC_1.NEF")
        try Data(repeating: 1, count: 10).write(to: a)
        func fp(_ engine: String, _ max: Int = 6000, _ pull: WindowPull.Options = WindowPull.Options()) -> String {
            HDRLog.fingerprint(identity: [a], engine: engine, maxDimension: max, align: true, sharpen: true, windowPull: pull)
        }
        #expect(fp("lightroom") != fp("coreImage"))
        #expect(fp("lightroom") == fp("lightroom", 0, WindowPull.Options(enabled: false)))
    }

    @Test("Förbättra hoppas över bara för Lightroom-HDR när inställningen är på")
    func enhancePassthroughDecision() {
        let job = PipelineRunner.EnhanceJob(key: "hdr_group_1", kind: .hdr, source: URL(fileURLWithPath: "/o/hdr_group_1.tiff"), label: "x")
        var log = HDRLog()
        log.entries["hdr_group_1"] = HDRLog.Entry(engineVersion: 7, fingerprint: "f", engine: "lightroom")
        #expect(PipelineRunner.isLightroomPassthrough(job, hdrLog: log, skipSetting: true))
        #expect(!PipelineRunner.isLightroomPassthrough(job, hdrLog: log, skipSetting: false))
        log.entries["hdr_group_1"]?.engine = "coreImage"
        #expect(!PipelineRunner.isLightroomPassthrough(job, hdrLog: log, skipSetting: true))
        var dng = job; dng.kind = .dng
        log.entries["hdr_group_1"]?.engine = "lightroom"
        #expect(!PipelineRunner.isLightroomPassthrough(dng, hdrLog: log, skipSetting: true))
        #expect(!PipelineRunner.isLightroomPassthrough(job, hdrLog: nil, skipSetting: true))
    }

    @Test("hdr.json: motorfältet sparas och äldre poster utan det går att läsa")
    func hdrLogEngineRoundTrip() throws {
        var log = HDRLog()
        log.entries["hdr_group_1"] = HDRLog.Entry(engineVersion: 7, fingerprint: "f", engine: "lightroom")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomRenderLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        log.save(to: dir)
        #expect(HDRLog.load(from: dir)?.entries["hdr_group_1"]?.engine == "lightroom")
        let legacy = #"{"version":1,"updatedAt":"2026-10-01T10:00:00Z","entries":{"hdr_group_2":{"engineVersion":6,"fingerprint":"x"}}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent(HDRLog.fileName))
        #expect(HDRLog.load(from: dir)?.entries["hdr_group_2"]?.engine == nil)
    }
}
