import Foundation

/// Fotografens urval till extern redigering: vilka grupper som skickas och vilka
/// exponeringar (DNG) i varje grupp. Sparas i `edit_selection.json` i sessionens
/// outputmapp och överlever omstart. Nyckel = grupp-id (samma som `bracket_groups.json`).
///
/// Avvisade bilder kan aldrig väljas: de stoppas när fotografen bockar i och filtreras
/// bort i `chosenFiles` om de avvisas i efterhand (urvalet minns dem ändå, så att en
/// ångrad avvisning ger tillbaka bocken).
nonisolated struct EditSelection: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// Gruppen ska skickas till redigeraren.
        var send: Bool
        /// Valda exponeringar (originalfilnamn, t.ex. `DSC_1234.NEF`), sorterade.
        /// Behålls när `send` slås av så att valet kommer tillbaka om gruppen slås på igen.
        var files: [String]
        /// Kommer från det automatiska förslaget och är orört av fotografen
        /// (UI:t visar då en liten "Förslag"-markering).
        var isSuggestion: Bool

        init(send: Bool, files: [String], isSuggestion: Bool = false) {
            self.send = send
            self.files = Array(Set(files)).sorted()
            self.isSuggestion = isSuggestion
        }
    }

    static let fileName = "edit_selection.json"
    static let currentVersion = 1

    private(set) var entries: [Int: Entry] = [:]
    /// Det automatiska förslaget har lagts in för sessionen. Det körs då inte igen av
    /// sig självt (fotografens ändringar ska inte skrivas över vid nästa öppning).
    var suggestionApplied: Bool = false

    init(entries: [Int: Entry] = [:], suggestionApplied: Bool = false) {
        self.entries = entries
        self.suggestionApplied = suggestionApplied
    }

    func entry(for group: Int) -> Entry? { entries[group] }

    func isSending(_ group: Int) -> Bool { entries[group]?.send ?? false }

    func isSuggestion(_ group: Int) -> Bool { entries[group]?.isSuggestion ?? false }

    /// Om filen är ibockad (oavsett om gruppen skickas just nu).
    func isChecked(_ file: String, in group: Int) -> Bool {
        entries[group]?.files.contains(file) ?? false
    }

    /// Filerna som faktiskt skickas för gruppen: tomt om gruppen inte skickas,
    /// annars de ibockade utom avvisade.
    func chosenFiles(for group: Int, rejected: Set<String> = []) -> [String] {
        guard let e = entries[group], e.send else { return [] }
        return e.files.filter { !rejected.contains($0) }
    }

    // MARK: - Ändringar (fotografens)

    /// Växlar "Skicka till redigering" för gruppen. Slås gruppen på utan tidigare
    /// (giltiga) val används `defaultFiles` (förslaget för exponeringar).
    mutating func toggleSend(group: Int, defaultFiles: [String], rejected: Set<String> = []) {
        var e = entries[group] ?? Entry(send: false, files: [])
        if e.send {
            e.send = false
        } else {
            let remembered = e.files.filter { !rejected.contains($0) }
            e.files = remembered.isEmpty ? defaultFiles.filter { !rejected.contains($0) }.sorted() : e.files
            e.send = !e.files.filter { !rejected.contains($0) }.isEmpty
        }
        e.isSuggestion = false
        entries[group] = e
    }

    /// Bockar i/ur en exponering. Att bocka i en fil i en grupp som inte skickas slår
    /// på gruppen; att bocka ur den sista slår av den. Returnerar false (ingen ändring)
    /// om filen är avvisad och skulle bockas i.
    @discardableResult
    mutating func toggleFile(_ file: String, in group: Int, rejected: Set<String> = []) -> Bool {
        var e = entries[group] ?? Entry(send: false, files: [])
        let checkedAndSending = e.send && e.files.contains(file)
        if checkedAndSending {
            e.files.removeAll { $0 == file }
            if e.files.filter({ !rejected.contains($0) }).isEmpty { e.send = false }
        } else {
            guard !rejected.contains(file) else { return false }
            if !e.send {
                // Gruppen var avslagen och visades utan bockar: börja från bara den här
                // filen (det fotografen ser är det som skickas).
                e.send = true
                e.files = [file]
            } else if !e.files.contains(file) {
                e.files = (e.files + [file]).sorted()
            }
        }
        e.isSuggestion = false
        entries[group] = e
        return true
    }

    /// Sätter (eller tar bort) en grupps post rakt av — används av ångra.
    mutating func setEntry(_ entry: Entry?, for group: Int) {
        entries[group] = entry
    }

    // MARK: - Automatiskt förslag

    /// Lägger in förslaget för grupper fotografen inte rört. Grupper med en egen
    /// (icke-förslag) post lämnas orörda; gamla förslag ersätts.
    mutating func applySuggestion(_ suggested: [Int: Entry]) {
        for (group, var entry) in suggested {
            if let existing = entries[group], !existing.isSuggestion { continue }
            entry.isSuggestion = true
            entries[group] = entry
        }
        suggestionApplied = true
    }

    /// Tar bort alla orörda förslag (fotografens egna val behålls).
    mutating func clearSuggestions() {
        entries = entries.filter { !$0.value.isSuggestion }
    }

    // MARK: - Räknare

    struct Counts: Equatable {
        var groups: Int
        var files: Int
    }

    /// Antal grupper som skickas (med minst en giltig fil) och antal filer totalt.
    func counts(rejected: Set<String> = [], validGroups: Set<Int>? = nil) -> Counts {
        var c = Counts(groups: 0, files: 0)
        for group in entries.keys where validGroups?.contains(group) ?? true {
            let n = chosenFiles(for: group, rejected: rejected).count
            if n > 0 { c.groups += 1; c.files += n }
        }
        return c
    }

    /// "3 grupper · 8 filer valda för redigering"
    static func countsText(_ c: Counts) -> String {
        let g = c.groups == 1 ? "1 grupp" : "\(c.groups) grupper"
        let f = c.files == 1 ? "1 fil" : "\(c.files) filer"
        return "\(g) · \(f) valda för redigering"
    }

    // MARK: - Persistens

    private struct FileFormat: Codable {
        var version: Int
        var suggestionApplied: Bool
        var groups: [String: Entry]
    }

    static func load(from dir: URL) -> EditSelection {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else { return EditSelection() }
        var s = EditSelection(suggestionApplied: file.suggestionApplied)
        for (k, v) in file.groups { if let id = Int(k) { s.entries[id] = v } }
        return s
    }

    func save(to dir: URL) throws {
        let file = FileFormat(version: Self.currentVersion, suggestionApplied: suggestionApplied,
                              groups: Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Ångra-post för en ändring av urvalet till redigering.
nonisolated struct EditSelectionUndo: Equatable {
    var groupID: Int
    /// Posten före ändringen (nil = gruppen hade ingen post).
    var previous: EditSelection.Entry?
    var groupIndex: Int
    var photoIndex: Int
}
