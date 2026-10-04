import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writes an `ExposureFusion` result (RGBA float32, sRGB gamma encoded,
/// [0,1]) to disk as a real 16-bit-per-channel TIFF plus an 8-bit JPEG
/// preview, and copies EXIF metadata from one of the source RAW files so the
/// merged file still sorts/calendar-matches correctly (date, camera,
/// aperture, ISO — the same fields the rest of the pipeline reads), plus —
/// when already known — the address/GPS/IPTC metadata (`writeMetadata`).
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
    ///   - tiffURL: destination for the full-resolution 16-bit TIFF (okomprimerad, se `tiffCompression`).
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

        // Built directly from `pixels` (not via `CIContext.createCGImage`,
        // which only offers `.RGBA16` — i.e. with an alpha channel we don't
        // need): a plain 3-channel 16-bit-per-component RGB image, matching
        // "16 bpc RGB" rather than RGBA.
        let cgImage16 = try PipelineMetrics.phase("makeRGB16") {
            try makeRGB16CGImage(pixels: pixels, width: width, height: height, colorSpace: colorSpace)
        }
        try PipelineMetrics.phase("writeTIFF") { try writeTIFF(cgImage16, to: tiffURL) }

        let longSide = max(width, height)
        let scale = (jpegMaxDimension > 0 && longSide > jpegMaxDimension) ? CGFloat(jpegMaxDimension) / CGFloat(longSide) : 1.0
        let jpegImage = scale < 1.0 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage
        try PipelineMetrics.phase("writeJPEG") {
            try context.writeJPEGRepresentation(
                of: jpegImage,
                to: jpegURL,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
            )
        }
    }

    /// Unsharp mask på RGBA float32-pixlar (sRGB-kodade, som resten av
    /// skrivningen), utan färghantering. Kanterna förlängs (`clampedToExtent`)
    /// så att bildkanten inte får en ljus eller mörk ram.
    static func sharpen(pixels: [Float], width: Int, height: Int, radius: Double, intensity: Double) -> [Float] {
        let rowBytes = width * 4 * MemoryLayout<Float>.size
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: extent.size, format: .RGBAf, colorSpace: nil)
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return pixels }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(intensity, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return pixels }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
        var result = [Float](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        return result
    }

    /// Packs `pixels` (RGBA float32, [0,1]) into a plain 3-channel,
    /// 16-bit-per-component RGB `CGImage` — no alpha, and no color conversion
    /// (`colorSpace` here must be the same one the values were rendered in).
    static func makeRGB16CGImage(pixels: [Float], width: Int, height: Int, colorSpace: CGColorSpace) throws -> CGImage {
        var rgb16 = [UInt16](repeating: 0, count: width * height * 3)
        pixels.withUnsafeBufferPointer { src in
            rgb16.withUnsafeMutableBufferPointer { dst in
                for p in 0..<(width * height) {
                    dst[p * 3] = UInt16((min(max(src[p * 4], 0), 1) * 65535).rounded())
                    dst[p * 3 + 1] = UInt16((min(max(src[p * 4 + 1], 0), 1) * 65535).rounded())
                    dst[p * 3 + 2] = UInt16((min(max(src[p * 4 + 2], 0), 1) * 65535).rounded())
                }
            }
        }
        let data = rgb16.withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!, count: raw.count)
        }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw WriterError.cgImageCreationFailed
        }
        // Native byte order on both Apple Silicon and Intel is little-endian,
        // matching how the `UInt16` values above are laid out in memory.
        guard let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 3 * 2,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGImageByteOrderInfo.order16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw WriterError.cgImageCreationFailed
        }
        return cgImage
    }

    /// Skrivs först till en dold temporärfil bredvid och byts in när den är
    /// färdig. `runHDRMerge` räknar en grupp som klar så fort TIFF-filen finns,
    /// så en halvskriven fil (appen avslutad mitt i) hade annars hoppats över
    /// för gott vid nästa körning.
    private static func writeTIFF(_ cgImage: CGImage, to url: URL) throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        try writeTIFFDirect(cgImage, to: partial)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
    }

    /// TIFF-komprimering (TIFF-taggen Compression): 1 = okomprimerad, 5 = LZW.
    ///
    /// Okomprimerad sedan fas 1a (#2). Mätt på tre riktiga HDR-bilder (6000 × 4000, 16 bpc RGB):
    /// LZW 172–177 MB, kodning 1,1 s och avkodning 0,33 s; okomprimerad 137 MB (alltså 20 % MINDRE —
    /// LZW komprimerar inte 16-bitars fotografiskt brus), kodning 0,05 s och avkodning 0,07 s.
    /// Avkodade pixlar är bit-för-bit identiska (SHA-256), så ingenting som bygger på filen
    /// (fingerprints, motorversioner) påverkas. Se docs/plan-snabbare-pipeline.md, "Uppmätt".
    static let tiffCompression = 1

    static func writeTIFFDirect(_ cgImage: CGImage, to url: URL, compression: Int = tiffCompression) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw WriterError.destinationCreationFailed
        }
        let tiffProperties: [CFString: Any] = [
            kCGImagePropertyTIFFCompression: compression
        ]
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiffProperties]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WriterError.finalizeFailed(url)
        }
    }

    /// EXIF-taggarna som kopieras från källan (datum, kamera, exponering — det resten av
    /// pipelinen läser för sortering och kalendermatchning).
    static let copiedEXIFTags = [
        "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-SubSecTimeOriginal",
        "-Make", "-Model", "-LensModel",
        "-FNumber", "-ApertureValue", "-ISO", "-FocalLength", "-ExposureTime"
    ]

    /// exiftool-argumenten för `writeMetadata`: ett kommando per unik metadata (normalt ett
    /// enda för TIFF + JPEG, som har samma adress och samma basnamn), åtskilda av `-execute`.
    /// Varje kommando kopierar EXIF-grunddata från `sourceRAW` (som `copyEXIF` gjorde före
    /// fas 1b) och lägger, när metadatan är känd, till samma IPTC/XMP/GPS-taggar som
    /// metadatasteget skriver (`ExiftoolMetadataArguments`).
    static func metadataArguments(from sourceRAW: URL, outputs: [(url: URL, meta: IPTCFileMetadata?)]) -> [String] {
        var groups: [(meta: IPTCFileMetadata?, urls: [URL])] = []
        for output in outputs {
            if let idx = groups.firstIndex(where: { $0.meta == output.meta }) {
                groups[idx].urls.append(output.url)
            } else {
                groups.append((output.meta, [output.url]))
            }
        }
        var args: [String] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { args.append("-execute") }
            if let meta = group.meta {
                args += ["-charset", "iptc=UTF8"]
                args += ExiftoolMetadataArguments.tagLines(for: meta, isNEF: false)
            }
            args += ["-TagsFromFile", sourceRAW.path] + copiedEXIFTags
            args += ["-overwrite_original", "-P"] + group.urls.map(\.path)
        }
        return args
    }

    /// Skriver metadata till de nyss skrivna TIFF/JPEG-filerna i ETT exiftool-anrop (fas 1b,
    /// steg A): EXIF-grunddata från `sourceRAW` (normalt bracketens mittexponering) och, för de
    /// utdata som har `meta`, IPTC/XMP/GPS. Förut skrevs filerna om två gånger: först av
    /// `copyEXIF` och sedan av metadatasteget. Via samma `exiftool` som resten av pipelinen —
    /// enklare och robustare än handbyggda `CGImageDestination`-egenskaper.
    ///
    /// Best-effort: returnerar `false` (utan att kasta) om `exiftool` misslyckas — en saknad
    /// EXIF-kopia ska inte fälla hela HDR-sammanslagningen, och metadatasteget skriver då
    /// IPTC/XMP/GPS som förut (ingen stämpel sätts).
    @discardableResult
    static func writeMetadata(from sourceRAW: URL, outputs: [(url: URL, meta: IPTCFileMetadata?)], exiftoolPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: sourceRAW.path), !outputs.isEmpty else { return false }
        // Argumenten går via en argfil (UTF-8, som metadatasteget), inte som processargument:
        // `Process` skickar argumenten i filsystemsrepresentation, alltså NFD, så "ä" hade
        // skrivits som "a" + kombinerande trema i IPTC-fälten (upptäckt av MetadataPlanTests).
        let argfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoflow-exif-\(UUID().uuidString).args")
        do {
            try metadataArguments(from: sourceRAW, outputs: outputs).joined(separator: "\n")
                .write(to: argfile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: argfile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-@", argfile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let observer = ChildDiskTracker.observe(process)
            process.waitUntilExit()
            observer.finish()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
