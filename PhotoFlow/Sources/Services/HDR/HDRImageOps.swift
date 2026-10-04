import Foundation
import Accelerate
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Små bildoperationer på RGBA-/planar-float-buffertar som `WindowPull` och HDR-
/// felsökningen behöver: skalning (vImage), boxfilter, min/max-filter (morfologi),
/// sRGB-överföringsfunktionen och PNG/JPEG-skrivning. Rena funktioner utan tillstånd.
nonisolated enum HDRImageOps {
    typealias Plane = ExposureFusion.Plane

    /// Råpekare som får delas mellan trådarna i `concurrentPerform`. Varje iteration
    /// skriver bara sina egna rader/kolumner, så det finns inga kapplöpningar.
    struct Shared: @unchecked Sendable {
        let base: UnsafeMutablePointer<Float>
        init(_ buffer: UnsafeBufferPointer<Float>) { base = UnsafeMutablePointer(mutating: buffer.baseAddress!) }
        init(_ buffer: UnsafeMutableBufferPointer<Float>) { base = buffer.baseAddress! }
        subscript(i: Int) -> Float {
            get { base[i] }
            nonmutating set { base[i] = newValue }
        }
    }

    // MARK: - sRGB

    @inline(__always) static func toLinear(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func toGamma(_ l: Float) -> Float {
        let c = max(l, 0)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    @inline(__always) static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Skalning

    /// Storlek med långsidan `maxDimension` (aldrig större än originalet).
    static func scaledSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxDimension, maxDimension > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longSide)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Skalar en RGBA-float-buffert (4 kanaler, ordningen spelar ingen roll för vImage).
    static func scaleRGBA(_ pixels: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        if toWidth == width && toHeight == height { return pixels }
        var out = [Float](repeating: 0, count: toWidth * toHeight * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * 16)
                var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(toHeight),
                                      width: vImagePixelCount(toWidth), rowBytes: toWidth * 16)
                _ = vImageScale_ARGBFFFF(&s, &d, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    static func scale(_ plane: Plane, toWidth: Int, toHeight: Int) -> Plane {
        if toWidth == plane.width && toHeight == plane.height { return plane }
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        plane.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: vImagePixelCount(plane.height),
                                      width: vImagePixelCount(plane.width), rowBytes: plane.width * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(toHeight),
                                      width: vImagePixelCount(toWidth), rowBytes: toWidth * 4)
                _ = vImageScale_PlanarF(&s, &d, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return Plane(width: toWidth, height: toHeight, data: out)
    }

    /// Bilinjär uppskalning (utan Lanczos-överslängar — viktigt för masker och guided
    /// filter-koefficienter, där ringningar blir synliga kanter).
    static func bilinear(_ plane: Plane, toWidth: Int, toHeight: Int) -> Plane {
        if toWidth == plane.width && toHeight == plane.height { return plane }
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        let sx = Float(plane.width) / Float(toWidth), sy = Float(plane.height) / Float(toHeight)
        let w = plane.width, h = plane.height
        plane.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let src = Shared(src), dst = Shared(dstBuf)
                DispatchQueue.concurrentPerform(iterations: toHeight) { y in
                    let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
                    let y0 = min(Int(fy), h - 1), y1 = min(y0 + 1, h - 1)
                    let ty = fy - Float(y0)
                    for x in 0..<toWidth {
                        let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                        let x0 = min(Int(fx), w - 1), x1 = min(x0 + 1, w - 1)
                        let tx = fx - Float(x0)
                        let top = src[y0 * w + x0] * (1 - tx) + src[y0 * w + x1] * tx
                        let bottom = src[y1 * w + x0] * (1 - tx) + src[y1 * w + x1] * tx
                        dst[y * toWidth + x] = top * (1 - ty) + bottom * ty
                    }
                }
            }
        }
        return Plane(width: toWidth, height: toHeight, data: out)
    }

    // MARK: - Kanaler

    static func lumaPlane(_ pixels: [Float], width: Int, height: Int) -> Plane {
        var out = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { px in
            out.withUnsafeMutableBufferPointer { dst in
                for p in 0..<(width * height) { dst[p] = luma(px[p * 4], px[p * 4 + 1], px[p * 4 + 2]) }
            }
        }
        return Plane(width: width, height: height, data: out)
    }

    static func maxChannelPlane(_ pixels: [Float], width: Int, height: Int) -> Plane {
        var out = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { px in
            out.withUnsafeMutableBufferPointer { dst in
                for p in 0..<(width * height) { dst[p] = max(px[p * 4], px[p * 4 + 1], px[p * 4 + 2]) }
            }
        }
        return Plane(width: width, height: height, data: out)
    }

    // MARK: - Filter

    /// Medelvärde i ett (2r+1)²-fönster med kantklippning (fönstret krymper vid kanten,
    /// som i He m.fl.:s guided filter). Separabelt med löpande summor: O(1) per pixel
    /// oavsett radie.
    static func boxMean(_ plane: Plane, radius r: Int) -> Plane {
        let w = plane.width, h = plane.height
        guard r > 0 else { return plane }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        plane.data.withUnsafeBufferPointer { srcBuf in
            tmp.withUnsafeMutableBufferPointer { tBuf in
                let src = Shared(srcBuf), t = Shared(tBuf)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let row = y * w
                    var sum = 0.0
                    for x in 0...min(r, w - 1) { sum += Double(src[row + x]) }
                    for x in 0..<w {
                        let lo = max(0, x - r), hi = min(w - 1, x + r)
                        t[row + x] = Float(sum / Double(hi - lo + 1))
                        let add = x + r + 1, remove = x - r
                        if add < w { sum += Double(src[row + add]) }
                        if remove >= 0 { sum -= Double(src[row + remove]) }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { tBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let t = Shared(tBuf), dst = Shared(dstBuf)
                // Kolumnvis i block om 64 kolumner för cachevänlighet.
                let blocks = (w + 63) / 64
                DispatchQueue.concurrentPerform(iterations: blocks) { block in
                    let x0 = block * 64, x1 = min(w, x0 + 64)
                    var sums = [Double](repeating: 0, count: x1 - x0)
                    for y in 0...min(r, h - 1) { for x in x0..<x1 { sums[x - x0] += Double(t[y * w + x]) } }
                    for y in 0..<h {
                        let lo = max(0, y - r), hi = min(h - 1, y + r)
                        let n = Double(hi - lo + 1)
                        for x in x0..<x1 { dst[y * w + x] = Float(sums[x - x0] / n) }
                        let add = y + r + 1, remove = y - r
                        if add < h { for x in x0..<x1 { sums[x - x0] += Double(t[add * w + x]) } }
                        if remove >= 0 { for x in x0..<x1 { sums[x - x0] -= Double(t[remove * w + x]) } }
                    }
                }
            }
        }
        return Plane(width: w, height: h, data: out)
    }

    /// Max-filter (dilatation) eller min-filter (erosion) med kvadratisk kärna (2r+1)².
    static func morph(_ plane: Plane, radius r: Int, dilate: Bool) -> Plane {
        guard r > 0 else { return plane }
        var out = [Float](repeating: 0, count: plane.data.count)
        let k = vImagePixelCount(2 * r + 1)
        plane.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: vImagePixelCount(plane.height),
                                      width: vImagePixelCount(plane.width), rowBytes: plane.width * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(plane.height),
                                      width: vImagePixelCount(plane.width), rowBytes: plane.width * 4)
                if dilate {
                    _ = vImageMax_PlanarF(&s, &d, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
                } else {
                    _ = vImageMin_PlanarF(&s, &d, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return Plane(width: plane.width, height: plane.height, data: out)
    }

    /// Guided filter (He, Sun, Tang 2010) av `input` med `guide` som kantguide, i
    /// "snabb" variant: koefficienterna räknas på guidens upplösning; anroparen kan
    /// skala upp `a`/`b` och tillämpa dem på en större guide.
    static func guidedCoefficients(guide: Plane, input: Plane, radius: Int, eps: Float) -> (a: Plane, b: Plane) {
        let n = guide.data.count
        var ii = [Float](repeating: 0, count: n), ip = [Float](repeating: 0, count: n)
        for i in 0..<n {
            ii[i] = guide.data[i] * guide.data[i]
            ip[i] = guide.data[i] * input.data[i]
        }
        let meanI = boxMean(guide, radius: radius)
        let meanP = boxMean(input, radius: radius)
        let corrI = boxMean(Plane(width: guide.width, height: guide.height, data: ii), radius: radius)
        let corrIP = boxMean(Plane(width: guide.width, height: guide.height, data: ip), radius: radius)
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let varI = corrI.data[i] - meanI.data[i] * meanI.data[i]
            let cov = corrIP.data[i] - meanI.data[i] * meanP.data[i]
            a[i] = cov / (varI + eps)
            b[i] = meanP.data[i] - a[i] * meanI.data[i]
        }
        return (boxMean(Plane(width: guide.width, height: guide.height, data: a), radius: radius),
                boxMean(Plane(width: guide.width, height: guide.height, data: b), radius: radius))
    }

    /// Percentil (0…1) av `values` (kopierar och sorterar — bara för små urval/mått).
    static func percentile(_ values: [Float], _ q: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[idx]
    }

    // MARK: - Skrivning

    /// 8-bitars gråskale-PNG av ett plan i 0…1.
    static func writeGrayPNG(_ plane: Plane, to url: URL) throws {
        let bytes = plane.data.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: plane.width, height: plane.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: plane.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// JPEG av en RGBA-float-buffert (sRGB), nedskalad till `maxDimension` (felsökningsbilder).
    static func writeJPEG(_ pixels: [Float], width: Int, height: Int, to url: URL, maxDimension: Int = 3000, quality: Double = 0.9) throws {
        let size = scaledSize(width: width, height: height, maxDimension: maxDimension)
        let small = scaleRGBA(pixels, width: width, height: height, toWidth: size.width, toHeight: size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileWriteUnknown) }
        let data = small.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        let image = CIImage(bitmapData: data, bytesPerRow: size.width * 16, size: CGSize(width: size.width, height: size.height),
                            format: .RGBAf, colorSpace: colorSpace)
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}
