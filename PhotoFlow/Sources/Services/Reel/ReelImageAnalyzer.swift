import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import Vision

/// Analysen av en färdig bild (exporterad från Lightroom) som bildspelsmodulen
/// ("Objektfilm") bygger urval och rörelse på. Allt är normaliserat
/// (koordinater i [0,1], origo uppe till vänster, y neråt) och `Codable`, så
/// att resultatet kan cachas i `reel_analysis.json` nycklat på `sha256`.
nonisolated struct ReelImageAnalysis: Codable, Sendable, Equatable {

    /// Ett saliency-område i normaliserade bildkoordinater (origo uppe till vänster).
    nonisolated struct Box: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// SHA-256 av filinnehållet (hex, gemener). Bildens identitet och cachenyckel.
    var sha256: String
    var width: Int
    var height: Int
    /// 0...1 (Visions estetikpoäng, normaliserad), se `PhotoQualityService`.
    var qualityScore: Double?
    var isUtility: Bool
    var horizonAngleDegrees: Double?
    /// Relativt mått (Laplace-varians), bara jämförbart inom ett objekt.
    var sharpness: Double?
    /// Visions feature print som råa `Float32`-värden (little endian). Kvadrerat
    /// euklidiskt avstånd mellan två sådana vektorer är detsamma som Visions `distance(to:)`.
    var featurePrint: Data?
    var saliencyBoxes: [Box]
    /// Motivets tyngdpunkt (areaviktad över saliency-boxarna), nil utan saliency.
    var focus: ReelSpec.Point?
    /// Motivets sammanlagda bredd som andel av bildbredden (unionen av boxarnas x-intervall).
    var salientWidth: Double?
    /// 0...1, medelluminans på en liten nedskalad kopia.
    var meanLuminance: Double?
    /// EXIF DateTimeOriginal (lokal tid) om den finns.
    var exifDate: Date?
    var room: String?
    /// "Interiör" / "Exteriör".
    var category: String?
    var features: [String]?
    var caption: String?
    /// Varifrån rum/bildtext kom: "foundationModels" (modellen tillfrågades, även
    /// om svaret blev tomt), "aiTags" (reserv från sessionens ai_tags.json) eller nil.
    var describedBy: String?

    /// Feature printen som flyttal, för avståndsberäkning.
    var featureVector: [Float]? {
        guard let data = featurePrint, !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Analyserar godtyckliga färdiga bilder (JPEG/TIFF) för bildspelsmodulen.
/// Återanvänder `PhotoQualityService.measureImage` (kvalitet, nyttobild, horisont,
/// skärpa, feature print), lägger till saliency, luminans och EXIF-tid, och
/// hämtar rum/kategori/särdrag/bildtext från `PhotoDescriptionService` när den
/// finns (reserv: sessionens `ai_tags.json`, se `fallbackEntry`).
///
/// Resultatet cachas i `reel_analysis.json` (versionerat, nycklat på SHA-256),
/// så att analysen överlever omdöpningar och om-exporter och bara det som saknas
/// analyseras om. `nonisolated enum`: samma mönster som `PhotoQualityService`;
/// tungt arbete körs i `@concurrent`-funktioner så att det aldrig hamnar på
/// MainActor (projektet har `NonisolatedNonsendingByDefault`).
nonisolated enum ReelImageAnalyzer {

    static let currentVersion = 1
    static let cacheFileName = "reel_analysis.json"

    /// En analyserad bild tillsammans med filen den kom från.
    nonisolated struct Item: Sendable, Equatable {
        var url: URL
        var analysis: ReelImageAnalysis
    }

    nonisolated struct PersistedFile: Codable {
        var version: Int
        var analyses: [String: ReelImageAnalysis]
    }

    // MARK: - Cache

    static func loadCache(from directory: URL) -> [String: ReelImageAnalysis] {
        let file = directory.appendingPathComponent(cacheFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // samma som i saveCache
        guard let data = try? Data(contentsOf: file),
              let persisted = try? decoder.decode(PersistedFile.self, from: data),
              persisted.version == currentVersion else { return [:] }
        return persisted.analyses
    }

    /// Skriver atomiskt (temporärfil + byte), så en avbruten körning aldrig lämnar halv JSON.
    static func saveCache(_ analyses: [String: ReelImageAnalysis], to directory: URL) {
        let file = directory.appendingPathComponent(cacheFileName)
        let persisted = PersistedFile(version: currentVersion, analyses: analyses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(persisted) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Analys av en lista bilder

    /// Analyserar `urls` (ordningen bevaras; filer som inte går att läsa som bild
    /// utelämnas). `cacheDirectory` får `reel_analysis.json`; bara bilder vars
    /// hash saknas där analyseras. `aiTagsDirectory` pekar på en mapp med
    /// `ai_tags.json` (reserv för rum/bildtext). `describe: false` hoppar över
    /// Foundation Models (t.ex. i tester). Respekterar Task-avbrytning: kastar
    /// `CancellationError`, men sparar först det som hunnit bli klart.
    static func analyze(
        urls: [URL],
        cacheDirectory: URL?,
        aiTagsDirectory: URL? = nil,
        describe: Bool = true,
        maxConcurrent: Int = 4,
        progress: @Sendable @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> [Item] {
        guard !urls.isEmpty else { return [] }
        var cache = cacheDirectory.map(loadCache(from:)) ?? [:]
        let aiTags = aiTagsDirectory.flatMap { AITagsStore.load(from: $0) }
        let cacheSnapshot = cache

        var results = [ReelImageAnalysis?](repeating: nil, count: urls.count)
        var failure: Error?

        do {
            try await withThrowingTaskGroup(of: (Int, ReelImageAnalysis?).self) { group in
                var next = 0, inFlight = 0, completed = 0
                func addNext() {
                    guard next < urls.count else { return }
                    let idx = next, url = urls[idx]
                    next += 1; inFlight += 1
                    group.addTask {
                        (idx, await analyzeOne(url: url, cache: cacheSnapshot, describe: describe, aiTags: aiTags))
                    }
                }
                while inFlight < max(1, maxConcurrent) && next < urls.count {
                    try Task.checkCancellation()
                    addNext()
                }
                while let (idx, analysis) = try await group.next() {
                    inFlight -= 1
                    results[idx] = analysis
                    if let analysis { cache[analysis.sha256] = analysis }
                    completed += 1
                    await progress(completed, urls.count)
                    try Task.checkCancellation()
                    addNext()
                }
            }
        } catch {
            failure = error
        }

        if let cacheDirectory { saveCache(cache, to: cacheDirectory) }
        if let failure { throw failure }

        return urls.indices.compactMap { i in results[i].map { Item(url: urls[i], analysis: $0) } }
    }

    /// Analyserar en bild (eller återanvänder cachad analys). `@concurrent`: körs
    /// alltid utanför anroparens aktör.
    @concurrent
    static func analyzeOne(
        url: URL,
        cache: [String: ReelImageAnalysis],
        describe: Bool,
        aiTags: [String: AITagsStore.Entry]?
    ) async -> ReelImageAnalysis? {
        guard let sha = sha256Hex(of: url) else { return nil }
        if Task.isCancelled { return nil }

        let wantsModel = describe && PhotoDescriptionService.isAvailable
        var analysis: ReelImageAnalysis
        if let cached = cache[sha] {
            analysis = cached          // mätningarna återanvänds; bara beskrivningen kan saknas
        } else {
            guard let measured = await measure(url: url, sha: sha) else { return nil }
            analysis = measured
        }
        if Task.isCancelled { return nil }

        if wantsModel, analysis.describedBy != "foundationModels" {
            let tags = await PhotoDescriptionService.shared.describe(imageAt: url)
            analysis.describedBy = "foundationModels"
            if let tags {
                analysis.room = tags.room
                analysis.category = tags.category
                analysis.features = tags.features
                analysis.caption = tags.caption
            }
        }
        // Reserv: sessionens ai_tags.json, bara när modellen inte gav något rum.
        if analysis.room == nil, let aiTags,
           let entry = fallbackEntry(forFilename: url.lastPathComponent, in: aiTags) {
            analysis.room = entry.mlRoom ?? entry.tags.first
            analysis.category = entry.mlCategory ?? entry.category
            analysis.features = entry.mlFeatures
            analysis.caption = entry.mlCaption ?? (entry.description.isEmpty ? nil : entry.description)
            if analysis.describedBy == nil { analysis.describedBy = "aiTags" }
        }
        return analysis
    }

    /// Alla mätningar utom beskrivningen.
    private static func measure(url: URL, sha: String) async -> ReelImageAnalysis? {
        guard let props = imageProperties(url: url) else { return nil }
        let m = await PhotoQualityService.measureImage(url: url)
        let (boxes, focus, salientWidth) = await saliency(url: url)
        return ReelImageAnalysis(
            sha256: sha,
            width: props.width,
            height: props.height,
            qualityScore: PhotoQualityService.normalizedQualityScore(overallScore: m.overallScore),
            isUtility: m.isUtility,
            horizonAngleDegrees: m.horizonAngleDegrees,
            sharpness: m.sharpness,
            featurePrint: m.featurePrint.flatMap(floatData(from:)),
            saliencyBoxes: boxes,
            focus: focus,
            salientWidth: salientWidth,
            meanLuminance: meanLuminance(url: url),
            exifDate: props.exifDate
        )
    }

    // MARK: - Saliency

    private static func saliency(url: URL) async -> ([ReelImageAnalysis.Box], ReelSpec.Point?, Double?) {
        guard let obs = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: url) else {
            return ([], nil, nil)
        }
        // Vision har origo nere till vänster; vi lagrar uppe till vänster.
        let boxes = obs.salientObjects.map { o -> ReelImageAnalysis.Box in
            let r = o.boundingBox.cgRect
            return .init(x: Double(r.minX), y: 1 - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
        return (boxes, focus(of: boxes), salientWidth(of: boxes))
    }

    /// Unionen av boxarnas x-intervall som andel av bildbredden (0...1). Nil utan boxar.
    static func salientWidth(of boxes: [ReelImageAnalysis.Box]) -> Double? {
        guard !boxes.isEmpty else { return nil }
        let intervals = boxes.map { (max(0, $0.x), min(1, $0.x + $0.width)) }.sorted { $0.0 < $1.0 }
        var total = 0.0
        var cur = intervals[0]
        for iv in intervals.dropFirst() {
            if iv.0 <= cur.1 { cur.1 = max(cur.1, iv.1) } else { total += max(0, cur.1 - cur.0); cur = iv }
        }
        total += max(0, cur.1 - cur.0)
        return min(1, total)
    }

    /// Areaviktad tyngdpunkt över boxarna. Nil utan boxar.
    static func focus(of boxes: [ReelImageAnalysis.Box]) -> ReelSpec.Point? {
        guard !boxes.isEmpty else { return nil }
        var sum = 0.0, fx = 0.0, fy = 0.0
        for b in boxes {
            let a = max(b.width * b.height, 1e-6)
            sum += a
            fx += (b.x + b.width / 2) * a
            fy += (b.y + b.height / 2) * a
        }
        return .init(x: min(max(fx / sum, 0), 1), y: min(max(fy / sum, 0), 1))
    }

    // MARK: - Fil, EXIF, luminans, hash

    private struct ImageProps {
        var width: Int
        var height: Int
        var exifDate: Date?
    }

    private static func imageProperties(url: URL) -> ImageProps? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        // Orientering 5...8 betyder att bilden visas roterad 90°.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseExifDate)
        return ImageProps(width: w, height: h, exifDate: date)
    }

    /// "2026:10:03 09:12:00" i lokal tid.
    static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    /// Medelluminans (0...1) på en 64 px-kopia i gråskala.
    private static func meanLuminance(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let w = thumb.width, h = thumb.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0
        for i in 0..<(w * h) { sum += Int(p[i]) }
        return Double(sum) / Double(w * h) / 255
    }

    /// SHA-256 av filinnehållet, strömmat i 4 MB-bitar (bilderna kan vara tiotals MB).
    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` ger nil (inte tom Data) vid filslut.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 4 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func floatData(from print: FeaturePrintObservation) -> Data? {
        switch print.elementType {
        case .float:
            return print.data
        case .double:
            let doubles = print.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            let floats = doubles.map { Float($0) }
            return floats.withUnsafeBytes { Data($0) }
        @unknown default:
            return nil
        }
    }

    // MARK: - Reserv: ai_tags.json

    /// Hittar ai_tags-posten som hör till ett färdigt filnamn. Nycklarna är
    /// previewns namn (med eller utan ändelse, t.ex. `DSC_1234`); ett färdigt namn
    /// som `DSC_1234-HDR.jpg` matchar om det börjar med nyckeln och nästa tecken
    /// inte är en siffra (så att `DSC_123` aldrig matchar `DSC_1234`). Längsta nyckeln vinner.
    static func fallbackEntry(forFilename filename: String, in tags: [String: AITagsStore.Entry]) -> AITagsStore.Entry? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        var best: (key: String, entry: AITagsStore.Entry)?
        for (rawKey, entry) in tags {
            let key = (rawKey as NSString).deletingPathExtension.lowercased()
            guard !key.isEmpty, stem.hasPrefix(key) else { continue }
            let rest = stem.dropFirst(key.count)
            if let c = rest.first, c.isNumber { continue }
            if best == nil || key.count > best!.key.count { best = (key, entry) }
        }
        return best?.entry
    }
}
