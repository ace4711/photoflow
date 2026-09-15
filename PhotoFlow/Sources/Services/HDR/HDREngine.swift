import Foundation
import CoreGraphics

/// Orchestrates the full RAW-to-merged-TIFF pipeline for one bracket group:
/// render every exposure with `RAWRenderer`, optionally correct hand-held
/// misalignment with `HDRAlignment`, fuse with `ExposureFusion`, and write
/// the result with `HDRWriter`. This is the Swift/Core Image replacement for
/// the old `PipelineRunner+HDR.swift` OpenCV/Python path (see
/// `FORBATTRINGAR.md`, "Fas 3a").
///
/// `nonisolated` (not `@MainActor`): called with `await` from
/// `PipelineRunner` (which itself runs on `@MainActor` under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`), a call from a `MainActor`
/// context into a `nonisolated async` function actually hops off the main
/// actor to run on the cooperative thread pool — exactly the "run outside
/// MainActor" behavior the pipeline needs for a multi-second RAW decode +
/// pyramid fusion, without a manual `Task.detached`.
nonisolated enum HDREngine {
    struct Options: Sendable {
        var maxDimension: Int = 6000
        var alignEnabled: Bool = true
        var jpegMaxDimension: Int = 2400
        var jpegQuality: Double = 0.92
    }

    enum EngineError: LocalizedError {
        case tooFewImages
        case sizeMismatch

        var errorDescription: String? {
            switch self {
            case .tooFewImages: return "Minst 2 bilder krävs för HDR-sammanslagning."
            case .sizeMismatch: return "Bilderna i bracket-gruppen har olika storlek efter RAW-rendering."
            }
        }
    }

    /// Merges `rawURLs` (already resolved to DNG-if-available/NEF paths, in
    /// their original bracket order) into one TIFF+JPEG pair at `tiffURL`/`jpegURL`.
    ///
    /// Checks `Task.checkCancellation()` between each image render and
    /// before/after fusion, so a cancelled pipeline `Task` unwinds promptly
    /// instead of finishing an already-started multi-second merge.
    ///
    /// - Parameter progress: optional UI progress callback, 0...1, called a
    ///   handful of times (per image rendered, per fusion phase) — not
    ///   throwing; use the caller's own `Task` cancellation to abort.
    static func merge(
        rawURLs: [URL],
        options: Options = Options(),
        tiffURL: URL,
        jpegURL: URL,
        exiftoolPath: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard rawURLs.count >= 2 else { throw EngineError.tooFewImages }

        let middleIndex = rawURLs.count / 2
        let whiteBalance = try RAWRenderer.readWhiteBalance(url: rawURLs[middleIndex])

        var rendered: [RAWRenderer.RenderedImage] = []
        rendered.reserveCapacity(rawURLs.count)
        for (i, url) in rawURLs.enumerated() {
            try Task.checkCancellation()
            progress?(0.05 + 0.45 * Double(i) / Double(rawURLs.count))
            rendered.append(try RAWRenderer.render(url: url, whiteBalance: whiteBalance, maxDimension: options.maxDimension))
        }

        guard let first = rendered.first else { throw EngineError.tooFewImages }
        let width = first.width, height = first.height
        guard rendered.allSatisfy({ $0.width == width && $0.height == height }) else {
            throw EngineError.sizeMismatch
        }

        if options.alignEnabled {
            let reference = rendered[middleIndex]
            for i in rendered.indices where i != middleIndex {
                try Task.checkCancellation()
                let shift = try HDRAlignment.computeShift(floating: rendered[i], reference: reference)
                if shift != .zero {
                    rendered[i].pixels = RAWRenderer.shiftRGBA(rendered[i].pixels, width: width, height: height, dx: Float(shift.x), dy: Float(shift.y))
                }
            }
        }
        progress?(0.55)
        try Task.checkCancellation()

        let images = rendered.map(\.pixels)
        let fused = try ExposureFusion.fuse(images: images, width: width, height: height) { fraction in
            try Task.checkCancellation()
            progress?(0.55 + 0.35 * fraction)
        }

        try Task.checkCancellation()
        try HDRWriter.write(pixels: fused, width: width, height: height, tiffURL: tiffURL, jpegURL: jpegURL, jpegMaxDimension: options.jpegMaxDimension, jpegQuality: options.jpegQuality)
        progress?(0.95)

        if let exiftoolPath {
            HDRWriter.copyEXIF(from: rawURLs[middleIndex], to: [tiffURL, jpegURL], exiftoolPath: exiftoolPath)
        }
        progress?(1.0)
    }
}
