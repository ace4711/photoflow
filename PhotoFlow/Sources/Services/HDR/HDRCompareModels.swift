import Foundation

/// Datamodeller för HDR-jämförelsen (docs/plan-hdr-jamforelse.md, avsnitt 2 och 5): manifestet som
/// skripten skriver, betygen (`verdicts.json`) och slumpningen av A/B-ordningen i blindläge.
/// Bara Foundation, så att CLI:t kan återanvända dem.

// MARK: - Manifest

nonisolated struct HDRCompareManifest: Codable, Equatable, Sendable {
    var version: Int
    var created: String?
    var groups: [Group]

    nonisolated struct Frame: Codable, Equatable, Sendable {
        var file: String
        var exposureSeconds: Double?
    }

    nonisolated struct Group: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var source: String?
        var groupId: Int?
        var category: String?
        var frames: [Frame]
        var photographerReference: String?
        /// Variant-id → sökväg (relativt manifestet). Tar även emot `{ "path": … }` som värde.
        var variants: [String: String]

        enum CodingKeys: String, CodingKey { case id, source, groupId, category, frames, photographerReference, variants }

        init(id: String, source: String? = nil, groupId: Int? = nil, category: String? = nil, frames: [Frame] = [],
             photographerReference: String? = nil, variants: [String: String] = [:]) {
            self.id = id; self.source = source; self.groupId = groupId; self.category = category
            self.frames = frames; self.photographerReference = photographerReference; self.variants = variants
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            groupId = try c.decodeIfPresent(Int.self, forKey: .groupId)
            category = try c.decodeIfPresent(String.self, forKey: .category)
            frames = try c.decodeIfPresent([Frame].self, forKey: .frames) ?? []
            photographerReference = try c.decodeIfPresent(String.self, forKey: .photographerReference)
            var out: [String: String] = [:]
            if let raw = try c.decodeIfPresent([String: PathValue?].self, forKey: .variants) {
                for (key, value) in raw { if let path = value?.path, !path.isEmpty { out[key] = path } }
            }
            variants = out
        }
    }

    /// Sträng eller objekt med `path`; allt annat (null) hoppas över.
    private nonisolated struct PathValue: Decodable {
        var path: String?
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { path = s; return }
            struct Obj: Decodable { var path: String? }
            path = try Obj(from: decoder).path
        }
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("PhotoFlowBenchmark/hdr-lr", isDirectory: true)
    static let defaultURL = defaultDirectory.appendingPathComponent("manifest.json")

    static func load(from url: URL) throws -> HDRCompareManifest {
        try JSONDecoder().decode(HDRCompareManifest.self, from: Data(contentsOf: url))
    }
}

nonisolated extension HDRCompareManifest.Group {
    /// Ordning varianterna visas i i väljarna; okända id:n kommer efter, alfabetiskt.
    static let knownVariantOrder = ["pf-radiance", "pf-radiance-enh", "pf-base", "pf-fusion", "lr-auto", "lr-plain", "ref"]

    /// Id för fotografens referens bland varianterna.
    static let referenceID = "ref"

    /// Alla jämförbara bilder: `variants` plus fotografens referens som `ref` (om den inte redan ligger där).
    var allImages: [String: String] {
        var all = variants
        if all[Self.referenceID] == nil, let ref = photographerReference, !ref.isEmpty { all[Self.referenceID] = ref }
        return all
    }

    var orderedVariantIDs: [String] {
        let ids = Array(allImages.keys)
        func rank(_ id: String) -> Int { Self.knownVariantOrder.firstIndex(of: id) ?? Self.knownVariantOrder.count }
        return ids.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// Standardparet A/B: pf-radiance mot lr-auto. Saknas lr-auto tas första tillgängliga av
    /// ref, pf-fusion, pf-base, pf-radiance-enh. Färre än två varianter ger nil.
    func defaultPair(available: Set<String>? = nil) -> (a: String, b: String)? {
        let ids = orderedVariantIDs.filter { available?.contains($0) ?? true }
        guard ids.count >= 2 else { return nil }
        let a = ids.contains("pf-radiance") ? "pf-radiance" : ids[0]
        let preferred = ["lr-auto", "ref", "pf-fusion", "pf-base", "pf-radiance-enh", "lr-plain"]
        let b = preferred.first { $0 != a && ids.contains($0) } ?? ids.first { $0 != a }
        guard let b else { return nil }
        return (a, b)
    }
}

/// Kategori-id → visningsnamn.
nonisolated enum HDRCompareCategory {
    static func title(_ id: String?) -> String {
        switch id {
        case "interior-window": return "Interiör med fönster"
        case "interior-dark", "dark-room": return "Mörkt rum"
        case "interior": return "Interiör"
        case "exterior": return "Exteriör"
        case "exterior-window": return "Exteriör med fönster"
        case "motion": return "Rörelse"
        case .some(let other) where !other.isEmpty: return other
        default: return "Okänd"
        }
    }
}

// MARK: - Betyg

nonisolated enum HDRCompareChoice: String, Codable, Sendable, CaseIterable {
    /// Bilden till vänster (A) är bättre.
    case left
    case tie
    /// Bilden till höger (B) är bättre.
    case right
}

nonisolated enum HDRCompareAspect: String, Codable, Sendable, CaseIterable, Identifiable {
    case window, color, shadows, ghosts, noise, naturalness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: return "Fönster"
        case .color: return "Färg/vitbalans"
        case .shadows: return "Skuggor"
        case .ghosts: return "Spöken"
        case .noise: return "Brus"
        case .naturalness: return "Naturlighet"
        }
    }
}

nonisolated struct HDRCompareVerdict: Codable, Equatable, Sendable {
    var groupId: String
    /// Varianterna såsom de visades (A till vänster, B till höger), efter eventuell blindslumpning.
    var left: String
    var right: String
    var blind: Bool
    var seed: UInt64
    var verdict: HDRCompareChoice
    /// `HDRCompareAspect.rawValue`.
    var aspects: [String]
    var note: String
    var ratedAt: Date

    /// Vinnande variant, nil vid lika.
    var winner: String? {
        switch verdict {
        case .left: return left
        case .right: return right
        case .tie: return nil
        }
    }

    func involves(_ variant: String) -> Bool { left == variant || right == variant }

    /// Samma grupp och samma två varianter (oavsett ordning).
    func samePair(as other: HDRCompareVerdict) -> Bool {
        groupId == other.groupId && Set([left, right]) == Set([other.left, other.right])
    }
}

nonisolated struct HDRCompareVerdictFile: Codable, Equatable, Sendable {
    var version = 1
    /// Seed för blindläget i den här omgången; sparas så att ordningen är densamma vid nästa start.
    var blindSeed: UInt64
    var verdicts: [HDRCompareVerdict] = []
}

/// Läser och skriver `verdicts.json` bredvid manifestet. Skrivningen är atomisk.
nonisolated enum HDRCompareVerdictStore {
    static func url(forManifest manifest: URL) -> URL {
        manifest.deletingLastPathComponent().appendingPathComponent("verdicts.json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Filen, eller en ny med slumpad seed om den saknas eller inte går att läsa.
    static func load(forManifest manifest: URL) -> HDRCompareVerdictFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url(forManifest: manifest)),
           let file = try? decoder.decode(HDRCompareVerdictFile.self, from: data) {
            return file
        }
        return HDRCompareVerdictFile(blindSeed: UInt64.random(in: 1...UInt64.max))
    }

    static func save(_ file: HDRCompareVerdictFile, forManifest manifest: URL) throws {
        try encoder().encode(file).write(to: url(forManifest: manifest), options: .atomic)
    }
}

nonisolated extension HDRCompareVerdictFile {
    /// Lägger in (eller ersätter) ett betyg för samma grupp och par.
    mutating func upsert(_ verdict: HDRCompareVerdict) {
        if let i = verdicts.firstIndex(where: { $0.samePair(as: verdict) }) {
            verdicts[i] = verdict
        } else {
            verdicts.append(verdict)
        }
    }

    mutating func remove(groupId: String, pair: Set<String>) {
        verdicts.removeAll { $0.groupId == groupId && Set([$0.left, $0.right]) == pair }
    }

    func verdict(groupId: String, pair: Set<String>) -> HDRCompareVerdict? {
        verdicts.first { $0.groupId == groupId && Set([$0.left, $0.right]) == pair }
    }
}

// MARK: - Blindläge

nonisolated enum HDRCompareBlind {
    /// Om A och B byter plats för gruppen. Beror bara på seed och grupp-id (FNV-1a), så ordningen
    /// är densamma varje gång gruppen visas och oberoende av vilken ordning grupperna bedöms i.
    static func isSwapped(seed: UInt64, groupId: String) -> Bool {
        var h: UInt64 = 0xcbf29ce484222325 ^ seed
        for byte in groupId.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        h ^= h >> 32
        h = h &* 0x9E3779B97F4A7C15
        return (h >> 40) & 1 == 1
    }
}
