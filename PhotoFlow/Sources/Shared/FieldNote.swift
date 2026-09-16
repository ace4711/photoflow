import Foundation

/// En dikterad fältanteckning, spelas in på iPhone-appen "PhotoFlow Fält"
/// (Fas 7) medan fotografen är på plats. Skickas senare till Mac-appen som
/// en `FieldNoteBundle` (se `FieldNoteBundle.swift`) och matchas mot
/// sessionens bilder via tidsstämpel (se `FieldNoteMatcher.swift`).
///
/// Delad mellan `PhotoFlowField` (iOS, skapar anteckningarna) och
/// `PhotoFlow` (macOS, importerar och matchar dem) — därför i
/// `Sources/Shared`, utan beroenden till CoreLocation/AppKit/UIKit (bara
/// `Foundation`), så samma fil kompilerar oförändrat på båda plattformarna.
struct FieldNote: Codable, Identifiable, Hashable {
    var id: UUID
    /// Exakt tidpunkt (enhetens klocka) då inspelningen stoppades/anteckningen
    /// sparades — det här är fältet `FieldNoteMatcher` matchar mot bildernas
    /// `dateTime` (EXIF `DateTimeOriginal`).
    var recordedAt: Date
    var text: String
    var transcriptLanguage: PhotoNote.NoteLanguage
    /// `nil` om platsbehörighet saknades eller ingen positionsfix hanns tas
    /// innan anteckningen sparades — appen ska fortfarande spara texten.
    var coordinate: FieldCoordinate?
    /// Snabbval i appen: "Kök", "Badrum", "Fasad", etc. Fritt textfält, inte
    /// en enum, så nya rum kan läggas till i appen utan en delad modelländring.
    var roomLabel: String?
    /// Hur många bilder fotografen sa sig mena med anteckningen (t.ex. "de här
    /// tre bilderna av köket") — rent informativt, `FieldNoteMatcher` matchar
    /// fortfarande bara mot EN bild (den tidsmässigt närmaste); resten är upp
    /// till användaren att härleda manuellt om värdet är > 1.
    var photoHintCount: Int?

    init(
        id: UUID = UUID(),
        recordedAt: Date,
        text: String,
        transcriptLanguage: PhotoNote.NoteLanguage,
        coordinate: FieldCoordinate? = nil,
        roomLabel: String? = nil,
        photoHintCount: Int? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.text = text
        self.transcriptLanguage = transcriptLanguage
        self.coordinate = coordinate
        self.roomLabel = roomLabel
        self.photoHintCount = photoHintCount
    }
}

/// Enkel lat/lon + noggrannhet, utan `CoreLocation`-beroende (`Foundation`
/// räcker) — så typen är trivialt `Codable` och kan användas i ren
/// Swift Testing-kod utan att importera CoreLocation. Mac-appen konverterar
/// till/från `CLLocationCoordinate2D` vid gränsytan (se
/// `PipelineRunner+FieldNotes.swift`).
struct FieldCoordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    /// Horisontell noggrannhet i meter, från `CLLocation.horizontalAccuracy`.
    /// `nil`/negativ betyder okänd noggrannhet (samma konvention som
    /// CoreLocation självt använder för "ogiltig" noggrannhet).
    var horizontalAccuracy: Double?
}
