import Foundation
import Testing
import CoreLocation
@testable import PhotoFlow

/// Tester för Fas 7:s import av fältanteckningar (`PipelineRunner+FieldNotes.swift`):
/// en `FieldNoteBundle` (från "PhotoFlow Fält", iOS) → poster i `photo_notes.json`
/// (samma format `NotesManager` läser) + förslag på rättad GPS-koordinat för
/// adresser vars matchade bild hade en fältantecknings position.
@MainActor
struct PipelineRunnerFieldNotesTests {

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerFieldNotesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePhoto(id: String, date: Date) -> PhotoItem {
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
            dateTime: date
        )
    }

    private func makeRunner(photos: [PhotoItem], outputDir: URL) -> PipelineRunner {
        let state = PipelineState()
        state.outputDirectory = outputDir
        state.allPhotos = photos
        return PipelineRunner(state: state)
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Matchad anteckning skrivs in i photo_notes.json med rätt id/filnamn")
    func matchedNote_writesPhotoNotesEntry() {
        let dir = tempOutputDir()
        let photo = makePhoto(id: "p1", date: Self.base)
        let runner = makeRunner(photos: [photo], outputDir: dir)

        let note = FieldNote(recordedAt: Self.base.addingTimeInterval(5), text: "fixa reflex i fönster", transcriptLanguage: .swedish, roomLabel: "Kök")
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note])

        let summary = runner.importFieldNotes(bundle)

        #expect(summary.totalNotes == 1)
        #expect(summary.matchedPhotoCount == 1)
        #expect(summary.sessionNoteCount == 0)

        let container = PhotoNotes.loadFrom(dir.appendingPathComponent("photo_notes.json"))
        #expect(container?.notes.count == 1)
        let written = container?.notes.first
        #expect(written?.id == "p1")
        #expect(written?.photoFilename == "p1.NEF")
        #expect(written?.originalText == "Kök: fixa reflex i fönster")
        #expect(written?.originalLanguage == .swedish)
    }

    @Test("Sessionsanteckning (ingen matchande bild) får ett field_session_-id och räknas separat")
    func sessionNote_getsSyntheticIDAndIsCountedSeparately() {
        let dir = tempOutputDir()
        let photo = makePhoto(id: "p1", date: Self.base)
        let runner = makeRunner(photos: [photo], outputDir: dir)

        // 1000s bort — långt utanför standardfönstret (90s).
        let note = FieldNote(recordedAt: Self.base.addingTimeInterval(1000), text: "fint väder idag", transcriptLanguage: .swedish)
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note])

        let summary = runner.importFieldNotes(bundle)

        #expect(summary.matchedPhotoCount == 0)
        #expect(summary.sessionNoteCount == 1)

        let container = PhotoNotes.loadFrom(dir.appendingPathComponent("photo_notes.json"))
        let written = container?.notes.first
        #expect(written?.id.hasPrefix("field_session_") == true)
        #expect(written?.originalText == "fint väder idag")
    }

    @Test("Flera anteckningar till samma bild slås ihop till en post, inte skriver över")
    func multipleNotesToSamePhoto_mergedIntoOneEntry() {
        let dir = tempOutputDir()
        let photo = makePhoto(id: "p1", date: Self.base)
        let runner = makeRunner(photos: [photo], outputDir: dir)

        let note1 = FieldNote(recordedAt: Self.base.addingTimeInterval(-5), text: "fixa reflex", transcriptLanguage: .swedish)
        let note2 = FieldNote(recordedAt: Self.base.addingTimeInterval(3), text: "diska disken", transcriptLanguage: .swedish)
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note1, note2])

        let summary = runner.importFieldNotes(bundle)
        #expect(summary.matchedPhotoCount == 1)

        let container = PhotoNotes.loadFrom(dir.appendingPathComponent("photo_notes.json"))
        #expect(container?.notes.count == 1)
        let text = container?.notes.first?.originalText ?? ""
        #expect(text.contains("fixa reflex"))
        #expect(text.contains("diska disken"))
    }

    @Test("Import bevarar en redan existerande anteckning för en annan bild")
    func import_preservesExistingNoteForOtherPhoto() {
        let dir = tempOutputDir()
        let photo1 = makePhoto(id: "p1", date: Self.base)
        let photo2 = makePhoto(id: "p2", date: Self.base.addingTimeInterval(500))
        let runner = makeRunner(photos: [photo1, photo2], outputDir: dir)

        // Pre-existing note for p2, written before the import (e.g. dictated
        // directly in the review view).
        let existing = PhotoNotes(
            notes: [PhotoNote(id: "p2", originalText: "befintlig anteckning", originalLanguage: .swedish, translatedText: "", targetLanguage: .english, timestamp: Date(), photoFilename: "p2.NEF")],
            sessionDate: Date(), inputFolder: "test", address: nil
        )
        try! existing.saveTo(dir.appendingPathComponent("photo_notes.json"))

        let note = FieldNote(recordedAt: Self.base, text: "ny anteckning", transcriptLanguage: .swedish)
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note])
        _ = runner.importFieldNotes(bundle)

        let container = PhotoNotes.loadFrom(dir.appendingPathComponent("photo_notes.json"))
        #expect(container?.notes.count == 2)
        #expect(container?.notes.first { $0.id == "p2" }?.originalText == "befintlig anteckning")
        #expect(container?.notes.first { $0.id == "p1" }?.originalText == "ny anteckning")
    }

    @Test("GPS på en matchad anteckning föreslår rättad koordinat för bildens adress")
    func gpsOnMatchedNote_suggestsCorrectedCoordinateForAddress() {
        let dir = tempOutputDir()
        let photo = makePhoto(id: "p1", date: Self.base)
        let runner = makeRunner(photos: [photo], outputDir: dir)
        runner.calendarMappings = [
            (address: "Lindvägen 12, Tyresö", eventTitle: "Fotografering", photoDateRange: Self.base.addingTimeInterval(-3600)...Self.base.addingTimeInterval(3600))
        ]

        let coordinate = FieldCoordinate(latitude: 59.25, longitude: 18.05, horizontalAccuracy: 5)
        let note = FieldNote(recordedAt: Self.base, text: "kök", transcriptLanguage: .swedish, coordinate: coordinate)
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note])

        let summary = runner.importFieldNotes(bundle)

        #expect(summary.correctedAddresses.count == 1)
        let corrected = summary.correctedAddresses.first
        #expect(corrected?.address == "Lindvägen 12, Tyresö")
        #expect(abs((corrected?.coordinate.latitude ?? 0) - 59.25) < 0.0001)
        #expect(abs((corrected?.coordinate.longitude ?? 0) - 18.05) < 0.0001)
    }

    @Test("Ingen matchande calendarMappings-adress ger inga rättningsförslag")
    func gpsWithoutMatchingAddress_producesNoCorrections() {
        let dir = tempOutputDir()
        let photo = makePhoto(id: "p1", date: Self.base)
        let runner = makeRunner(photos: [photo], outputDir: dir)
        // No calendarMappings set at all.

        let coordinate = FieldCoordinate(latitude: 59.25, longitude: 18.05, horizontalAccuracy: 5)
        let note = FieldNote(recordedAt: Self.base, text: "kök", transcriptLanguage: .swedish, coordinate: coordinate)
        let bundle = FieldNoteBundle(exportedAt: Date(), deviceName: "iPhone", notes: [note])

        let summary = runner.importFieldNotes(bundle)
        #expect(summary.correctedAddresses.isEmpty)
    }
}
