import Foundation

/// Håller dagens (och tidigare, tills de tas bort) fältanteckningar på
/// telefonen och sköter lokal JSON-persistens i appens Documents-mapp
/// (`field_notes.json`) — INTE samma format som exportfilen
/// (`FieldNoteBundle`/`.photoflownotes`), som bara byggs på begäran när
/// användaren trycker "Exportera" (se `makeExportBundle`/`writeExportFile`).
///
/// Fas 7: ingen iCloud/CloudKit här (se `FORBATTRINGAR.md`) — bara lokal
/// disk på enheten/Simulatorn. Synk till Mac-appen sker uteslutande via den
/// exporterade filen (delningsark/Filer/AirDrop).
@MainActor
final class FieldNoteStore: ObservableObject {
    @Published private(set) var notes: [FieldNote] = []

    /// Snabbval för rumsetikett i inspelningsvyn — se planen: "Kök, Badrum,
    /// Sovrum, Vardagsrum, Hall, Fasad, Trädgård…". Fri text är också
    /// tillåtet (se `FieldNote.roomLabel`), det här är bara genvägar.
    static let quickRoomLabels = ["Kök", "Badrum", "Sovrum", "Vardagsrum", "Hall", "Fasad", "Trädgård"]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("field_notes.json")
    }()

    init() {
        load()
    }

    func add(_ note: FieldNote) {
        notes.insert(note, at: 0)
        save()
    }

    func update(_ note: FieldNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx] = note
        save()
    }

    func remove(_ note: FieldNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([FieldNote].self, from: data) else { return }
        notes = decoded.sorted { $0.recordedAt > $1.recordedAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Bygger en exportbunt av ALLA sparade anteckningar, äldst→nyast.
    func makeExportBundle(deviceName: String) -> FieldNoteBundle {
        FieldNoteBundle(exportedAt: Date(), deviceName: deviceName, notes: notes.sorted { $0.recordedAt < $1.recordedAt })
    }

    /// Skriver exportbunten till en tempfil (`.photoflownotes`) redo för
    /// `ShareLink`/delningsarket. Filnamnet inkluderar tidsstämpel så flera
    /// exporter samma dag inte skriver över varandra i Filer-appen.
    func writeExportFile(deviceName: String) throws -> URL {
        let bundle = makeExportBundle(deviceName: deviceName)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "Fältanteckningar_\(formatter.string(from: Date())).photoflownotes"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try bundle.saveTo(url)
        return url
    }
}
