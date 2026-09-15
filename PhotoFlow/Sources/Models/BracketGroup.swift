import Foundation

struct BracketGroup: Identifiable, Hashable {
    let id: Int
    let isBracket: Bool
    let folderName: String
    var photos: [PhotoItem]
    let fNumber: Double
    let iso: Int
    let timeStart: String
    let timeEnd: String
    let exposureRangeStops: Double
    var mergedHDRPreviewURL: URL?

    var selectedPhotos: [PhotoItem] {
        photos.filter { $0.accepted }
    }

    var allReviewed: Bool {
        photos.allSatisfy { $0.accepted || $0.rejected }
    }

    var selectedCount: Int {
        photos.filter { $0.accepted }.count
    }

    var label: String {
        if isBracket {
            return "HDR \(id) - \(selectedCount)/\(photos.count) exp (f/\(fNumber))"
        } else {
            return "Grupp \(id) - \(photos.count) bilder (f/\(fNumber))"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BracketGroup, rhs: BracketGroup) -> Bool {
        lhs.id == rhs.id
    }
}
