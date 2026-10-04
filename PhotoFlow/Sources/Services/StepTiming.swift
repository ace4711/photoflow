import Foundation

/// Uppmätta stegtider över körningar, och prognoser byggda på dem.
///
/// Varje avslutat steg loggas som en rad i
/// `~/Library/Application Support/PhotoFlow/step_timings.jsonl` (en JSON-rad per
/// steg och körning — lätt att läsa och att lägga till i utan att skriva om
/// filen). Sessionsmanifestet (`photoflow_session.json`) har fortfarande varje
/// sessions egna tider; den här filen är det som går ATT jämföra över
/// körningar, och det prognoserna bygger på.
///
/// Prognosmodellen är medvetet enkel: sekunder per bild för varje steg (median
/// av de senaste körningarna) gånger antalet bilder i körningen. För steget som
/// pågår vägs den mot den faktiska takten hittills, och den faktiska takten tar
/// över allt mer ju längre steget kommit.
nonisolated enum StepTiming {

    nonisolated struct Record: Codable, Equatable, Sendable {
        /// `DashboardStep.manifestKey`.
        var step: String
        /// Bilder (NEF) i körningen — gemensam skala för alla steg.
        var photos: Int
        /// Stegets eget antal (t.ex. HDR-grupper), om det rapporterade något.
        var items: Int
        var seconds: Double
        var finishedAt: Date
        /// Inställningar som påverkar tiden (HDR-motor m.m.), för senare jämförelser.
        var settings: [String: String] = [:]
        // Resursdata per steg (fas 1a, se `ResourceMeter`). Valfria så att poster skrivna
        // före fälten fanns avkodas som förut (`nil`).
        /// Processortid (app + barnprocesser), sekunder.
        var cpuSeconds: Double? = nil
        /// Disk-I/O för appen och barnprocesserna, bytes.
        var diskReadBytes: Int64? = nil
        var diskWriteBytes: Int64? = nil
        /// Toppminne (phys_footprint, samplat ~1 Hz), MB.
        var peakMemoryMB: Double? = nil
        /// "sequential" (stegen i följd, som i dag). Senare "overlapped" — då ska
        /// `expectedDuration` inte blanda ihop lägena. `nil` = äldre post (alltid i följd).
        var mode: String? = nil

        var secondsPerPhoto: Double? { photos > 0 && seconds > 0 ? seconds / Double(photos) : nil }
    }

    // MARK: - Lagring

    nonisolated final class Store: @unchecked Sendable {
        let fileURL: URL
        /// Filen trimmas till de senaste `keep` raderna när den passerar `maxLines`.
        let maxLines = 2_000
        let keep = 1_000
        private let lock = NSLock()
        /// Antal rader i filen, räknat en gång och sedan uppdaterat i minnet.
        private var lineCount: Int?

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        /// Samma regel som `SessionHistoryStore.defaultRegistryURL`: under
        /// `xcodebuild test` (appen är testvärd) skrivs till en temporär mapp,
        /// annars hade testerna fyllt användarens riktiga historik med påhittade tider.
        static let shared: Store = {
            let dir: URL
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlowTestTimings-\(UUID().uuidString)")
            } else {
                if let override = ProcessInfo.processInfo.environment["PHOTOFLOW_SUPPORT_DIR"], !override.isEmpty {
                    // Riktmärkeskörningar (scripts/benchmark.sh) skriver historiken till sin egen
                    // resultatmapp, så de varken blandas med eller förstör användarens riktiga tider.
                    dir = URL(fileURLWithPath: override)
                } else {
                    dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("PhotoFlow")
                }
            }
            return Store(fileURL: dir.appendingPathComponent("step_timings.jsonl"))
        }()

        private static let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.sortedKeys]
            return e
        }()

        private static let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()

        func load() -> [Record] {
            lock.lock(); defer { lock.unlock() }
            return readAll()
        }

        func append(_ record: Record) {
            lock.lock(); defer { lock.unlock() }
            guard var line = try? Self.encoder.encode(record) else { return }
            line.append(0x0A)
            if lineCount == nil { lineCount = readAll().count }
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
            lineCount! += 1
            if lineCount! > maxLines { trim() }
        }

        private func readAll() -> [Record] {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Record.self, from: Data($0)) }
        }

        private func trim() {
            let records = readAll()
            let kept = records.suffix(keep).compactMap { try? Self.encoder.encode($0) }
            var data = Data()
            for line in kept { data.append(line); data.append(0x0A) }
            try? data.write(to: fileURL, options: .atomic)
            lineCount = kept.count
        }
    }

    // MARK: - Prognos

    /// Hur många av de senaste körningarna medianen räknas på.
    static let historyWindow = 5

    /// Sekunder per bild för ett steg: median av de senaste körningarna.
    static func secondsPerPhoto(step: String, history: [Record]) -> Double? {
        let rates = history.filter { $0.step == step }.suffix(historyWindow).compactMap(\.secondsPerPhoto)
        guard !rates.isEmpty else { return nil }
        let sorted = rates.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Hela stegets förväntade tid för `photos` bilder, om historik finns.
    static func expectedDuration(step: String, photos: Int, history: [Record]) -> TimeInterval? {
        guard photos > 0, let rate = secondsPerPhoto(step: step, history: history) else { return nil }
        return rate * Double(photos)
    }

    /// Återstående tid för steget som pågår. Utan förlopp används historiken
    /// (minus tiden som gått). Med förlopp räknas takten hittills fram, och den
    /// får allt större vikt: vid 25 % av steget litar prognosen helt på den.
    static func remaining(
        elapsed: TimeInterval, processed: Int, total: Int, expected: TimeInterval?
    ) -> TimeInterval? {
        let fromHistory = expected.map { max(0, $0 - elapsed) }
        guard total > 0, processed > 0, elapsed >= 5 else { return fromHistory }
        let live = elapsed / Double(processed) * Double(max(0, total - processed))
        guard let fromHistory else { return live }
        let weight = min(1, Double(processed) / Double(total) * 4)
        return fromHistory * (1 - weight) + live * weight
    }

    // MARK: - Visning

    /// "45 s", "12 min", "1 h 05 min".
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// Exakt längd för loggen: "14m 02s".
    static func formatExact(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm %02ds", s / 3600, (s % 3600) / 60, s % 60)
    }
}
