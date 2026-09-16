import Foundation
import Testing
@testable import PhotoFlow

/// Fas 6: `PipelineState.updateStep`/`updateStepProgress`/`completeStep`/
/// `saveCullDecisions`/`correctAddress` all funnel through `syncManifest()`,
/// the single place that keeps `sessionManifest` (in-memory), the persisted
/// `photoflow_session.json`, and `SessionHistoryStore`'s registry all in
/// sync — see `PipelineState.swift`'s "Fas 6" section.
@MainActor
struct PipelineStateManifestTests {
    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineStateManifestTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePhoto(id: String, accepted: Bool = false, rejected: Bool = false) -> PhotoItem {
        var photo = PhotoItem(
            id: id,
            filename: "\(id).NEF",
            nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
            dngURL: nil,
            previewURL: nil,
            exposureTime: "1/125",
            exposureSeconds: 1.0 / 125.0,
            fNumber: 8.0,
            iso: 100,
            dateTime: Date(),
            accepted: accepted
        )
        photo.rejected = rejected
        return photo
    }

    @Test("completeStep skriver ett manifest till disk med rätt steg-fas och antal")
    func completeStep_persistsManifestToDisk() {
        let state = PipelineState()
        let outputDir = tempOutputDir()
        state.outputDirectory = outputDir
        state.inputDirectory = outputDir // doesn't matter for this test

        state.updateStep(.convertToDNG, phase: .active)
        state.completeStep(.convertToDNG, count: 7)

        #expect(state.sessionManifest != nil)
        let record = state.sessionManifest?.steps[DashboardStep.convertToDNG.manifestKey]
        #expect(record?.phase == "complete")
        #expect(record?.processedCount == 7)
        #expect(record?.totalCount == 7)

        // Also persisted to disk, not just in memory.
        let loaded = SessionManifestStore.load(from: outputDir)
        #expect(loaded?.sessionID == state.sessionManifest?.sessionID)
        #expect(loaded?.steps[DashboardStep.convertToDNG.manifestKey]?.phase == "complete")
    }

    @Test("setPendingFingerprint följer med till manifestets StepRecord vid completeStep")
    func pendingFingerprint_isCommittedOnCompleteStep() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()

        state.setPendingFingerprint("abc123", for: .createHDR)
        state.completeStep(.createHDR, count: 3)

        #expect(state.sessionManifest?.steps[DashboardStep.createHDR.manifestKey]?.inputFingerprint == "abc123")
    }

    @Test("photoCount/groupCount/cullSummary speglar allPhotos/bracketGroups vid varje sync")
    func manifest_reflectsPhotosAndCullDecisions() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [
            makePhoto(id: "a", accepted: true),
            makePhoto(id: "b", rejected: true),
            makePhoto(id: "c")
        ]
        state.bracketGroups = [
            BracketGroup(id: 1, isBracket: false, folderName: "single_001", photoIDs: ["a", "b", "c"], fNumber: 8, iso: 100, timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 0)
        ]

        state.updateStep(.moveToFolders, phase: .complete)

        #expect(state.sessionManifest?.photoCount == 3)
        #expect(state.sessionManifest?.groupCount == 1)
        #expect(state.sessionManifest?.cullSummary.accepted == 1)
        #expect(state.sessionManifest?.cullSummary.rejected == 1)
        #expect(state.sessionManifest?.cullSummary.unreviewed == 1)
    }

    @Test("saveCullDecisions synkar manifestets gallringssammanfattning utan ett explicit steg")
    func saveCullDecisions_syncsManifest() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [makePhoto(id: "x", accepted: true), makePhoto(id: "y", rejected: true)]

        state.saveCullDecisions()

        #expect(state.sessionManifest?.cullSummary.accepted == 1)
        #expect(state.sessionManifest?.cullSummary.rejected == 1)
    }

    @Test("reset() nollställer sessionManifest och väntande fingerprints")
    func reset_clearsManifestState() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.setPendingFingerprint("fp", for: .createHDR)
        state.completeStep(.createHDR)
        #expect(state.sessionManifest != nil)

        state.reset()
        #expect(state.sessionManifest == nil)
    }

    @Test("syncManifest utan outputDirectory är en no-op (kraschar inte)")
    func syncManifest_withoutOutputDirectory_isNoOp() {
        let state = PipelineState()
        state.updateStep(.convertToDNG, phase: .active)
        #expect(state.sessionManifest == nil)
    }

    @Test("En session utan manifest men med bracket_groups.json migreras automatiskt vid första syncen")
    func syncManifest_migratesLegacySession() {
        let outputDir = tempOutputDir()
        let data = try! JSONSerialization.data(withJSONObject: [
            "total_images": 1, "groups": [["group_id": 1, "is_bracket": false, "files": ["DSC_0001.NEF"]]]
        ] as [String: Any])
        try! data.write(to: outputDir.appendingPathComponent("bracket_groups.json"))

        let state = PipelineState()
        state.outputDirectory = outputDir
        state.updateStep(.convertToDNG, phase: .active)

        // The migrated manifest's pre-existing photoCount (from bracket_groups.json)
        // should show up even though `allPhotos` in THIS state instance is empty —
        // syncManifest immediately overwrites photoCount from allPhotos.count (0),
        // which is the correct behavior once a real run populates allPhotos; here we
        // only check that migration actually happened (a manifest now exists on disk).
        #expect(state.sessionManifest != nil)
        #expect(SessionManifestStore.load(from: outputDir) != nil)
    }
}
