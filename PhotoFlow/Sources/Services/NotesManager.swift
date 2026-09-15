import Foundation

@MainActor
class NotesManager: ObservableObject {
    @Published var notes: [String: PhotoNote] = [:]  // keyed by PhotoItem.id or "group_\(id)"
    @Published var hasUnsavedChanges = false

    private var outputDirectory: URL?
    private var sessionAddress: String?

    private var jsonURL: URL? {
        outputDirectory?.appendingPathComponent("photo_notes.json")
    }

    func setup(outputDir: URL?, address: String?) {
        self.outputDirectory = outputDir
        self.sessionAddress = address
        loadNotes()
    }

    func noteFor(photoId: String) -> PhotoNote? {
        notes[photoId]
    }

    func setNote(photoId: String, filename: String, originalText: String, language: PhotoNote.NoteLanguage, translatedText: String) {
        let note = PhotoNote(
            id: photoId,
            originalText: originalText,
            originalLanguage: language,
            translatedText: translatedText,
            targetLanguage: language.other,
            timestamp: Date(),
            photoFilename: filename
        )
        notes[photoId] = note
        hasUnsavedChanges = true
        saveNotes()
    }

    func removeNote(photoId: String) {
        notes.removeValue(forKey: photoId)
        hasUnsavedChanges = true
        saveNotes()
    }

    func loadNotes() {
        guard let url = jsonURL else { return }
        guard let container = PhotoNotes.loadFrom(url) else { return }
        notes = Dictionary(uniqueKeysWithValues: container.notes.map { ($0.id, $0) })
    }

    func saveNotes() {
        guard let url = jsonURL, let outputDir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let container = PhotoNotes(
            notes: Array(notes.values).sorted { $0.timestamp < $1.timestamp },
            sessionDate: Date(),
            inputFolder: outputDirectory?.lastPathComponent ?? "",
            address: sessionAddress
        )
        try? container.saveTo(url)
        hasUnsavedChanges = false
    }

    /// Build email body with all translated notes
    func emailBody(language: PhotoNote.NoteLanguage) -> String {
        let sorted = Array(notes.values).sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("Bildanteckningar / Photo Notes")
        if let addr = sessionAddress {
            lines.append("Adress: \(addr)")
        }
        lines.append("Datum: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))")
        lines.append("")
        lines.append("---")
        lines.append("")

        for note in sorted {
            lines.append("📷 \(note.photoFilename)")
            let text = language == note.originalLanguage ? note.originalText : note.translatedText
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Compose mailto: URL for sending notes
    func mailtoURL(to recipient: String = "", language: PhotoNote.NoteLanguage = .swedish) -> URL? {
        let subject = sessionAddress.map { "Bildanteckningar — \($0)" } ?? "Bildanteckningar"
        let body = emailBody(language: language)
        guard !body.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}
