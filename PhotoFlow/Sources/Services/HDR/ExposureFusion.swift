import Foundation
import Accelerate

/// Mertens/Kautz/Van Reeth exposure fusion, implemented directly (no OpenCV)
/// on top of Accelerate (vImage for the Gaussian/Laplacian pyramids).
///
/// Pure and stateless — no I/O, no actor isolation — so it's trivially
/// testable and safe to call from a background `Task`. Operates on RGBA
/// float32 buffers as produced by `RAWRenderer` (sRGB-gamma encoded, alpha
/// ignored on input and always written back as 1.0).
nonisolated enum ExposureFusion {
    struct Options: Sendable {
        var contrastExponent: Float = 1.0
        var saturationExponent: Float = 1.0
        var exposureExponent: Float = 1.0
        var wellExposedSigma: Float = 0.2
        /// Added to every per-pixel weight before normalization so a pixel
        /// that scores exactly zero on contrast/saturation/exposedness in
        /// *every* input image (e.g. a flat black or white area in all
        /// exposures) still gets a defined, equal share from each image
        /// instead of a 0/0 division.
        var weightEpsilon: Float = 1e-12

        init(contrastExponent: Float = 1.0, saturationExponent: Float = 1.0, exposureExponent: Float = 1.0, wellExposedSigma: Float = 0.2, weightEpsilon: Float = 1e-12) {
            self.contrastExponent = contrastExponent
            self.saturationExponent = saturationExponent
            self.exposureExponent = exposureExponent
            self.wellExposedSigma = wellExposedSigma
            self.weightEpsilon = weightEpsilon
        }
    }

    enum FusionError: LocalizedError {
        case noImages
        case sizeMismatch

        var errorDescription: String? {
            switch self {
            case .noImages: return "Inga bilder att slå ihop."
            case .sizeMismatch: return "Bilderna som ska slås ihop har olika storlek."
            }
        }
    }

    /// A single-channel float image, used internally for pyramids (grayscale
    /// weight maps, and one color channel at a time of the RGBA inputs).
    /// `internal` (default) visibility so `PhotoFlowTests` can exercise the
    /// pyramid building blocks directly (`@testable import`).
    struct Plane {
        var width: Int
        var height: Int
        var data: [Float]
    }

    /// Number of pyramid levels: `floor(log2(min(w, h))) - 3`, at least 1.
    static func levelsCount(width: Int, height: Int) -> Int {
        let shortSide = min(width, height)
        guard shortSide > 1 else { return 1 }
        let levels = Int(floor(log2(Double(shortSide)))) - 3
        return max(1, levels)
    }

    /// Fuses `images` (each `width * height * 4` RGBA float32 values, sRGB
    /// gamma encoded) into one image of the same size, clipped to [0, 1].
    /// - Parameter progress: called with a 0...1 fraction a handful of times
    ///   (not per-pixel); throw from it (e.g. via `Task.checkCancellation()`)
    ///   to abort the fusion partway through.
    static func fuse(
        images: [[Float]],
        width: Int,
        height: Int,
        options: Options = Options(),
        progress: ((Double) throws -> Void)? = nil
    ) throws -> [Float] {
        guard !images.isEmpty else { throw FusionError.noImages }
        let expectedCount = width * height * 4
        for image in images where image.count != expectedCount {
            throw FusionError.sizeMismatch
        }

        if images.count == 1 {
            try progress?(1.0)
            return images[0].map { min(max($0, 0), 1) }
        }

        // 1. Per-image weight maps (contrast * saturation * well-exposedness).
        var weightPlanes: [Plane] = []
        weightPlanes.reserveCapacity(images.count)
        for image in images {
            weightPlanes.append(computeWeight(image, width: width, height: height, options: options))
            try progress?(0.2 * Double(weightPlanes.count) / Double(images.count))
        }

        // 2. Normalize so weights sum to 1 at every pixel.
        normalizeWeights(&weightPlanes)
        try progress?(0.25)

        let levels = levelsCount(width: width, height: height)

        // 3. Weight Gaussian pyramids — shared across all 3 color channels below.
        let weightPyramids = weightPlanes.map { Pyramid.gaussianPyramid($0, levels: levels) }
        try progress?(0.3)

        // 4. Blend one color channel at a time: build every image's Laplacian
        //    pyramid for this channel, blend with the weight pyramids, collapse,
        //    then let the per-channel Laplacian pyramids be freed before the
        //    next channel starts (keeps peak memory to ~1 channel + the shared
        //    weight pyramids, not all 3 channels at once).
        var resultPlanes: [Plane] = []
        resultPlanes.reserveCapacity(3)
        for channel in 0..<3 {
            let laplacianPyramids = images.map { image in
                Pyramid.laplacianPyramid(extractChannel(image, width: width, height: height, channel: channel), levels: levels)
            }

            var blended: [Plane] = []
            blended.reserveCapacity(levels + 1)
            for level in 0...levels {
                let levelSize = weightPyramids[0][level]
                var accumulator = [Float](repeating: 0, count: levelSize.width * levelSize.height)
                for i in 0..<images.count {
                    accumulateWeightedSum(&accumulator, weight: weightPyramids[i][level].data, value: laplacianPyramids[i][level].data)
                }
                blended.append(Plane(width: levelSize.width, height: levelSize.height, data: accumulator))
            }

            resultPlanes.append(Pyramid.collapse(blended))
            try progress?(0.3 + 0.7 * Double(channel + 1) / 3.0)
        }

        // 5. Interleave R,G,B back into RGBA, clip to [0,1], alpha = 1.
        var output = [Float](repeating: 1, count: width * height * 4)
        for (channel, plane) in resultPlanes.enumerated() {
            output.withUnsafeMutableBufferPointer { dst in
                plane.data.withUnsafeBufferPointer { src in
                    for p in 0..<plane.data.count {
                        dst[p * 4 + channel] = min(max(src[p], 0), 1)
                    }
                }
            }
        }
        return output
    }

    // MARK: - Weight maps

    private static func computeWeight(_ image: [Float], width: Int, height: Int, options: Options) -> Plane {
        let count = width * height
        var gray = [Float](repeating: 0, count: count)
        var saturation = [Float](repeating: 0, count: count)
        var wellExposed = [Float](repeating: 0, count: count)
        let sigma2 = 2 * options.wellExposedSigma * options.wellExposedSigma

        image.withUnsafeBufferPointer { px in
            for p in 0..<count {
                let r = px[p * 4]
                let g = px[p * 4 + 1]
                let b = px[p * 4 + 2]

                gray[p] = 0.2126 * r + 0.7152 * g + 0.0722 * b

                let mean = (r + g + b) / 3
                let dr = r - mean, dg = g - mean, db = b - mean
                saturation[p] = sqrt((dr * dr + dg * dg + db * db) / 3)

                let wr = exp(-((r - 0.5) * (r - 0.5)) / sigma2)
                let wg = exp(-((g - 0.5) * (g - 0.5)) / sigma2)
                let wb = exp(-((b - 0.5) * (b - 0.5)) / sigma2)
                wellExposed[p] = wr * wg * wb
            }
        }

        let contrast = Pyramid.laplacianAbs(Plane(width: width, height: height, data: gray))

        var weight = [Float](repeating: 0, count: count)
        for p in 0..<count {
            let c = options.contrastExponent == 1 ? contrast.data[p] : pow(contrast.data[p], options.contrastExponent)
            let s = options.saturationExponent == 1 ? saturation[p] : pow(saturation[p], options.saturationExponent)
            let e = options.exposureExponent == 1 ? wellExposed[p] : pow(wellExposed[p], options.exposureExponent)
            weight[p] = c * s * e + options.weightEpsilon
        }
        return Plane(width: width, height: height, data: weight)
    }

    private static func normalizeWeights(_ planes: inout [Plane]) {
        guard let first = planes.first else { return }
        let count = first.data.count
        var sums = [Float](repeating: 0, count: count)
        for plane in planes {
            sums.withUnsafeMutableBufferPointer { sumBuf in
                plane.data.withUnsafeBufferPointer { dataBuf in
                    vDSP_vadd(sumBuf.baseAddress!, 1, dataBuf.baseAddress!, 1, sumBuf.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        for i in planes.indices {
            planes[i].data.withUnsafeMutableBufferPointer { dataBuf in
                sums.withUnsafeBufferPointer { sumBuf in
                    vDSP_vdiv(sumBuf.baseAddress!, 1, dataBuf.baseAddress!, 1, dataBuf.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
    }

    /// `accumulator += weight * value` (element-wise), via `vDSP_vma`.
    private static func accumulateWeightedSum(_ accumulator: inout [Float], weight: [Float], value: [Float]) {
        let n = vDSP_Length(accumulator.count)
        accumulator.withUnsafeMutableBufferPointer { accBuf in
            weight.withUnsafeBufferPointer { wBuf in
                value.withUnsafeBufferPointer { vBuf in
                    vDSP_vma(wBuf.baseAddress!, 1, vBuf.baseAddress!, 1, accBuf.baseAddress!, 1, accBuf.baseAddress!, 1, n)
                }
            }
        }
    }

    private static func extractChannel(_ image: [Float], width: Int, height: Int, channel: Int) -> Plane {
        let count = width * height
        var out = [Float](repeating: 0, count: count)
        image.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for p in 0..<count {
                    dst[p] = src[p * 4 + channel]
                }
            }
        }
        return Plane(width: width, height: height, data: out)
    }

    // MARK: - Gaussian/Laplacian pyramids (separable 5-tap [1,4,6,4,1]/16)

    enum Pyramid {
        private static let kernel1D: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        private static let blurKernel5x5: [Float] = {
            var k = [Float](repeating: 0, count: 25)
            for y in 0..<5 {
                for x in 0..<5 {
                    k[y * 5 + x] = kernel1D[y] * kernel1D[x]
                }
            }
            return k
        }()
        private static let laplacianKernel3x3: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]

        private static func convolve(_ plane: Plane, kernel: [Float], kernelSize: Int32) -> Plane {
            var out = [Float](repeating: 0, count: plane.width * plane.height)
            let rowBytes = plane.width * MemoryLayout<Float>.size
            plane.data.withUnsafeBufferPointer { srcBuf in
                out.withUnsafeMutableBufferPointer { dstBuf in
                    var srcBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: srcBuf.baseAddress!),
                        height: vImagePixelCount(plane.height), width: vImagePixelCount(plane.width), rowBytes: rowBytes
                    )
                    var dstBuffer = vImage_Buffer(
                        data: dstBuf.baseAddress!,
                        height: vImagePixelCount(plane.height), width: vImagePixelCount(plane.width), rowBytes: rowBytes
                    )
                    kernel.withUnsafeBufferPointer { kernelBuf in
                        _ = vImageConvolve_PlanarF(
                            &srcBuffer, &dstBuffer, nil, 0, 0,
                            kernelBuf.baseAddress!, UInt32(kernelSize), UInt32(kernelSize),
                            0, vImage_Flags(kvImageEdgeExtend)
                        )
                    }
                }
            }
            return Plane(width: plane.width, height: plane.height, data: out)
        }

        static func blur(_ plane: Plane) -> Plane {
            convolve(plane, kernel: blurKernel5x5, kernelSize: 5)
        }

        static func laplacianAbs(_ plane: Plane) -> Plane {
            var result = convolve(plane, kernel: laplacianKernel3x3, kernelSize: 3)
            for i in 0..<result.data.count {
                result.data[i] = abs(result.data[i])
            }
            return result
        }

        /// Blurs then decimates by 2, rounding sizes up (`(n+1)/2`) so an odd
        /// dimension still halves sensibly (23 -> 12) instead of crashing or
        /// dropping the last row/column's information entirely.
        static func reduce(_ plane: Plane) -> Plane {
            let blurred = blur(plane)
            let newWidth = (plane.width + 1) / 2
            let newHeight = (plane.height + 1) / 2
            var out = [Float](repeating: 0, count: newWidth * newHeight)
            blurred.data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<newHeight {
                        let sy = min(y * 2, plane.height - 1)
                        for x in 0..<newWidth {
                            let sx = min(x * 2, plane.width - 1)
                            dst[y * newWidth + x] = src[sy * plane.width + sx]
                        }
                    }
                }
            }
            return Plane(width: newWidth, height: newHeight, data: out)
        }

        /// Upsamples `plane` to exactly `(toWidth, toHeight)` — the inverse of
        /// `reduce`: zero-insert at even coordinates, blur, then scale by 4 to
        /// restore the energy the zero-insertion diluted.
        static func expand(_ plane: Plane, toWidth: Int, toHeight: Int) -> Plane {
            var zeroFilled = [Float](repeating: 0, count: toWidth * toHeight)
            plane.data.withUnsafeBufferPointer { src in
                zeroFilled.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<plane.height {
                        let ty = y * 2
                        guard ty < toHeight else { continue }
                        for x in 0..<plane.width {
                            let tx = x * 2
                            guard tx < toWidth else { continue }
                            dst[ty * toWidth + tx] = src[y * plane.width + x]
                        }
                    }
                }
            }
            var blurred = blur(Plane(width: toWidth, height: toHeight, data: zeroFilled))
            for i in 0..<blurred.data.count {
                blurred.data[i] *= 4
            }
            return blurred
        }

        static func gaussianPyramid(_ base: Plane, levels: Int) -> [Plane] {
            var pyramid = [base]
            for _ in 0..<levels {
                pyramid.append(reduce(pyramid[pyramid.count - 1]))
            }
            return pyramid
        }

        /// Returns `levels + 1` planes: `levels` Laplacian (difference) images
        /// from largest to smallest, followed by the smallest Gaussian level
        /// (the residual needed to reconstruct the original via `collapse`).
        static func laplacianPyramid(_ base: Plane, levels: Int) -> [Plane] {
            let gaussian = gaussianPyramid(base, levels: levels)
            var laplacian: [Plane] = []
            laplacian.reserveCapacity(levels + 1)
            for level in 0..<levels {
                let expanded = expand(gaussian[level + 1], toWidth: gaussian[level].width, toHeight: gaussian[level].height)
                var diff = [Float](repeating: 0, count: gaussian[level].data.count)
                for p in 0..<diff.count {
                    diff[p] = gaussian[level].data[p] - expanded.data[p]
                }
                laplacian.append(Plane(width: gaussian[level].width, height: gaussian[level].height, data: diff))
            }
            laplacian.append(gaussian[levels])
            return laplacian
        }

        /// Inverse of `laplacianPyramid`: reconstructs the full-resolution
        /// plane from a (possibly blended) Laplacian pyramid.
        static func collapse(_ laplacian: [Plane]) -> Plane {
            guard var result = laplacian.last else {
                return Plane(width: 0, height: 0, data: [])
            }
            var level = laplacian.count - 2
            while level >= 0 {
                let target = laplacian[level]
                let expanded = expand(result, toWidth: target.width, toHeight: target.height)
                var summed = [Float](repeating: 0, count: target.data.count)
                for p in 0..<summed.count {
                    summed[p] = expanded.data[p] + target.data[p]
                }
                result = Plane(width: target.width, height: target.height, data: summed)
                level -= 1
            }
            return result
        }
    }
}
