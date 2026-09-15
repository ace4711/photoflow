import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes an `ExposureFusion` result (RGBA float32, sRGB gamma encoded,
/// [0,1]) to disk as a real 16-bit-per-channel TIFF plus an 8-bit JPEG
/// preview, and copies EXIF metadata from one of the source RAW files so the
/// merged file still sorts/calendar-matches correctly (date, camera,
/// aperture, ISO — the same fields the rest of the pipeline reads).
///
/// Pure/stateless aside from the file writes themselves and the optional
/// `exiftool` shell-out — no actor isolation, safe to call from a background
/// `Task`.
nonisolated enum HDRWriter {
    enum WriterError: LocalizedError {
        case colorSpaceCreationFailed
        case cgImageCreationFailed
        case destinationCreationFailed
        case finalizeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .colorSpaceCreationFailed: return "Kunde inte skapa sRGB-färgrymd."
            case .cgImageCreationFailed: return "Kunde inte skapa 16-bitars bild från HDR-resultatet."
            case .destinationCreationFailed: return "Kunde inte skapa filskrivare för TIFF."
            case .finalizeFailed(let url): return "Kunde inte slutföra skrivning av \(url.lastPathComponent)."
            }
        }
    }

    /// - Parameters:
    ///   - pixels: RGBA float32, sRGB gamma encoded, `width * height * 4` values.
    ///   - tiffURL: destination for the full-resolution 16-bit LZW TIFF.
    ///   - jpegURL: destination for the JPEG preview.
    ///   - jpegMaxDimension: JPEG preview long-side cap (0 = full resolution).
    ///   - jpegQuality: 0...1 JPEG compression quality.
    static func write(
        pixels: [Float],
        width: Int,
        height: Int,
        tiffURL: URL,
        jpegURL: URL,
        jpegMaxDimension: Int = 2400,
        jpegQuality: Double = 0.92
    ) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WriterError.colorSpaceCreationFailed
        }

        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        let data = pixels.withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!, count: raw.count)
        }
        // Non-failable initializer (CIImage.h: `initWithBitmapData:...` has no
        // `nullable` prefix, unlike most other CIImage inits).
        let ciImage = CIImage(bitmapData: data, bytesPerRow: bytesPerRow, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)

        let context = CIContext(options: [.workingColorSpace: colorSpace])

        // Source and destination color space are identical (sRGB), so this is
        // a pure float->16-bit-integer format conversion, not a re-encoding —
        // the gamma-encoded values written by RAWRenderer/ExposureFusion are
        // preserved exactly (up to 16-bit quantization).
        guard let cgImage16 = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA16, colorSpace: colorSpace) else {
            throw WriterError.cgImageCreationFailed
        }
        try writeTIFF(cgImage16, to: tiffURL)

        let longSide = max(width, height)
        let scale = (jpegMaxDimension > 0 && longSide > jpegMaxDimension) ? CGFloat(jpegMaxDimension) / CGFloat(longSide) : 1.0
        let jpegImage = scale < 1.0 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage
        try context.writeJPEGRepresentation(
            of: jpegImage,
            to: jpegURL,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        )
    }

    private static func writeTIFF(_ cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw WriterError.destinationCreationFailed
        }
        let tiffProperties: [CFString: Any] = [
            kCGImagePropertyTIFFCompression: 5 // LZW — lossless, meaningfully smaller than uncompressed for photographic content
        ]
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiffProperties]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WriterError.finalizeFailed(url)
        }
    }

    /// Copies date/camera/exposure EXIF tags from `sourceRAW` (normally the
    /// bracket's middle exposure) onto the written TIFF/JPEG, via the same
    /// `exiftool` dependency the rest of the pipeline already requires — far
    /// simpler and more robust than hand-building `CGImageDestination` EXIF
    /// property dictionaries, and keeps output byte-for-byte consistent with
    /// how the pipeline writes metadata everywhere else.
    ///
    /// Best-effort: returns `false` (without throwing) if `exiftool` fails —
    /// a missing/incorrect EXIF copy shouldn't fail the whole HDR merge, just
    /// degrade calendar/date sorting for that one merged file.
    @discardableResult
    static func copyEXIF(from sourceRAW: URL, to outputs: [URL], exiftoolPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: sourceRAW.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = [
            "-TagsFromFile", sourceRAW.path,
            "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-SubSecTimeOriginal",
            "-Make", "-Model", "-LensModel",
            "-FNumber", "-ApertureValue", "-ISO", "-FocalLength", "-ExposureTime",
            "-overwrite_original", "-P"
        ] + outputs.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
