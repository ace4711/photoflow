import Foundation

/// Sammanfattning av en grupp, tillräcklig för filtrering utan åtkomst till pipeline-tillståndet.
nonisolated struct ReviewGroupSummary: Equatable {
    var allReviewed: Bool
    /// Minst en bild i gruppen är avvisad.
    var hasRejected: Bool
    /// Minst en bild är handvald av användaren (avviker från algoritmens förslag).
    var hasUserOverride: Bool
    /// Adressmappen gruppen hamnat i (nil = ingen kalendermatchning).
    var addressFolder: String?
}

/// Filter för grupplistan i granska-läget.
nonisolated enum ReviewFilter: Hashable {
    case all
    case unreviewed
    case flagged
    case address(String)

    var title: String {
        switch self {
        case .all: return "Alla"
        case .unreviewed: return "Ej granskade"
        case .flagged: return "Flaggade/avvisade"
        case .address(let name): return name
        }
    }

    func matches(_ s: ReviewGroupSummary) -> Bool {
        switch self {
        case .all: return true
        case .unreviewed: return !s.allReviewed
        case .flagged: return s.hasRejected || s.hasUserOverride
        case .address(let name): return s.addressFolder == name
        }
    }

    /// Index (i ursprungslistan) för grupper som passerar filtret, i ordning.
    static func visibleIndices(_ summaries: [ReviewGroupSummary], filter: ReviewFilter) -> [Int] {
        summaries.indices.filter { filter.matches(summaries[$0]) }
    }

    /// Distinkta adressmappar i ordning efter första förekomst.
    static func addresses(in summaries: [ReviewGroupSummary]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case let a? in summaries.map(\.addressFolder) where seen.insert(a).inserted { result.append(a) }
        return result
    }

    /// Nästa synliga index i `direction` från `current` (ingen wrap). Är `current` själv
    /// dold hoppar den till närmaste synliga i riktningen.
    static func step(from current: Int, direction: Int, visible: [Int]) -> Int? {
        direction > 0 ? visible.first(where: { $0 > current }) : visible.last(where: { $0 < current })
    }
}

/// Ett granskningsbeslut för ångra.
nonisolated struct ReviewDecisionSnapshot: Equatable {
    var photoID: String
    var accepted: Bool
    var rejected: Bool
    var algorithmSuggested: Bool
    var groupIndex: Int
    var photoIndex: Int
}

/// Begränsad ångra-stapel (senaste överst).
nonisolated struct ReviewUndoStack {
    private(set) var items: [ReviewDecisionSnapshot] = []
    let limit: Int
    init(limit: Int = 200) { self.limit = limit }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    mutating func push(_ s: ReviewDecisionSnapshot) {
        items.append(s)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    mutating func pop() -> ReviewDecisionSnapshot? { items.popLast() }
}
