import Foundation

/// `hdr.json` i sessionens outputmapp: vilken motorversion och vilka indata/inställningar
/// (fingerprint) varje grupps HDR gjordes med, plus fönsterstatistiken från window pull.
/// Samma mönster som `enhancement.json` (`EnhancementLog`).
///
/// HDR-steget gör om en grupp när posten saknas och ingen fil finns, när fingerprintet
/// skiljer (andra exponeringar eller ändrade HDR-inställningar), eller — beroende på
/// inställningen "Gör om befintliga HDR när motorn uppdaterats" — när posten gjordes med
/// en äldre motorversion. Befintliga HDR-filer utan post (sessioner från före `hdr.json`)
/// adopteras: posten skrivs med `legacyEngineVersion` och dagens fingerprint, och filen
/// görs inte om bara för att loggen saknades.
nonisolated struct HDRLog: Codable, Sendable, Equatable {
    static let fileName = "hdr.json"
    /// Motorversionen som gällde när `hdr.json` infördes: HDR-filer utan post antas vara
    /// gjorda med den.
    static let legacyEngineVersion = 2

    var version: Int = 1
    var updatedAt: Date
    /// Nyckel = `hdr_group_<id>` (samma som i `enhancement.json`).
    var entries: [String: Entry]

    struct Entry: Codable, Sendable, Equatable {
        var engineVersion: Int
        var fingerprint: String
        /// Posten skrevs för en befintlig fil utan att den gjordes om (migrering).
        var adopted: Bool = false
        /// Exponeringarna som slogs ihop (NEF-filnamn, mörkast först när det är känt).
        var frames: [String] = []
        /// Urvalet kommer från granskningen (inte bracket-analysens förslag) — HDR-steget
        /// behåller det i stället för att gå tillbaka till förslaget.
        var manualSelection: Bool = false
        var reference: String?
        /// Fönsterkällan (gruppens mörkaste exponering) om window pull kördes.
        var windowSource: String?
        var window: WindowPull.Stats?
        /// När filen senast skrevs om (nil för adopterade poster). "Förbättra bilder" gör om
        /// en förbättring som är äldre än så.
        var mergedAt: Date?
        var seconds: Double?
    }

    init(entries: [String: Entry] = [:]) {
        self.updatedAt = Date()
        self.entries = entries
    }

    static func key(groupId: Int) -> String { "hdr_group_\(groupId)" }

    /// Inställningen "Gör om befintliga HDR när motorn uppdaterats". `ask` (Fråga) kräver
    /// en dialog som kommer i fas 4 (docs/plan-hdr-fonster.md) — till dess beter den sig
    /// som `never`.
    enum RedoPolicy: String, Sendable, CaseIterable {
        case never, always, ask

        init(setting: String) { self = RedoPolicy(rawValue: setting) ?? .never }
    }

    enum Decision: Equatable, Sendable {
        /// Filen är aktuell.
        case skip
        /// Filen finns men saknar post: skriv posten, gör inte om.
        case adopt
        /// Gör om (eller gör för första gången).
        case merge(reason: String)
    }

    /// - Parameter identityComplete: alla original-NEF:er hittades. Saknas någon (t.ex.
    ///   inputmappen är inte monterad) går fingerprintet inte att lita på, och en befintlig
    ///   fil görs inte om på grund av det.
    static func decide(fileExists: Bool, entry: Entry?, fingerprint: String, currentVersion: Int,
                       policy: RedoPolicy, force: Bool, identityComplete: Bool = true) -> Decision {
        if force { return .merge(reason: "kör om steget") }
        guard fileExists else { return .merge(reason: entry == nil ? "ny" : "filen saknas") }
        guard let entry else { return .adopt }
        if entry.fingerprint != fingerprint {
            return identityComplete ? .merge(reason: "ändrade indata eller inställningar") : .skip
        }
        if entry.engineVersion < currentVersion {
            switch policy {
            case .always: return .merge(reason: "motorn uppdaterad (v\(entry.engineVersion) → v\(currentVersion))")
            case .never, .ask: return .skip
            }
        }
        return .skip
    }

    /// Fingerprint av NEF-identiteten (namn + storlek — originalen skrivs aldrig till) och
    /// allt som ändrar HDR-resultatet.
    /// Metoden ingår bara när den är `fusion`: HDR gjorda med fusion före v6 saknar nyckeln och
    /// ska inte göras om bara för att standarden blev basram — det styrs av motorversionen och
    /// inställningen "Gör om befintliga HDR när motorn uppdaterats".
    @MainActor static func fingerprint(identity: [URL], engine: String, maxDimension: Int, align: Bool, sharpen: Bool,
                            windowPull: WindowPull.Options, method: HDREngine.Method = .baseFrame) -> String {
        var settings: [String: String] = [
            "engine": engine, "maxDimension": "\(maxDimension)", "align": "\(align)", "sharpen": "\(sharpen)"
        ]
        if engine != "opencv", method == .fusion { settings["method"] = method.rawValue }
        if engine != "opencv" {
            settings["windowPull"] = windowPull.enabled
                ? String(format: "on s=%.2f b=%.2f", windowPull.strength, windowPull.brightnessEV)
                    + " lamps=\(windowPull.includeLampsAndSky ? 1 : 0)"
                : "off"
        }
        return SessionManifestStore.fingerprint(fileURLs: identity, settings: settings)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(from outputDir: URL) -> HDRLog? {
        guard let data = try? Data(contentsOf: outputDir.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(HDRLog.self, from: data)
    }

    func save(to outputDir: URL) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: outputDir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
