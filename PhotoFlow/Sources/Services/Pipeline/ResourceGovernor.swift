import Foundation
import Dispatch

// MARK: - Fas 1c: resursvakt för parallella HDR-grupper och förbättringar
//
// Se `docs/plan-snabbare-pipeline.md` (fas 1c, avsnitt 3.3 och 7.5). Vakten räknar fram hur
// många tunga jobb av ett slag som får köras samtidigt:
//  - minst 2 kärnor lämnas fria (`reservedCores`),
//  - minst 25 % av minnet lämnas fritt (`freeMemoryFraction`), plus en fast reserv för appen
//    själv och stegen som körs samtidigt (AI-taggning m.m.),
//  - minnestryck från systemet (`DispatchSource.makeMemoryPressureSource`) sänker taket:
//    varning halverar, kritiskt ger ett jobb i taget. Pågående jobb får alltid bli klara.
//  - användarens inställning `maxParallelism` (0 = automatiskt, 1 = allt i följd).
//
// Beräkningen är en ren funktion (`maxConcurrent`) så att den går att testa; `ResourceGovernor`
// läser bara av maskinen och minnestrycket.

/// Systemets minnestryck, som `DispatchSource.makeMemoryPressureSource` rapporterar det.
nonisolated enum MemoryPressureLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case normal = 0, warning, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .normal: "normalt"
        case .warning: "varning"
        case .critical: "kritiskt"
        }
    }
}

/// Vad ett jobb av ett visst slag kostar, uppskattat ur mätningar (`timings.jsonl`,
/// toppminne per steg i `step_timings.jsonl`).
nonisolated struct JobCost: Sendable, Equatable {
    /// Toppminne per jobb, bytes.
    var memoryBytes: UInt64
    /// Kärnor per jobb i snitt (HDR och Förbättra är till stor del GPU-bundna).
    var cores: Double
    /// Högsta antal samtidiga oavsett maskin (där mätningen visar att fler inte hjälper,
    /// t.ex. för att GPU:n eller disken redan är full).
    var hardCap: Int
}

/// Maskinens resurser vid ett givet tillfälle — indata till `ResourceGovernor.maxConcurrent`.
nonisolated struct ResourceBudget: Sendable, Equatable {
    var physicalMemory: UInt64
    var activeCores: Int
    var pressure: MemoryPressureLevel = .normal
    /// Användarens tak: 0 = automatiskt, 1 = seriellt (felsökningsläge), n = högst n.
    var userMax: Int = 0
}

nonisolated enum ResourceGovernor {
    static let gigabyte: UInt64 = 1 << 30

    /// Kärnor som alltid lämnas åt resten av datorn.
    static let reservedCores = 2
    /// Andel av minnet som alltid lämnas fri.
    static let freeMemoryFraction = 0.25
    /// Minne som räknas bort från budgeten innan tunga jobb fördelas: appen själv (bildcache,
    /// UI), AI-taggningen som körs samtidigt med HDR och exiftool/DNG-processer.
    static let baseReserveBytes: UInt64 = 4 * gigabyte

    /// Mätt (fas 1c, 160 NEF, 6000 px): en HDR-grupp tar ~4,4 GB i topp; fönsterutsikten
    /// (window pull) lägger till ~0,4 GB. Avrundat uppåt till 5 GB per grupp vid 6000 px lång sida.
    static let hdrBytesAt6000px: UInt64 = 5 * gigabyte
    /// Lång sida när `hdrMaxDimension == 0` (full upplösning): Nikon Z8/Z9, 8256 px.
    static let fullResolutionLongSide = 8256

    /// Kostnad för en HDR-grupp. Minnet skalar med pixelantalet (lång sida i kvadrat).
    static func hdrCost(maxDimension: Int) -> JobCost {
        let side = Double(maxDimension > 0 ? maxDimension : fullResolutionLongSide)
        let scale = max(0.1, (side / 6000) * (side / 6000))
        return JobCost(memoryBytes: UInt64(Double(hdrBytesAt6000px) * scale), cores: 1.5, hardCap: 3)
    }

    /// Kostnad för en förbättring (RAW-rendering eller HDR-TIFF + Core Image-kedjan).
    static func enhanceCost(maxDimension: Int) -> JobCost {
        let side = Double(maxDimension > 0 ? maxDimension : fullResolutionLongSide)
        let scale = max(0.1, (side / 6000) * (side / 6000))
        return JobCost(memoryBytes: UInt64(Double(2 * gigabyte) * scale), cores: 1.0, hardCap: 6)
    }

    /// Högsta antal samtidiga jobb med kostnaden `cost` givet `budget`. Alltid minst 1.
    static func maxConcurrent(cost: JobCost, budget: ResourceBudget) -> Int {
        if budget.userMax == 1 { return 1 }
        let usableMemory = Double(budget.physicalMemory) * (1 - freeMemoryFraction) - Double(baseReserveBytes)
        let byMemory = cost.memoryBytes > 0 ? Int((max(0, usableMemory) / Double(cost.memoryBytes)).rounded(.down)) : cost.hardCap
        let usableCores = max(1, budget.activeCores - reservedCores)
        let byCores = cost.cores > 0 ? Int((Double(usableCores) / cost.cores).rounded(.down)) : cost.hardCap
        var limit = min(cost.hardCap, byMemory, byCores)
        if budget.userMax > 1 { limit = min(limit, budget.userMax) }
        switch budget.pressure {
        case .normal: break
        case .warning: limit /= 2
        case .critical: limit = 1
        }
        return max(1, limit)
    }

    /// Om oberoende steg (AI-taggning och HDR) får köras samtidigt. Av i felsökningsläget
    /// (1 = allt i följd) och när minnet inte räcker till ens en HDR-grupp bredvid AI.
    static func allowsStepOverlap(budget: ResourceBudget) -> Bool {
        budget.userMax != 1 && budget.pressure != .critical
    }

    /// Maskinens resurser just nu, med användarens inställning.
    static func currentBudget(userMax: Int) -> ResourceBudget {
        ResourceBudget(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            activeCores: ProcessInfo.processInfo.activeProcessorCount,
            pressure: MemoryPressureMonitor.shared.level,
            userMax: max(0, userMax)
        )
    }
}

/// Lyssnar på systemets minnestryck under hela appens livstid (billigt: en dispatch-källa).
/// Läses av `ResourceGovernor.currentBudget` innan varje nytt tungt jobb startas.
nonisolated final class MemoryPressureMonitor: @unchecked Sendable {
    static let shared = MemoryPressureMonitor()

    private let lock = NSLock()
    private var current: MemoryPressureLevel = .normal
    private let source: DispatchSourceMemoryPressure
    private let queue = DispatchQueue(label: "se.digido.photoflow.memorypressure", qos: .utility)

    var level: MemoryPressureLevel {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.lock.lock()
            self.current = level
            self.lock.unlock()
        }
        source.activate()
    }

    /// För tester: tvinga en nivå (återställs av nästa händelse från systemet).
    func override(_ level: MemoryPressureLevel) {
        lock.lock(); defer { lock.unlock() }
        current = level
    }
}

extension PipelineRunner {
    /// Taket för samtidiga `label`-jobb, som en funktion som läses om före varje ny start
    /// (`OrderedParallel.run`). Skriver taket i loggen första gången och när det ändras
    /// (minnestryck), så att det går att se i efterhand varför ett steg gick långsammare.
    func liveConcurrencyLimit(label: String, cost: JobCost) -> () -> Int {
        var last: Int?
        return { [unowned self] in
            let budget = ResourceGovernor.currentBudget(userMax: AppSettings.shared.maxParallelism)
            let limit = ResourceGovernor.maxConcurrent(cost: cost, budget: budget)
            if let previous = last {
                if previous != limit {
                    pipelineLog("  \(label): högst \(limit) samtidigt (var \(previous); minnestryck \(budget.pressure))")
                }
            } else {
                let mode = budget.userMax == 0 ? "automatiskt" : "inställt tak \(budget.userMax)"
                pipelineLog("  \(label): högst \(limit) samtidigt (\(mode), \(budget.activeCores) kärnor, \(budget.physicalMemory / ResourceGovernor.gigabyte) GB, minnestryck \(budget.pressure))")
            }
            last = limit
            return limit
        }
    }
}
