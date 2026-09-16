import Testing
import Foundation
@testable import PhotoFlow

/// Syntetisk, minimal `TimestampedPhoto` för tester — ingen `PhotoItem`
/// behövs (se `FieldNoteMatcher`s klasskommentar för varför).
private struct FakePhoto: TimestampedPhoto {
    let photoID: String
    let capturedAt: Date
}

@Suite("FieldNoteMatcher (Fas 7, matchning av fältanteckningar mot bilder)")
struct FieldNoteMatcherTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(secondsAfterBase: TimeInterval, text: String = "anteckning") -> FieldNote {
        FieldNote(
            recordedAt: Self.base.addingTimeInterval(secondsAfterBase),
            text: text,
            transcriptLanguage: .swedish
        )
    }

    private func photo(id: String, secondsAfterBase: TimeInterval) -> FakePhoto {
        FakePhoto(photoID: id, capturedAt: Self.base.addingTimeInterval(secondsAfterBase))
    }

    @Test("Exakt träff (0s skillnad) matchar rätt bild")
    func exactMatch() {
        let photos = [photo(id: "a", secondsAfterBase: 0), photo(id: "b", secondsAfterBase: 1000)]
        let matches = FieldNoteMatcher.match(notes: [note(secondsAfterBase: 0)], photos: photos)
        #expect(matches.count == 1)
        #expect(matches[0].photoID == "a")
    }

    @Test("Väljer den tidsmässigt närmaste bilden bland flera kandidater")
    func closestOfMultiple() {
        let photos = [
            photo(id: "far", secondsAfterBase: -200),
            photo(id: "closest", secondsAfterBase: 10),
            photo(id: "alsoFar", secondsAfterBase: 300)
        ]
        let matches = FieldNoteMatcher.match(notes: [note(secondsAfterBase: 5)], photos: photos)
        #expect(matches[0].photoID == "closest")
    }

    @Test("Exakt på fönstrets kant (90s) räknas som match")
    func edgeOfWindowMatches() {
        let photos = [photo(id: "a", secondsAfterBase: 0)]
        let matches = FieldNoteMatcher.match(notes: [note(secondsAfterBase: 90)], photos: photos, window: 90)
        #expect(matches[0].photoID == "a")
    }

    @Test("Precis utanför fönstret (90.001s) blir en sessionsanteckning")
    func justOutsideWindowBecomesSessionNote() {
        let photos = [photo(id: "a", secondsAfterBase: 0)]
        let matches = FieldNoteMatcher.match(notes: [note(secondsAfterBase: 90.001)], photos: photos, window: 90)
        #expect(matches[0].photoID == nil)
    }

    @Test("Samma gräns testad från andra hållet (-90s exakt matchar, -90.001s gör inte)")
    func edgeFromNegativeSide() {
        let photos = [photo(id: "a", secondsAfterBase: 0)]
        let onEdge = FieldNoteMatcher.match(notes: [note(secondsAfterBase: -90)], photos: photos, window: 90)
        #expect(onEdge[0].photoID == "a")

        let overEdge = FieldNoteMatcher.match(notes: [note(secondsAfterBase: -90.5)], photos: photos, window: 90)
        #expect(overEdge[0].photoID == nil)
    }

    @Test("Ingen bild alls ger bara sessionsanteckningar")
    func noPhotosGivesSessionNotesOnly() {
        let matches = FieldNoteMatcher.match(notes: [note(secondsAfterBase: 0), note(secondsAfterBase: 1)], photos: [])
        #expect(matches.allSatisfy { $0.photoID == nil })
    }

    @Test("Flera anteckningar kan matcha samma bild oberoende av varandra")
    func multipleNotesToSamePhoto() {
        let photos = [photo(id: "kitchen", secondsAfterBase: 0)]
        let notes = [
            note(secondsAfterBase: -5, text: "fixa reflex i fönster"),
            note(secondsAfterBase: 3, text: "diska disken innan")
        ]
        let matches = FieldNoteMatcher.match(notes: notes, photos: photos)
        #expect(matches.allSatisfy { $0.photoID == "kitchen" })
    }

    @Test("Klockdrift-offset flyttar anteckningens tid innan matchning")
    func clockOffsetCompensatesDrift() {
        // Telefonens klocka går 120s FÖRE kamerans — utan korrigering skulle
        // anteckningen (klockad 120s efter bilden på telefonens klocka)
        // hamna precis utanför ett 90s-fönster mot bildens faktiska
        // (kamera-)tid. Med clockOffset = -120 justeras den tillbaka till 0s
        // skillnad och matchar exakt.
        let photos = [photo(id: "a", secondsAfterBase: 0)]
        let drifted = note(secondsAfterBase: 120)

        let withoutOffset = FieldNoteMatcher.match(notes: [drifted], photos: photos, window: 90)
        #expect(withoutOffset[0].photoID == nil)

        let withOffset = FieldNoteMatcher.match(notes: [drifted], photos: photos, window: 90, clockOffset: -120)
        #expect(withOffset[0].photoID == "a")
    }

    @Test("Positiv klockdrift-offset (telefon går efter kameran)")
    func positiveClockOffset() {
        let photos = [photo(id: "a", secondsAfterBase: 100)]
        let drifted = note(secondsAfterBase: 0) // telefonens klocka 100s efter kamerans

        let withoutOffset = FieldNoteMatcher.match(notes: [drifted], photos: photos, window: 90)
        #expect(withoutOffset[0].photoID == nil)

        let withOffset = FieldNoteMatcher.match(notes: [drifted], photos: photos, window: 90, clockOffset: 100)
        #expect(withOffset[0].photoID == "a")
    }
}
