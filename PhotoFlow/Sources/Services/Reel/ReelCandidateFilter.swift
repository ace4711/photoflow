import Foundation

/// Filtren i bildspelsfönstrets rutnät (plan 4.4): vilka bilder som visas för ett valt läge och rum.
/// Ren logik på `ReelEditorModel.CandidateRow`, så att den går att testa utan vy.
nonisolated enum ReelCandidateFilter {

    /// Läget i rutnätets segmentväljare.
    nonisolated enum Scope: String, CaseIterable, Sendable, Equatable {
        /// Alla bilder.
        case all
        /// Bilder som är med i filmen.
        case inFilm
        /// Bilder som kan läggas till: inte med i filmen och inte uteslutna eller bortfiltrerade.
        case notInFilm
        /// Uteslutna av fotografen eller bortfiltrerade av urvalet (har ett bortfallsskäl), även om
        /// fotografen ändå lagt in en sådan bild i filmen.
        case excluded

        var label: String {
            switch self {
            case .all: return "Alla"
            case .inFilm: return "I filmen"
            case .notInFilm: return "Ej i filmen"
            case .excluded: return "Uteslutna"
            }
        }

        func matches(_ row: ReelEditorModel.CandidateRow) -> Bool {
            switch self {
            case .all: return true
            case .inFilm: return row.clipIndex != nil
            case .notInFilm: return row.clipIndex == nil && row.excludedReason == nil
            case .excluded: return row.excludedReason != nil
            }
        }
    }

    /// Raderna som matchar läget och, om `room` anges, rummet (`CandidateRow.roomLabel`). Ordningen behålls.
    static func filter(_ rows: [ReelEditorModel.CandidateRow], scope: Scope, room: String?) -> [ReelEditorModel.CandidateRow] {
        rows.filter { scope.matches($0) && (room == nil || $0.roomLabel == room) }
    }

    /// Rummen som finns bland bilderna, i bokstavsordning (svensk sortering), utan dubbletter.
    static func rooms(_ rows: [ReelEditorModel.CandidateRow]) -> [String] {
        Array(Set(rows.map(\.roomLabel))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Antal bilder per läge (för etiketterna i segmentväljaren), inom rummet om det anges.
    static func counts(_ rows: [ReelEditorModel.CandidateRow], room: String?) -> [Scope: Int] {
        Dictionary(uniqueKeysWithValues: Scope.allCases.map { ($0, filter(rows, scope: $0, room: room).count) })
    }
}
