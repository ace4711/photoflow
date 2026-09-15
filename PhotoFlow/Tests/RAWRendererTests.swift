import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the pure, I/O-free parts of `RAWRenderer` — `shiftRGBA`, the
/// bilinear pixel-shift utility `HDRAlignment`/`HDREngine` use to correct
/// hand-held misalignment between exposures. Actually decoding a RAW file
/// needs a real DNG/NEF, which isn't available to the test target, so
/// `render`/`readWhiteBalance` are exercised manually (see FORBATTRINGAR.md,
/// "Fas 3a") rather than here.
struct RAWRendererTests {

    private func makeGradient(width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                pixels[p * 4] = Float(x) / Float(max(width - 1, 1))
                pixels[p * 4 + 1] = Float(y) / Float(max(height - 1, 1))
                pixels[p * 4 + 2] = 0.5
                pixels[p * 4 + 3] = 1
            }
        }
        return pixels
    }

    @Test("Nollförskjutning returnerar samma buffert oförändrad")
    func zeroShift_returnsInputUnchanged() {
        let width = 12, height = 9
        let pixels = makeGradient(width: width, height: height)
        let shifted = RAWRenderer.shiftRGBA(pixels, width: width, height: height, dx: 0, dy: 0)
        #expect(shifted == pixels)
    }

    @Test("Heltalsförskjutning flyttar innehållet exakt ett pixelsteg")
    func integerShift_movesContentByExactlyOnePixel() {
        let width = 10, height = 10
        let pixels = makeGradient(width: width, height: height)
        // Shift by (+1, 0): output pixel (x, y) should sample source pixel (x-1, y).
        let shifted = RAWRenderer.shiftRGBA(pixels, width: width, height: height, dx: 1, dy: 0)

        for y in 0..<height {
            for x in 1..<width {
                let srcIdx = (y * width + (x - 1)) * 4
                let dstIdx = (y * width + x) * 4
                #expect(abs(shifted[dstIdx] - pixels[srcIdx]) < 1e-5)
                #expect(abs(shifted[dstIdx + 1] - pixels[srcIdx + 1]) < 1e-5)
            }
        }
    }

    @Test("Förskjutning bevarar buffertstorleken och håller värden inom rimligt intervall")
    func shift_preservesSizeAndRange() {
        let width = 15, height = 11
        let pixels = makeGradient(width: width, height: height)
        let shifted = RAWRenderer.shiftRGBA(pixels, width: width, height: height, dx: 2.5, dy: -1.5)
        #expect(shifted.count == pixels.count)
        for v in shifted {
            #expect(v >= -0.001 && v <= 1.001)
        }
    }
}
