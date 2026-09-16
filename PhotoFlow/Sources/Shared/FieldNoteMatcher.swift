import Foundation

/// Minimal, plattformsoberoende vy av en bild som `FieldNoteMatcher` matchar
/// mot — bara ett id och en tidsstämpel. Mac-appens `PhotoItem` (som drar in
/// `CoreLocation`-oberoende men ändå plattformsspecifika beroenden på sikt)
/// konformar till detta i stället för att `PhotoItem` självt flyttas till
/// `Sources/Shared`, så matchningslogiken går att enhetstesta med rena
/// syntetiska structs utan att dra in resten av Mac-appens modeller.
protocol TimestampedPhoto {
    var photoID: String { get }
    var capturedAt: Date { get }
}

/// Matchar dikterade fältanteckningar (`FieldNote`, inspelade på iPhone) mot
/// sessionens bilder via tidsstämpel — se planen i Fas 7: fotografen dikterar
/// "kök, fixa reflexen i fönstret" på plats, och anteckningen ska senare
/// hamna vid rätt bild på Mac:en.
///
/// **Algoritm**: för varje anteckning, justera dess tidsstämpel med
/// `clockOffset` (kompenserar klockdrift mellan telefon och kamera — positiv
/// om telefonens klocka går FÖRE kamerans, dvs. `photoTime ≈ noteTime -
/// clockOffset`) och hitta bilden med minsta absoluta tidsskillnad. Om den
/// skillnaden är inom `window` (inklusive kanten) blir anteckningen kopplad
/// till den bilden; annars blir den en "sessionsanteckning" (`photoID ==
/// nil`) — t.ex. en anteckning om hela huset ("fint väder idag") som inte
/// hör till en specifik bild.
///
/// Flera anteckningar kan matcha samma bild (varje anteckning matchas
/// oberoende av de andra) — det är avsett, se uppgiftsbeskrivningen
/// ("flera anteckningar till samma bild").
enum FieldNoteMatcher {
    static let defaultWindow: TimeInterval = 90

    struct Match {
        let note: FieldNote
        /// `nil` om ingen bild låg inom `window` — en sessionsanteckning.
        let photoID: String?
    }

    /// - Parameters:
    ///   - notes: Anteckningarna som ska matchas, i valfri ordning.
    ///   - photos: Sessionens bilder (id + tidsstämpel).
    ///   - window: Max tillåten absolut tidsskillnad, i sekunder. Standard
    ///     ±90s enligt planen. Måste vara >= 0.
    ///   - clockOffset: Sekunder att lägga till varje anteckning innan
    ///     matchning, för att kompensera klockdrift mellan telefon och
    ///     kamera. 0 = ingen korrigering.
    static func match(
        notes: [FieldNote],
        photos: [TimestampedPhoto],
        window: TimeInterval = defaultWindow,
        clockOffset: TimeInterval = 0
    ) -> [Match] {
        guard !photos.isEmpty else {
            return notes.map { Match(note: $0, photoID: nil) }
        }

        return notes.map { note in
            let adjustedTime = note.recordedAt.addingTimeInterval(clockOffset)

            // `min(by:)` returnerar den FÖRSTA bilden vid oavgjort, vilket ger
            // deterministiskt beteende (stabilt för samma indata) i stället
            // för att bero på osorterad ordning.
            let best = photos.min { lhs, rhs in
                abs(lhs.capturedAt.timeIntervalSince(adjustedTime)) < abs(rhs.capturedAt.timeIntervalSince(adjustedTime))
            }

            guard let best, abs(best.capturedAt.timeIntervalSince(adjustedTime)) <= window else {
                return Match(note: note, photoID: nil)
            }
            return Match(note: note, photoID: best.photoID)
        }
    }
}
