import Foundation
import ImageIO

/// Ren logik bakom HDR-motorn "Lightroom Classic": triggern till pluginet (`mode = "render"`),
/// tolkningen av `lr_status.json`/`lr_done.json`, kopplingen mellan resultat och förväntade
/// utfiler samt valet av vilka grupper som ska falla tillbaka på den inbyggda motorn.
/// Själva körningen (mellanlagring, väntan, efterarbete) ligger i `PipelineRunner+HDRLightroom`.
/// Ingen Lightroom behövs för att enhetstesta det här.
nonisolated enum LightroomRender {

    static let bundleIdentifier = "com.adobe.LightroomClassicCC7"
    /// Första pluginversionen som kan `mode = "render"`. Äldre plugin ignorerar läget och
    /// skulle bara importera ramarna i katalogen, utan export.
    static let minimumPluginVersion = "1.5"

    /// Ett grupp-jobb till Lightroom: de (mellanlagrade) ramarna och exakt var bilden ska hamna.
    struct Job: Equatable, Sendable {
        var groupId: Int
        var files: [String]
        var outputPath: String
    }

    /// Triggern som `PipelineRunner` skriver till `lr_trigger.json`. `headless: false` eftersom
    /// Ctrl+Skift+H inte gör någon sammanslagning i Lightroom Classic (provkört 2026-10-18).
    static func triggerPayload(jobs: [Job]) -> [String: Any] {
        [
            "mode": "render",
            "export_format": "TIFF",
            "headless": false,
            "cleanup_catalog": true,
            "groups": jobs.map { job -> [String: Any] in
                [
                    "group_id": job.groupId,
                    "files": job.files,
                    "output_dir": (job.outputPath as NSString).deletingLastPathComponent,
                    "output_path": job.outputPath,
                ]
            },
        ]
    }

    // MARK: - Status

    struct GroupResult: Equatable, Sendable {
        var groupId: Int
        var status: String
        var message: String
        var export: String?
        var seconds: Double?
    }

    struct Status: Equatable, Sendable {
        /// "running" eller "complete" (pluginets `status`).
        var state: String
        var pluginVersion: String?
        var results: [GroupResult]
        /// Gruppen pluginet arbetar med just nu (`current` i running-status).
        var currentGroupId: Int?
        var currentIndex: Int?
        var total: Int?

        var isComplete: Bool { state == "complete" }
    }

    static func parseStatus(_ object: [String: Any]) -> Status {
        let results = (object["results"] as? [[String: Any]] ?? []).compactMap { raw -> GroupResult? in
            guard let id = (raw["group_id"] as? NSNumber)?.intValue else { return nil }
            return GroupResult(groupId: id, status: raw["status"] as? String ?? "error",
                               message: raw["message"] as? String ?? "",
                               export: raw["export"] as? String,
                               seconds: (raw["seconds"] as? NSNumber)?.doubleValue)
        }
        let current = object["current"] as? [String: Any]
        return Status(state: object["status"] as? String ?? "", pluginVersion: object["plugin_version"] as? String,
                      results: results,
                      currentGroupId: (current?["group_id"] as? NSNumber)?.intValue,
                      currentIndex: (current?["index"] as? NSNumber)?.intValue,
                      total: (current?["total"] as? NSNumber)?.intValue)
    }

    /// nil om filen inte (än) är giltig JSON — pluginet kan hinna skriva halvt mellan två avläsningar.
    static func parseStatus(data: Data) -> Status? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseStatus(object)
    }

    /// `lr_done.json` från pluginet: klar med läget `render`.
    static func isDone(doneData: Data?) -> Bool {
        guard let doneData, let object = (try? JSONSerialization.jsonObject(with: doneData)) as? [String: Any] else { return false }
        return object["status"] as? String == "complete"
    }

    /// "1.5" ≥ "1.5", "1.10" ≥ "1.5", nil/skräp är för gammalt.
    static func versionAtLeast(_ version: String?, _ minimum: String = minimumPluginVersion) -> Bool {
        guard let version else { return false }
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    // MARK: - Utfall

    enum Outcome: Equatable, Sendable {
        /// Bilden finns, är giltig och ligger på den begärda sökvägen.
        case rendered
        case failed(String)

        var isRendered: Bool { if case .rendered = self { return true } else { return false } }
    }

    /// Utfall per grupp: Lightroom ska ha svarat `ok` för gruppen OCH filen på `outputPath` ska
    /// vara en giltig bild. Allt annat (inget svar, fel, saknad eller trasig fil, för gammalt
    /// plugin) blir `.failed` med en orsak — de grupperna faller tillbaka på den inbyggda motorn.
    static func outcomes(jobs: [Job], status: Status?, isValid: (String) -> Bool) -> [Int: Outcome] {
        var map: [Int: Outcome] = [:]
        guard let status else {
            for job in jobs { map[job.groupId] = .failed("inget svar från Lightroom-pluginet") }
            return map
        }
        let pluginTooOld = !versionAtLeast(status.pluginVersion)
        for job in jobs {
            if pluginTooOld {
                map[job.groupId] = .failed("Lightroom-pluginet är för gammalt (\(status.pluginVersion ?? "okänd version"), kräver \(minimumPluginVersion))")
                continue
            }
            guard let result = status.results.last(where: { $0.groupId == job.groupId }) else {
                map[job.groupId] = .failed(status.isComplete ? "Lightroom rapporterade inget resultat" : "tidsgräns — Lightroom hann inte klart")
                continue
            }
            guard result.status == "ok" else {
                map[job.groupId] = .failed(result.message.isEmpty ? result.status : result.message)
                continue
            }
            guard isValid(job.outputPath) else {
                map[job.groupId] = .failed("Lightroom rapporterade klart men filen saknas eller är ogiltig")
                continue
            }
            map[job.groupId] = .rendered
        }
        return map
    }

    /// Grupperna (i jobbordning) som ska göras med reservmotorn.
    static func fallbackGroupIds(jobs: [Job], outcomes: [Int: Outcome]) -> [Int] {
        jobs.map(\.groupId).filter { outcomes[$0]?.isRendered != true }
    }

    // MARK: - Tider

    /// Övre gräns för hela körningen: pluginets egna väntetider (dialog 120 s, DNG 120 s, export)
    /// ger ungefär fyra minuter per grupp i värsta fall, plus tid för att starta Lightroom.
    static func overallTimeoutSeconds(groupCount: Int) -> Double {
        300 + Double(max(groupCount, 1)) * 240
    }

    /// Hur länge utan något tecken på framsteg (nytt resultat, ny aktuell grupp) innan vi ger upp.
    static let stallTimeoutSeconds: Double = 600
    /// Hur länge pluginet får på sig att plocka upp triggern (Lightroom kan behöva starta).
    static let pickupTimeoutSeconds: Double = 240

    // MARK: - Filer

    /// Mellanlagringsmappen för en grupps ramkopior. Lightroom skriver sin `-HDR.dng` bredvid
    /// ramarna, och då ska varken indatamappen (kanske ett kort/nätverk) eller `dng/` smutsas ner.
    static func stagingDirectory(outputDir: URL, groupId: Int) -> URL {
        outputDir.appendingPathComponent("lr_staging").appendingPathComponent("group_\(groupId)")
    }

    static var stagingRootName: String { "lr_staging" }

    /// En färdig bildfil: finns, inte försumbart liten och går att öppna med ImageIO.
    static func isValidImage(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), size > 50_000 else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width > 0 && height > 0
    }
}
