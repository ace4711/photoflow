import Foundation
import Testing
import ImageIO
@testable import PhotoFlow

struct ReelWebVariantTests {

    private func properties(of data: Data) -> [CFString: Any] {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }

    @Test("Källbilden har verkligen GPS/EXIF, så testet bevisar något")
    func sourceHasMetadata() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ObjektfilmTestKit.writeJPEG(to: dir.appendingPathComponent("k.jpg"), width: 2400, height: 1600, gps: true)
        let data = try Data(contentsOf: file)
        #expect(ReelWebVariant.hasMetadata(data))
        #expect(properties(of: data)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test("Webbvarianterna saknar all metadata (ingen APP1/APP13/COM, ingen GPS/EXIF/IPTC/TIFF) och har rätt storlek")
    func variantsHaveNoMetadata() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ObjektfilmTestKit.writeJPEG(to: dir.appendingPathComponent("k.jpg"), width: 2400, height: 1600, gps: true)
        for variant in ReelWebVariant.Variant.allCases {
            let out = try #require(ReelWebVariant.make(from: file, variant: variant))
            #expect(max(out.width, out.height) == variant.longEdge)
            #expect(out.data.count < ReelWebVariant.maxBytes)
            #expect(!ReelWebVariant.hasMetadata(out.data))
            let markers = ReelWebVariant.segmentMarkers(of: out.data)
            #expect(!markers.contains(0xE1) && !markers.contains(0xED) && !markers.contains(0xFE))
            let props = properties(of: out.data)
            #expect(props[kCGImagePropertyGPSDictionary] == nil)
            #expect(props[kCGImagePropertyExifDictionary] == nil)
            #expect(props[kCGImagePropertyIPTCDictionary] == nil)
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
            // Rå byte-skanning efter texten från metadatan.
            #expect(out.data.range(of: Data("Hemlig adress".utf8)) == nil)
            #expect(out.data.range(of: Data("TestCam".utf8)) == nil)
            #expect(out.data.range(of: Data("Exif".utf8)) == nil)
            #expect((props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelRGB as String))
            #expect(out.data.prefix(2) == Data([0xFF, 0xD8]))
        }
    }

    @Test("Mindre bilder förstoras inte")
    func noUpscale() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ObjektfilmTestKit.writeJPEG(to: dir.appendingPathComponent("liten.jpg"), width: 320, height: 240)
        let out = try #require(ReelWebVariant.make(from: file, variant: .w1600))
        #expect(out.width <= 320 && out.height <= 240)
    }

    @Test("En fil som inte är en bild ger nil")
    func notAnImage() throws {
        let dir = try ObjektfilmTestKit.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("text.jpg")
        try Data("inte en bild".utf8).write(to: file)
        #expect(ReelWebVariant.make(from: file, variant: .w480) == nil)
    }
}
