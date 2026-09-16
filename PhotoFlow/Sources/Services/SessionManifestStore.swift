import Foundation

/// Fas 6: läser/skriver `photoflow_session.json` (se `SessionManifest`) och
/// bygger ett manifest retroaktivt från de gamla lösa filerna för sessioner
/// som kördes innan Fas 6 fanns (`migrate`). Bara statiska funktioner mot en
/// explicit `outputDir`/`inputDir`, så de går att testa mot en tillfällig
/// mapp — anropas uteslutande från `PipelineState`/`PipelineRunner`
/// (MainActor, precis som resten av appen; se `project.yml`s
/// `SWIFT_DEFAULT_ACTOR_ISOLATION`), så INTE `nonisolated` (till skillnad
/// från t.ex. `PhotoQualityService`, som medvetet kör tungt Vision-arbete
/// parallellt utanför MainActor).
enum SessionManifestStore {
    static let filename = "photoflow_session.json"

    static func url(in outputDir: URL) -> URL {
        outputDir.appendingPathComponent(filename)
    }

    /// Med fraktionerade sekunder — plain `.iso8601` (both here and in
    /// `JSONEncoder`/`JSONDecoder`'s built-in strategy) drops sub-second
    /// precision, which made a `save` -> `load` round trip of a freshly
    /// created `Date()` compare unequal purely from formatting, not from an
    /// actual bug. Same pattern as `PipelineRunner.decisionLogTimestampFormatter`.
    // nonisolated(unsafe): see `SessionHistoryStore.dateFormatter`'s comment —
    // same JSONEncoder/JSONDecoder `.custom`-closure-Sendable situation.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func load(from outputDir: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: url(in: outputDir)) else { return nil }
        let decoder = JSONDecoder()
        // `.formatted(DateFormatter)` doesn't accept an `ISO8601DateFormatter`
        // — `.custom` is the only strategy that lets us reuse the same
        // fractional-seconds formatter for both encode and decode.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ogiltigt ISO8601-datum: \(string)")
            }
            return date
        }
        return try? decoder.decode(SessionManifest.self, from: data)
    }

    /// Atomisk skrivning: temp-fil i samma mapp + `replaceItemAt` (eller
    /// `moveItem` om filen inte redan finns) — så en läsare (t.ex. en annan
    /// process, eller appen efter en krasch mitt i skrivning) aldrig ser en
    /// halvskriven JSON-fil.
    static func save(_ manifest: SessionManifest, to outputDir: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let finalURL = url(in: outputDir)
        let tempURL = outputDir.appendingPathComponent(".\(filename).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    /// Läser ett befintligt manifest, eller bygger (och sparar) ett nytt
    /// genom migrering från de gamla lösa filerna om inget manifest finns
    /// ännu. Returnerar `nil` bara om outputmappen är helt tom (en genuint
    /// ny, aldrig körd session — inget att migrera).
    static func loadOrMigrate(inputDir: URL, outputDir: URL) -> SessionManifest? {
        if let existing = load(from: outputDir) { return existing }
        guard let migrated = migrate(inputDir: inputDir, outputDir: outputDir) else { return nil }
        save(migrated, to: outputDir)
        return migrated
    }

    /// Filerna en pre-Fas-6-körning kan ha lämnat efter sig i outputmappen —
    /// se `agent-rules.md`/uppdragsbeskrivningen. Om INGEN av dem finns antas
    /// detta vara en genuint ny session (inget att migrera från).
    private static let legacyArtifactNames = [
        "bracket_groups.json", "cull_decisions.json", "calendar_matches.json",
        "files_sorted.json", "metadata_written.json", "ai_tags.json", "photo_quality.json"
    ]

    static func migrate(inputDir: URL, outputDir: URL) -> SessionManifest? {
        let fm = FileManager.default
        guard legacyArtifactNames.contains(where: { fm.fileExists(atPath: outputDir.appendingPathComponent($0).path) }) else {
            return nil
        }

        var photoCount = 0
        var groupCount = 0
        var steps: [String: SessionManifest.StepRecord] = [:]

        func markComplete(_ step: DashboardStep, count: Int) {
            steps[step.manifestKey] = SessionManifest.StepRecord(
                stepID: step.manifestKey, phase: "complete",
                processedCount: count, totalCount: count,
                duration: nil, finishedAt: nil, inputFingerprint: nil
            )
        }

        // bracket_groups.json -> photoCount/groupCount + createHDR-steget
        // (bracket-analysens loggar/status lever redan under .createHDR i
        // resten av pipelinen, se PipelineRunner+Brackets.swift).
        if let data = try? Data(contentsOf: outputDir.appendingPathComponent("bracket_groups.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let groups = (json["groups"] as? [[String: Any]]) ?? []
            groupCount = groups.count
            photoCount = groups.reduce(0) { $0 + (($1["files"] as? [String])?.count ?? 0) }
            markComplete(.createHDR, count: groupCount)
        }

        // calendar_matches.json -> adresser + findCalendarInfo-steget
        var addresses: [SessionManifest.AddressRecord] = []
        if let data = try? Data(contentsOf: outputDir.appendingPathComponent("calendar_matches.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in json {
                guard let address = entry["address"] as? String else { continue }
                addresses.append(SessionManifest.AddressRecord(
                    address: address,
                    eventTitle: (entry["event_title"] as? String) ?? "",
                    latitude: entry["latitude"] as? Double,
                    longitude: entry["longitude"] as? Double,
                    manuallyCorrected: (entry["corrected"] as? Bool) ?? false
                ))
            }
            if !json.isEmpty { markComplete(.findCalendarInfo, count: json.count) }
        }

        // cull_decisions.json -> gallringssammanfattning
        var accepted = 0
        var rejected = 0
        if let data = try? Data(contentsOf: outputDir.appendingPathComponent("cull_decisions.json")),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            accepted = dict.values.filter { $0 == "accepted" }.count
            rejected = dict.values.filter { $0 == "rejected" }.count
        }
        let unreviewed = max(0, photoCount - accepted - rejected)

        // files_sorted.json -> moveToFolders-steget
        if let data = try? Data(contentsOf: outputDir.appendingPathComponent("files_sorted.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = json["photos_sorted"] as? Int {
            markComplete(.moveToFolders, count: count)
        }

        // metadata_written.json -> writeIPTCTags-steget
        if let data = try? Data(contentsOf: outputDir.appendingPathComponent("metadata_written.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = json["files_written"] as? Int {
            markComplete(.writeIPTCTags, count: count)
        }

        // ai_tags.json -> aiTagging-steget (bara antal — se AITagsStore för formatet)
        if let entries = AITagsStore.load(from: outputDir), !entries.isEmpty {
            markComplete(.aiTagging, count: entries.count)
        }

        let now = Date()
        return SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            sessionID: UUID(),
            createdAt: now,
            updatedAt: now,
            inputDirectory: inputDir.path,
            outputDirectory: outputDir.path,
            photoCount: photoCount,
            groupCount: groupCount,
            addresses: addresses,
            steps: steps,
            cullSummary: SessionManifest.CullSummary(accepted: accepted, rejected: rejected, unreviewed: unreviewed)
        )
    }

    // MARK: - Fingerprint

    /// Billig, STABIL hash av ett stegs faktiska indata (filantal + sorterade
    /// basnamn + total filstorlek) + en valfri inställnings-ögonblicksbild —
    /// så ett steg körs om både när filerna ändras OCH när en relevant
    /// inställning gör det (t.ex. `maxTimeGap`), i stället för att bara
    /// jämföra ett antal som händelsevis råkar vara oförändrat.
    ///
    /// Använder INTE Swift's inbyggda `Hasher`/`hash(into:)` — den har en
    /// slumpad seed per processtart (dokumenterat i `Hashable`) och skulle
    /// alltså aldrig ge samma värde mellan två körningar av appen, vilket helt
    /// skulle omintetgöra poängen med att spara ett fingerprint på disk.
    /// FNV-1a över en enkel kanonisk sträng är gott nog här — det här är ett
    /// "har indata ändrats"-filter, inte ett kryptografiskt hashvärde.
    static func fingerprint(fileURLs: [URL], settings: [String: String] = [:]) -> String {
        let fm = FileManager.default
        let names = fileURLs.map(\.lastPathComponent).sorted()
        var totalSize: Int64 = 0
        for url in fileURLs {
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                totalSize += size
            }
        }

        var canonical = "count=\(names.count);size=\(totalSize)"
        for name in names { canonical += ";f=\(name)" }
        for key in settings.keys.sorted() { canonical += ";\(key)=\(settings[key] ?? "")" }
        return fnv1aHex(canonical)
    }

    private static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce4_84222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
