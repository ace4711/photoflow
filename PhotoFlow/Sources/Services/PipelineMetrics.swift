import Foundation
import os
import Darwin

/// Mätning av pipelinen (fas 1a i `docs/plan-snabbare-pipeline.md`, avsnitt 5.1).
///
/// Tre delar, alla utan inverkan på resultatet:
///  1. **Signposts** (`OSSignposter`, `se.digido.photoflow` / `pipeline`) kring varje
///     jobb och delfas — syns i Instruments (Points of Interest, System Trace).
///  2. **`timings.jsonl`** i outputmappen: en rad per jobb och delfas med steg, enhet,
///     start, slut, sekunder och bytes in/ut. Lätt att summera med `jq`.
///  3. **Resursräknare per steg** (`ResourceMeter`): processortid (egen + barnprocesser),
///     disk-I/O och toppminne. Loggas i `pipeline.log` och sparas i `StepTiming.Record`.
nonisolated enum PipelineMetrics {
    static let signposter = OSSignposter(subsystem: "se.digido.photoflow", category: "pipeline")

    /// Enheten (t.ex. `group:17`, `DSC_1234`) som jobbet gäller. Sätts av anroparen med
    /// `PipelineMetrics.$unit.withValue(...)` och ärvs av delfaserna inne i motorerna
    /// (`HDREngine.merge`, `EnhancementEngine.enhance`) utan att de behöver känna till den.
    @TaskLocal static var unit: String?

    /// Stegnamnet för delfaserna inne i en motor ("hdr", "enhance").
    @TaskLocal static var step: String?

    // MARK: - Intervall

    struct Interval {
        fileprivate let step: String
        fileprivate let unit: String?
        fileprivate let phase: String?
        fileprivate let bytesIn: Int64?
        fileprivate let start: Date
        fileprivate let signpostState: OSSignpostIntervalState
        fileprivate let name: StaticString

        /// Avslutar intervallet: signpost + en rad i `timings.jsonl`.
        func end(bytesOut: Int64? = nil) {
            let end = Date()
            PipelineMetrics.signposter.endInterval(name, signpostState)
            JobTimingLog.shared.append(JobTiming(
                step: step, unit: unit, phase: phase, start: start, end: end,
                seconds: end.timeIntervalSince(start), bytesIn: bytesIn, bytesOut: bytesOut
            ))
        }
    }

    /// Börjar ett jobb (`phase == nil`) eller en delfas av ett jobb.
    static func begin(step: String, unit: String? = nil, phase: String? = nil, bytesIn: Int64? = nil) -> Interval {
        let unit = unit ?? Self.unit
        let label = [step, unit, phase].compactMap { $0 }.joined(separator: " ")
        let id = signposter.makeSignpostID()
        if phase == nil {
            let state = signposter.beginInterval("job", id: id, "\(label, privacy: .public)")
            return Interval(step: step, unit: unit, phase: phase, bytesIn: bytesIn, start: Date(), signpostState: state, name: "job")
        } else {
            let state = signposter.beginInterval("phase", id: id, "\(label, privacy: .public)")
            return Interval(step: step, unit: unit, phase: phase, bytesIn: bytesIn, start: Date(), signpostState: state, name: "phase")
        }
    }

    /// Mäter en synkron delfas. Använder `step`/`unit` från task-lokala värden.
    @discardableResult
    static func phase<T>(_ phase: String, bytesIn: Int64? = nil, _ body: () throws -> T) rethrows -> T {
        let interval = begin(step: Self.step ?? "-", phase: phase, bytesIn: bytesIn)
        defer { interval.end() }
        return try body()
    }

    /// Mäter en asynkron delfas.
    static func phaseAsync<T>(_ phase: String, bytesIn: Int64? = nil, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(step: Self.step ?? "-", phase: phase, bytesIn: bytesIn)
        do {
            let result = try await body()
            interval.end()
            return result
        } catch {
            interval.end()
            throw error
        }
    }

    /// Mäter ett helt jobb (en enhet i ett steg), synkront.
    static func job<T>(step: String, unit: String?, bytesIn: Int64? = nil, bytesOut: ((T) -> Int64?)? = nil, _ body: () throws -> T) rethrows -> T {
        let interval = begin(step: step, unit: unit, bytesIn: bytesIn)
        do {
            let result = try body()
            interval.end(bytesOut: bytesOut?(result))
            return result
        } catch {
            interval.end()
            throw error
        }
    }

    /// Mäter ett helt jobb, asynkront. Sätter `step`/`unit` så att delfaserna ärver dem.
    static func jobAsync<T>(step: String, unit: String?, bytesIn: Int64? = nil, bytesOut: ((T) -> Int64?)? = nil, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(step: step, unit: unit, bytesIn: bytesIn)
        do {
            let result = try await $step.withValue(step) {
                try await $unit.withValue(unit) {
                    try await body()
                }
            }
            interval.end(bytesOut: bytesOut?(result))
            return result
        } catch {
            interval.end()
            throw error
        }
    }

    // MARK: - Filstorlekar

    /// Summan av filstorlekarna (saknade filer räknas som 0).
    static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(into: Int64(0)) { sum, url in
            sum += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

// MARK: - timings.jsonl

/// En rad i `timings.jsonl`.
nonisolated struct JobTiming: Codable, Equatable, Sendable {
    /// Steg ("dng", "hdr", "enhance", "metadata", "ai.vision", ...).
    var step: String
    /// Enhet inom steget ("group:17", "DSC_1234", "batch:2/4"). `nil` för stegövergripande delar.
    var unit: String?
    /// Delfas inom ett jobb ("render", "fuse", ...). `nil` för själva jobbet.
    var phase: String?
    var start: Date
    var end: Date
    var seconds: Double
    var bytesIn: Int64?
    var bytesOut: Int64?
}

/// Skriver `timings.jsonl` i den pågående körningens outputmapp. En process kör en
/// pipeline åt gången, så en delad instans räcker; `configure` pekar om den vid start.
nonisolated final class JobTimingLog: @unchecked Sendable {
    static let shared = JobTimingLog()

    private let lock = NSLock()
    private var fileURL: URL?

    static let fileName = "timings.jsonl"

    /// Används bara med `lock` hållet (`append`).
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(JobTimingLog.dateFormatter.string(from: date))
        }
        return e
    }()

    /// Börjar ett nytt spår: `timings.jsonl` i `outputDirectory` (en befintlig fil behålls och fylls på).
    func configure(outputDirectory: URL?) {
        lock.lock(); defer { lock.unlock() }
        fileURL = outputDirectory?.appendingPathComponent(Self.fileName)
    }

    func append(_ timing: JobTiming) {
        lock.lock(); defer { lock.unlock() }
        guard let fileURL, var line = try? Self.encoder.encode(timing) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }
}

// MARK: - Resursräknare

/// Resursåtgång under ett steg.
nonisolated struct StepResources: Equatable, Sendable {
    /// Processortid (användar + system) för appen och dess barnprocesser, sekunder.
    var cpuSeconds: Double
    /// Disk-I/O (läst/skrivet) för appen och barnprocesserna (se `ChildDiskTracker`).
    var diskReadBytes: Int64
    var diskWriteBytes: Int64
    /// Högsta `phys_footprint` för appen under steget (samplat ~1 Hz), MB.
    var peakMemoryMB: Double

    /// En rad för `pipeline.log`.
    func summary(wallSeconds: Double) -> String {
        let cores = wallSeconds > 0 ? cpuSeconds / wallSeconds : 0
        return String(
            format: "CPU %.1f s (%.1f kärnor i snitt), disk läst %.0f MB / skriven %.0f MB, toppminne %.0f MB",
            cpuSeconds, cores, Double(diskReadBytes) / 1_048_576, Double(diskWriteBytes) / 1_048_576, peakMemoryMB
        )
    }
}

/// Ögonblicksbild av processens räknare.
nonisolated struct ResourceSnapshot: Sendable {
    var cpuSeconds: Double
    var diskRead: UInt64
    var diskWritten: UInt64
    var footprintBytes: UInt64

    static func take() -> ResourceSnapshot {
        var cpu = 0.0
        for who in [RUSAGE_SELF, RUSAGE_CHILDREN] {
            var usage = rusage()
            if getrusage(who, &usage) == 0 {
                cpu += Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                cpu += Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            }
        }
        let info = ChildDiskTracker.rusageV4(pid: getpid())
        return ResourceSnapshot(
            cpuSeconds: cpu,
            diskRead: (info?.ri_diskio_bytesread ?? 0) + ChildDiskTracker.shared.totals.read,
            diskWritten: (info?.ri_diskio_byteswritten ?? 0) + ChildDiskTracker.shared.totals.written,
            footprintBytes: info?.ri_phys_footprint ?? 0
        )
    }
}

/// Disk-I/O från barnprocesser (exiftool, Adobe DNG Converter). `proc_pid_rusage` ger bara
/// I/O för processen själv och `getrusage(RUSAGE_CHILDREN)` har inga användbara
/// bytesräknare på macOS, så `runProcess` och `HDRWriter.writeMetadata` låter en
/// `Observer` läsa barnets räknare var 50:e ms medan det körs och lägger sista värdet
/// till summan när det är klart. Korta processer (några ms) kan därför underskattas något.
nonisolated final class ChildDiskTracker: @unchecked Sendable {
    static let shared = ChildDiskTracker()

    private let lock = NSLock()
    private var read: UInt64 = 0
    private var written: UInt64 = 0

    var totals: (read: UInt64, written: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (read, written)
    }

    fileprivate func add(read r: UInt64, written w: UInt64) {
        lock.lock(); defer { lock.unlock() }
        read += r
        written += w
    }

    static func rusageV4(pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info : nil
    }

    /// Följer ett barn tills `finish()` anropas (efter `waitUntilExit`).
    final class Observer: @unchecked Sendable {
        private let pid: pid_t
        private let timer: DispatchSourceTimer
        private let lock = NSLock()
        private var lastRead: UInt64 = 0
        private var lastWritten: UInt64 = 0
        private var finished = false

        fileprivate init(pid: pid_t) {
            self.pid = pid
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }

        private func sample() {
            guard let info = ChildDiskTracker.rusageV4(pid: pid) else { return }
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            lastRead = info.ri_diskio_bytesread
            lastWritten = info.ri_diskio_byteswritten
        }

        func finish() {
            timer.cancel()
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let (r, w) = (lastRead, lastWritten)
            lock.unlock()
            ChildDiskTracker.shared.add(read: r, written: w)
        }
    }

    static func observe(_ process: Process) -> Observer {
        Observer(pid: process.processIdentifier)
    }
}

/// Mäter ett steg: tar en ögonblicksbild vid start, samplar toppminnet ~1 Hz och ger
/// differensen i `finish()`.
nonisolated final class ResourceMeter: @unchecked Sendable {
    private let start: ResourceSnapshot
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var peakFootprint: UInt64
    private var stopped = false

    init() {
        start = ResourceSnapshot.take()
        peakFootprint = start.footprintBytes
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { stop() }

    private func sample() {
        let footprint = ChildDiskTracker.rusageV4(pid: getpid())?.ri_phys_footprint ?? 0
        lock.lock(); defer { lock.unlock() }
        peakFootprint = max(peakFootprint, footprint)
    }

    private func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already { timer.cancel() }
    }

    /// Avbryter mätningen utan resultat (steget avbröts eller felade).
    func cancel() { stop() }

    /// Avslutar mätningen och ger resursåtgången sedan start.
    func finish() -> StepResources {
        let end = ResourceSnapshot.take()
        stop()
        lock.lock()
        let peak = max(peakFootprint, end.footprintBytes)
        lock.unlock()
        return StepResources(
            cpuSeconds: max(0, end.cpuSeconds - start.cpuSeconds),
            diskReadBytes: Int64(clamping: end.diskRead &- min(start.diskRead, end.diskRead)),
            diskWriteBytes: Int64(clamping: end.diskWritten &- min(start.diskWritten, end.diskWritten)),
            peakMemoryMB: Double(peak) / 1_048_576
        )
    }
}
