import Foundation
import Testing
@testable import PhotoFlow

/// Tests for Fas 3e's FSEvents-based watching: the debounce decision
/// (`FSEventDebouncer`, clock injected via explicit `Date`s — no real timers
/// or `sleep`) and the file-stability check
/// (`WatchService.isFileStable`/`stableFiles`, pure functions over size
/// dictionaries) that together replace the old fixed-interval `Timer` poll as
/// the primary way new files are detected.
struct WatchServiceDebounceStabilityTests {

    // MARK: - FSEventDebouncer

    @Test("Ingen händelse registrerad ännu -> tick ger aldrig true")
    func tick_withNoEvent_isAlwaysFalse() {
        let debouncer = FSEventDebouncer(interval: 2.0)
        let now = Date()
        #expect(debouncer.tick(now: now) == false)
        #expect(debouncer.tick(now: now.addingTimeInterval(10)) == false)
    }

    @Test("tick() är false innan debounce-fönstret gått ut")
    func tick_beforeIntervalElapsed_isFalse() {
        let debouncer = FSEventDebouncer(interval: 2.0)
        let t0 = Date()
        debouncer.recordEvent(at: t0)
        #expect(debouncer.tick(now: t0.addingTimeInterval(1.0)) == false)
        #expect(debouncer.tick(now: t0.addingTimeInterval(1.9)) == false)
    }

    @Test("tick() blir true precis när debounce-fönstret gått ut sedan senaste händelsen")
    func tick_afterIntervalElapsed_isTrue() {
        let debouncer = FSEventDebouncer(interval: 2.0)
        let t0 = Date()
        debouncer.recordEvent(at: t0)
        #expect(debouncer.tick(now: t0.addingTimeInterval(2.0)) == true)
    }

    @Test("En skur av händelser skjuter upp debounce-fönstret till den SENASTE händelsen")
    func burstOfEvents_debouncesToLastEvent() {
        let debouncer = FSEventDebouncer(interval: 2.0)
        let t0 = Date()
        debouncer.recordEvent(at: t0)
        debouncer.recordEvent(at: t0.addingTimeInterval(0.5))
        debouncer.recordEvent(at: t0.addingTimeInterval(1.0))

        // 2s efter den FÖRSTA händelsen har fönstret inte gått ut, eftersom
        // fler händelser kom in under tiden.
        #expect(debouncer.tick(now: t0.addingTimeInterval(2.0)) == false)
        // Men 2s efter den SISTA händelsen har det.
        #expect(debouncer.tick(now: t0.addingTimeInterval(3.0)) == true)
    }

    @Test("tick() utlöser bara EN gång per skur, sedan nollställs den till nästa skur upptäcks")
    func tick_firesOnlyOncePerBurst() {
        let debouncer = FSEventDebouncer(interval: 2.0)
        let t0 = Date()
        debouncer.recordEvent(at: t0)

        #expect(debouncer.tick(now: t0.addingTimeInterval(2.0)) == true)
        // Samma "tystnad" fortsätter — ska inte utlösa igen.
        #expect(debouncer.tick(now: t0.addingTimeInterval(2.5)) == false)
        #expect(debouncer.tick(now: t0.addingTimeInterval(100)) == false)

        // En ny händelse startar en ny skur.
        debouncer.recordEvent(at: t0.addingTimeInterval(100))
        #expect(debouncer.tick(now: t0.addingTimeInterval(101.9)) == false)
        #expect(debouncer.tick(now: t0.addingTimeInterval(102.0)) == true)
    }

    // MARK: - Stabilitetskontroll (väntar tills filstorlekar slutat växa)

    @Test("isFileStable: samma storlek i båda mätningarna är stabil")
    func isFileStable_sameSize_isStable() {
        #expect(WatchService.isFileStable(sizeBefore: 1_000, sizeAfter: 1_000) == true)
    }

    @Test("isFileStable: växande storlek (kopiering pågår) är inte stabil")
    func isFileStable_growingSize_isNotStable() {
        #expect(WatchService.isFileStable(sizeBefore: 1_000, sizeAfter: 50_000) == false)
    }

    @Test("isFileStable: saknad mätning (t.ex. filen försvann) är inte stabil")
    func isFileStable_missingMeasurement_isNotStable() {
        #expect(WatchService.isFileStable(sizeBefore: nil, sizeAfter: 1_000) == false)
        #expect(WatchService.isFileStable(sizeBefore: 1_000, sizeAfter: nil) == false)
        #expect(WatchService.isFileStable(sizeBefore: nil, sizeAfter: nil) == false)
    }

    @Test("stableFiles filtrerar bort filer som fortfarande växer, en SD-kortskopiering mitt i")
    func stableFiles_filtersOutStillGrowingFiles() {
        let done1 = URL(fileURLWithPath: "/input/DSC_0001.NEF")
        let done2 = URL(fileURLWithPath: "/input/DSC_0002.NEF")
        let copying = URL(fileURLWithPath: "/input/DSC_0003.NEF")

        let sizesBefore: [URL: Int64] = [done1: 24_000_000, done2: 24_100_000, copying: 4_000_000]
        let sizesAfter: [URL: Int64] = [done1: 24_000_000, done2: 24_100_000, copying: 9_500_000]

        let result = WatchService.stableFiles([done1, done2, copying], sizesBefore: sizesBefore, sizesAfter: sizesAfter)

        #expect(Set(result) == Set([done1, done2]))
    }

    @Test("stableFiles: tom lista ger tom lista")
    func stableFiles_emptyInput_isEmpty() {
        #expect(WatchService.stableFiles([], sizesBefore: [:], sizesAfter: [:]).isEmpty)
    }
}
