import Foundation

/// Stjärnbetyg (1–5) per grupp i granska-läget. Sparas i `group_ratings.json` i outputmappen,
/// bredvid gallringsbesluten (`cull_decisions.json`). Nyckel = grupp-id.
nonisolated struct ReviewRatings: Equatable, Codable {
    private(set) var byGroup: [Int: Int] = [:]

    static let fileName = "group_ratings.json"

    func rating(for group: Int) -> Int { byGroup[group] ?? 0 }

    /// Sätter betyg 1–5; 0 (eller utanför intervallet) tar bort betyget.
    /// Samma betyg igen tar bort det (växla).
    mutating func set(_ rating: Int, for group: Int) {
        guard (1...5).contains(rating), byGroup[group] != rating else {
            byGroup[group] = nil
            return
        }
        byGroup[group] = rating
    }

    mutating func clear(group: Int) { byGroup[group] = nil }

    /// "★★★☆☆"
    static func stars(_ rating: Int) -> String {
        let r = max(0, min(5, rating))
        return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
    }

    static func load(from dir: URL) -> ReviewRatings {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return ReviewRatings() }
        var r = ReviewRatings()
        for (k, v) in raw { if let id = Int(k), (1...5).contains(v) { r.byGroup[id] = v } }
        return r
    }

    func save(to dir: URL) {
        let raw = Dictionary(uniqueKeysWithValues: byGroup.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Jämförelseläge sida vid sida: höger sida är alltid slutbilden (förbättrad/sammanslagen HDR).
nonisolated enum ReviewCompareMode: Equatable {
    case off
    /// Vänster: vald källexponering.
    case source
    /// Vänster: sammanslagen HDR före förbättring.
    case merged

    /// Nästa läge vid X. `hasFinal` = gruppen har en HDR, `hasEnhanced` = även en förbättrad version.
    func next(hasFinal: Bool, hasEnhanced: Bool) -> ReviewCompareMode {
        guard hasFinal else { return .off }
        switch self {
        case .off: return .source
        case .source: return hasEnhanced ? .merged : .off
        case .merged: return .off
        }
    }

    var leftLabel: String {
        switch self {
        case .off: return ""
        case .source: return "Källexponering"
        case .merged: return "HDR (före förbättring)"
        }
    }
}

/// Status för omgörning av en grupps HDR i grupplistan.
nonisolated enum ReMergeStatus: Equatable {
    case idle
    case running
    case failed(String)

    static func resolve(isRunning: Bool, error: String?) -> ReMergeStatus {
        if isRunning { return .running }
        if let error { return .failed(error) }
        return .idle
    }
}
