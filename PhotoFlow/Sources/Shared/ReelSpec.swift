import Foundation
import CoreGraphics

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
    /// Den högsta schemaversion den här koden förstår (läsare). Skrivaren skriver bara 2 när filmen
    /// har rutklipp (`fit: "panels"`), annars 1 (se `requiredVersion`, `updatingVersions`).
    static let currentVersion = 2
    /// Version 2 = rutor (`docs/reel-spec-v2.md`).
    static let panelsVersion = 2

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
    /// Redigerarens val (lås, tempo). Bara metadata; renderare ignorerar det. Nil = utelämnas
    /// vid kodning, så att filmer utan lås kodas exakt som förut. Tillägg inom v1.
    var editor: EditorState?

    /// Kan den här koden läsa filen? (`schema` rätt och inget brytande krav.)
    var isReadable: Bool {
        schema == Self.schemaName && minReaderVersion <= Self.currentVersion
    }

    /// Lägsta läsarversion filmens innehåll kräver: 2 om något klipp är ett rutklipp, annars 1.
    var requiredVersion: Int {
        timeline.contains { $0.fit == .panels } ? Self.panelsVersion : 1
    }

    /// Samma spec med `version` och `minReaderVersion` satta exakt efter innehållet (`requiredVersion`):
    /// 2 med rutklipp, annars 1. Ombyggnaden (`ReelComposer.rebuild`) använder den, så att en film
    /// som inte längre har rutor åter skrivs som version 1.
    func updatingVersions() -> ReelSpec {
        var s = self
        s.version = requiredVersion
        s.minReaderVersion = requiredVersion
        return s
    }

    /// Samma spec med versionsfälten höjda till minst `requiredVersion` (aldrig sänkta). `jsonData()`
    /// använder den: rutklipp ger alltid `minReaderVersion` 2, och en spec utan rutor kodas byte för byte som förut.
    func raisingVersions() -> ReelSpec {
        var s = self
        s.version = max(s.version, requiredVersion)
        s.minReaderVersion = max(s.minReaderVersion, requiredVersion)
        return s
    }

    /// Asset-id:n som något klipp använder: klippets egen bild och rutornas bilder.
    var usedAssetIDs: Set<String> {
        Set(timeline.flatMap(\.referencedAssetIDs))
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
        /// Montage (R6b): källrektanglarna (vänster, höger) för de två stående halvorna, om bilden är två
        /// bilder som satts ihop sida vid sida. Saknas fältet (eller är det tomt) är bilden ingen montage.
        /// Planeraren gör ett sådant montage till ett rutklipp (`layout: sequence`) i smala format.
        /// Tillägg inom v1 (läsare ignorerar det).
        var panels: [UnitRect]?
        /// Rumstypen per halva (samma ordning som `panels`; tom sträng = okänt rum), t.ex. ["Hall", "Uteplats"].
        /// `room` är då den viktigaste av dem. Tillägg inom v1.
        var panelRooms: [String]?
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
        /// Klippet består av rutor (`Clip.panels`, `Clip.layout`). Kräver version 2.
        case panels
    }

    /// Hur rutorna i ett rutklipp läggs ut (avsnitt 2 i `docs/reel-spec-v2.md`).
    nonisolated enum PanelLayout: String, Codable, Sendable {
        /// Två rutor ovanför varandra.
        case stack
        /// Två rutor sida vid sida.
        case side
        /// Rutorna visas efter varandra med en intern skjut-övergång.
        case sequence
    }

    /// Rektangel i normaliserade bildkoordinater (origo uppe till vänster).
    nonisolated struct UnitRect: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    }

    /// En ruta i ett rutklipp: en bild (eller en del av den, `source`) med egen rörelse.
    nonisolated struct Panel: Codable, Sendable, Equatable {
        var asset: String
        /// Den del av bilden rutan använder (bildkoordinater); nil = hela bilden. Montagehalvor.
        var source: UnitRect?
        /// Rörelsen i hela bildens koordinater (mittpunkten klampas inom `source`).
        var motion: Motion
    }

    nonisolated enum EntranceType: String, Codable, Sendable {
        case slide, fade, none
    }

    /// Hur rutorna kommer in i början av ett `stack`/`side`-klipp (ignoreras för `sequence`).
    nonisolated struct Entrance: Codable, Sendable, Equatable {
        var type: EntranceType
        /// Sekunder mellan rutornas start. Saknas den gäller `defaultStagger`.
        var stagger: Double?
        /// Längd (sekunder) på varje rutas ingång. Saknas den gäller `defaultDuration`.
        var duration: Double?

        static let defaultStagger = 0.3
        static let defaultDuration = 0.6
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
        /// true när övergången satts för hand: en ombyggnad behåller då `transitionIn` (även
        /// `{"type":"cut"}`). Låst och `transitionIn == nil` betyder "använd `style.defaultTransition`".
        /// Tillägg inom v1.
        var transitionLocked: Bool?
        /// Fotografens egna nycklar (`motionPreset == "custom"`) före klampning mot formatet, satt
        /// bara när `motion` fick klampas och därför skiljer sig. En ombyggnad klampar om från dem, så
        /// att ett formatbyte fram och tillbaka inte ändrar den egna rörelsen för gott. Bara metadata
        /// för redigeraren; renderare läser `motion`. Tillägg inom v1.
        var customMotion: Motion?
        /// Bara för `fit == .panels` (version 2): hur rutorna läggs ut.
        var layout: PanelLayout?
        /// Bara för `fit == .panels`: rutorna (två för `stack`/`side`, två eller fler för `sequence`).
        var panels: [Panel]?
        /// Bara för `stack`/`side`: avståndet mellan rutorna som andel av ramens kortsida (förval `defaultGutter`).
        var gutter: Double?
        /// Bara för `stack`/`side`: ingången. Saknas den visas rutorna direkt.
        var entrance: Entrance?

        static let defaultGutter = 0.006

        /// Alla bilder klippet visar: den egna och rutornas.
        var referencedAssetIDs: [String] {
            var ids = [asset]
            for p in panels ?? [] where !ids.contains(p.asset) { ids.append(p.asset) }
            return ids
        }
    }

    /// Redigerarens val som gäller hela filmen. Bara metadata (se `ReelComposer`).
    /// Alla fält är valfria; ett tomt objekt skrivs aldrig (se `isEmpty`). Tillägg inom v1.
    nonisolated struct EditorState: Codable, Sendable, Equatable {
        /// Bilder (sha256) som alltid ska vara med vid "Föreslå igen".
        var pinnedAssets: [String]?
        /// Bilder (sha256) som aldrig ska föreslås.
        var excludedAssets: [String]?
        /// true = "Föreslå igen" flyttar inte låsta klipp.
        var orderLocked: Bool?
        /// "calm", "normal" eller "fast": faktor på planerarens längder.
        var tempo: String?
        /// Fotografens exakta antal bilder (Bilder-steppern, 3...12). Saknas = automatiskt antal
        /// (en bild per viktig rumstyp, 5...8): "Föreslå igen" behåller ett fast antal.
        var fixedCount: Int?

        var isEmpty: Bool {
            (pinnedAssets ?? []).isEmpty && (excludedAssets ?? []).isEmpty
                && orderLocked != true && (tempo ?? "normal") == "normal" && fixedCount == nil
        }

        /// Samma värde med tomma fält borttagna, eller nil om inget är satt.
        var normalized: EditorState? {
            var e = self
            if e.pinnedAssets?.isEmpty == true { e.pinnedAssets = nil }
            if e.excludedAssets?.isEmpty == true { e.excludedAssets = nil }
            if e.orderLocked != true { e.orderLocked = nil }
            if e.tempo == "normal" { e.tempo = nil }
            return isEmpty ? nil : e
        }
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
        return try encoder.encode(raisingVersions())
    }

    /// Avkodar en spec. Okända fält ignoreras; versionskravet kontrolleras
    /// separat med `isReadable`, så att anroparen kan ge ett begripligt fel.
    static func decode(from data: Data) throws -> ReelSpec {
        try makeDecoder().decode(ReelSpec.self, from: data)
    }

    /// Avkodaren som `decode(from:)` använder; även för svar där en spec ligger inbäddad.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Servern skriver millisekunder ("…:07.123Z"), appen hela sekunder: båda ska gå att läsa.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.parseISO8601(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Ogiltigt datum: \(text)"))
        }
        return decoder
    }

    /// ISO 8601 med eller utan bråkdelssekunder.
    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
