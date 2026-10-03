import Foundation

/// Ren planering inför "Skicka till mäklare": vilken kandidatpool som ska registreras, vilka
/// bilder som ska laddas upp och hur specen skrivs om för servern. Inget nätverk och ingen disk,
/// så allt går att testa direkt.
nonisolated enum ReelUploadPlanner {

    /// Serverns tak för antal bilder i poolen.
    static let poolLimit = 40

    nonisolated struct PoolItem: Sendable, Equatable {
        var assetID: String
        var sha256: String
        var width: Int
        var height: Int
        var analysis: ReelSpec.Analysis?

        var serverAsset: ReelServerPoolAsset {
            .init(assetId: assetID, sha256: sha256, width: width, height: height, analysis: analysis)
        }
    }

    /// Kandidatpoolen: filmens bilder först (med sina asset-id:n), därefter övriga färdiga bilder
    /// som har en fil (bästa kvalitet först, "nyttobilder" sist), högst `limit`. Bilder utan fil
    /// tas inte med: de kan inte laddas upp, och mäklaren ska inte kunna välja något som saknar bild.
    static func pool(spec: ReelSpec, analyses: [String: ReelImageAnalysis], files: [String: URL],
                     limit: Int = poolLimit) -> [PoolItem] {
        var items: [PoolItem] = []
        var seen = Set<String>()
        for asset in spec.assets where seen.insert(asset.sha256).inserted {
            let a = analyses[asset.sha256]
            items.append(.init(assetID: asset.id, sha256: asset.sha256, width: asset.width, height: asset.height,
                               analysis: asset.analysis ?? a.map(specAnalysis(from:))))
        }
        let extras = analyses.values
            .filter { !seen.contains($0.sha256) && files[$0.sha256] != nil }
            .sorted {
                if $0.isUtility != $1.isUtility { return !$0.isUtility }
                let q0 = $0.qualityScore ?? 0, q1 = $1.qualityScore ?? 0
                return q0 != q1 ? q0 > q1 : $0.sha256 < $1.sha256
            }
        for a in extras where items.count < limit {
            items.append(.init(assetID: poolID(for: a.sha256), sha256: a.sha256, width: a.width, height: a.height,
                               analysis: specAnalysis(from: a)))
        }
        return Array(items.prefix(limit))
    }

    /// Stabilt id för en poolbild som inte ligger i specen (får aldrig krocka med specens "a1", "a2", …).
    static func poolID(for sha256: String) -> String { "pool-\(sha256.prefix(12))" }

    static func specAnalysis(from a: ReelImageAnalysis) -> ReelSpec.Analysis {
        .init(room: a.room, category: a.category, focus: a.focus, salientWidth: a.salientWidth, focusWidth: a.focusWidth)
    }

    nonisolated struct Upload: Sendable, Equatable {
        var sha256: String
        var url: URL
    }

    /// Av `missing` (serverns svar): det som ska laddas upp, och hashar vi inte har någon fil för.
    static func uploads(missing: [String], files: [String: URL]) -> (uploads: [Upload], unresolved: [String]) {
        var uploads: [Upload] = []
        var unresolved: [String] = []
        for sha in missing {
            if let url = files[sha] { uploads.append(.init(sha256: sha, url: url)) } else { unresolved.append(sha) }
        }
        return (uploads, unresolved)
    }

    /// Specen som skickas: `local → store` (`img/<sha256>`). Lokala sökvägar lämnar aldrig Macen.
    static func storeSpec(_ spec: ReelSpec) -> ReelSpec {
        var out = spec
        for i in out.assets.indices {
            out.assets[i].sources = [.init(kind: .store, path: nil, url: nil, key: "img/\(out.assets[i].sha256)")]
        }
        return out
    }
}
