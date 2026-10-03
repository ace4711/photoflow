import Foundation
import Testing
@testable import PhotoFlow

/// `PipelineRunner.descriptionSample`: vilka bilder som får en ML-beskrivning.
struct AIDescriptionSampleTests {

    func entry(caption: String? = nil, attempted: Bool? = nil) -> AITagsStore.Entry {
        var e = AITagsStore.Entry(tags: [], description: "", category: "", mlCaption: caption)
        e.mlAttempted = attempted
        return e
    }

    let groups = ["A1": 1, "A2": 1, "A3": 1, "B1": 2, "B2": 2]

    @Test("Första körningen: en bild per grupp plus ogrupperade")
    func firstRun() {
        let sample = PipelineRunner.descriptionSample(
            previewBaseNames: ["A1", "A2", "A3", "B1", "B2", "S1"], stored: [:], groupByFilename: groups
        )
        #expect(sample == ["A1", "B1", "S1"])
    }

    @Test("Omkörning: grupper som redan beskrivits väljs inte igen via nästa bild")
    func rerun_skipsDescribedGroups() {
        let stored = ["A1": entry(caption: "Kök"), "B1": entry(caption: "Fasad"), "S1": entry(caption: "Hall")]
        let sample = PipelineRunner.descriptionSample(
            previewBaseNames: ["A1", "A2", "A3", "B1", "B2", "S1"], stored: stored, groupByFilename: groups
        )
        #expect(sample.isEmpty)
    }

    @Test("Ett misslyckat försök görs inte om vid varje körning")
    func rerun_skipsFailedAttempts() {
        let stored = ["A1": entry(attempted: true), "B1": entry(caption: "Fasad"), "S1": entry(attempted: true)]
        let sample = PipelineRunner.descriptionSample(
            previewBaseNames: ["A1", "A2", "A3", "B1", "B2", "S1", "S2"], stored: stored, groupByFilename: groups
        )
        #expect(sample == ["S2"])
    }
}
