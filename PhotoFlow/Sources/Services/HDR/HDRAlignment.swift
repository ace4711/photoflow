import Foundation
import CoreGraphics
import Accelerate
import Vision

/// Corrects small hand-held movement between exposures in a bracket before
/// fusion, using Vision's translational image registration on a downscaled
/// grayscale copy of each frame.
///
/// ## API choice
/// macOS 26/27 Vision has two translational-registration APIs:
/// - The new Swift-native `TrackTranslationalImageRegistrationRequest`, built
///   for *video* frame tracking (it's `StatefulRequest`, takes a
///   `frameAnalysisSpacing: CMTime`, and is designed to be fed a stream of
///   frames one at a time).
/// - The older `VNTranslationalImageRegistrationRequest` /
///   `VNImageRequestHandler`, a plain one-shot "align floating image onto
///   reference image" request (verified in
///   `Vision.framework/Headers/VNImageRegistrationRequest.h`).
///
/// A bracket is a handful of independent still exposures, not a video
/// stream, so the older one-shot API is the better fit here and is what's
/// used below — it isn't deprecated, just superseded for the video use case.
nonisolated enum HDRAlignment {
    enum AlignmentError: LocalizedError {
        case cgImageCreationFailed

        var errorDescription: String? {
            "Kunde inte skapa en nedskalad gråskalebild för bildjustering."
        }
    }

    /// Computes the pixel-space `(dx, dy)` translation that moves `floating`'s
    /// content onto `reference`'s framing, at `floating`/`reference`'s own
    /// (full working) resolution. Both images must be the same size — true by
    /// construction since every exposure in a bracket is rendered by
    /// `RAWRenderer` with the same `maxDimension`.
    ///
    /// Registration itself runs on a small grayscale downscale (`maxAlignDimension`,
    /// default 800px long side) for speed and robustness (less sensitive to
    /// per-pixel noise than full resolution), then the result is scaled back
    /// up. Returns `.zero` (no correction) if registration finds no result or
    /// the images differ in size.
    static func computeShift(
        floating: RAWRenderer.RenderedImage,
        reference: RAWRenderer.RenderedImage,
        maxAlignDimension: Int = 800
    ) throws -> CGPoint {
        guard floating.width == reference.width, floating.height == reference.height else {
            return .zero
        }

        let floatingSmall = try downscaledGrayscaleCGImage(floating, maxDimension: maxAlignDimension)
        let referenceSmall = try downscaledGrayscaleCGImage(reference, maxDimension: maxAlignDimension)

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floatingSmall.image, options: [:], completionHandler: nil)
        let handler = VNImageRequestHandler(cgImage: referenceSmall.image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else { return .zero }
        let transform = observation.alignmentTransform

        // Both small images were downscaled by the same factor from the same
        // full-resolution size, so this ratio is exact (no aspect assumptions).
        let scaleX = Double(floating.width) / Double(floatingSmall.width)
        let scaleY = Double(floating.height) / Double(floatingSmall.height)
        return CGPoint(x: transform.tx * scaleX, y: transform.ty * scaleY)
    }

    /// Extracts luminance from `image`, scales it down to `maxDimension` long
    /// side with `vImageScale_PlanarF`, and wraps it as an 8-bit grayscale
    /// `CGImage` for Vision.
    private static func downscaledGrayscaleCGImage(
        _ image: RAWRenderer.RenderedImage,
        maxDimension: Int
    ) throws -> (image: CGImage, width: Int, height: Int) {
        var gray = [Float](repeating: 0, count: image.width * image.height)
        image.pixels.withUnsafeBufferPointer { src in
            gray.withUnsafeMutableBufferPointer { dst in
                for p in 0..<(image.width * image.height) {
                    dst[p] = 0.2126 * src[p * 4] + 0.7152 * src[p * 4 + 1] + 0.0722 * src[p * 4 + 2]
                }
            }
        }

        let longSide = max(image.width, image.height)
        let scale = longSide > maxDimension ? Double(maxDimension) / Double(longSide) : 1.0
        let smallWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let smallHeight = max(1, Int((Double(image.height) * scale).rounded()))

        var scaledFloat = [Float](repeating: 0, count: smallWidth * smallHeight)
        gray.withUnsafeMutableBufferPointer { srcBuf in
            scaledFloat.withUnsafeMutableBufferPointer { dstBuf in
                var srcBuffer = vImage_Buffer(
                    data: srcBuf.baseAddress, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                    rowBytes: image.width * MemoryLayout<Float>.size
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBuf.baseAddress, height: vImagePixelCount(smallHeight), width: vImagePixelCount(smallWidth),
                    rowBytes: smallWidth * MemoryLayout<Float>.size
                )
                _ = vImageScale_PlanarF(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
            }
        }

        var pixels8 = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        scaledFloat.withUnsafeMutableBufferPointer { srcBuf in
            pixels8.withUnsafeMutableBufferPointer { dstBuf in
                var srcBuffer = vImage_Buffer(
                    data: srcBuf.baseAddress, height: vImagePixelCount(smallHeight), width: vImagePixelCount(smallWidth),
                    rowBytes: smallWidth * MemoryLayout<Float>.size
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBuf.baseAddress, height: vImagePixelCount(smallHeight), width: vImagePixelCount(smallWidth),
                    rowBytes: smallWidth
                )
                _ = vImageConvert_PlanarFtoPlanar8(&srcBuffer, &dstBuffer, 1.0, 0.0, vImage_Flags(kvImageNoFlags))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels8) as CFData),
              let cgImage = CGImage(
                width: smallWidth, height: smallHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: smallWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw AlignmentError.cgImageCreationFailed
        }

        return (cgImage, smallWidth, smallHeight)
    }
}
