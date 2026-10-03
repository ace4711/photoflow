import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Webbvarianterna som laddas upp till Objektfilm-servern: nedskalade JPEG i sRGB, kvalitet ca 0,8 och
/// **helt utan metadata** (inga APP1/EXIF/GPS, inga APP13/IPTC, ingen XMP). Servern nekar JPEG med
/// GPS-EXIF (422 `gps_in_image`), och en mäklarlänk ska aldrig avslöja var en bild togs.
///
/// Bilden avkodas med `CGImageSourceCreateThumbnailAtIndex` (EXIF-orienteringen bakas in i pixlarna),
/// ritas om i sRGB och skrivs med `CGImageDestination` utan egna egenskaper: bara bildpixlar, JFIF
/// och sRGB-profilen (APP2) hamnar i filen.
nonisolated enum ReelWebVariant {

    nonisolated enum Variant: String, Sendable, CaseIterable {
        case w1600, w480
        /// Längsta sidan i pixlar.
        var longEdge: Int { self == .w1600 ? 1600 : 480 }
    }

    nonisolated struct Output: Sendable, Equatable {
        var data: Data
        var width: Int
        var height: Int
    }

    static let quality = 0.8
    /// Serverns tak per bild (4 MB); kvaliteten sänks tills filen ryms.
    static let maxBytes = 4_000_000

    /// Skapar varianten av `url`, nil om filen inte går att läsa som bild. Aldrig större än originalet.
    static func make(from url: URL, variant: Variant) -> Output? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: variant.longEdge
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        guard let srgb = redraw(thumb) else { return nil }

        var q = quality
        while true {
            guard let data = encode(srgb, quality: q) else { return nil }
            if data.count <= maxBytes || q <= 0.3 { return Output(data: data, width: srgb.width, height: srgb.height) }
            q -= 0.15
        }
    }

    /// Ritar om bilden i sRGB utan alfa (och utan färgprofilen från originalet, t.ex. Display P3).
    private static func redraw(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Bara kvaliteten; inga EXIF-/GPS-/IPTC-egenskaper sätts.
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        // ImageIO lägger själv in en minimal EXIF-post (APP1) även när inga egenskaper anges: ta bort allt som inte behövs.
        return stripMetadata(data as Data)
    }

    /// Tar bort metadatasegment ur en JPEG: APP1 (EXIF/XMP), APP3–APP13 (IPTC m.fl.), APP15 och kommentarer.
    /// JFIF (APP0), färgprofilen (APP2) och Adobe-markören (APP14) behålls; bilddatan rörs inte.
    static func stripMetadata(_ jpeg: Data) -> Data {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
        var out = Data([0xFF, 0xD8])
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }
            if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { out.append(contentsOf: b[i..<i + 2]); i += 2; continue }
            if m == 0xDA { break }   // bilddatan börjar: resten kopieras oförändrad
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return jpeg }
            let isMetadata = m == 0xE1 || (0xE3...0xED).contains(m) || m == 0xEF || m == 0xFE
            if !isMetadata { out.append(contentsOf: b[i..<i + 2 + length]) }
            i += 2 + length
        }
        out.append(contentsOf: b[i...])
        return out
    }

    // MARK: Kontroll

    /// JPEG-markörerna (en byte vardera, t.ex. 0xE1 = APP1) i den ordning de förekommer före bilddatan.
    static func segmentMarkers(of jpeg: Data) -> [UInt8] {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return [] }
        var markers: [UInt8] = []
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }
            if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }
            markers.append(m)
            if m == 0xDA { break }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        return markers
    }

    /// Sant om filen har metadatasegment: APP1 (EXIF/XMP), APP13 (IPTC/Photoshop) eller kommentar (COM).
    static func hasMetadata(_ jpeg: Data) -> Bool {
        !Set(segmentMarkers(of: jpeg)).isDisjoint(with: [0xE1, 0xED, 0xFE])
    }
}
