import Foundation

/// Fas 3f: laser ihop `calendar_matches.json` + `bracket_groups.json` +
/// `cull_decisions.json` fran den AKTUELLA outputmappen
/// (`AppSettings.shared.outputDirectory`) till en lista adress-"sessioner"
/// for App Intents/Spotlight (`AddressSessionEntity`).
///
/// PhotoFlow har idag inget begrepp om sessionshistorik — en outputmapp
/// motsvarar en korning, och en ny korning i SAMMA mapp skriver over
/// `calendar_matches.json`. Den har lasningen kan darfor bara aterspegla
/// SENASTE sessionen i den mapp som just nu ar konfigurerad, inte flera
/// veckors historik. En riktig sessionshistorik (t.ex. en lista over tidigare
/// outputmappar) fanns inte i nagon tidigare fas och laggs inte till har —
/// se FORBATTRINGAR.md, Fas 3f, "Kvarstaende".
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

    static func loadCurrentSessions() -> [AddressSessionEntity] {
        guard let outputDir = AppSettings.shared.outputDirectory else { return [] }

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
