import Foundation
import CoreGraphics
import ImageIO

/// Histogram och klippning för en (nedskalad) bild.
nonisolated struct HistogramResult: Equatable {
    /// 64 staplar, andel pixlar per luminansintervall (summan ≈ 1).
    var bins: [Double]
    /// Andel pixlar där någon kanal är klippt i högdagrarna.
    var highClipFraction: Double
    /// Andel pixlar där alla kanaler är klippta i skuggorna.
    var lowClipFraction: Double
    /// RGBA-mask (röd = klippt hög, blå = klippt låg, annars transparent), width*height*4 byte.
    var mask: [UInt8]
    var width: Int
    var height: Int
}

nonisolated enum ReviewImageAnalysis {
    static let binCount = 64
    static let highThreshold: UInt8 = 250
    static let lowThreshold: UInt8 = 5

    static func isHighClipped(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        r >= highThreshold || g >= highThreshold || b >= highThreshold
    }

    static func isLowClipped(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        r <= lowThreshold && g <= lowThreshold && b <= lowThreshold
    }

    /// Ren analys av en RGBA-buffert (8 bit, 4 byte per pixel).
    static func analyze(rgba: [UInt8], width: Int, height: Int) -> HistogramResult {
        let n = width * height
        var bins = [Double](repeating: 0, count: binCount)
        var mask = [UInt8](repeating: 0, count: n * 4)
        guard n > 0, rgba.count >= n * 4 else {
            return HistogramResult(bins: bins, highClipFraction: 0, lowClipFraction: 0, mask: mask, width: width, height: height)
        }
        var high = 0, low = 0
        for i in 0..<n {
            let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
            let luma = (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
            bins[min(binCount - 1, luma * binCount / 256)] += 1
            if isHighClipped(r: r, g: g, b: b) {
                high += 1
                mask[i * 4] = 255; mask[i * 4 + 3] = 170
            } else if isLowClipped(r: r, g: g, b: b) {
                low += 1
                mask[i * 4 + 2] = 255; mask[i * 4 + 3] = 170
            }
        }
        let dn = Double(n)
        return HistogramResult(bins: bins.map { $0 / dn }, highClipFraction: Double(high) / dn,
                               lowClipFraction: Double(low) / dn, mask: mask, width: width, height: height)
    }

    /// Läser `url` nedskalad till högst `maxDimension` px och analyserar. Körs av anroparen
    /// utanför MainActor.
    static func analyze(url: URL, maxDimension: Int = 480) -> HistogramResult? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return analyze(rgba: buf, width: w, height: h)
    }

    /// Maskbild för överlägg.
    static func maskImage(_ r: HistogramResult) -> CGImage? {
        var data = r.mask
        return data.withUnsafeMutableBytes { p -> CGImage? in
            CGContext(data: p.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: r.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

/// Geometri för zoom 100 % och lupp.
nonisolated enum ReviewZoom {
    /// Rektangeln en bild med storlek `image` får när den passas in (aspect fit) i `container`.
    static func fitRect(container: CGSize, image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let s = min(container.width / image.width, container.height / image.height)
        let w = image.width * s, h = image.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Begränsar panorering (förskjutning av bildens centrum) så att bilden täcker vyn där den kan;
    /// är bilden mindre än vyn i en riktning hålls den centrerad.
    static func clampOffset(_ offset: CGSize, image: CGSize, viewport: CGSize) -> CGSize {
        func clamp(_ o: CGFloat, _ img: CGFloat, _ view: CGFloat) -> CGFloat {
            let maxO = max(0, (img - view) / 2)
            return min(maxO, max(-maxO, o))
        }
        return CGSize(width: clamp(offset.width, image.width, viewport.width),
                      height: clamp(offset.height, image.height, viewport.height))
    }

    /// Normaliserad punkt (0...1) i bilden under pekaren, eller nil utanför bilden.
    static func normalizedPoint(pointer: CGPoint, fit: CGRect) -> CGPoint? {
        guard fit.width > 0, fit.height > 0, fit.contains(pointer) else { return nil }
        return CGPoint(x: (pointer.x - fit.minX) / fit.width, y: (pointer.y - fit.minY) / fit.height)
    }

    /// Förskjutning av en bild i full pixelstorlek så att den normaliserade punkten hamnar i
    /// mitten av en ruta (lupp).
    static func loupeOffset(normalized p: CGPoint, imagePixels: CGSize) -> CGSize {
        CGSize(width: (0.5 - p.x) * imagePixels.width, height: (0.5 - p.y) * imagePixels.height)
    }
}
