import Foundation
import CoreLocation

/// `PhotoItem` behöver bara id + tidsstämpel för att matchas av
/// `FieldNoteMatcher` (se `Sources/Shared/FieldNoteMatcher.swift` för varför
/// matchningen är byggd mot ett litet protokoll i stället för `PhotoItem`
/// direkt — `PhotoItem` självt stannar kvar i macOS-appens `Models/`, det är
/// bara den här konformansen som behövs för att koppla ihop dem).
extension PhotoItem: TimestampedPhoto {
    var photoID: String { id }
    var capturedAt: Date { dateTime }
}

/// Resultatet av en fältanteckningsimport — visas för användaren som en
/// sammanfattning ("12 anteckningar, 10 matchade bilder, 2
/// sessionsanteckningar") och loggas.
struct FieldNotesImportSummary {
    let totalNotes: Int
    let matchedPhotoCount: Int
    let sessionNoteCount: Int
    /// Adresser vars koordinat rättades utifrån en fältantecknings GPS-
    /// position (se `PipelineRunner.importFieldNotes`s dokkommentar).
    let correctedAddresses: [(address: String, coordinate: CLLocationCoordinate2D)]
}

extension PipelineRunner {
    /// Importerar en `.photoflownotes`-bunt (från "PhotoFlow Fält", iOS):
    /// matchar varje anteckning mot sessionens bilder via
    /// `FieldNoteMatcher` (tidsstämpel, ±`AppSettings.fieldNotesMatchWindowSeconds`,
    /// klockdrift `AppSettings.fieldNotesClockOffsetSeconds`), skriver in dem
    /// i `photo_notes.json` (samma fil/format `NotesManager` läser — så de
    /// dyker upp i dikteringspanelen vid rätt bild nästa gång en granskningsvy
    /// öppnas/laddar om), och — om en matchad anteckning har en GPS-position —
    /// föreslår den positionen som "rättad koordinat" för adressen den
    /// tillhör (samma mekanism som en manuell adressrättning i
    /// `AddressBanner`, se `PipelineState.correctAddress`), eftersom en
    /// riktig GPS-fix från platsen nästan alltid slår en geokodad adress.
    ///
    /// Anropar INTE `state.correctAddress` själv — returnerar bara förslagen
    /// (`FieldNotesImportSummary.correctedAddresses`) så anroparen (UI:t) kan
    /// slå upp rätt index i `state.allMatchedAddresses` och visa/logga vilken
    /// adress som ändras innan den appliceras.
    ///
    /// Anteckningar utan en matchande bild inom fönstret ("sessionsanteckningar")
    /// skrivs också in, med ett syntetiskt id (`field_session_<uuid>`) och en
    /// tydlig `photoFilename`-markör — de dyker då upp i
    /// `NotesManager.emailBody`/anteckningsräkningen men inte knutna till
    /// någon specifik bild i granskningsvyerna.
    @discardableResult
    func importFieldNotes(_ bundle: FieldNoteBundle) -> FieldNotesImportSummary {
        let photos: [TimestampedPhoto] = state.allPhotos
        let matches = FieldNoteMatcher.match(
            notes: bundle.notes,
            photos: photos,
            window: AppSettings.shared.fieldNotesMatchWindowSeconds,
            clockOffset: AppSettings.shared.fieldNotesClockOffsetSeconds
        )

        var container = loadPhotoNotesContainer()
        var notesByID = Dictionary(uniqueKeysWithValues: container.notes.map { ($0.id, $0) })
        var matchedPhotoIDs: Set<String> = []
        var sessionCount = 0

        // photoID → alla GPS-koordinater från anteckningar som matchade en
        // bild med den identiteten, i den ordning de kom in i bunten.
        var coordinatesByPhotoID: [String: [CLLocationCoordinate2D]] = [:]

        for match in matches {
            let note = match.note
            let roomPrefix = note.roomLabel.map { "\($0): " } ?? ""
            let text = roomPrefix + note.text

            if let photoID = match.photoID {
                matchedPhotoIDs.insert(photoID)
                let photo = state.allPhotos.first { $0.id == photoID }
                let filename = photo?.filename ?? photoID

                if var existing = notesByID[photoID] {
                    // Flera fältanteckningar kan matcha samma bild (se
                    // FieldNoteMatcher) — lägg till i stället för att skriva
                    // över en anteckning som redan fanns (t.ex. dikterad
                    // direkt i granskningsvyn innan importen).
                    existing.originalText = existing.originalText.isEmpty ? text : existing.originalText + "\n" + text
                    notesByID[photoID] = existing
                } else {
                    notesByID[photoID] = PhotoNote(
                        id: photoID,
                        originalText: text,
                        originalLanguage: note.transcriptLanguage,
                        translatedText: "",
                        targetLanguage: note.transcriptLanguage.other,
                        timestamp: note.recordedAt,
                        photoFilename: filename
                    )
                }

                if let coordinate = note.coordinate {
                    coordinatesByPhotoID[photoID, default: []].append(
                        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    )
                }
            } else {
                sessionCount += 1
                let sessionID = "field_session_\(note.id.uuidString)"
                notesByID[sessionID] = PhotoNote(
                    id: sessionID,
                    originalText: text,
                    originalLanguage: note.transcriptLanguage,
                    translatedText: "",
                    targetLanguage: note.transcriptLanguage.other,
                    timestamp: note.recordedAt,
                    photoFilename: "(sessionsanteckning – ingen bild inom \(Int(AppSettings.shared.fieldNotesMatchWindowSeconds))s)"
                )
            }
        }

        container.notes = Array(notesByID.values).sorted { $0.timestamp < $1.timestamp }
        savePhotoNotesContainer(container)

        // Slå upp vilken adress varje matchad bild med GPS hör till, via
        // samma `calendarMappings`-datumintervall som kalenderstegets
        // adressmatchning redan byggt (se PipelineRunner+Calendar.swift) —
        // en bild "hör till" en adress om dess tagningstid ligger i
        // adressens matchade bokningsintervall.
        var coordinateSumsByAddress: [String: (sumLat: Double, sumLon: Double, count: Int)] = [:]
        for (photoID, coordinates) in coordinatesByPhotoID {
            guard let photo = state.allPhotos.first(where: { $0.id == photoID }) else { continue }
            guard let address = calendarMappings.first(where: { $0.photoDateRange.contains(photo.dateTime) })?.address else { continue }
            for coordinate in coordinates {
                var entry = coordinateSumsByAddress[address] ?? (0, 0, 0)
                entry.sumLat += coordinate.latitude
                entry.sumLon += coordinate.longitude
                entry.count += 1
                coordinateSumsByAddress[address] = entry
            }
        }
        let correctedAddresses: [(address: String, coordinate: CLLocationCoordinate2D)] = coordinateSumsByAddress.map { address, sums in
            (address: address, coordinate: CLLocationCoordinate2D(latitude: sums.sumLat / Double(sums.count), longitude: sums.sumLon / Double(sums.count)))
        }

        let summary = FieldNotesImportSummary(
            totalNotes: bundle.notes.count,
            matchedPhotoCount: matchedPhotoIDs.count,
            sessionNoteCount: sessionCount,
            correctedAddresses: correctedAddresses
        )

        state.appendLog(
            "Fältanteckningar importerade: \(summary.totalNotes) st, \(summary.matchedPhotoCount) matchade bilder, \(summary.sessionNoteCount) sessionsanteckningar (från \(bundle.deviceName)).",
            type: .success
        )
        for corrected in correctedAddresses {
            state.appendLog(
                "Fältanteckning har GPS för \"\(corrected.address)\" — föreslår rättad koordinat (\(String(format: "%.6f", corrected.coordinate.latitude)), \(String(format: "%.6f", corrected.coordinate.longitude))).",
                type: .info
            )
        }

        return summary
    }

    private func photoNotesURL() -> URL? {
        state.outputDirectory?.appendingPathComponent("photo_notes.json")
    }

    private func loadPhotoNotesContainer() -> PhotoNotes {
        if let url = photoNotesURL(), let existing = PhotoNotes.loadFrom(url) {
            return existing
        }
        return PhotoNotes(notes: [], sessionDate: Date(), inputFolder: state.outputDirectory?.lastPathComponent ?? "", address: state.matchedAddress)
    }

    private func savePhotoNotesContainer(_ container: PhotoNotes) {
        guard let url = photoNotesURL(), let outputDir = state.outputDirectory else { return }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? container.saveTo(url)
    }
}
