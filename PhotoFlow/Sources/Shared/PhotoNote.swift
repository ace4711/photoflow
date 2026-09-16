import Foundation

struct PhotoNote: Codable, Identifiable {
    var id: String  // matches PhotoItem.id or "group_\(groupId)"
    var originalText: String
    var originalLanguage: NoteLanguage
    var translatedText: String
    var targetLanguage: NoteLanguage
    var timestamp: Date
    var photoFilename: String

    enum NoteLanguage: String, Codable, CaseIterable {
        case swedish = "sv"
        case english = "en"

        var displayName: String {
            switch self {
            case .swedish: return "Svenska"
            case .english: return "English"
            }
        }

        var other: NoteLanguage {
            switch self {
            case .swedish: return .english
            case .english: return .swedish
            }
        }
    }
}

/// Container for all notes in a session, saved as JSON
struct PhotoNotes: Codable {
    var notes: [PhotoNote]
    var sessionDate: Date
    var inputFolder: String
    var address: String?

    static func loadFrom(_ url: URL) -> PhotoNotes? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PhotoNotes.self, from: data)
    }

    func saveTo(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
