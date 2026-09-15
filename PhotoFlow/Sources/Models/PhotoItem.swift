import Foundation

struct PhotoItem: Identifiable, Hashable {
    let id: String
    let filename: String
    let nefURL: URL
    let dngURL: URL?
    let previewURL: URL?
    let exposureTime: String
    let exposureSeconds: Double
    let fNumber: Double
    let iso: Int
    let dateTime: Date
    var accepted: Bool = false
    var rejected: Bool = false
    var algorithmSuggested: Bool = false
    var aiTags: [String] = []
    var aiDescription: String = ""

    var displayName: String {
        filename.replacingOccurrences(of: ".NEF", with: "")
    }

    var exposureDisplay: String {
        if exposureSeconds >= 1.0 {
            return String(format: "%.1fs", exposureSeconds)
        } else {
            return exposureTime
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }
}
