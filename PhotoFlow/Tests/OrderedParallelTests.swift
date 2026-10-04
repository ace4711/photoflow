import Foundation
import Testing
@testable import PhotoFlow

/// Fas 1c: `OrderedParallel` — jobben körs samtidigt, men resultaten lämnas i jobbordning,
/// taket respekteras (även när det sänks mitt i), fel isoleras och avbrott tar med det som
/// hann bli klart.
@MainActor
struct OrderedParallelTests {

    /// Räknar hur många jobb som pågår samtidigt (jobben körs utanför MainActor).
    nonisolated final class ConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var peak = 0
        private(set) var started: [Int] = []
        private(set) var completed: [Int] = []

        func begin(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            running += 1
            peak = max(peak, running)
            started.append(index)
        }

        func end(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            running -= 1
            completed.append(index)
        }

        var snapshot: (peak: Int, started: [Int], completed: [Int]) {
            lock.lock(); defer { lock.unlock() }
            return (peak, started, completed)
        }

        func resetPeak() {
            lock.lock(); defer { lock.unlock() }
            peak = running
        }
    }

    /// Delat, föränderligt värde för closures som körs i en egen `Task`.
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Jobb `i` sover en "slumpad" men deterministisk tid så att de blir klara i en annan
    /// ordning än de startades.
    nonisolated private static func delay(for index: Int) -> UInt64 {
        UInt64((index * 7919) % 5 + 1) * 4_000_000
    }

    private func runJobs(count: Int, limit: Int, probe: ConcurrencyProbe, fail: Set<Int> = []) async throws -> [(Int, String)] {
        var finished: [(Int, String)] = []
        try await OrderedParallel.run(
            count: count,
            limit: { limit },
            gate: { try Task.checkCancellation() },
            prepare: { index -> @Sendable () async throws -> String in
                return {
                    probe.begin(index)
                    defer { probe.end(index) }
                    try await Task.sleep(nanoseconds: Self.delay(for: index))
                    if fail.contains(index) { throw CocoaError(.fileReadCorruptFile) }
                    return "resultat \(index)"
                }
            },
            finish: { index, result in
                switch result {
                case .success(let value): finished.append((index, value))
                case .failure: finished.append((index, "fel"))
                }
            }
        )
        return finished
    }

    @Test("Resultaten lämnas i jobbordning och blir desamma som seriellt, trots annan klar-ordning")
    func resultsInOrder_sameAsSerial() async throws {
        let serialProbe = ConcurrencyProbe()
        let serial = try await runJobs(count: 24, limit: 1, probe: serialProbe)
        let parallelProbe = ConcurrencyProbe()
        let parallel = try await runJobs(count: 24, limit: 4, probe: parallelProbe)

        #expect(serial.map(\.0) == Array(0..<24))
        #expect(parallel.map(\.0) == serial.map(\.0))
        #expect(parallel.map(\.1) == serial.map(\.1))
        #expect(serialProbe.snapshot.peak == 1)
        #expect(parallelProbe.snapshot.peak == 4)
        // Jobben blev faktiskt klara i en annan ordning än de lämnades.
        #expect(parallelProbe.snapshot.completed != Array(0..<24))
    }

    @Test("Ett fel i ett jobb avbryter inte de andra och lämnas på sin plats i ordningen")
    func failureIsolated() async throws {
        let probe = ConcurrencyProbe()
        let results = try await runJobs(count: 10, limit: 3, probe: probe, fail: [4])
        #expect(results.map(\.0) == Array(0..<10))
        #expect(results[4].1 == "fel")
        #expect(results.filter { $0.1 == "fel" }.count == 1)
    }

    @Test("Taket läses om före varje start: sänkt tak gäller för nya jobb")
    func limitLoweredMidRun() async throws {
        let probe = ConcurrencyProbe()
        var limit = 4
        var finishedCount = 0
        var peakAfterLowering = 0
        try await OrderedParallel.run(
            count: 30,
            limit: { limit },
            gate: { try Task.checkCancellation() },
            prepare: { index -> @Sendable () async throws -> Int in
                return {
                    probe.begin(index)
                    defer { probe.end(index) }
                    try await Task.sleep(nanoseconds: 5_000_000)
                    return index
                }
            },
            finish: { _, _ in
                finishedCount += 1
                if finishedCount == 8 {
                    limit = 1
                } else if finishedCount > 12 {
                    // Efter att de som redan pågick blivit klara kör högst ett jobb i taget.
                    peakAfterLowering = max(peakAfterLowering, probe.snapshot.started.count - probe.snapshot.completed.count)
                }
            }
        )
        #expect(finishedCount == 30)
        #expect(peakAfterLowering <= 1)
    }

    @Test("Avbrott mitt i: inga nya jobb startar, pågående avbryts, färdiga resultat lämnas ändå")
    func cancellationMidRun() async throws {
        let probe = ConcurrencyProbe()
        let finished = Box<[Int]>([])
        let task = Task { @MainActor in
            try await OrderedParallel.run(
                count: 1_000,
                limit: { 4 },
                gate: { try Task.checkCancellation() },
                prepare: { index -> @Sendable () async throws -> Int in
                    return {
                        probe.begin(index)
                        defer { probe.end(index) }
                        try await Task.sleep(nanoseconds: Self.delay(for: index))
                        return index
                    }
                },
                finish: { index, _ in finished.value.append(index) }
            )
        }
        while finished.value.count < 10 { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let snapshot = probe.snapshot
        #expect(snapshot.started.count < 1_000)
        // Inga jobb pågår efteråt (alla väntades in).
        #expect(snapshot.started.count == snapshot.completed.count)
        // Varje resultat lämnades högst en gång, och de första lämnades i ordning.
        #expect(Set(finished.value).count == finished.value.count)
        #expect(Array(finished.value.prefix(10)) == Array(0..<10))
    }

    @Test("Paus: inga nya jobb startar medan något pågår och körningen är pausad")
    func pauseStopsNewLaunches() async throws {
        let probe = ConcurrencyProbe()
        let paused = Box(false)
        var startedWhilePaused = 0
        var finishedCount = 0
        try await OrderedParallel.run(
            count: 12,
            limit: { 3 },
            gate: {
                // Som `waitIfPaused`: vänta tills pausen släpps.
                while paused.value { try await Task.sleep(nanoseconds: 1_000_000) }
            },
            isPaused: { paused.value },
            prepare: { index -> @Sendable () async throws -> Int in
                if paused.value { startedWhilePaused += 1 }
                return {
                    probe.begin(index)
                    defer { probe.end(index) }
                    try await Task.sleep(nanoseconds: 3_000_000)
                    return index
                }
            },
            finish: { _, _ in
                finishedCount += 1
                if finishedCount == 3 {
                    paused.value = true
                    // Släpp pausen lite senare (som användaren som trycker "Fortsätt").
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        paused.value = false
                    }
                }
            }
        )
        #expect(finishedCount == 12)
        #expect(startedWhilePaused == 0)
    }
}
