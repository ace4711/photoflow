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
    /// Räknas upp när sammanslagningens resultat ändras för samma indata, så att
    /// det som bygger på HDR-filen (t.ex. "Förbättra bilder") vet att göra om.
    /// 2 = rimlig justering (3000 px, avvisade orimliga förskjutningar), skärpning
    /// och rätta kanter i pyramiden.
    static let version = 2

    struct Options: Sendable {
        var maxDimension: Int = 6000
        var alignEnabled: Bool = true
        /// Förut 2400 px — förstorades ~2,5× i granskningen på en 6K-skärm.
        var jpegMaxDimension: Int = 4000
        var jpegQuality: Double = 0.92
        /// Lätt skärpning (unsharp mask) av resultatet, som kamerans och
        /// Lightrooms standardrendering gör — RAW-renderingen skärper inte.
        var sharpenEnabled: Bool = true
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
    ///
    /// - Parameter metadata: IPTC/XMP/GPS för TIFF- respektive JPEG-filen när den redan är
    ///   känd (fas 1b) — skrivs i samma exiftool-anrop som EXIF-kopian. `nil` = bara EXIF,
    ///   metadatasteget skriver resten.
    /// - Returns: sant om metadatan (EXIF + ev. IPTC/XMP/GPS) skrevs utan fel.
    ///
    /// `@concurrent`: projektet bygger med `NonisolatedNonsendingByDefault`, så
    /// utan det kördes hela sammanslagningen (sekunder per grupp, pixel för pixel)
    /// på anroparens aktör — huvudtråden — och appen frös med snurrande färghjul.
    @concurrent
    @discardableResult
    static func merge(
        rawURLs: [URL],
        options: Options = Options(),
        tiffURL: URL,
        jpegURL: URL,
        exiftoolPath: String?,
        metadata: (tiff: IPTCFileMetadata?, jpeg: IPTCFileMetadata?) = (nil, nil),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        guard rawURLs.count >= 2 else { throw EngineError.tooFewImages }

        let middleIndex = rawURLs.count / 2
        let whiteBalance = try PipelineMetrics.phase("readWhiteBalance") { try RAWRenderer.readWhiteBalance(url: rawURLs[middleIndex]) }

        var rendered: [RAWRenderer.RenderedImage] = []
        rendered.reserveCapacity(rawURLs.count)
        for (i, url) in rawURLs.enumerated() {
            try Task.checkCancellation()
            progress?(0.05 + 0.45 * Double(i) / Double(rawURLs.count))
            rendered.append(try PipelineMetrics.phase("render", bytesIn: PipelineMetrics.totalSize(of: [url])) {
                try RAWRenderer.render(url: url, whiteBalance: whiteBalance, maxDimension: options.maxDimension)
            })
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
                let measured = try PipelineMetrics.phase("align") {
                    try HDRAlignment.computeShift(
                        floating: rendered[i], reference: reference, maxAlignDimension: HDRAlignment.refinedAlignDimension
                    )
                }
                // Orimliga förskjutningar avvisas, små rundas till hela pixlar — se sanitizedShift.
                guard let shift = HDRAlignment.sanitizedShift(measured, width: width, height: height), shift != .zero else { continue }
                rendered[i].pixels = PipelineMetrics.phase("align.shift") {
                    RAWRenderer.shiftRGBA(rendered[i].pixels, width: width, height: height, dx: Float(shift.x), dy: Float(shift.y))
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
        // Radien skalas med upplösningen: 1,2 px vid kamerans 8256 px.
        let finalPixels = options.sharpenEnabled
            ? PipelineMetrics.phase("sharpen") {
                HDRWriter.sharpen(pixels: fused, width: width, height: height, radius: max(0.6, 1.2 * Double(max(width, height)) / 8256), intensity: 0.6)
            }
            : fused
        try HDRWriter.write(pixels: finalPixels, width: width, height: height, tiffURL: tiffURL, jpegURL: jpegURL, jpegMaxDimension: options.jpegMaxDimension, jpegQuality: options.jpegQuality)
        progress?(0.95)

        var metadataWritten = false
        if let exiftoolPath {
            // Fasnamnet "copyEXIF" behålls för jämförbarhet i timings.jsonl (fas 1a).
            metadataWritten = PipelineMetrics.phase("copyEXIF") {
                HDRWriter.writeMetadata(from: rawURLs[middleIndex],
                                        outputs: [(tiffURL, metadata.tiff), (jpegURL, metadata.jpeg)],
                                        exiftoolPath: exiftoolPath)
            }
        }
        progress?(1.0)
        return metadataWritten
    }
}
