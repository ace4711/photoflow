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

    // MARK: - Vision-baserat kvalitetsbeslutsstöd (Fas 3b, se PhotoQualityService)

    /// 0...1, normaliserad från Vision's aesthetics-poäng (-1...1). `nil` om
    /// kvalitetsanalysen inte kunde köras (t.ex. saknad preview).
    var qualityScore: Double?
    /// Vision's "nyttobild"-signal (dokument/skärmdump-liknande, inte ett
    /// minnesvärt foto) — föreslås avvisad i "Föreslå gallring".
    var isUtility: Bool = false
    /// Horisontlutning i grader, normaliserad till (-90, 90]. `nil` om Vision
    /// inte kunde detektera en horisontlinje (vanligt för närbilder/interiörer).
    var horizonAngle: Double?
    /// Varians av Laplace på en nedskalad gråskalebild — bara meningsfull
    /// relativt andra bilder i samma session/dubblettgrupp.
    var sharpness: Double?
    /// Kluster-id för nästan-dubbletter i samma session (`nil` = ingen
    /// dubblett hittad). Flera bilder med samma id anses vara samma motiv.
    var duplicateGroupID: Int?

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
