import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the single-source-of-truth fix: `PipelineState.allPhotos` used to be
/// duplicated inside `BracketGroup.photos`, so a decision made in BracketReviewView
/// (which only edited the group's copy) could be invisible to PreviewCullView/
/// `saveCullDecisions` (which only read `allPhotos`), and vice versa. `BracketGroup`
/// now only stores `photoIDs`; `PipelineState.photos(in:)` resolves them from
/// `allPhotos`, and `setDecision`/`setAlgorithmSuggested` are the only way to change
/// a decision.
@MainActor
struct PipelineStateCullDecisionsTests {

    private func makePhoto(id: String) -> PhotoItem {
        PhotoItem(
            id: id,
            filename: "\(id).NEF",
            nefURL: URL(fileURLWithPath: "/tmp/\(id).NEF"),
            dngURL: nil,
            previewURL: nil,
            exposureTime: "1/125",
            exposureSeconds: 1.0 / 125.0,
            fNumber: 8.0,
            iso: 100,
            dateTime: Date()
        )
    }

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineStateCullDecisionsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("photos(in:) löser upp photoIDs från allPhotos i gruppens ordning")
    func photosInGroup_resolvesFromAllPhotos() {
        let state = PipelineState()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b"), makePhoto(id: "c")]
        let group = BracketGroup(
            id: 1, isBracket: true, folderName: "bracket_001",
            photoIDs: ["c", "a"], fNumber: 8, iso: 100,
            timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 2
        )
        let resolved = state.photos(in: group)
        #expect(resolved.map(\.id) == ["c", "a"])
    }

    @Test("Beslut satt via grupp (setDecision) syns direkt i allPhotos")
    func setDecision_viaGroup_isVisibleInAllPhotos() {
        let state = PipelineState()
        state.allPhotos = [makePhoto(id: "a"), makePhoto(id: "b")]
        let group = BracketGroup(
            id: 1, isBracket: true, folderName: "bracket_001",
            photoIDs: ["a", "b"], fNumber: 8, iso: 100,
            timeStart: "10:00", timeEnd: "10:01", exposureRangeStops: 2
        )

        // Simulates what BracketReviewView does: resolve the photo through the
        // group, then set the decision by ID.
        let photo = state.photos(in: group)[0]
        state.setDecision(photoID: photo.id, accepted: true, rejected: false)

        #expect(state.allPhotos[0].accepted == true)
        #expect(state.photos(in: group)[0].accepted == true)
        #expect(state.selectedCount(in: group) == 1)
        #expect(state.allReviewed(group) == false)

        state.setDecision(photoID: "b", accepted: false, rejected: true)
        #expect(state.allReviewed(group) == true)
    }

    @Test("saveCullDecisions/loadCullDecisions gör en rundtripp via allPhotos")
    func saveCullDecisions_roundTripsThroughAllPhotos() {
        let state = PipelineState()
        state.outputDirectory = tempOutputDir()
        state.allPhotos = [makePhoto(id: "x"), makePhoto(id: "y"), makePhoto(id: "z")]
        state.setDecision(photoID: "x", accepted: true, rejected: false)
        state.setDecision(photoID: "y", accepted: false, rejected: true)
        // "z" stays undecided.

        state.saveCullDecisions()
        let loaded = state.loadCullDecisions()

        #expect(loaded["x"] == "accepted")
        #expect(loaded["y"] == "rejected")
        #expect(loaded["z"] == nil)
    }

    @Test("setAlgorithmSuggested ändrar bara den angivna bilden")
    func setAlgorithmSuggested_onlyAffectsTargetPhoto() {
        let state = PipelineState()
        var a = makePhoto(id: "a")
        a.algorithmSuggested = true
        state.allPhotos = [a, makePhoto(id: "b")]

        state.setAlgorithmSuggested(photoID: "a", suggested: false)

        #expect(state.allPhotos[0].algorithmSuggested == false)
        #expect(state.allPhotos[1].algorithmSuggested == false)
    }
}
