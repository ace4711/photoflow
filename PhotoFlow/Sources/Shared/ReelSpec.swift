import Foundation

/// ReelSpec v1: den plattformsoberoende beskrivningen av ett bildspel
/// ("Objektfilm"). Specen säger *vad* som ska synas vid tid *t*, aldrig *hur*
/// en viss renderare gör det; formlerna finns i `ReelTimeline` och
/// `docs/reel-spec-v1.md`.
///
/// Ligger i `Sources/Shared` (bara Foundation) så att iOS-målet och en framtida
/// webbrenderare kan dela formatet. Alla typer är `nonisolated` eftersom
/// projektet annars gör dem MainActor-isolerade, och specen ska kunna kodas
/// och räknas på från vilken tråd som helst.
///
/// Avkodning tål okända fält (JSONDecoder ignorerar dem), så tillägg är
/// tillåtna inom v1. Brytande ändringar höjer `version` och `minReaderVersion`;
/// en läsare ska vägra spec med `minReaderVersion > ReelSpec.currentVersion`
/// (se `isReadable`).
nonisolated struct ReelSpec: Codable, Sendable, Equatable {

    /// Fast värde i `schema`, så att en läsare kan avgöra att filen är en reel.
    static let schemaName = "photoflow.reel"
    /// Den schemaversion den här koden skriver och förstår.
    static let currentVersion = 1

    var schema: String
    var version: Int
    var minReaderVersion: Int
    var id: String
    var revision: Int
    /// Fritext ("draft", "approved", ...). Inte en enum: nya statusar ska inte
    /// göra att äldre läsare inte kan öppna filen.
    var status: String
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UpdatedBy
    var property: Property
    var assets: [Asset]
    var style: Style
    var timeline: [Clip]
    /// Alltid `null` i v1 (ingen inbränd musik), men typat så att fältet finns.
    var audio: Audio?
    /// Reserverad (textlager, Fas 3). Renderare i v1 ignorerar listan.
    var overlays: [Overlay]
    var brand: Brand?
    var outputs: [Output]
    var provenance: Provenance

    /// Kan den här koden läsa filen? (`schema` rätt och inget brytande krav.)
    var isReadable: Bool {
        schema == Self.schemaName && minReaderVersion <= Self.currentVersion
    }

    // MARK: - Delstrukturer

    nonisolated struct UpdatedBy: Codable, Sendable, Equatable {
        /// "photographer", "agent", ...
        var role: String
        var name: String?
    }

    nonisolated struct Property: Codable, Sendable, Equatable {
        var address: String
        var sessionID: String?
        /// "house", "apartment", ...
        var kind: String?
    }

    nonisolated struct Asset: Codable, Sendable, Equatable {
        var id: String
        /// Bildens identitet. En plattform som inte hittar en källa letar på hash.
        var sha256: String
        var width: Int
        var height: Int
        var sources: [Source]
        var analysis: Analysis?

        var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
    }

    nonisolated struct Source: Codable, Sendable, Equatable {
        nonisolated enum Kind: String, Codable, Sendable { case local, url, store }
        var kind: Kind
        /// För `local`: relativ sökväg från spec-filens mapp.
        var path: String?
        /// För `url`.
        var url: String?
        /// För `store`.
        var key: String?
    }

    nonisolated struct Analysis: Codable, Sendable, Equatable {
        var room: String?
        var category: String?
        var focus: Point?
        /// Motivets sammanlagda bredd som andel av bildbredden (0...1).
        var salientWidth: Double?
        /// Bredden (andel av bildbredden) på den största saliency-boxen, ett tätare mått
        /// än `salientWidth` (unionen). Valfritt; används av rörelseplaneringen. Tillägg inom v1.
        var focusWidth: Double?
    }

    /// Punkt i normaliserade bildkoordinater [0,1].
    nonisolated struct Point: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
    }

    nonisolated struct Style: Codable, Sendable, Equatable {
        /// Används för varje klipp (utom det första) som saknar egen `transitionIn`.
        var defaultTransition: Transition
        var easing: Easing
        var background: Background
    }

    nonisolated enum Easing: String, Codable, Sendable {
        case linear
        case easeInOut
    }

    nonisolated struct Background: Codable, Sendable, Equatable {
        /// "blur" (suddig kopia av bilden) eller "black".
        var type: String
        /// 0...1, bara för "blur".
        var amount: Double?
    }

    nonisolated enum TransitionType: String, Codable, Sendable {
        case crossfade, cut, fadeThroughBlack, push
    }

    nonisolated enum Direction: String, Codable, Sendable {
        case left, right, up, down
    }

    nonisolated struct Transition: Codable, Sendable, Equatable {
        var type: TransitionType
        /// Bara för `push`. Riktningen innehållet rör sig (`left` = nästa bild kommer in från höger).
        var direction: Direction?
        /// Sekunder. Ignoreras (0) för `cut`.
        var duration: Double
    }

    nonisolated enum Fit: String, Codable, Sendable {
        case cover
        case containBlur = "contain-blur"
    }

    /// Ett lägesbeskrivande nyckelbildsläge: mittpunkt i normaliserade
    /// bildkoordinater och zoom relativt "cover"-utsnittet (1,0 = hela cover).
    nonisolated struct MotionKey: Codable, Sendable, Equatable {
        var cx: Double
        var cy: Double
        var zoom: Double
    }

    nonisolated struct Motion: Codable, Sendable, Equatable {
        var from: MotionKey
        var to: MotionKey
    }

    nonisolated struct Clip: Codable, Sendable, Equatable {
        var asset: String
        var duration: Double
        var fit: Fit
        var motion: Motion
        /// Övergången in från föregående klipp. Ignoreras för det första klippet.
        var transitionIn: Transition?
        /// Fotografens val av rörelse ("zoomIn", "zoomOut", "panRight", "panLeft", "contain"),
        /// nil = automatiskt. Bara metadata för redigeraren; renderare läser `motion`.
        /// Tillägg inom v1.
        var motionPreset: String?
        /// true när fotografen satt längden själv, så att en ombyggnad inte räknar om den.
        var durationLocked: Bool?
    }

    /// Reserverad ljudbeskrivning. `audio` är `null` i v1.
    nonisolated struct Audio: Codable, Sendable, Equatable {
        var asset: String?
        var volume: Double?
    }

    /// Reserverat textlager (se plan 5.5). Alla fält utom `type` är valfria;
    /// okända fält tappas vid omkodning, vilket är acceptabelt eftersom v1-renderare
    /// ändå ignorerar overlays.
    nonisolated struct Overlay: Codable, Sendable, Equatable {
        var type: String
        var text: String?
        var from: Double?
        var to: Double?
        var duration: Double?
        var position: String?
        var style: String?
        var fields: [String]?
    }

    nonisolated struct Brand: Codable, Sendable, Equatable {
        var id: String
        var logo: String?
        var primaryColor: String?
        var font: String?
    }

    nonisolated struct Output: Codable, Sendable, Equatable {
        var id: String
        /// "9:16", "1:1", "16:9" (informativt; `width`/`height` gäller).
        var aspect: String
        var width: Int
        var height: Int
        var fps: Int
        var encoding: Encoding?
    }

    nonisolated struct Encoding: Codable, Sendable, Equatable {
        var codec: String
        var bitrateMbps: Double?
        var audio: String?
    }

    nonisolated struct Provenance: Codable, Sendable, Equatable {
        var generator: String
        var autoSelection: [AutoSelection]?
        var edits: [Edit]?
    }

    nonisolated struct AutoSelection: Codable, Sendable, Equatable {
        var asset: String
        var slot: String
        var reason: String
    }

    nonisolated struct Edit: Codable, Sendable, Equatable {
        var at: Date
        var by: String
        var op: String
    }

    // MARK: - JSON

    /// Stabil, läsbar kodning: sorterade nycklar (diffvänligt), pretty-printed,
    /// ISO 8601-datum och oescapade snedstreck (sökvägar ska vara läsbara).
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Avkodar en spec. Okända fält ignoreras; versionskravet kontrolleras
    /// separat med `isReadable`, så att anroparen kan ge ett begripligt fel.
    static func decode(from data: Data) throws -> ReelSpec {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReelSpec.self, from: data)
    }
}
