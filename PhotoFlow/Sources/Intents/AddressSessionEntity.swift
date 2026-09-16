import AppIntents
import CoreSpotlight
import Foundation

/// En adress-"session" — en kalendermatchad bokning i en outputmapp. Fas 6:
/// `AddressSessionLoader` aggregerar nu over ALLA kanda outputmappar
/// (`SessionHistoryStore`s register), inte bara den senaste/aktuella
/// korningen (Fas 3f:s ursprungliga begransning) — se dess klasskommentar.
///
/// `IndexedEntity` (macOS 15+, verifierat i SDK:n) later `AddressSessionQuery`
/// aven indexera dessa i Spotlights semantiska index via
/// `CSSearchableIndex.indexAppEntities(_:)` — standardimplementationen av
/// `attributeSet` (titel/undertitel fran `displayRepresentation`) racker gott
/// har, ingen anpassad `CSSearchableItemAttributeSet` byggs for hand.
struct AddressSessionEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "PhotoFlow-session"
    static let defaultQuery = AddressSessionQuery()

    let id: String
    let address: String
    let eventTitle: String
    let date: Date
    let imageCount: Int
    let acceptedCount: Int

    var displayRepresentation: DisplayRepresentation {
        let dateStr = Self.dateFormatter.string(from: date)
        return DisplayRepresentation(
            title: "\(address)",
            subtitle: "\(eventTitle) \u{2014} \(dateStr) \u{2014} \(imageCount) bilder, \(acceptedCount) godkanda"
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "sv_SE")
        return formatter
    }()
}

/// Enumererbar sa bade "Hitta sessioner"-genvagen och Spotlight-indexeringen
/// kan lista ALLA sessioner (inte bara sla upp kanda id:n).
struct AddressSessionQuery: EnumerableEntityQuery {
    func entities(for identifiers: [AddressSessionEntity.ID]) async throws -> [AddressSessionEntity] {
        let all = try await allEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func allEntities() async throws -> [AddressSessionEntity] {
        let sessions = AddressSessionLoader.loadCurrentSessions()
        // Bast-forsok-indexering i Spotlight — fel (t.ex. indexet otillgangligt)
        // ska aldrig hindra att sessionerna anda returneras till anroparen.
        if #available(macOS 15.0, *) {
            try? await CSSearchableIndex.default().indexAppEntities(sessions)
        }
        return sessions
    }
}

/// "Hitta sessioner i PhotoFlow" — listar (valfritt filtrerat pa
/// adress/bokningstitel) adress-sessionerna over ALLA kanda korningar
/// (Fas 6: `SessionHistoryStore`), inte bara den senaste.
struct FindSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Hitta sessioner i PhotoFlow"
    static let description = IntentDescription(
        "Listar adresser fran alla kanda PhotoFlow-sessioner, med antal bilder och hur manga som ar godkanda."
    )

    @Parameter(title: "Sokterm", description: "Filtrera pa adress eller bokningstitel. Lamna tom for alla.")
    var searchTerm: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Hitta sessioner i PhotoFlow \(\.$searchTerm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AddressSessionEntity]> & ProvidesDialog {
        let all = try await AddressSessionQuery().allEntities()
        let filtered: [AddressSessionEntity]
        if let term = searchTerm, !term.isEmpty {
            filtered = all.filter {
                $0.address.localizedCaseInsensitiveContains(term) || $0.eventTitle.localizedCaseInsensitiveContains(term)
            }
        } else {
            filtered = all
        }

        let dialog: IntentDialog = filtered.isEmpty
            ? "Inga sessioner hittades."
            : "Hittade \(filtered.count) session(er)."
        return .result(value: filtered, dialog: dialog)
    }
}
