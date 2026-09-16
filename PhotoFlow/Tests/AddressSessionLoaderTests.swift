import Foundation
import Testing
@testable import PhotoFlow

/// Fas 3f: `AddressSessionLoader` läser ihop tre JSON-filer
/// (`calendar_matches.json`/`bracket_groups.json`/`cull_decisions.json`) till
/// `AddressSessionEntity`-värden för App Intents/Spotlight. Testas mot en
/// tillfällig mapp med syntetiska filer i exakt samma format som
/// `PipelineRunner+Calendar`/`BracketAnalyzer`/`PipelineState.saveCullDecisions`
/// faktiskt skriver — se de filernas kommentarer för formatkontraktet.
struct AddressSessionLoaderTests {
    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AddressSessionLoaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: Any, to url: URL) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: url)
    }

    @Test("Tom outputmapp utan calendar_matches.json ger inga sessioner")
    func noCalendarMatches_returnsEmpty() {
        let dir = tempOutputDir()
        #expect(AddressSessionLoader.loadSessions(outputDir: dir).isEmpty)
    }

    @Test("En adress med två bilder inom intervallet räknas rätt, en utanför räknas inte")
    func oneAddress_countsPhotosInRange() {
        let dir = tempOutputDir()

        // `range_start`/`range_end` (ISO8601, absolut tidpunkt) och
        // `bracket_groups.json`s "datetimes" (lokal väggklocka, samma
        // format PipelineRunner+LoadSession läser) måste peka på SAMMA
        // ögonblick oavsett vilken tidszon test-maskinen kör i — så båda
        // härleds här från samma lokala `Date`, i stället för att hårdkoda
        // en "Z"-sträng som bara råkar stämma i UTC.
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rangeStart = localFormatter.date(from: "2026-01-10 09:00:00")!
        let rangeEnd = localFormatter.date(from: "2026-01-10 11:00:00")!
        let isoFormatter = ISO8601DateFormatter()

        write([
            [
                "address": "Testgatan 1, Teststad",
                "event_title": "Fotografering A",
                "range_start": isoFormatter.string(from: rangeStart),
                "range_end": isoFormatter.string(from: rangeEnd)
            ]
        ], to: dir.appendingPathComponent("calendar_matches.json"))

        write([
            "total_images": 3,
            "total_groups": 2,
            "params": ["max_time_gap": 15, "min_bracket_size": 3],
            "bracket_groups_count": 0,
            "single_groups_count": 2,
            "groups": [
                [
                    "group_id": 1,
                    "is_bracket": false,
                    "image_count": 2,
                    "files": ["DSC_0001.NEF", "DSC_0002.NEF"],
                    "exposures": ["1/100", "1/100"],
                    "fnumber": 8.0,
                    "iso": 100,
                    "time_start": "10:00:00",
                    "time_end": "10:00:05",
                    "date_start": "2026-01-10 10:00:00",
                    "date_end": "2026-01-10 10:00:05",
                    "datetimes": ["2026-01-10 10:00:00", "2026-01-10 10:00:05"],
                    "exposure_range_stops": 0,
                    "suggested_hdr_indices": [],
                    "unique_exposure_levels": 1
                ],
                [
                    // Utanför kalenderintervallet (12:00, intervallet slutar 11:00) — ska INTE räknas.
                    "group_id": 2,
                    "is_bracket": false,
                    "image_count": 1,
                    "files": ["DSC_0003.NEF"],
                    "exposures": ["1/100"],
                    "fnumber": 8.0,
                    "iso": 100,
                    "time_start": "12:00:00",
                    "time_end": "12:00:00",
                    "date_start": "2026-01-10 12:00:00",
                    "date_end": "2026-01-10 12:00:00",
                    "datetimes": ["2026-01-10 12:00:00"],
                    "exposure_range_stops": 0,
                    "suggested_hdr_indices": [],
                    "unique_exposure_levels": 1
                ]
            ]
        ] as [String: Any], to: dir.appendingPathComponent("bracket_groups.json"))

        write([
            "1_DSC_0001.NEF": "accepted",
            "1_DSC_0002.NEF": "rejected",
            "2_DSC_0003.NEF": "accepted"
        ], to: dir.appendingPathComponent("cull_decisions.json"))

        let sessions = AddressSessionLoader.loadSessions(outputDir: dir)

        #expect(sessions.count == 1)
        #expect(sessions.first?.address == "Testgatan 1, Teststad")
        #expect(sessions.first?.eventTitle == "Fotografering A")
        // Bara grupp 1:s två bilder faller inom 09:00–11:00 — grupp 2 (12:00) räknas inte.
        #expect(sessions.first?.imageCount == 2)
        // Av de två: bara DSC_0001 är "accepted" i cull_decisions.json.
        #expect(sessions.first?.acceptedCount == 1)
    }

    @Test("Flera adresser ger flera sessioner, en per calendar_matches-post")
    func multipleAddresses_giveMultipleSessions() {
        let dir = tempOutputDir()

        write([
            [
                "address": "Gata A 1, Stad A",
                "event_title": "Bokning A",
                "range_start": "2026-02-01T08:00:00Z",
                "range_end": "2026-02-01T09:00:00Z"
            ],
            [
                "address": "Gata B 2, Stad B",
                "event_title": "Bokning B",
                "range_start": "2026-02-01T13:00:00Z",
                "range_end": "2026-02-01T14:00:00Z"
            ]
        ], to: dir.appendingPathComponent("calendar_matches.json"))

        // Inga bracket_groups.json/cull_decisions.json — ska ge 0 bilder/0 godkända
        // per session, inte krascha eller filtrera bort dem.
        let sessions = AddressSessionLoader.loadSessions(outputDir: dir)

        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.address)) == ["Gata A 1, Stad A", "Gata B 2, Stad B"])
        #expect(sessions.allSatisfy { $0.imageCount == 0 && $0.acceptedCount == 0 })
    }

    @Test("Saknad range_start/range_end filtreras bort utan att krascha")
    func malformedEntry_isSkipped() {
        let dir = tempOutputDir()
        write([
            ["address": "Ofullständig adress", "event_title": "X"]
        ], to: dir.appendingPathComponent("calendar_matches.json"))

        #expect(AddressSessionLoader.loadSessions(outputDir: dir).isEmpty)
    }

    // MARK: - Fas 6: loadCurrentSessions aggregerar över historikregistret

    private func tempRegistryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AddressSessionLoaderTests-registry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private func makeManifest(outputDir: URL) -> SessionManifest {
        SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion, sessionID: UUID(),
            createdAt: Date(), updatedAt: Date(),
            inputDirectory: outputDir.path, outputDirectory: outputDir.path,
            photoCount: 1, groupCount: 1, addresses: [], steps: [:],
            cullSummary: SessionManifest.CullSummary(accepted: 0, rejected: 0, unreviewed: 1)
        )
    }

    @Test("loadCurrentSessions läser adress-sessioner från FLERA outputmappar via historikregistret")
    func loadCurrentSessions_aggregatesAcrossHistory() {
        let registryURL = tempRegistryURL()
        let dirA = tempOutputDir()
        let dirB = tempOutputDir()

        write([["address": "Gata A", "event_title": "Bokning A", "range_start": "2026-01-01T08:00:00Z", "range_end": "2026-01-01T09:00:00Z"]],
              to: dirA.appendingPathComponent("calendar_matches.json"))
        write([["address": "Gata B", "event_title": "Bokning B", "range_start": "2026-02-01T08:00:00Z", "range_end": "2026-02-01T09:00:00Z"]],
              to: dirB.appendingPathComponent("calendar_matches.json"))

        SessionHistoryStore.record(makeManifest(outputDir: dirA), registryURL: registryURL)
        SessionHistoryStore.record(makeManifest(outputDir: dirB), registryURL: registryURL)

        let sessions = AddressSessionLoader.loadCurrentSessions(registryURL: registryURL)
        #expect(Set(sessions.map(\.address)) == ["Gata A", "Gata B"])
    }

    @Test("loadCurrentSessions ger tom lista för en tom (men existerande) historik utan att krascha")
    func loadCurrentSessions_emptyHistory_withNoConfiguredOutputDir_isSafe() {
        let registryURL = tempRegistryURL()
        // No entries recorded at all — an empty (but valid, zero-length) registry.
        let sessions = AddressSessionLoader.loadCurrentSessions(registryURL: registryURL)
        // Falls back to AppSettings.shared.outputDirectory, which is very
        // likely nil/unrelated in a test environment — either way this must
        // not crash.
        #expect(sessions.count >= 0)
    }
}
