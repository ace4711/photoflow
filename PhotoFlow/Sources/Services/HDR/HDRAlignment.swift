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
    /// Upplösning som registreringen körs på. Förut 800 px: där syns inte
    /// rörelser på 2–3 px i full storlek, och varje fel blev ~7 px uppskalat.
    static let refinedAlignDimension = 3000

    /// Gör en uppmätt förskjutning användbar, eller avvisar den:
    /// - mer än `maxFraction` av bilden → felregistrering (Vision ger ibland
    ///   tusentals px för den mörkaste/ljusaste exponeringen — det gav spökbilder
    ///   och strimmor i 8 av 97 grupper), ingen förskjutning alls;
    /// - under `minPixels` → brus, ingen förskjutning;
    /// - annars avrundat till hela pixlar, så att förskjutningen blir en ren
    ///   kopiering i stället för en bilinjär omsampling som mjukar upp bilden.
    /// Returnerar `nil` när förskjutningen avvisats som orimlig.
    static func sanitizedShift(_ raw: CGPoint, width: Int, height: Int, maxFraction: Double = 0.02, minPixels: Double = 1.5) -> CGPoint? {
        guard raw.x.isFinite, raw.y.isFinite,
              abs(raw.x) <= maxFraction * Double(width), abs(raw.y) <= maxFraction * Double(height) else { return nil }
        let x = abs(raw.x) < minPixels ? 0 : raw.x.rounded()
        let y = abs(raw.y) < minPixels ? 0 : raw.y.rounded()
        return CGPoint(x: x, y: y)
    }

    /// Förskjutningar över `threshold` px mäts om efter att de tillämpats (se `verifiedShift`).
    static func needsVerification(_ shift: CGPoint, threshold: Double = 3) -> Bool {
        (shift.x * shift.x + shift.y * shift.y).squareRoot() > threshold
    }

    /// Godkänner en förskjutning om det som är kvar efteråt är litet — högst 1,5 px eller
    /// en tredjedel av förskjutningen.
    static func verifiedShift(_ shift: CGPoint, residual: CGPoint) -> Bool {
        let s = (shift.x * shift.x + shift.y * shift.y).squareRoot()
        let r = (residual.x * residual.x + residual.y * residual.y).squareRoot()
        return r <= max(1.5, s / 3)
    }

    enum AlignmentError: LocalizedError {
        case cgImageCreationFailed

        var errorDescription: String? {
            "Kunde inte skapa en nedskalad gråskalebild för bildjustering."
        }
    }

    /// Computes the pixel-space `(dx, dy)` translation that moves `floating`'s
    /// content onto `reference`'s framing — i buffertens koordinater (x åt höger,
    /// y nedåt, samma som `RAWRenderer.shiftRGBA`), at `floating`/`reference`'s own
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
        maxAlignDimension: Int = 800,
        matchExposure: Bool = true,
        linearInput: Bool = false
    ) throws -> CGPoint {
        guard floating.width == reference.width, floating.height == reference.height else {
            return .zero
        }

        // Linjära ramar (radians): luma gammakodas efter nedskalningen, annars hamnar nästan hela
        // bilden på några få 8-bitarsnivåer.
        var floatingLuma = downscaledLuma(floating, maxDimension: maxAlignDimension)
        var referenceLuma = downscaledLuma(reference, maxDimension: maxAlignDimension)
        if linearInput {
            floatingLuma.pixels = floatingLuma.pixels.map { HDRImageOps.toGamma($0) }
            referenceLuma.pixels = referenceLuma.pixels.map { HDRImageOps.toGamma($0) }
        }
        // Exponeringsmatchning före registreringen: den mörkaste ramen (fönsterkällan i window
        // pull) är ofta 3–5 EV mörkare än referensen, och Vision jämför då nästan svarta
        // väggar mot en ljus interiör — registreringen blev osäker eller misslyckades. Med
        // gråskalebilden avbildad till referensens ljushetsfördelning (histogrammatchning,
        // en monoton "gain" som också tar hand om tonkurvan) ser båda bilderna likadana ut.
        let floatingPixels = matchExposure ? matchHistogram(floatingLuma.pixels, to: referenceLuma.pixels) : floatingLuma.pixels
        let floatingSmall = try grayscaleCGImage(floatingPixels, width: floatingLuma.width, height: floatingLuma.height)
        let referenceSmall = try grayscaleCGImage(referenceLuma.pixels, width: referenceLuma.width, height: referenceLuma.height)

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floatingSmall, options: [:], completionHandler: nil)
        let handler = VNImageRequestHandler(cgImage: referenceSmall, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else { return .zero }
        let transform = observation.alignmentTransform

        // Both small images were downscaled by the same factor from the same
        // full-resolution size, so this ratio is exact (no aspect assumptions).
        let scaleX = Double(floating.width) / Double(floatingLuma.width)
        let scaleY = Double(floating.height) / Double(floatingLuma.height)
        // Visions transform har origo nere till vänster (y uppåt), bufferten rad 0 överst
        // (y nedåt): y byter tecken. Förut användes ty rakt av, och den lodräta rättelsen
        // gick åt fel håll — en förskjutning på 2 px blev 4 px (uppmätt som kvarvarande
        // förskjutning i felsökningsläget, fas 1).
        return CGPoint(x: transform.tx * scaleX, y: -transform.ty * scaleY)
    }

    /// Avbildar `source` monotont så att dess fördelning (CDF) blir som `reference`s.
    /// Båda är luma i 0…1. 1024 nivåer räcker gott för registreringen (som ändå kör på 8 bitar).
    static func matchHistogram(_ source: [Float], to reference: [Float], bins: Int = 1024) -> [Float] {
        guard !source.isEmpty, !reference.isEmpty else { return source }
        func cdf(_ values: [Float]) -> [Double] {
            var hist = [Double](repeating: 0, count: bins)
            let scale = Float(bins - 1)
            for v in values {
                let i = Int((min(max(v, 0), 1) * scale).rounded())
                hist[i] += 1
            }
            var acc = 0.0
            let total = Double(values.count)
            return hist.map { acc += $0; return acc / total }
        }
        let srcCDF = cdf(source)
        let refCDF = cdf(reference)
        // För varje källnivå: den lägsta referensnivå vars CDF når källans CDF.
        var lut = [Float](repeating: 0, count: bins)
        var j = 0
        for i in 0..<bins {
            while j < bins - 1 && refCDF[j] < srcCDF[i] { j += 1 }
            lut[i] = Float(j) / Float(bins - 1)
        }
        let scale = Float(bins - 1)
        return source.map { lut[Int((min(max($0, 0), 1) * scale).rounded())] }
    }

    /// Luma ur `image`, nedskalad till `maxDimension` på långsidan med `vImageScale_PlanarF`.
    static func downscaledLuma(
        _ image: RAWRenderer.RenderedImage,
        maxDimension: Int
    ) -> (pixels: [Float], width: Int, height: Int) {
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
        guard smallWidth != image.width || smallHeight != image.height else { return (gray, image.width, image.height) }

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
        return (scaledFloat, smallWidth, smallHeight)
    }

    /// 8-bitars gråskale-`CGImage` för Vision av luma i 0…1.
    private static func grayscaleCGImage(_ luma: [Float], width: Int, height: Int) throws -> CGImage {
        let pixels8 = luma.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(pixels8) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw AlignmentError.cgImageCreationFailed
        }
        return cgImage
    }
}
