import Foundation

/// A bracket (or single-photo) group produced by the bracket-analysis step.
///
/// `PipelineState.allPhotos` is the single source of truth for cull decisions
/// (`accepted`/`rejected`/`algorithmSuggested`) — a `BracketGroup` only stores
/// which photo IDs belong to it (`photoIDs`), never its own copy of `PhotoItem`.
/// Use `PipelineState.photos(in:)` (and the related `selectedCount`/`allReviewed`/
/// `label` helpers) to resolve a group's photos and derived state. This avoids
/// the two-copies-of-the-truth bug where BracketReviewView (editing groups) and
/// PreviewCullView (editing allPhotos) disagreed about a photo's decision.
struct BracketGroup: Identifiable, Hashable {
    let id: Int
    let isBracket: Bool
    let folderName: String
    var photoIDs: [String]
    let fNumber: Double
    let iso: Int
    let timeStart: String
    let timeEnd: String
    let exposureRangeStops: Double
    var mergedHDRPreviewURL: URL?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BracketGroup, rhs: BracketGroup) -> Bool {
        lhs.id == rhs.id
    }
}
