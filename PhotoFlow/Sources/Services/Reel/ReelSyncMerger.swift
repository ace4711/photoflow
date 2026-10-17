import Foundation
import CryptoKit

/// Serverns spec → lokal spec. Ren logik: servern lagrar bara `store`-källor (`img/<sha256>`), och
/// `ReelRenderer.fileURL(for:)` löser bara `local`, så varje bild måste hitta sin fil på den här
/// Macen via innehållshash (`files`, se `ReelFileIndex`).
nonisolated enum ReelSyncMerger {

    nonisolated struct Result: Sendable, Equatable {
        var spec: ReelSpec
        /// Hashar för bilder som filmen använder men som inte finns på den här Macen.
        var missing: [String]
        var isComplete: Bool { missing.isEmpty }
    }

    /// `files`: sha256 → fil. `local`: nuvarande lokala spec (dess sökvägar används om en bild inte
    /// finns i `files` men filen ändå ligger kvar). `analyses`: `reel_analysis.json`, fyller i
    /// bildens `analysis` om servern saknar den. Tillgångar som inget klipp använder tas bort
    /// (redigeraren förutsätter att `assets` bara innehåller använda bilder).
    static func merge(remote: ReelSpec, local: ReelSpec?, files: [String: URL], specDirectory: URL,
                      analyses: [String: ReelImageAnalysis] = [:]) -> Result {
        // Relativa sökvägar ska lösas mot mappen, inte mot en "fil" med mappens namn.
        let specDirectory = URL(fileURLWithPath: specDirectory.path, isDirectory: true)
        let used = remote.usedAssetIDs   // klippens bilder och rutornas
        let localByHash = Dictionary((local?.assets ?? []).map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        var spec = remote
        var missing: [String] = []
        spec.assets = remote.assets.filter { used.contains($0.id) }.map { asset in
            var a = asset
            if let url = files[a.sha256] {
                a.sources = [.init(kind: .local, path: ReelComposer.relativePath(from: specDirectory, to: url), url: nil, key: nil)]
            } else if let kept = localByHash[a.sha256]?.sources.filter({ $0.kind == .local && exists($0, in: specDirectory) }),
                      !kept.isEmpty {
                a.sources = kept
            } else {
                a.sources = []
                if !missing.contains(a.sha256) { missing.append(a.sha256) }
            }
            if a.analysis == nil, let found = analyses[a.sha256] { a.analysis = ReelUploadPlanner.specAnalysis(from: found) }
            return a
        }
        let ids = Set(spec.assets.map(\.id))
        spec.provenance.autoSelection = spec.provenance.autoSelection?.filter { ids.contains($0.asset) }
        return Result(spec: spec, missing: missing)
    }

    private static func exists(_ source: ReelSpec.Source, in dir: URL) -> Bool {
        guard let path = source.path else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL.path)
    }
}

/// sha256 → bildfil för en mapp med färdiga bilder. Hashar filinnehållet (samma hash som
/// `ReelImageAnalyzer`), så en omdöpt fil hittas ändå. Första filen vinner om två är identiska.
nonisolated enum ReelFileIndex {

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]

    static func imageFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static let lightExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    static let tiffExtensions: Set<String> = ["tif", "tiff"]

    /// Utan TIFF-tvillingar: en `.tif`/`.tiff` hoppas över när en JPG/HEIC/PNG med samma stam finns i
    /// listan (`DSC_1635_enh.tiff` mot `DSC_1635_enh.jpg`). TIFF:en är 50 gånger större och ger
    /// filmen ingenting (analysen läser hela filen över nätet). Filer i `keeping` (filnamn) behålls
    /// alltid: bilder en befintlig film redan använder, så att den känns igen och inget går förlorat.
    /// Ordningen bevaras.
    static func withoutTiffTwins(_ files: [URL], keeping: Set<String> = []) -> [URL] {
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        let lightStems = Set(files.filter { lightExtensions.contains($0.pathExtension.lowercased()) }.map(stem))
        return files.filter { url in
            guard tiffExtensions.contains(url.pathExtension.lowercased()) else { return true }
            return keeping.contains(url.lastPathComponent) || !lightStems.contains(stem(url))
        }
    }

    /// Filnamnen (utan mapp) som en befintlig `reel.json` i filmmappen refererar till via `sources.path`.
    /// Tomt om filen saknas eller inte går att läsa.
    static func referencedFileNames(inFilmDirectory directory: URL?) -> Set<String> {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("reel.json")),
              let spec = try? ReelSpec.decode(from: data) else { return [] }
        return Set(spec.assets.flatMap(\.sources).compactMap(\.path).map { ($0 as NSString).lastPathComponent })
    }

    /// Bilderna en film byggs av: alla bilder i mappen utom TIFF-tvillingar (se `withoutTiffTwins`),
    /// med undantag för det en befintlig `reel.json` i `filmDirectory` använder.
    static func filmImages(in directory: URL, filmDirectory: URL?) -> [URL] {
        withoutTiffTwins(imageFiles(in: directory), keeping: referencedFileNames(inFilmDirectory: filmDirectory))
    }

    /// Hashar alla bilder i mappen (utanför anroparens aktör).
    @concurrent
    static func build(sourceDirectory: URL) async -> [String: URL] {
        var index: [String: URL] = [:]
        for url in imageFiles(in: sourceDirectory) {
            if Task.isCancelled { break }
            guard let sha = ReelImageAnalyzer.sha256Hex(of: url) else { continue }
            if index[sha] == nil { index[sha] = url }
        }
        return index
    }

    /// Samma sak utan hashning, ur redan analyserade bilder.
    static func index(from items: [ReelImageAnalyzer.Item]) -> [String: URL] {
        var index: [String: URL] = [:]
        for item in items where index[item.analysis.sha256] == nil { index[item.analysis.sha256] = item.url }
        return index
    }
}
