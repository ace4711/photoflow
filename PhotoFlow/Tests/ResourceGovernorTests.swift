import Foundation
import Testing
@testable import PhotoFlow

/// Fas 1c: resursvaktens gränsberäkning (en ren funktion av maskin, kostnad, minnestryck och
/// användarens inställning).
struct ResourceGovernorTests {
    private let gb = ResourceGovernor.gigabyte

    private func budget(memoryGB: UInt64, cores: Int, pressure: MemoryPressureLevel = .normal, userMax: Int = 0) -> ResourceBudget {
        ResourceBudget(physicalMemory: memoryGB * gb, activeCores: cores, pressure: pressure, userMax: userMax)
    }

    @Test("M3 Max (128 GB, 16 kärnor): HDR når taket 3, Förbättra taket 6")
    func largeMachine_hitsHardCaps() {
        let machine = budget(memoryGB: 128, cores: 16)
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.hdrCost(maxDimension: 6000), budget: machine) == 3)
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.enhanceCost(maxDimension: 6000), budget: machine) == 6)
    }

    @Test("16 GB: bara en HDR-grupp i taget (25 % fritt + reserv lämnar plats för en)")
    func smallMachine_oneHDRGroup() {
        let machine = budget(memoryGB: 16, cores: 8)
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.hdrCost(maxDimension: 6000), budget: machine) == 1)
    }

    @Test("Minnet räknas på den faktiska upplösningen: full upplösning ger färre grupper")
    func fullResolution_usesMoreMemory() {
        let machine = budget(memoryGB: 32, cores: 16)
        // 32 GB × 0,75 − 4 GB = 20 GB. 6000 px: 5 GB/grupp → 4 → taket 3. 8256 px: ~9,5 GB → 2.
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.hdrCost(maxDimension: 6000), budget: machine) == 3)
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.hdrCost(maxDimension: 0), budget: machine) == 2)
        #expect(ResourceGovernor.hdrCost(maxDimension: 0).memoryBytes > ResourceGovernor.hdrCost(maxDimension: 6000).memoryBytes)
        #expect(ResourceGovernor.hdrCost(maxDimension: 3000).memoryBytes < ResourceGovernor.hdrCost(maxDimension: 6000).memoryBytes)
    }

    @Test("Två kärnor lämnas alltid fria")
    func reservesTwoCores() {
        let cost = JobCost(memoryBytes: 1, cores: 1, hardCap: 100)
        #expect(ResourceGovernor.maxConcurrent(cost: cost, budget: budget(memoryGB: 128, cores: 16)) == 14)
        #expect(ResourceGovernor.maxConcurrent(cost: cost, budget: budget(memoryGB: 128, cores: 4)) == 2)
        #expect(ResourceGovernor.maxConcurrent(cost: cost, budget: budget(memoryGB: 128, cores: 2)) == 1)
    }

    @Test("25 % av minnet lämnas fritt (plus reserven)")
    func reservesQuarterOfMemory() {
        let cost = JobCost(memoryBytes: 1 * gb, cores: 0.01, hardCap: 1000)
        // 64 GB × 0,75 − 4 GB = 44 GB → 44 jobb à 1 GB.
        #expect(ResourceGovernor.maxConcurrent(cost: cost, budget: budget(memoryGB: 64, cores: 1000)) == 44)
    }

    @Test("Minnestryck sänker taket: varning halverar, kritiskt ger ett")
    func memoryPressure_lowersLimit() {
        let enhance = ResourceGovernor.enhanceCost(maxDimension: 6000)
        #expect(ResourceGovernor.maxConcurrent(cost: enhance, budget: budget(memoryGB: 128, cores: 16, pressure: .warning)) == 3)
        #expect(ResourceGovernor.maxConcurrent(cost: enhance, budget: budget(memoryGB: 128, cores: 16, pressure: .critical)) == 1)
        let hdr = ResourceGovernor.hdrCost(maxDimension: 6000)
        #expect(ResourceGovernor.maxConcurrent(cost: hdr, budget: budget(memoryGB: 128, cores: 16, pressure: .warning)) == 1)
    }

    @Test("Användarens tak: 1 = i följd, n = högst n, 0 = automatiskt")
    func userMax() {
        let enhance = ResourceGovernor.enhanceCost(maxDimension: 6000)
        #expect(ResourceGovernor.maxConcurrent(cost: enhance, budget: budget(memoryGB: 128, cores: 16, userMax: 1)) == 1)
        #expect(ResourceGovernor.maxConcurrent(cost: enhance, budget: budget(memoryGB: 128, cores: 16, userMax: 2)) == 2)
        #expect(ResourceGovernor.maxConcurrent(cost: enhance, budget: budget(memoryGB: 128, cores: 16, userMax: 50)) == 6)
        // Ett högt användartak trollar inte fram minne som inte finns.
        #expect(ResourceGovernor.maxConcurrent(cost: ResourceGovernor.hdrCost(maxDimension: 6000), budget: budget(memoryGB: 16, cores: 8, userMax: 6)) == 1)
    }

    @Test("Alltid minst ett jobb, även när budgeten inte räcker")
    func alwaysAtLeastOne() {
        let huge = JobCost(memoryBytes: 1_000 * gb, cores: 100, hardCap: 3)
        #expect(ResourceGovernor.maxConcurrent(cost: huge, budget: budget(memoryGB: 4, cores: 1)) == 1)
    }

    @Test("AI samtidigt med HDR: av i läge 1 och vid kritiskt minnestryck")
    func stepOverlap() {
        #expect(ResourceGovernor.allowsStepOverlap(budget: budget(memoryGB: 128, cores: 16)))
        #expect(ResourceGovernor.allowsStepOverlap(budget: budget(memoryGB: 128, cores: 16, userMax: 2)))
        #expect(!ResourceGovernor.allowsStepOverlap(budget: budget(memoryGB: 128, cores: 16, userMax: 1)))
        #expect(!ResourceGovernor.allowsStepOverlap(budget: budget(memoryGB: 128, cores: 16, pressure: .critical)))
    }

    @Test("Stegtider: prognosen blandar inte seriella och parallella körningar")
    func stepTiming_separatesModes() {
        func record(_ seconds: Double, mode: String?) -> StepTiming.Record {
            StepTiming.Record(step: "hdr", photos: 100, items: 10, seconds: seconds, finishedAt: Date(), mode: mode)
        }
        let history = [record(200, mode: nil), record(200, mode: "sequential"), record(100, mode: "parallel")]
        #expect(StepTiming.secondsPerPhoto(step: "hdr", history: history, mode: StepTiming.sequentialMode) == 2.0)
        #expect(StepTiming.secondsPerPhoto(step: "hdr", history: history, mode: StepTiming.parallelMode) == 1.0)
        // Ingen historik i läget: alla körningar används.
        #expect(StepTiming.secondsPerPhoto(step: "hdr", history: [record(200, mode: nil)], mode: StepTiming.parallelMode) == 2.0)
        #expect(StepTiming.mode(maxParallelism: 1) == StepTiming.sequentialMode)
        #expect(StepTiming.mode(maxParallelism: 0) == StepTiming.parallelMode)
    }
}
