import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `StepTiming`: medianen över tidigare körningar, vägningen mellan
/// historik och takten hittills, och lagringen i JSONL-filen.
struct StepTimingTests {

    func record(_ step: String, photos: Int, seconds: Double) -> StepTiming.Record {
        StepTiming.Record(step: step, photos: photos, items: photos, seconds: seconds, finishedAt: Date())
    }

    @Test("Sekunder per bild är medianen av de senaste körningarna för steget")
    func secondsPerPhoto_median() {
        let history = [
            record("dng", photos: 100, seconds: 100),   // 1,0
            record("dng", photos: 100, seconds: 300),   // 3,0 (avvikare)
            record("dng", photos: 200, seconds: 240),   // 1,2
            record("previews", photos: 100, seconds: 10),
        ]
        #expect(StepTiming.secondsPerPhoto(step: "dng", history: history) == 1.2)
        #expect(StepTiming.secondsPerPhoto(step: "previews", history: history) == 0.1)
        #expect(StepTiming.secondsPerPhoto(step: "hdr", history: history) == nil)
    }

    @Test("Bara de senaste körningarna räknas")
    func secondsPerPhoto_window() {
        let old = (0..<10).map { _ in record("dng", photos: 10, seconds: 100) }      // 10 s/bild
        let recent = (0..<StepTiming.historyWindow).map { _ in record("dng", photos: 10, seconds: 10) } // 1 s/bild
        #expect(StepTiming.secondsPerPhoto(step: "dng", history: old + recent) == 1.0)
    }

    @Test("Förväntad tid skalar med antalet bilder")
    func expectedDuration_scales() {
        let history = [record("dng", photos: 100, seconds: 90)]
        #expect(StepTiming.expectedDuration(step: "dng", photos: 912, history: history) == 0.9 * 912)
        #expect(StepTiming.expectedDuration(step: "dng", photos: 0, history: history) == nil)
    }

    @Test("Utan förlopp: historiken minus tiden som gått, aldrig negativ")
    func remaining_historyOnly() {
        #expect(StepTiming.remaining(elapsed: 60, processed: 0, total: 0, expected: 600) == 540)
        #expect(StepTiming.remaining(elapsed: 900, processed: 0, total: 0, expected: 600) == 0)
        #expect(StepTiming.remaining(elapsed: 60, processed: 0, total: 0, expected: nil) == nil)
    }

    @Test("Utan historik: takten hittills")
    func remaining_liveOnly() {
        // 100 av 400 på 50 s → 0,5 s/bild → 300 bilder kvar = 150 s
        #expect(StepTiming.remaining(elapsed: 50, processed: 100, total: 400, expected: nil) == 150)
    }

    @Test("Efter 25 % av steget gäller takten hittills helt")
    func remaining_liveTakesOverAtQuarter() {
        let r = StepTiming.remaining(elapsed: 50, processed: 100, total: 400, expected: 10_000)
        #expect(r == 150)
    }

    @Test("Tidigt i steget vägs historik och takt samman")
    func remaining_blendEarly() {
        // 10 av 400 (2,5 %) → vikt 0,1 för takten
        let r = StepTiming.remaining(elapsed: 10, processed: 10, total: 400, expected: 410)!
        let fromHistory = 400.0, live = 390.0
        #expect(abs(r - (fromHistory * 0.9 + live * 0.1)) < 0.0001)
    }

    @Test("De första sekunderna litar prognosen inte på takten")
    func remaining_ignoresFirstSeconds() {
        #expect(StepTiming.remaining(elapsed: 2, processed: 50, total: 400, expected: 600) == 598)
    }

    @Test("Lagringen: rader läggs till och läses tillbaka, och filen trimmas")
    func store_appendLoadTrim() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepTimingTests-\(UUID().uuidString)/step_timings.jsonl")
        let store = StepTiming.Store(fileURL: url)
        #expect(store.load().isEmpty)
        store.append(record("dng", photos: 10, seconds: 12))
        store.append(record("hdr", photos: 10, seconds: 30))
        #expect(store.load().map(\.step) == ["dng", "hdr"])

        for i in 0..<(store.maxLines - 1) {
            store.append(record("x\(i)", photos: 1, seconds: 1))
        }
        let trimmed = store.load()
        #expect(trimmed.count == store.keep)
        #expect(trimmed.last?.step == "x\(store.maxLines - 2)")
    }

    @Test("Visningsformat")
    func formatting() {
        #expect(StepTiming.format(42) == "42 s")
        #expect(StepTiming.format(12 * 60 + 20) == "12 min")
        #expect(StepTiming.format(65 * 60) == "1 h 05 min")
        #expect(StepTiming.formatExact(14 * 60 + 2) == "14m 02s")
    }
}
