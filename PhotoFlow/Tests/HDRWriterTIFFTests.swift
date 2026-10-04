import Foundation
import Testing
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Fas 1a (#2): HDR-/förbättrade TIFF:er skrivs okomprimerade (mindre och mycket snabbare än LZW för
/// 16-bitars bilder). Formatbytet får inte ändra en enda pixel.
@MainActor
struct HDRWriterTIFFTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HDRWriterTIFFTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Brusig (pseudoslump, deterministisk) RGBA float32-bild med värden även utanför 0…1.
    private func noisyPixels(width: Int, height: Int) -> [Float] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 1.1 - 0.05
        }
        return (0..<(width * height * 4)).map { _ in next() }
    }

    private func decodeRGB16(_ url: URL) throws -> (cg: CGImage, bytes: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image, drawRGB16(image))
    }

    /// Avkodade pixlar som rå 16-bitars RGBX (samma sak ImageIO ger oavsett komprimering).
    private func drawRGB16(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 8)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test("HDRWriter skriver TIFF okomprimerat (Compression = 1)")
    func write_usesUncompressedTIFF() throws {
        #expect(HDRWriter.tiffCompression == 1)
        let dir = tempDir()
        let tiff = dir.appendingPathComponent("a.tiff"), jpeg = dir.appendingPathComponent("a.jpg")
        try HDRWriter.write(pixels: noisyPixels(width: 64, height: 48), width: 64, height: 48, tiffURL: tiff, jpegURL: jpeg)

        let source = try #require(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiffDict = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiffDict[kCGImagePropertyTIFFCompression] as? Int == 1)
        #expect(properties[kCGImagePropertyDepth] as? Int == 16)
    }

    @Test("Okomprimerad och LZW ger identiska avkodade pixlar (SHA-256), lika med bilden i minnet")
    func uncompressedAndLZW_decodeToIdenticalPixels() throws {
        let width = 97, height = 61   // udda storlek: kollar radfyllning
        let pixels = noisyPixels(width: width, height: height)
        let cg = try HDRWriter.makeRGB16CGImage(pixels: pixels, width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        let dir = tempDir()
        let lzw = dir.appendingPathComponent("lzw.tiff"), raw = dir.appendingPathComponent("raw.tiff")
        try HDRWriter.writeTIFFDirect(cg, to: lzw, compression: 5)
        try HDRWriter.writeTIFFDirect(cg, to: raw, compression: HDRWriter.tiffCompression)

        let a = try decodeRGB16(lzw), b = try decodeRGB16(raw)
        #expect(a.cg.width == width && b.cg.width == width && a.cg.height == height && b.cg.height == height)
        #expect(sha256(a.bytes) == sha256(b.bytes))
        #expect(sha256(b.bytes) == sha256(drawRGB16(cg)))
    }

    @Test("Okomprimerad TIFF är inte större än LZW för brusig 16-bitarsdata")
    func uncompressed_isNotLargerThanLZW() throws {
        let width = 256, height = 192
        let cg = try HDRWriter.makeRGB16CGImage(pixels: noisyPixels(width: width, height: height), width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let dir = tempDir()
        let lzw = dir.appendingPathComponent("lzw.tiff"), raw = dir.appendingPathComponent("raw.tiff")
        try HDRWriter.writeTIFFDirect(cg, to: lzw, compression: 5)
        try HDRWriter.writeTIFFDirect(cg, to: raw, compression: 1)
        let lzwSize = try #require(try FileManager.default.attributesOfItem(atPath: lzw.path)[.size] as? Int)
        let rawSize = try #require(try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int)
        #expect(rawSize <= lzwSize)
    }
}
