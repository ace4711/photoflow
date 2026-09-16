import AppKit

/// Fas 5: gallringens filmremsa (`LocalThumbnailView`) och förhandsvisning
/// (`LocalImageView`/`ProgressiveImageView`) avkodade tidigare om samma bild
/// från disk varje gång vyn dök upp igen (`onAppear`/`onChange`) — att bläddra
/// fram och tillbaka i `PreviewCullView`/`BracketReviewView` betydde att
/// samma JPEG-förhandsbild kunde avkodas dussintals gånger under en session.
///
/// Två separata `NSCache`-nivåer (samma mönster som appens övriga
/// storleksbegränsade, självstädande cachar): miniatyrer (~200px, filmremsan,
/// många poster) och fullstorlek/preview (2400–4800px, huvudvyn, färre men
/// mycket större poster). `NSCache` är trådsäker och tömmer sig själv vid
/// minnespress oavsett — `totalCostLimit`/`countLimit` nedan är bara en övre
/// gräns så en riktig session (300–1000+ bilder) inte växer obegränsat innan
/// systemet hinner reagera på minnespress.
///
/// Klassen är `@MainActor` (som resten av UI-lagret, se
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` i Fas 2b) — alla anrop sker från
/// SwiftUI-vyer. Den faktiska bildavkodningen sker fortfarande i bakgrunden
/// via `ImageLoader`s async-wrappers (se `LocalImageView.swift`); cachen
/// lagrar bara resultatet.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    enum Tier {
        /// Filmremsans miniatyrer (~200px). Många poster, liten kostnad var.
        case thumbnail
        /// Huvudvyns förhandsbild/RAW-rendering (2400–4800px). Få poster,
        /// stor kostnad var.
        case fullSize
    }

    private let thumbnailCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.name = "PhotoFlow.ImageCache.thumbnail"
        cache.totalCostLimit = 128 * 1024 * 1024 // 128 MB
        cache.countLimit = 4000
        return cache
    }()

    private let fullSizeCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.name = "PhotoFlow.ImageCache.fullSize"
        cache.totalCostLimit = 512 * 1024 * 1024 // 512 MB
        cache.countLimit = 200
        return cache
    }()

    /// URLs som just nu håller på att förhämtas (se `prefetch(url:tier:maxDimension:)`)
    /// — förhindrar att samma bild startas om flera gånger om
    /// `currentCullIndex` hinner ändras igen innan en pågående förhämtning
    /// blir klar.
    private var pendingPrefetches: Set<URL> = []

    private init() {}

    func image(for url: URL, tier: Tier) -> NSImage? {
        cache(for: tier).object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL, tier: Tier) {
        cache(for: tier).setObject(image, forKey: url as NSURL, cost: cost(of: image))
    }

    /// Laddar `url` i bakgrunden och lägger resultatet i cachen om det inte
    /// redan finns där (eller redan är på väg dit) — gör ingenting synkront,
    /// bara startar en lågprioriterad bakgrundsuppgift. Används för att
    /// förhämta grannbilder runt `currentCullIndex`/`selectedPhotoIndex`
    /// innan användaren faktiskt navigerar dit.
    func prefetch(url: URL?, tier: Tier, maxDimension: CGFloat) {
        guard let url else { return }
        guard image(for: url, tier: tier) == nil else { return }
        guard pendingPrefetches.insert(url).inserted else { return }

        Task.detached(priority: .utility) { [weak self] in
            let image = await ImageLoader.downsampledImageAsync(at: url, maxDimension: maxDimension)
            await MainActor.run {
                guard let self else { return }
                self.pendingPrefetches.remove(url)
                if let image {
                    self.store(image, for: url, tier: tier)
                }
            }
        }
    }

    /// Rensar båda nivåerna — används inte av appen idag men finns för
    /// framtida bruk (t.ex. om en ny session öppnas och gamla previews aldrig
    /// kommer att visas igen).
    func clear() {
        thumbnailCache.removeAllObjects()
        fullSizeCache.removeAllObjects()
        pendingPrefetches.removeAll()
    }

    private func cache(for tier: Tier) -> NSCache<NSURL, NSImage> {
        switch tier {
        case .thumbnail: return thumbnailCache
        case .fullSize: return fullSizeCache
        }
    }

    /// Grov byte-uppskattning (bredd × höjd × 4 kanaler) för `NSCache`s
    /// relativa kostnadsbokföring — behöver inte vara exakt, bara i rätt
    /// storleksordning så `totalCostLimit` faktiskt begränsar minnet.
    private func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}
