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
    /// Stjärnbetyg 0–5 (0 = obetygsatt).
    var rating: Int = 0
    /// Gruppen är vald för extern redigering (minst en fil skickas).
    var isSending: Bool = false
}

/// Filter för grupplistan i granska-läget.
nonisolated enum ReviewFilter: Hashable {
    case all
    case unreviewed
    case flagged
    case address(String)
    /// Betyg minst N stjärnor.
    case minRating(Int)
    /// Vald för extern redigering.
    case sending
    /// Inte vald för extern redigering.
    case notSending

    var title: String {
        switch self {
        case .all: return "Alla"
        case .unreviewed: return "Ej granskade"
        case .flagged: return "Flaggade/avvisade"
        case .address(let name): return name
        case .minRating(let n): return "★ \(n)+"
        case .sending: return "Skickas"
        case .notSending: return "Ej vald"
        }
    }

    func matches(_ s: ReviewGroupSummary) -> Bool {
        switch self {
        case .all: return true
        case .unreviewed: return !s.allReviewed
        case .flagged: return s.hasRejected || s.hasUserOverride
        case .address(let name): return s.addressFolder == name
        case .minRating(let n): return s.rating >= n
        case .sending: return s.isSending
        case .notSending: return !s.isSending
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

/// En post i ångra-stapeln: ett granskningsbeslut eller en ändring av urvalet till redigering.
nonisolated enum ReviewUndoEntry: Equatable {
    case decision(ReviewDecisionSnapshot)
    case editSelection(EditSelectionUndo)

    var decision: ReviewDecisionSnapshot? {
        if case .decision(let s) = self { return s }
        return nil
    }

    var editSelection: EditSelectionUndo? {
        if case .editSelection(let u) = self { return u }
        return nil
    }
}

/// Begränsad ångra-stapel (senaste överst).
nonisolated struct ReviewUndoStack {
    private(set) var items: [ReviewUndoEntry] = []
    let limit: Int
    init(limit: Int = 200) { self.limit = limit }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    mutating func push(_ entry: ReviewUndoEntry) {
        items.append(entry)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    mutating func push(_ s: ReviewDecisionSnapshot) { push(.decision(s)) }

    mutating func pop() -> ReviewUndoEntry? { items.popLast() }
}
