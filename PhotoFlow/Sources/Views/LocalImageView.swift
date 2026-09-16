import SwiftUI
import AppKit
import CoreImage

struct LocalImageView: View {
    let url: URL?
    var maxSize: CGFloat? = nil

    @State private var nsImage: NSImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color.gray.opacity(0.1)
                    if url != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in loadImage() }
        .onDisappear { loadTask?.cancel() }
    }

    private func loadImage() {
        loadTask?.cancel()
        nsImage = nil

        guard let url else { return }
        let maxDim = maxSize ?? 2400

        // Fas 5: filmremsan/förhandsvisningen hoppar ofta fram och tillbaka
        // mellan samma bilder — kolla cachen innan vi avkodar från disk igen.
        if let cached = ImageCache.shared.image(for: url, tier: .fullSize) {
            nsImage = cached
            return
        }

        loadTask = Task {
            let image = await ImageLoader.downsampledImageAsync(at: url, maxDimension: maxDim)
            guard !Task.isCancelled else { return }
            if let image {
                ImageCache.shared.store(image, for: url, tier: .fullSize)
            }
            nsImage = image
        }
    }
}

/// Progressive image view: shows fast JPEG preview first, then loads full-res
/// RAW rendering after user stops navigating for a moment.
struct ProgressiveImageView: View {
    let previewURL: URL?
    let fullResURL: URL?  // NEF or DNG URL for full-resolution rendering
    var dngURL: URL? = nil // Preferred: DNG is better supported than NEF on macOS
    var delay: TimeInterval = 0.8

    @State private var previewImage: NSImage?
    @State private var fullResImage: NSImage?
    @State private var isHighRes: Bool = false
    @State private var previewTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?

    private var displayImage: NSImage? {
        fullResImage ?? previewImage
    }

    var body: some View {
        ZStack {
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color.gray.opacity(0.1)
                    if previewURL != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // High-res indicator
            if isHighRes {
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 10, weight: .bold))
                            Text("RAW")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        // Fas 5: glaseffekt i stället för solid färgbakgrund,
                        // i samma anda som Fas 3g:s övriga flytande badges.
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.85)), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        Spacer()
                    }
                    .padding(10)
                }
            }
        }
        .onAppear { startLoading() }
        .onChange(of: previewURL) { _, _ in startLoading() }
        .onChange(of: fullResURL) { _, _ in startLoading() }
        .onDisappear {
            previewTask?.cancel()
            loadTask?.cancel()
        }
    }

    private func startLoading() {
        // Cancel any pending full-res load
        previewTask?.cancel()
        loadTask?.cancel()
        fullResImage = nil
        isHighRes = false

        // Load preview immediately
        guard let previewURL else {
            previewImage = nil
            return
        }

        // Fas 5: cache-uppslag innan vi avkodar från disk igen.
        if let cached = ImageCache.shared.image(for: previewURL, tier: .fullSize) {
            previewImage = cached
        } else {
            previewImage = nil
            previewTask = Task {
                let img = await ImageLoader.downsampledImageAsync(at: previewURL, maxDimension: 2400)
                guard !Task.isCancelled else { return }
                if let img {
                    ImageCache.shared.store(img, for: previewURL, tier: .fullSize)
                }
                previewImage = img
            }
        }

        // Pick best RAW source: prefer DNG, fall back to NEF
        let rawURL: URL? = {
            if let dngURL, FileManager.default.fileExists(atPath: dngURL.path) { return dngURL }
            if let fullResURL, FileManager.default.fileExists(atPath: fullResURL.path) { return fullResURL }
            return nil
        }()

        guard let rawURL else { return }

        // Fas 5: en tidigare RAW-rendering av exakt denna fil (t.ex. vid
        // återbesök efter att ha bläddrat vidare och tillbaka) hämtas direkt
        // ur cachen i stället för att köras om (RAW-rendering är den
        // dyraste operationen i hela vyn).
        if let cachedRaw = ImageCache.shared.image(for: rawURL, tier: .fullSize) {
            fullResImage = cachedRaw
            isHighRes = true
            return
        }

        loadTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let img = await ImageLoader.renderRAW(at: rawURL, maxDimension: 4800)
            guard !Task.isCancelled, let img else { return }
            ImageCache.shared.store(img, for: rawURL, tier: .fullSize)

            withAnimation(.easeInOut(duration: 0.25)) {
                self.fullResImage = img
                self.isHighRes = true
            }
        }
    }
}

// MARK: - Shared image loading

// Pure/stateless image decoding, deliberately called from background
// DispatchQueue.global contexts (see call sites below) so RAW/JPEG decoding
// doesn't block the main thread. Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// this would otherwise be inferred MainActor-isolated.
nonisolated enum ImageLoader {
    static func downsampledImage(at url: URL, maxDimension: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Async wrapper around `downsampledImage`, so views can use `Task`
    /// (cancellable, structured) instead of dispatching to
    /// `DispatchQueue.global` themselves (Fas 5) — the actual decode still
    /// runs off the main thread here, same as before.
    static func downsampledImageAsync(at url: URL, maxDimension: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: downsampledImage(at: url, maxDimension: maxDimension))
            }
        }
    }

    /// Render a RAW file (NEF/DNG) using Core Image's RAW processing pipeline.
    /// This produces a properly tone-mapped, color-corrected image.
    static func renderRAW(at url: URL, maxDimension: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = renderRAWSync(at: url, maxDimension: maxDimension)
                continuation.resume(returning: img)
            }
        }
    }

    private static func renderRAWSync(at url: URL, maxDimension: CGFloat) -> NSImage? {
        // Try CIRAWFilter first (macOS 12+), then fall back to CGImageSource
        if let image = renderWithCIRAWFilter(at: url, maxDimension: maxDimension) {
            return image
        }
        // Fallback: use CGImageSource with RAW-specific options
        return renderWithCGImageSource(at: url, maxDimension: maxDimension)
    }

    private static func renderWithCIRAWFilter(at url: URL, maxDimension: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let rawFilter = CIRAWFilter(imageURL: url) else { return nil }

        // Use default RAW processing (auto white balance, exposure, etc.)
        rawFilter.extendedDynamicRangeAmount = 0
        rawFilter.boostAmount = 0

        guard let ciImage = rawFilter.outputImage else { return nil }

        // Scale down if needed
        let extent = ciImage.extent
        let scale = min(maxDimension / extent.width, maxDimension / extent.height, 1.0)
        let scaledImage = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let scaledExtent = scaledImage.extent
        guard let cgImage = context.createCGImage(scaledImage, from: scaledExtent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func renderWithCGImageSource(at url: URL, maxDimension: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct LocalThumbnailView: View {
    let url: URL?

    @State private var nsImage: NSImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear { loadThumb() }
        .onChange(of: url) { _, _ in loadThumb() }
        .onDisappear { loadTask?.cancel() }
    }

    private func loadThumb() {
        loadTask?.cancel()
        guard let url else {
            nsImage = nil
            return
        }

        if let cached = ImageCache.shared.image(for: url, tier: .thumbnail) {
            nsImage = cached
            return
        }

        loadTask = Task {
            let img = await ImageLoader.downsampledImageAsync(at: url, maxDimension: 200)
            guard !Task.isCancelled else { return }
            if let img {
                ImageCache.shared.store(img, for: url, tier: .thumbnail)
            }
            nsImage = img
        }
    }
}
