import Foundation

/// `reel-remote.json` bredvid `reel.json` i FILM-mappen: kopplingen mellan en lokal film och dess
/// objekt på Objektfilm-servern. Innehåller aldrig API-nycklar eller mäklartoken (länkens token
/// visas bara en gång, när den skapas).
nonisolated struct ReelRemoteState: Codable, Sendable, Equatable {

    static let fileName = "reel-remote.json"

    nonisolated struct Link: Codable, Sendable, Equatable {
        var linkId: String
        var label: String?
        var createdAt: String?
        var expiresAt: String?
    }

    var server: String
    var objectId: String
    var reelId: String
    /// Serverns revision som lokala filen senast stämdes av mot (`If-Match` vid nästa skrivning).
    var lastSyncedRevision: Int
    /// Lokala specens `revision` vid samma tillfälle. Skiljer den sig nu finns osynkade lokala ändringar.
    var lastSyncedLocalRevision: Int?
    /// Mappen med de färdiga bilderna, relativt FILM-mappen (t.ex. `../Lindvägen 12 FÄRDIGA`).
    /// Renderworkern behöver den för att hitta originalen.
    var sourceRelativePath: String?
    /// Senast kända status på servern: draft, proposed, approved, rendered.
    var lastKnownStatus: String?
    var approvedRevision: Int?
    var links: [Link]

    init(server: String, objectId: String, reelId: String, lastSyncedRevision: Int = 0,
         lastSyncedLocalRevision: Int? = nil, sourceRelativePath: String? = nil,
         lastKnownStatus: String? = "draft", approvedRevision: Int? = nil, links: [Link] = []) {
        self.server = server
        self.objectId = objectId
        self.reelId = reelId
        self.lastSyncedRevision = lastSyncedRevision
        self.lastSyncedLocalRevision = lastSyncedLocalRevision
        self.sourceRelativePath = sourceRelativePath
        self.lastKnownStatus = lastKnownStatus
        self.approvedRevision = approvedRevision
        self.links = links
    }

    static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func load(from directory: URL) -> ReelRemoteState? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(ReelRemoteState.self, from: data)
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    /// Mappen med färdiga bilder, löst mot FILM-mappen.
    func sourceDirectory(relativeTo reelDirectory: URL) -> URL? {
        sourceRelativePath.map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: reelDirectory.path, isDirectory: true)).standardizedFileURL
        }
    }
}

/// Appindexet `objectId → FILM-mapp` i Application Support, så att renderworkern hittar mappen
/// (och därmed originalbilderna) för ett jobb utan att någon FILM-mapp är öppen.
nonisolated enum ReelRemoteIndex {

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PhotoFlow/objektfilm-index.json")
    }

    static func entries(at file: URL = defaultURL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// FILM-mappen för objektet, om den finns kvar på disk.
    static func directory(for objectId: String, at file: URL = defaultURL) -> URL? {
        guard let path = entries(at: file)[objectId] else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func register(objectId: String, directory: URL, at file: URL = defaultURL) throws {
        var map = entries(at: file)
        map[objectId] = directory.standardizedFileURL.path
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(map).write(to: file, options: .atomic)
    }
}
