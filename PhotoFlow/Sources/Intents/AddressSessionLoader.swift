import Foundation

/// Laser ihop `calendar_matches.json` + `bracket_groups.json` +
/// `cull_decisions.json` fran EN outputmapp till en lista adress-"sessioner"
/// for App Intents/Spotlight (`AddressSessionEntity`).
///
/// Fas 3f kunde bara se den SENASTE korningen i den just nu konfigurerade
/// outputmappen (`AppSettings.shared.outputDirectory`) — PhotoFlow hade
/// inget begrepp om sessionshistorik an. Fas 6 loste det med
/// `SessionHistoryStore` (registret i
/// `~/Library/Application Support/PhotoFlow/sessions.json`, uppdaterat
/// varje gang en session kors eller oppnas igen): `loadCurrentSessions()`
/// aggregerar nu adress-sessioner over ALLA kanda outputmappar i registret,
/// inte bara den aktuella. `loadSessions(outputDir:)` (karnlogiken per mapp)
/// ar ofodrandrad och fortfarande det testbara stallet — se
/// `AddressSessionLoaderTests`.
enum AddressSessionLoader {
    private struct CalendarMatchEntry {
        let address: String
        let eventTitle: String
        let start: Date
        let end: Date
    }

    /// En bilds capture-tid, for att rakna hur manga bilder/godkanda som
    /// hor till varje kalenderadress datumintervall.
    private struct PhotoDate {
        let groupId: Int
        let filename: String
        let date: Date
    }

    /// Fas 6: en session per adress, over ALLA outputmappar
    /// `SessionHistoryStore` kanner till (senast uppdaterade session forst) —
    /// inte bara den just nu konfigurerade outputmappen. Mappar som saknas
    /// pa disk (redan stadade av `SessionHistoryStore.pruneMissingOutputDirectories`
    /// vid appstart/historikvyns `onAppear`, men kan tillfalligt finnas kvar
    /// i registret daremellan) ger helt enkelt inga sessioner for den posten
    /// istallet for att krascha — `loadSessions` lasningar misslyckas bara
    /// tyst (`try?`) mot en obefintlig mapp.
    static func loadCurrentSessions(registryURL: URL = SessionHistoryStore.defaultRegistryURL) -> [AddressSessionEntity] {
        let historyEntries = SessionHistoryStore.load(from: registryURL)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !historyEntries.isEmpty else {
            // Backat kompatibilitet for en session som kordes/lastes in
            // FORE Fas 6 registrerade den i historikregistret (t.ex. om
            // appen kraschade innan forsta `syncManifest()` hann spara) —
            // fall tillbaka till den gamla, enkla-mapp-lasningen sa
            // "Hitta sessioner" inte plotsligt blir tom for en befintlig
            // anvandare.
            guard let outputDir = AppSettings.shared.outputDirectory else { return [] }
            return loadSessions(outputDir: outputDir)
        }
        return historyEntries.flatMap { loadSessions(outputDir: URL(fileURLWithPath: $0.outputDirectory)) }
    }

    /// Kärnlogiken, separerad från `AppSettings.shared` så den går att testa
    /// mot en tillfällig mapp (se `AddressSessionLoaderTests`) utan att röra
    /// den riktiga konfigurerade outputmappen.
    static func loadSessions(outputDir: URL) -> [AddressSessionEntity] {
        let matches = loadCalendarMatches(outputDir: outputDir)
        guard !matches.isEmpty else { return [] }

        let photoDates = loadPhotoDates(outputDir: outputDir)
        let cullDecisions = loadCullDecisions(outputDir: outputDir)

        return matches.enumerated().map { index, match in
            let photosInRange = photoDates.filter { $0.date >= match.start && $0.date <= match.end }
            let acceptedCount = photosInRange.filter { photo in
                // Samma nyckelformat som PipelineRunner+LoadSession bygger
                // photoId med ("\(groupId)_\(filename)") — se cull_decisions.json.
                cullDecisions["\(photo.groupId)_\(photo.filename)"] == "accepted"
            }.count

            return AddressSessionEntity(
                id: "\(outputDir.path)#\(index)",
                address: match.address,
                eventTitle: match.eventTitle,
                date: match.start,
                imageCount: photosInRange.count,
                acceptedCount: acceptedCount
            )
        }
    }

    private static func loadCalendarMatches(outputDir: URL) -> [CalendarMatchEntry] {
        let file = outputDir.appendingPathComponent("calendar_matches.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        // Samma ISO8601-format som PipelineRunner+Calendar.matchCalendarBookings
        // skriver "range_start"/"range_end" med.
        let formatter = ISO8601DateFormatter()
        return json.compactMap { entry in
            guard let address = entry["address"] as? String,
                  let eventTitle = entry["event_title"] as? String,
                  let startStr = entry["range_start"] as? String,
                  let endStr = entry["range_end"] as? String,
                  let start = formatter.date(from: startStr),
                  let end = formatter.date(from: endStr) else { return nil }
            return CalendarMatchEntry(address: address, eventTitle: eventTitle, start: start, end: end)
        }
    }

    private static func loadPhotoDates(outputDir: URL) -> [PhotoDate] {
        let file = outputDir.appendingPathComponent("bracket_groups.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var result: [PhotoDate] = []
        for group in groups {
            guard let groupId = group["group_id"] as? Int,
                  let files = group["files"] as? [String] else { continue }
            let dateStrs = group["datetimes"] as? [String] ?? []
            let fallbackDate = (group["date_start"] as? String).flatMap { formatter.date(from: $0) }

            for (i, filename) in files.enumerated() {
                let date = (i < dateStrs.count ? formatter.date(from: dateStrs[i]) : nil) ?? fallbackDate
                guard let date else { continue }
                result.append(PhotoDate(groupId: groupId, filename: filename, date: date))
            }
        }
        return result
    }

    private static func loadCullDecisions(outputDir: URL) -> [String: String] {
        let file = outputDir.appendingPathComponent("cull_decisions.json")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }
}
