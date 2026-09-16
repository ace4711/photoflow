import Foundation
import UniformTypeIdentifiers

/// Exportformat för fältanteckningar från "PhotoFlow Fält" (iOS) —
/// serialiseras som JSON med filändelsen `.photoflownotes`. Delas via
/// systemets delningsark (`ShareLink`) på iPhone-sidan eftersom Fas 7
/// medvetet INTE använder iCloud/CloudKit (se `FORBATTRINGAR.md`, Fas 7:
/// inget riktigt signeringsteam finns, appen körs bara i Simulator, och
/// CloudKit-entitlements hade krävt en riktig utvecklarprofil för att ens
/// starta appen). Mac-appen importerar filen via NSOpenPanel eller genom att
/// öppna den direkt i Finder.
struct FieldNoteBundle: Codable {
    /// Höjs om formatet ändras på ett sätt som kräver särskild hantering vid
    /// import (samma mönster som `SessionManifest.schemaVersion`).
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    /// `UIDevice.current.name` på iOS-sidan — rent informativt, visas i
    /// Mac-appens importsammanfattning så en fotograf med flera enheter kan
    /// se vilken telefon anteckningarna kom från.
    var deviceName: String
    var notes: [FieldNote]

    init(schemaVersion: Int = FieldNoteBundle.currentSchemaVersion, exportedAt: Date, deviceName: String, notes: [FieldNote]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.deviceName = deviceName
        self.notes = notes
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func encoded() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    static func decode(from data: Data) throws -> FieldNoteBundle {
        try jsonDecoder.decode(FieldNoteBundle.self, from: data)
    }

    static func loadFrom(_ url: URL) -> FieldNoteBundle? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(from: data)
    }

    func saveTo(_ url: URL) throws {
        try encoded().write(to: url)
    }
}

extension UTType {
    /// Registrerad i båda målens Info.plist (se `project.yml`):
    /// `PhotoFlowField` (iOS) exporterar typen (den skapar filerna),
    /// `PhotoFlow` (macOS) importerar den (den bara läser/konsumerar dem) —
    /// samma "en ägare, flera konsumenter"-mönster som Apple rekommenderar
    /// för appspecifika dokumenttyper. `UTType(exportedAs:conformingTo:)`
    /// fungerar även om Info.plist-deklarationen av någon anledning saknas
    /// (systemet deklarerar då typen dynamiskt vid körning), så filtrering i
    /// NSOpenPanel/ShareLink fungerar oavsett.
    static var photoFlowFieldNotes: UTType {
        UTType(exportedAs: "com.photoflow.fieldnotes", conformingTo: .json)
    }
}
