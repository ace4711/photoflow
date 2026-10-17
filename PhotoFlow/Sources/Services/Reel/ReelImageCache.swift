import Foundation
import CoreGraphics
import ImageIO

/// Delad bildcache för bildspelet (Regi R3, risk 5.1): överlever `ReelRenderer`-byten, så att
/// förhandsvisningen inte laddar om bilderna vid varje redigering eller dragning, och används
/// också av rörelseeditorn för källbilden.
///
/// Nyckel: bildens identitet (sha256) och längsta sidan i pixlar. Ett uppslag godtar den minsta
/// cachade bild med samma identitet vars längsta sida räcker (`>=` önskad), annars laddas en ny
/// (avrundad uppåt till 256 pixlar, aldrig över originalet) och ersätter mindre bilder av samma
/// identitet. Taket är i byte (dekodad storlek, bredd × höjd × 4); minst använda bilder kastas först.
/// Trådsäker (lås). Laddaren är injicerbar så att tester kan räkna laddningar utan bildfiler.
nonisolated final class ReelImageCache: @unchecked Sendable {

    /// Laddar `url` nedskalad så att längsta sidan är högst `longEdge` pixlar (EXIF-roterad).
    typealias Loader = @Sendable (_ url: URL, _ longEdge: Int) -> CGImage?

    static let shared = ReelImageCache()
    /// Standardtak: ca 600 MB dekodade bilder (en 1920-pixlars bild är ca 10 MB).
    static let defaultMaxBytes = 600_000_000

    private struct Entry {
        var image: CGImage
        var longEdge: Int
        var bytes: Int
        var lastUsed: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: [Int: Entry]] = [:]   // id -> längsta sida -> bild
    private var tick: UInt64 = 0
    private var _loadCount = 0
    private var totalBytes = 0
    let maxBytes: Int
    private let loader: Loader

    init(maxBytes: Int = ReelImageCache.defaultMaxBytes, loader: @escaping Loader = ReelImageCache.loadThumbnail) {
        self.maxBytes = maxBytes
        self.loader = loader
    }

    /// Antal gånger laddaren anropats (för tester och mätning).
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return _loadCount }
    /// Antal cachade bilder och deras sammanlagda storlek i byte.
    var stats: (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries.values.reduce(0) { $0 + $1.count }, totalBytes)
    }

    func removeAll() {
        lock.lock(); entries.removeAll(); totalBytes = 0; lock.unlock()
    }

    /// Bilden för `id` med längsta sida minst `minLongEdge` (begränsad till `originalLongEdge`).
    /// nil om filen inte går att läsa.
    func image(id: String, url: URL, minLongEdge: Int, originalLongEdge: Int) -> CGImage? {
        let wanted = max(1, min(minLongEdge, originalLongEdge))
        lock.lock()
        tick += 1
        if let best = entries[id]?.filter({ $0.key >= wanted }).min(by: { $0.key < $1.key }) {
            entries[id]?[best.key]?.lastUsed = tick
            let image = best.value.image
            lock.unlock()
            return image
        }
        _loadCount += 1
        lock.unlock()

        let edge = min(originalLongEdge, (wanted + 255) / 256 * 256)
        guard let loaded = loader(url, edge) else { return nil }
        let cost = loaded.width * loaded.height * 4

        lock.lock()
        defer { lock.unlock() }
        tick += 1
        // Mindre bilder av samma identitet är nu överflödiga.
        for (k, e) in entries[id] ?? [:] where k < edge {
            totalBytes -= e.bytes
            entries[id]?[k] = nil
        }
        if let old = entries[id]?[edge] { totalBytes -= old.bytes }
        entries[id, default: [:]][edge] = Entry(image: loaded, longEdge: edge, bytes: cost, lastUsed: tick)
        totalBytes += cost
        evict(keeping: (id, edge))
        return loaded
    }

    /// Kastar minst använda bilder tills taket hålls (den nyss lagda bilden behålls alltid).
    private func evict(keeping: (String, Int)) {
        while totalBytes > maxBytes {
            var oldest: (id: String, edge: Int, used: UInt64)?
            for (id, byEdge) in entries {
                for (edge, e) in byEdge where !(id == keeping.0 && edge == keeping.1) {
                    if oldest == nil || e.lastUsed < oldest!.used { oldest = (id, edge, e.lastUsed) }
                }
            }
            guard let victim = oldest else { return }
            totalBytes -= entries[victim.id]?[victim.edge]?.bytes ?? 0
            entries[victim.id]?[victim.edge] = nil
            if entries[victim.id]?.isEmpty == true { entries[victim.id] = nil }
        }
    }

    /// Standardladdare: nedskalad miniatyr med `CGImageSource`, roterad enligt EXIF.
    static let loadThumbnail: Loader = { url, longEdge in
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
