import Foundation
import Testing
@testable import PhotoFlow

/// Fas 6: `SessionHistoryStore` är alltid testat med en EXPLICIT
/// `registryURL` (en temp-fil), aldrig `defaultRegistryURL` — se
/// `SessionHistoryStore.defaultRegistryURL`s dokkommentar för varför det
/// annars skulle skriva låtsassessioner in i användarens riktiga
/// `~/Library/Application Support/PhotoFlow/sessions.json`.
@MainActor
struct SessionHistoryStoreTests {
    private func tempRegistryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionHistoryStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private func makeManifest(outputDir: URL, sessionID: UUID = UUID(), addresses: [String] = ["Testgatan 1"]) -> SessionManifest {
        SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            sessionID: sessionID,
            createdAt: Date(),
            updatedAt: Date(),
            inputDirectory: outputDir.path,
            outputDirectory: outputDir.path,
            photoCount: 10,
            groupCount: 2,
            addresses: addresses.map { SessionManifest.AddressRecord(address: $0, eventTitle: "Bokning", latitude: nil, longitude: nil, manuallyCorrected: false) },
            steps: [:],
            cullSummary: SessionManifest.CullSummary(accepted: 3, rejected: 1, unreviewed: 6)
        )
    }

    @Test("load returnerar tom lista när ingen sessions.json finns")
    func load_missingFile_returnsEmpty() {
        #expect(SessionHistoryStore.load(from: tempRegistryURL()).isEmpty)
    }

    @Test("record lägger till en ny post")
    func record_addsNewEntry() {
        let registryURL = tempRegistryURL()
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = makeManifest(outputDir: outputDir)

        SessionHistoryStore.record(manifest, registryURL: registryURL)

        let entries = SessionHistoryStore.load(from: registryURL)
        #expect(entries.count == 1)
        #expect(entries.first?.sessionID == manifest.sessionID)
        #expect(entries.first?.addresses == ["Testgatan 1"])
        #expect(entries.first?.photoCount == 10)
        #expect(entries.first?.acceptedCount == 3)
    }

    @Test("record uppdaterar (upsert) en befintlig post med samma sessionID i stället för att duplicera")
    func record_upsertsExistingEntry() {
        let registryURL = tempRegistryURL()
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionID = UUID()

        SessionHistoryStore.record(makeManifest(outputDir: outputDir, sessionID: sessionID), registryURL: registryURL)
        var updated = makeManifest(outputDir: outputDir, sessionID: sessionID)
        updated.photoCount = 42
        SessionHistoryStore.record(updated, registryURL: registryURL)

        let entries = SessionHistoryStore.load(from: registryURL)
        #expect(entries.count == 1)
        #expect(entries.first?.photoCount == 42)
    }

    @Test("record markerar status Klar när alla steg är complete/disabled, annars Pågående")
    func record_statusReflectsStepCompletion() {
        let registryURL = tempRegistryURL()
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        var inProgress = makeManifest(outputDir: outputDir)
        inProgress.steps = [
            DashboardStep.convertToDNG.manifestKey: SessionManifest.StepRecord(stepID: "x", phase: "complete", processedCount: 1, totalCount: 1, duration: nil, finishedAt: nil, inputFingerprint: nil),
            DashboardStep.createHDR.manifestKey: SessionManifest.StepRecord(stepID: "y", phase: "active", processedCount: 0, totalCount: 1, duration: nil, finishedAt: nil, inputFingerprint: nil)
        ]
        SessionHistoryStore.record(inProgress, registryURL: registryURL)
        #expect(SessionHistoryStore.load(from: registryURL).first?.status == "Pågående")

        var done = makeManifest(outputDir: outputDir, sessionID: inProgress.sessionID)
        done.steps = [
            DashboardStep.convertToDNG.manifestKey: SessionManifest.StepRecord(stepID: "x", phase: "complete", processedCount: 1, totalCount: 1, duration: nil, finishedAt: nil, inputFingerprint: nil),
            DashboardStep.createHDR.manifestKey: SessionManifest.StepRecord(stepID: "y", phase: "disabled", processedCount: 0, totalCount: 0, duration: nil, finishedAt: nil, inputFingerprint: nil)
        ]
        SessionHistoryStore.record(done, registryURL: registryURL)
        let entries = SessionHistoryStore.load(from: registryURL)
        #expect(entries.count == 1, "Samma sessionID ska uppdatera, inte lägga till en ny post.")
        #expect(entries.first?.status == "Klar")
    }

    @Test("pruneMissingOutputDirectories tar bort poster vars outputmapp inte längre finns, behåller resten")
    func prune_removesEntriesForMissingDirectories() {
        let registryURL = tempRegistryURL()
        let existingDir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionHistoryStoreTests-existing-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionHistoryStoreTests-missing-\(UUID().uuidString)")
        // Intentionally never created.

        SessionHistoryStore.record(makeManifest(outputDir: existingDir), registryURL: registryURL)
        SessionHistoryStore.record(makeManifest(outputDir: missingDir), registryURL: registryURL)
        #expect(SessionHistoryStore.load(from: registryURL).count == 2)

        let kept = SessionHistoryStore.pruneMissingOutputDirectories(registryURL: registryURL)
        #expect(kept.count == 1)
        #expect(kept.first?.outputDirectory == existingDir.path)

        // Change persisted to disk, not just the returned value.
        #expect(SessionHistoryStore.load(from: registryURL).count == 1)
    }

    @Test("pruneMissingOutputDirectories är en no-op när alla mappar finns")
    func prune_noMissingDirectories_keepsAll() {
        let registryURL = tempRegistryURL()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionHistoryStoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionHistoryStore.record(makeManifest(outputDir: dir), registryURL: registryURL)

        let kept = SessionHistoryStore.pruneMissingOutputDirectories(registryURL: registryURL)
        #expect(kept.count == 1)
    }

    @Test("Flera adresser i manifestet sparas alla i historikposten")
    func record_multipleAddresses_allPersisted() {
        let registryURL = tempRegistryURL()
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = makeManifest(outputDir: outputDir, addresses: ["Gata A 1", "Gata B 2"])

        SessionHistoryStore.record(manifest, registryURL: registryURL)

        let entries = SessionHistoryStore.load(from: registryURL)
        #expect(Set(entries.first?.addresses ?? []) == ["Gata A 1", "Gata B 2"])
    }
}
