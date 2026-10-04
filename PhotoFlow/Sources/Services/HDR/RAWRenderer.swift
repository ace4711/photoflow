import Foundation
import CoreImage
import CoreGraphics
import ImageIO

/// Renders a single RAW file (DNG or NEF) to a linear-in-name-only, but
/// actually display-referred, sRGB-gamma-encoded RGBA float32 buffer using
/// `CIRAWFilter`.
///
/// Pure/stateless (no actor-isolated state) so it can run off the main actor —
/// RAW decoding is slow (tens to hundreds of ms per image at full res) and
/// must not block the UI. Follows the same `nonisolated enum` pattern as
/// `ExifReader`/`ToolLocator` for the same reason under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`.
///
/// ## Why sRGB-gamma-encoded output, not linear
/// The Mertens exposure-fusion weights (`ExposureFusion`) — contrast, saturation
/// and "well-exposedness" centered at 0.5 — are defined by the original paper on
/// display-referred (gamma-encoded) images, exactly like the 8-bit JPEGs the old
/// OpenCV path fused. Feeding it scene-linear values would make the
/// well-exposedness weight (centered at 0.5) meaningless (mid-gray in linear
/// light is far from 0.5) and bias contrast/saturation. So `CIRAWFilter`'s
/// linear sensor data is intentionally rendered through the sRGB transfer
/// function here, via `CGColorSpace.sRGB` passed to `CIContext.render`.
nonisolated enum RAWRenderer {
    /// One decoded RAW image: `width`x`height` RGBA float32 pixels, sRGB gamma
    /// encoded, straight (non-premultiplied) alpha, values clamped to
    /// approximately [0, 1] (small excursions above 1 are possible from the
    /// RAW decoder's tone curve/highlight recovery and are left as-is —
    /// `ExposureFusion` clamps its final output, not each input).
    struct RenderedImage {
        var width: Int
        var height: Int
        /// Row-major, 4 floats (R,G,B,A) per pixel, `width * height * 4` count.
        var pixels: [Float]
    }

    /// White balance captured from one exposure (normally the bracket's middle
    /// exposure) and then applied to every exposure in the group, so a
    /// per-shot auto-white-balance drift doesn't show up as color banding
    /// between fused regions that came from different source frames.
    struct WhiteBalance: Equatable {
        var temperature: Float
        var tint: Float
    }

    enum RendererError: LocalizedError {
        case cannotOpenRAW(URL)
        case noOutputImage(URL)
        case renderFailed(URL)

        var errorDescription: String? {
            switch self {
            case .cannotOpenRAW(let url):
                return "Kunde inte öppna RAW-fil: \(url.lastPathComponent)"
            case .noOutputImage(let url):
                return "CIRAWFilter gav ingen output-bild för: \(url.lastPathComponent)"
            case .renderFailed(let url):
                return "Kunde inte rendera RAW till buffert: \(url.lastPathComponent)"
            }
        }
    }

    /// Reads white balance from a RAW file without rendering the full image
    /// (cheap — `CIRAWFilter`'s properties are available before `outputImage`
    /// is ever pulled).
    static func readWhiteBalance(url: URL) throws -> WhiteBalance {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RendererError.cannotOpenRAW(url)
        }
        return WhiteBalance(temperature: filter.neutralTemperature, tint: filter.neutralTint)
    }

    /// Renders `url` (DNG preferred, NEF also supported — both go through
    /// `CIRAWFilter`) to a float32 RGBA buffer.
    ///
    /// - Parameters:
    ///   - whiteBalance: if given, overrides the file's own auto white balance
    ///     with a fixed value shared across the whole bracket (see
    ///     `WhiteBalance` above). If `nil`, uses the file's own as-shot value.
    ///   - maxDimension: target long-side size in pixels; `0` means full
    ///     native resolution. The actual `CIRAWFilter.scaleFactor` knob is used
    ///     (not a post-hoc resize) so the RAW decoder itself does less work.
    ///
    /// Hand-held misalignment between exposures is *not* corrected here —
    /// `HDRAlignment` measures it from the already-rendered buffers (so it
    /// can compare exposures at identical scale) and `shiftRGBA` below
    /// applies it afterwards, rather than this function re-entering
    /// `CIRAWFilter` with a guessed shift.
    static func render(
        url: URL,
        whiteBalance: WhiteBalance?,
        maxDimension: Int,
        boostAmount: Float = 1.0,
        shadowBias: Float? = nil,
        linearOutput: Bool = false
    ) throws -> RenderedImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RendererError.cannotOpenRAW(url)
        }

        // Use the newest decoder version this SDK/OS supports for this file's
        // image type (RAW vs. DNG have separate version lists). Verified in
        // CIRAWFilter.h: `supportedDecoderVersions` is "sorted in increasingly
        // newer order", so `.last` is always the newest — this automatically
        // picks up macOS 27's newer RAW decoder without hardcoding its name.
        if let newest = filter.supportedDecoderVersions.last {
            filter.decoderVersion = newest
        }

        // Same settings for every exposure in a bracket, so fusion only sees
        // differences in actual scene exposure, not per-shot decoder drift.
        if let whiteBalance {
            filter.neutralTemperature = whiteBalance.temperature
            filter.neutralTint = whiteBalance.tint
        }
        filter.exposure = 0
        // Full global tone curve (1, explicit rather than relying on the image-dependent default);
        // HDR "basram" renders with 0 so the exposures are proportional in linear light.
        filter.boostAmount = boostAmount
        filter.extendedDynamicRangeAmount = 0
        // Skuggförskjutningen (CIRAWFilter drar av ett svartvärde, 3 för NEF, 5 för Lightrooms
        // flyttals-DNG) gör en linjär rendering olinjär i skuggorna och kan ge negativa kanaler:
        // i LR:s HDR-DNG blev blå kanal < 0 i mörka partier → orange stick och krossade skuggor.
        // Med 0 är LR-DNG:n exakt proportionell mot NEF-ramarna (uppmätt, samma färg i alla nivåer).
        if let shadowBias { filter.shadowBias = shadowBias }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = true
        }

        let nativeSize = filter.nativeSize
        var postScale: CGFloat = 1
        if maxDimension > 0 {
            let longSide = max(nativeSize.width, nativeSize.height)
            if longSide > CGFloat(maxDimension) {
                let scale = CGFloat(maxDimension) / longSide
                // CIRAWFilter avkodar Lightrooms flyttals-DNG fel vid scaleFactor ≤ 0,5 (ett
                // förstorat utsnitt i stället för hela bilden, uppmätt på HDR-DNG:erna; 0,727 och
                // 1 är rätt) — för DNG avkodas då i 0,75 och skalas ned efteråt. NEF påverkas inte.
                if scale < 0.6, url.pathExtension.lowercased() == "dng" {
                    filter.scaleFactor = Float(minimumScaleFactor)
                    postScale = scale / minimumScaleFactor
                } else {
                    filter.scaleFactor = Float(scale)
                }
            }
        }

        guard var outputImage = filter.outputImage else {
            throw RendererError.noOutputImage(url)
        }
        if postScale < 1 {
            outputImage = outputImage.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: postScale, kCIInputAspectRatioKey: 1.0
            ])
            let e = outputImage.extent
            outputImage = outputImage.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .cropped(to: CGRect(x: 0, y: 0, width: floor(e.width), height: floor(e.height)))
        }

        let renderExtent = outputImage.extent
        let width = Int(renderExtent.width.rounded())
        let height = Int(renderExtent.height.rounded())
        guard width > 0, height > 0 else {
            throw RendererError.renderFailed(url)
        }

        // extendedLinearSRGB working space keeps the RAW decoder's wide gamut/
        // highlight headroom through the pipeline; the *destination* space of
        // the bitmap render below (sRGB) is what actually applies the gamma
        // encoding the fusion math needs.
        // `linearOutput`: scenlinjära värden (extendedLinearSRGB, inget tak) för radianssammanslagningen.
        guard let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let outputSpace = CGColorSpace(name: linearOutput ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB) else {
            throw RendererError.renderFailed(url)
        }
        let context = CIContext(options: [.workingColorSpace: workingSpace])

        var pixels = [Float](repeating: 0, count: width * height * 4)
        let rowBytes = width * 4 * MemoryLayout<Float>.size
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                outputImage,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: renderExtent,
                format: .RGBAf,
                colorSpace: outputSpace
            )
        }

        return RenderedImage(width: width, height: height, pixels: pixels)
    }

    /// Minsta `scaleFactor` som CIRAWFilter får avkoda med (se `render`).
    static let minimumScaleFactor: CGFloat = 0.75

    /// Sant för en scenlinjär, redan demosaicerad DNG (PhotometricInterpretation = LinearRaw,
    /// t.ex. Lightrooms HDR-/panoramasammanslagning): ingen tonkurva, ofta flera stopp mörk
    /// (BaselineExposure +2…+2,5) — Förbättra tonsätter den med `SceneLinearTone`.
    static func isSceneLinearDNG(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng",
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any] else { return false }
        let photometric = (dng["PhotometricInterpretation"] as? NSNumber)?.intValue
            ?? ((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?["PhotometricInterpretation"] as? NSNumber)?.intValue
        return photometric == 34892
    }

    /// DNG:ns BaselineExposure (EV), 0 om den saknas.
    static func baselineExposure(url: URL) -> Double {
        guard let filter = CIRAWFilter(imageURL: url) else { return 0 }
        return Double(filter.baselineExposure)
    }

    /// Shifts an RGBA float image by `(dx, dy)` pixels using bilinear
    /// interpolation with edge-clamped sampling, used to apply the sub-pixel
    /// translation `HDRAlignment` computes between a non-reference exposure
    /// and the bracket's reference exposure.
    ///
    /// Positiva `dx`/`dy` flyttar innehållet till högre x/y i bufferten, dvs. åt
    /// höger respektive nedåt (rad 0 är överst). `HDRAlignment.computeShift`
    /// returnerar förskjutningen i samma koordinater.
    static func shiftRGBA(_ pixels: [Float], width: Int, height: Int, dx: Float, dy: Float) -> [Float] {
        guard dx != 0 || dy != 0 else { return pixels }
        var out = [Float](repeating: 0, count: pixels.count)
        let w = width, h = height
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    // Source row for this y (content shifted by +dy means the
                    // sample for output row y comes from source row y - dy).
                    let sy = Float(y) - dy
                    let sy0 = Int(floor(sy))
                    let fy = sy - Float(sy0)
                    let y0 = min(max(sy0, 0), h - 1)
                    let y1 = min(max(sy0 + 1, 0), h - 1)

                    for x in 0..<w {
                        let sx = Float(x) - dx
                        let sx0 = Int(floor(sx))
                        let fx = sx - Float(sx0)
                        let x0 = min(max(sx0, 0), w - 1)
                        let x1 = min(max(sx0 + 1, 0), w - 1)

                        let i00 = (y0 * w + x0) * 4
                        let i10 = (y0 * w + x1) * 4
                        let i01 = (y1 * w + x0) * 4
                        let i11 = (y1 * w + x1) * 4
                        let outIdx = (y * w + x) * 4

                        for c in 0..<4 {
                            let top = src[i00 + c] * (1 - fx) + src[i10 + c] * fx
                            let bottom = src[i01 + c] * (1 - fx) + src[i11 + c] * fx
                            dst[outIdx + c] = top * (1 - fy) + bottom * fy
                        }
                    }
                }
            }
        }
        return out
    }
}
