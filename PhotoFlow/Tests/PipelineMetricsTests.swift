import Foundation
import Testing
@testable import PhotoFlow

/// Fas 1a: mätningen — `timings.jsonl`, resursräknare och bakåtkompatibel avkodning av `StepTiming.Record`.
// Serialiserad: testerna pekar om den delade `JobTimingLog`, och raderna filtreras på unika stegnamn
// eftersom andra tester (motorerna) också skriver delfaser medan loggen är konfigurerad.
@Suite(.serialized)
@MainActor
struct PipelineMetricsTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineMetricsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Gamla StepTiming-poster utan resursfält avkodas som förut (fälten blir nil)")
    func stepTimingRecord_decodesOldLines() throws {
        let old = #"{"finishedAt":"2026-10-02T10:00:00Z","items":97,"photos":912,"seconds":480.5,"settings":{"hdrEngine":"coreImage"},"step":"createHDR"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(StepTiming.Record.self, from: Data(old.utf8))
        #expect(record.step == "createHDR")
        #expect(record.photos == 912)
        #expect(record.seconds == 480.5)
        #expect(record.cpuSeconds == nil)
        #expect(record.diskReadBytes == nil)
        #expect(record.diskWriteBytes == nil)
        #expect(record.peakMemoryMB == nil)
        #expect(record.mode == nil)
    }

    @Test("Nya poster med resursdata skrivs och läses tillbaka, och gamla rader i samma fil läses med")
    func stepTimingStore_roundTripsNewAndOld() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("step_timings.jsonl")
        let old = #"{"finishedAt":"2026-10-02T10:00:00Z","items":1,"photos":10,"seconds":5,"settings":{},"step":"dng"}"# + "\n"
        try old.write(to: file, atomically: true, encoding: .utf8)

        let store = StepTiming.Store(fileURL: file)
        let record = StepTiming.Record(
            step: "dng", photos: 10, items: 10, seconds: 6, finishedAt: Date(timeIntervalSince1970: 1_790_000_000),
            cpuSeconds: 12.5, diskReadBytes: 1_000, diskWriteBytes: 2_000, peakMemoryMB: 321.5, mode: "sequential"
        )
        store.append(record)

        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].cpuSeconds == nil)
        #expect(loaded[1] == record)
    }

    private func lines(_ dir: URL, step: String) throws -> [[String: Any]] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("timings.jsonl"), encoding: .utf8)) ?? ""
        return try text.split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["step"] as? String == step }
    }

    @Test("timings.jsonl: en rad per jobb med steg, enhet, start/slut, sekunder och bytes")
    func jobTimingLog_writesJSONL() throws {
        let dir = tempDir()
        let step = "testhdr-\(UUID().uuidString)"
        JobTimingLog.shared.configure(outputDirectory: dir)
        defer { JobTimingLog.shared.configure(outputDirectory: nil) }

        let result = PipelineMetrics.job(step: step, unit: "group:3", bytesIn: 100, bytesOut: { (_: Int) in 40 }) { 7 }
        #expect(result == 7)
        PipelineMetrics.begin(step: step, unit: "group:3", phase: "fuse", bytesIn: nil).end()

        let objects = try lines(dir, step: step)
        #expect(objects.count == 2)
        let first = try #require(objects.first { $0["phase"] == nil })
        #expect(first["unit"] as? String == "group:3")
        #expect(first["bytesIn"] as? Int == 100)
        #expect(first["bytesOut"] as? Int == 40)
        #expect(first["seconds"] is Double)
        #expect((first["start"] as? String)?.hasSuffix("Z") == true)
        #expect((first["end"] as? String)?.hasSuffix("Z") == true)
        let second = try #require(objects.first { $0["phase"] as? String == "fuse" })
        #expect(second["unit"] as? String == "group:3")
    }

    @Test("Delfaser ärver steg och enhet från jobbet via task-lokala värden")
    func phases_inheritStepAndUnit() async throws {
        let dir = tempDir()
        let step = "testenhance-\(UUID().uuidString)"
        JobTimingLog.shared.configure(outputDirectory: dir)
        defer { JobTimingLog.shared.configure(outputDirectory: nil) }

        await PipelineMetrics.jobAsync(step: step, unit: "DSC_1") { () async -> Void in
            PipelineMetrics.phase("render") {}
        }
        let phase = try #require(try lines(dir, step: step).first { $0["phase"] as? String == "render" })
        #expect(phase["unit"] as? String == "DSC_1")
    }

    @Test("ResourceMeter ger processortid och toppminne för arbete i processen")
    func resourceMeter_measuresCPUAndMemory() {
        let meter = ResourceMeter()
        var x = 0.0
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { x += sin(x) + 1 }   // bränn processortid
        #expect(x != 0)
        let resources = meter.finish()
        #expect(resources.cpuSeconds > 0.1)
        #expect(resources.peakMemoryMB > 1)
        #expect(resources.diskReadBytes >= 0)
    }

    @Test("completeStep lägger resursdata och mode i stegtiderna (och loggar raden i pipeline.log)")
    func completeStep_recordsResources() async throws {
        let state = PipelineState()
        state.outputDirectory = tempDir()
        var logged: [String] = []
        state.pipelineLogFileWriter = { logged.append($0) }

        state.updateStep(.convertToDNG, phase: .active)
        try await Task.sleep(nanoseconds: 700_000_000)
        state.completeStep(.convertToDNG, count: 3)

        #expect(logged.contains { $0.contains("Resurser") && $0.contains("toppminne") })
    }
}
