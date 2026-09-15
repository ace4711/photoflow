import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `ExposureFusion`, the Swift/Accelerate replacement for the old
/// OpenCV `cv2.createMergeMertens` path (see `FORBATTRINGAR.md`, "Fas 3a").
/// Pure/stateless so these run with synthetic pixel buffers, no real photos.
struct ExposureFusionTests {

    /// Builds a flat RGBA float32 buffer, all pixels the same color.
    private func solidImage(width: Int, height: Int, r: Float, g: Float, b: Float) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for p in 0..<(width * height) {
            pixels[p * 4] = r
            pixels[p * 4 + 1] = g
            pixels[p * 4 + 2] = b
            pixels[p * 4 + 3] = 1
        }
        return pixels
    }

    @Test("Identiska indata ger output nära indata")
    func identicalInputs_reproduceInput() throws {
        let width = 64, height = 48
        // A gradient, not a flat color, so contrast/saturation weights are non-trivial.
        var image = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let v = Float(x) / Float(width - 1)
                image[p * 4] = v
                image[p * 4 + 1] = 1 - v
                image[p * 4 + 2] = 0.5
                image[p * 4 + 3] = 1
            }
        }

        let result = try ExposureFusion.fuse(images: [image, image, image], width: width, height: height)

        #expect(result.count == image.count)
        var maxDiff: Float = 0
        for i in 0..<result.count {
            maxDiff = max(maxDiff, abs(result[i] - image[i]))
        }
        #expect(maxDiff < 0.01)
    }

    @Test("Välexponerad pixel i bild A dominerar över utbränd pixel i bild B")
    func wellExposedImage_dominatesOverBlownOutImage() throws {
        let width = 32, height = 32
        // Image A: mid-gray everywhere (well exposed, decent contrast via a checkerboard).
        var imageA = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let checker: Float = ((x / 4) + (y / 4)).isMultiple(of: 2) ? 0.4 : 0.6
                imageA[p * 4] = checker
                imageA[p * 4 + 1] = checker
                imageA[p * 4 + 2] = checker
                imageA[p * 4 + 3] = 1
            }
        }
        // Image B: completely blown out (pure white, zero contrast, zero saturation).
        let imageB = solidImage(width: width, height: height, r: 1, g: 1, b: 1)

        let result = try ExposureFusion.fuse(images: [imageA, imageB], width: width, height: height)

        // The fused result should look like image A (mid-gray-ish), not white.
        var sum: Float = 0
        for p in 0..<(width * height) {
            sum += result[p * 4]
        }
        let average = sum / Float(width * height)
        #expect(average < 0.8, "Fused result should be dominated by the well-exposed image, not the blown-out one (average was \(average))")
    }

    @Test("Vikter summerar till 1 i varje pixel")
    func weights_sumToOne() throws {
        // Exercise the same weight computation `fuse` uses, indirectly: fusing
        // N copies of an all-different-content set of images and checking the
        // normalized-weight invariant would require exposing computeWeight, so
        // instead verify it via a property of the algorithm: fusing an image
        // with itself N times must reproduce the image exactly (mathematically
        // guaranteed only if each copy's normalized weight is 1/N everywhere).
        let width = 16, height = 16
        var image = [Float](repeating: 1, count: width * height * 4)
        for p in 0..<(width * height) {
            image[p * 4] = Float(p % 7) / 6
            image[p * 4 + 1] = Float(p % 5) / 4
            image[p * 4 + 2] = Float(p % 3) / 2
            image[p * 4 + 3] = 1
        }
        let result = try ExposureFusion.fuse(images: [image, image, image, image], width: width, height: height)
        var maxDiff: Float = 0
        for i in 0..<result.count {
            maxDiff = max(maxDiff, abs(result[i] - image[i]))
        }
        #expect(maxDiff < 0.01)
    }

    @Test("Udda bildstorlekar kraschar inte")
    func oddImageSizes_doNotCrash() throws {
        let width = 37, height = 23
        var imageA = [Float](repeating: 0.3, count: width * height * 4)
        var imageB = [Float](repeating: 0.7, count: width * height * 4)
        for p in 0..<(width * height) {
            imageA[p * 4 + 3] = 1
            imageB[p * 4 + 3] = 1
        }
        let result = try ExposureFusion.fuse(images: [imageA, imageB], width: width, height: height)
        #expect(result.count == width * height * 4)
        for v in result {
            #expect(v >= 0 && v <= 1)
        }
    }

    @Test("Pyramid + kollaps utan blandning återskapar bilden")
    func pyramidCollapse_withoutBlending_reconstructsImage() {
        let width = 41, height = 33
        var data = [Float](repeating: 0, count: width * height)
        for p in 0..<data.count {
            data[p] = Float(p % 97) / 96
        }
        let plane = ExposureFusion.Plane(width: width, height: height, data: data)
        let levels = ExposureFusion.levelsCount(width: width, height: height)

        let laplacian = ExposureFusion.Pyramid.laplacianPyramid(plane, levels: levels)
        let collapsed = ExposureFusion.Pyramid.collapse(laplacian)

        #expect(collapsed.width == width)
        #expect(collapsed.height == height)
        var maxDiff: Float = 0
        for i in 0..<data.count {
            maxDiff = max(maxDiff, abs(collapsed.data[i] - data[i]))
        }
        #expect(maxDiff < 1e-4, "Laplacian pyramid reconstruction should be exact up to float rounding (max diff \(maxDiff))")
    }

    @Test("levelsCount är minst 1 även för små bilder")
    func levelsCount_isAtLeastOne() {
        #expect(ExposureFusion.levelsCount(width: 4, height: 4) >= 1)
        #expect(ExposureFusion.levelsCount(width: 1, height: 1) >= 1)
    }
}
