import Foundation
import Testing
@testable import PhotoFlow

/// Fas 6: rundtripp, migrering från en pre-Fas-6-session (bara de gamla lösa
/// filerna, inget `photoflow_session.json`), och fingerprint-stabilitet för
/// `SessionManifestStore`.
@MainActor
struct SessionManifestStoreTests {
    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionManifestStoreTests-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: Any, to url: URL) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: url)
    }

    /// `SessionManifestStore`'s ISO8601 date formatter (like
    /// `PipelineRunner.decisionLogTimestampFormatter`) only round-trips
    /// millisecond precision — plenty for a manifest that's read for display/
    /// bookkeeping, never compared to sub-millisecond accuracy. A raw
    /// `Date()` carries more precision than that, so equality tests need a
    /// date already rounded to the millisecond, or they'd flake on the
    /// truncated sub-millisecond remainder.
    private func millisecondPrecisionDate() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private func makeManifest(outputDir: URL, inputDir: URL) -> SessionManifest {
        SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            sessionID: UUID(),
            createdAt: millisecondPrecisionDate(),
            updatedAt: millisecondPrecisionDate(),
            inputDirectory: inputDir.path,
            outputDirectory: outputDir.path,
            photoCount: 12,
            groupCount: 3,
            addresses: [
                SessionManifest.AddressRecord(address: "Testgatan 1", eventTitle: "Fotografering", latitude: 59.3, longitude: 18.0, manuallyCorrected: false)
            ],
            steps: [
                DashboardStep.createHDR.manifestKey: SessionManifest.StepRecord(
                    stepID: DashboardStep.createHDR.manifestKey, phase: "complete",
                    processedCount: 3, totalCount: 3, duration: 1.5, finishedAt: millisecondPrecisionDate(),
                    inputFingerprint: "abc123"
                )
            ],
            cullSummary: SessionManifest.CullSummary(accepted: 5, rejected: 2, unreviewed: 5)
        )
    }

    // MARK: - Roundtrip

    @Test("save/load gör en rundtripp med alla fält intakta")
    func saveLoad_roundTrips() {
        let outputDir = tempDir("roundtrip")
        let inputDir = tempDir("roundtrip-input")
        let manifest = makeManifest(outputDir: outputDir, inputDir: inputDir)

        SessionManifestStore.save(manifest, to: outputDir)
        let loaded = SessionManifestStore.load(from: outputDir)

        #expect(loaded == manifest)
    }

    @Test("save skriver atomiskt — filen finns direkt och går att läsa om igen efter en andra save")
    func save_isAtomicAndOverwritable() {
        let outputDir = tempDir("atomic")
        let inputDir = tempDir("atomic-input")
        var manifest = makeManifest(outputDir: outputDir, inputDir: inputDir)

        SessionManifestStore.save(manifest, to: outputDir)
        #expect(FileManager.default.fileExists(atPath: SessionManifestStore.url(in: outputDir).path))

        manifest.photoCount = 99
        SessionManifestStore.save(manifest, to: outputDir)
        let loaded = SessionManifestStore.load(from: outputDir)
        #expect(loaded?.photoCount == 99)

        // No leftover temp files.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path))?
            .filter { $0.contains(".tmp-") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("load returnerar nil när ingen photoflow_session.json finns")
    func load_missingFile_returnsNil() {
        let outputDir = tempDir("missing")
        #expect(SessionManifestStore.load(from: outputDir) == nil)
    }

    // MARK: - Migration från pre-Fas-6-session

    @Test("migrate bygger ett manifest från bracket_groups.json + cull_decisions.json + calendar_matches.json")
    func migrate_buildsManifestFromLegacyFiles() {
        let outputDir = tempDir("migrate")
        let inputDir = tempDir("migrate-input")

        write([
            "total_images": 3,
            "total_groups": 2,
            "params": ["max_time_gap": 15, "min_bracket_size": 3],
            "groups": [
                ["group_id": 1, "is_bracket": false, "files": ["DSC_0001.NEF", "DSC_0002.NEF"]],
                ["group_id": 2, "is_bracket": false, "files": ["DSC_0003.NEF"]]
            ]
        ] as [String: Any], to: outputDir.appendingPathComponent("bracket_groups.json"))

        write([
            ["address": "Testgatan 1, Teststad", "event_title": "Fotografering A",
             "range_start": "2026-01-10T08:00:00Z", "range_end": "2026-01-10T10:00:00Z"]
        ], to: outputDir.appendingPathComponent("calendar_matches.json"))

        write([
            "1_DSC_0001.NEF": "accepted",
            "1_DSC_0002.NEF": "rejected"
        ], to: outputDir.appendingPathComponent("cull_decisions.json"))

        write(["photos_sorted": 3, "organized": 3, "unmatched": 0], to: outputDir.appendingPathComponent("files_sorted.json"))
        write(["version": 2, "folders_written": 1, "files_written": 6], to: outputDir.appendingPathComponent("metadata_written.json"))

        let migrated = SessionManifestStore.migrate(inputDir: inputDir, outputDir: outputDir)
        #expect(migrated != nil)
        guard let migrated else { return }

        #expect(migrated.photoCount == 3)
        #expect(migrated.groupCount == 2)
        #expect(migrated.addresses.count == 1)
        #expect(migrated.addresses.first?.address == "Testgatan 1, Teststad")
        #expect(migrated.cullSummary.accepted == 1)
        #expect(migrated.cullSummary.rejected == 1)
        // 3 photos - 1 accepted - 1 rejected = 1 unreviewed (DSC_0003 has no decision).
        #expect(migrated.cullSummary.unreviewed == 1)
        #expect(migrated.steps[DashboardStep.createHDR.manifestKey]?.phase == "complete")
        #expect(migrated.steps[DashboardStep.moveToFolders.manifestKey]?.processedCount == 3)
        #expect(migrated.steps[DashboardStep.writeIPTCTags.manifestKey]?.processedCount == 6)
    }

    @Test("migrate returnerar nil för en helt tom outputmapp (genuint ny session)")
    func migrate_emptyDirectory_returnsNil() {
        let outputDir = tempDir("migrate-empty")
        let inputDir = tempDir("migrate-empty-input")
        #expect(SessionManifestStore.migrate(inputDir: inputDir, outputDir: outputDir) == nil)
    }

    @Test("loadOrMigrate sparar det migrerade manifestet så nästa load hittar det direkt")
    func loadOrMigrate_persistsMigratedManifest() {
        let outputDir = tempDir("load-or-migrate")
        let inputDir = tempDir("load-or-migrate-input")
        write([
            ["address": "Gata 1", "event_title": "Bokning",
             "range_start": "2026-01-10T08:00:00Z", "range_end": "2026-01-10T10:00:00Z"]
        ], to: outputDir.appendingPathComponent("calendar_matches.json"))

        let first = SessionManifestStore.loadOrMigrate(inputDir: inputDir, outputDir: outputDir)
        #expect(first != nil)
        #expect(FileManager.default.fileExists(atPath: SessionManifestStore.url(in: outputDir).path))

        // A direct load() (not loadOrMigrate) must now find the persisted file
        // and return the SAME sessionID — a second migration would mint a new
        // UUID every time, which would break session-history continuity.
        let reloaded = SessionManifestStore.load(from: outputDir)
        #expect(reloaded?.sessionID == first?.sessionID)
    }

    @Test("loadOrMigrate föredrar ett befintligt manifest framför migrering")
    func loadOrMigrate_prefersExistingManifest() {
        let outputDir = tempDir("prefer-existing")
        let inputDir = tempDir("prefer-existing-input")
        let existing = makeManifest(outputDir: outputDir, inputDir: inputDir)
        SessionManifestStore.save(existing, to: outputDir)

        // Also drop a legacy file — if migration ran anyway it would mint a
        // different sessionID than `existing`'s.
        write([["address": "Ignorerad", "event_title": "X", "range_start": "2026-01-10T08:00:00Z", "range_end": "2026-01-10T09:00:00Z"]],
              to: outputDir.appendingPathComponent("calendar_matches.json"))

        let result = SessionManifestStore.loadOrMigrate(inputDir: inputDir, outputDir: outputDir)
        #expect(result?.sessionID == existing.sessionID)
    }

    // MARK: - Fingerprint

    @Test("Samma filer + samma inställningar ger samma fingerprint")
    func fingerprint_sameInput_isStable() {
        let dir = tempDir("fp-stable")
        let fileA = dir.appendingPathComponent("a.NEF")
        let fileB = dir.appendingPathComponent("b.NEF")
        try! Data(repeating: 1, count: 100).write(to: fileA)
        try! Data(repeating: 2, count: 200).write(to: fileB)

        let fp1 = SessionManifestStore.fingerprint(fileURLs: [fileA, fileB], settings: ["maxTimeGap": "15"])
        let fp2 = SessionManifestStore.fingerprint(fileURLs: [fileB, fileA], settings: ["maxTimeGap": "15"])
        #expect(fp1 == fp2, "Filordningen ska inte spela roll — filnamnen sorteras internt.")
    }

    @Test("En ändrad inställning ger ett annat fingerprint även om filerna är oförändrade")
    func fingerprint_changedSetting_changesFingerprint() {
        let dir = tempDir("fp-setting")
        let file = dir.appendingPathComponent("a.NEF")
        try! Data(repeating: 1, count: 100).write(to: file)

        let fp1 = SessionManifestStore.fingerprint(fileURLs: [file], settings: ["maxTimeGap": "15"])
        let fp2 = SessionManifestStore.fingerprint(fileURLs: [file], settings: ["maxTimeGap": "20"])
        #expect(fp1 != fp2)
    }

    @Test("Ändrad filstorlek (samma antal/namn) ger ett annat fingerprint")
    func fingerprint_changedFileContent_changesFingerprint() {
        let dir = tempDir("fp-content")
        let file = dir.appendingPathComponent("a.NEF")

        try! Data(repeating: 1, count: 100).write(to: file)
        let fp1 = SessionManifestStore.fingerprint(fileURLs: [file])

        try! Data(repeating: 1, count: 500).write(to: file)
        let fp2 = SessionManifestStore.fingerprint(fileURLs: [file])

        #expect(fp1 != fp2)
    }

    @Test("Fler filer ger ett annat fingerprint")
    func fingerprint_changedFileCount_changesFingerprint() {
        let dir = tempDir("fp-count")
        let fileA = dir.appendingPathComponent("a.NEF")
        let fileB = dir.appendingPathComponent("b.NEF")
        try! Data(repeating: 1, count: 100).write(to: fileA)
        try! Data(repeating: 1, count: 100).write(to: fileB)

        let fp1 = SessionManifestStore.fingerprint(fileURLs: [fileA])
        let fp2 = SessionManifestStore.fingerprint(fileURLs: [fileA, fileB])
        #expect(fp1 != fp2)
    }

    // MARK: - Fingerprint (Fas 10: kalenderstegets `calendarNames`)

    @Test("Kalenderstegets fingerprint ändras när det valda kalenderurvalet ändras, oförändrade filer")
    func fingerprint_changedCalendarSelection_changesFingerprint() {
        let dir = tempDir("fp-calendar")
        let groupsFile = dir.appendingPathComponent("bracket_groups.json")
        try! Data("{}".utf8).write(to: groupsFile)

        // Speglar EXAKT hur PipelineRunner+Calendar.swift bygger fingerprintet,
        // så testet fångar en regression i den faktiska trådningen mellan
        // `AppSettings.calendarNames` och kalenderstegets skip-logik, inte
        // bara `SessionManifestStore.fingerprint`s generella beteende.
        func fingerprintFor(_ names: [String]) -> String {
            SessionManifestStore.fingerprint(
                fileURLs: [groupsFile],
                settings: ["calendarNames": CalendarService.calendarNamesFingerprintValue(names)]
            )
        }

        let allCalendars = fingerprintFor([])
        let oneCalendar = fingerprintFor(["Fastighetsfoto"])
        let twoCalendars = fingerprintFor(["Fastighetsfoto", "Jobb"])

        #expect(allCalendars != oneCalendar, "Från 'alla kalendrar' till ett val ska trigga en ny matchning.")
        #expect(oneCalendar != twoCalendars, "Att lägga till ytterligare en vald kalender ska trigga en ny matchning.")
        // Samma urval (oavsett ordning) ska INTE trigga en ny matchning.
        #expect(fingerprintFor(["Fastighetsfoto", "Jobb"]) == fingerprintFor(["Jobb", "Fastighetsfoto"]))
    }
}
