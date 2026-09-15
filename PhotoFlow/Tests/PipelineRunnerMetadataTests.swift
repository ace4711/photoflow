import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `PipelineRunner.exiftoolArguments`, the pure argfile-line builder used
/// by `writeIPTCMetadata`. These exist because of a real data-loss bug: writing
/// `-overwrite_original` to a NEF symlink in an address "ÖVRIGA" folder makes
/// exiftool replace the symlink with a full copy of the user's original file.
@MainActor
struct PipelineRunnerMetadataTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerMetadataTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - NEF → sidecar

    @Test("NEF utan befintlig sidecar skriver ny .xmp via -o, rör aldrig NEF-filen")
    func nef_noExistingSidecar_usesDashOToCreateSidecar() {
        let dir = tempDir()
        let nef = dir.appendingPathComponent("DSC_0001.nef")
        let meta = IPTCFileMetadata(address: "Lindvägen 12, Tyresö", eventTitle: "Fotografering", description: "Lindvägen 12, Tyresö")

        let args = PipelineRunner.exiftoolArguments(for: nef, meta: meta)

        #expect(!args.contains("-overwrite_original"))
        #expect(!args.contains("-overwrite_original_in_place"))
        #expect(args.contains("-o"))
        let sidecarPath = dir.appendingPathComponent("DSC_0001.xmp").path
        // Order: ... -o <sidecar> <nef-path> -execute
        #expect(args.suffix(3) == [sidecarPath, nef.path, "-execute"])
        #expect(args.contains("-XMP:Title=Lindvägen 12, Tyresö"))
    }

    @Test("NEF med befintlig sidecar skriver direkt till .xmp-filen med -overwrite_original")
    func nef_existingSidecar_overwritesSidecarDirectly() {
        let dir = tempDir()
        let nef = dir.appendingPathComponent("DSC_0002.nef")
        let sidecar = dir.appendingPathComponent("DSC_0002.xmp")
        FileManager.default.createFile(atPath: sidecar.path, contents: nil)

        let meta = IPTCFileMetadata(address: "Storgatan 1, Stockholm", eventTitle: nil, description: "Storgatan 1, Stockholm")
        let args = PipelineRunner.exiftoolArguments(for: nef, meta: meta)

        #expect(args.first == "-overwrite_original")
        #expect(!args.contains("-o"))
        #expect(args.last == "-execute")
        #expect(args[args.count - 2] == sidecar.path)
        #expect(!args.contains(nef.path))
    }

    // MARK: - DNG/preview/HDR → in place

    @Test("DNG skrivs in place, symlänken bevaras")
    func dng_writesInPlace() {
        let dir = tempDir()
        let dng = dir.appendingPathComponent("DSC_0003.dng")
        let meta = IPTCFileMetadata(address: "Storgatan 1, Stockholm", eventTitle: "Visning", description: "Storgatan 1, Stockholm")

        let args = PipelineRunner.exiftoolArguments(for: dng, meta: meta)

        #expect(args.first == "-overwrite_original_in_place")
        #expect(!args.contains("-overwrite_original"))
        #expect(!args.contains("-o"))
        #expect(args.last == "-execute")
        #expect(args[args.count - 2] == dng.path)
        #expect(args.contains("-IPTC:Headline=Storgatan 1, Stockholm"))
        #expect(args.contains("-IPTC:SpecialInstructions=Visning"))
    }

    @Test("JPEG-preview skrivs in place precis som DNG")
    func previewJPEG_writesInPlace() {
        let dir = tempDir()
        let jpg = dir.appendingPathComponent("DSC_0004.jpg")
        let meta = IPTCFileMetadata(address: "Vägen 5, Ort", eventTitle: nil, description: "Vägen 5, Ort")

        let args = PipelineRunner.exiftoolArguments(for: jpg, meta: meta)

        #expect(args.first == "-overwrite_original_in_place")
        #expect(args[args.count - 2] == jpg.path)
    }

    // MARK: - GPS ref

    @Test("Positiv lat/lon ger N/E-referenser (icke-NEF)")
    func gpsRef_positiveGivesNorthEast() {
        let dng = URL(fileURLWithPath: "/tmp/x.dng")
        let meta = IPTCFileMetadata(address: "A", eventTitle: nil, description: "A", latitude: 59.33, longitude: 18.06)
        let args = PipelineRunner.exiftoolArguments(for: dng, meta: meta)
        #expect(args.contains("-GPSLatitudeRef=N"))
        #expect(args.contains("-GPSLongitudeRef=E"))
        #expect(args.contains("-GPSLatitude=59.33"))
        #expect(args.contains("-GPSLongitude=18.06"))
    }

    @Test("Negativ lat/lon ger S/W-referenser (icke-NEF)")
    func gpsRef_negativeGivesSouthWest() {
        let dng = URL(fileURLWithPath: "/tmp/x.dng")
        let meta = IPTCFileMetadata(address: "A", eventTitle: nil, description: "A", latitude: -33.86, longitude: -70.9)
        let args = PipelineRunner.exiftoolArguments(for: dng, meta: meta)
        #expect(args.contains("-GPSLatitudeRef=S"))
        #expect(args.contains("-GPSLongitudeRef=W"))
        #expect(args.contains("-GPSLatitude=33.86"))
        #expect(args.contains("-GPSLongitude=70.9"))
    }

    @Test("GPS för NEF-sidecar använder XMP-prefixade taggar")
    func gpsRef_nefUsesXMPPrefixedTags() {
        let nef = URL(fileURLWithPath: "/tmp/x.nef")
        let meta = IPTCFileMetadata(address: "A", eventTitle: nil, description: "A", latitude: 59.33, longitude: 18.06)
        let args = PipelineRunner.exiftoolArguments(for: nef, meta: meta)
        #expect(args.contains("-XMP:GPSLatitudeRef=N"))
        #expect(args.contains("-XMP:GPSLongitudeRef=E"))
        #expect(!args.contains("-GPSLatitudeRef=N"))
    }

    @Test("Utan GPS skrivs inga GPS-taggar")
    func gpsRef_nilOmitsGPSTags() {
        let dng = URL(fileURLWithPath: "/tmp/x.dng")
        let meta = IPTCFileMetadata(address: "A", eventTitle: nil, description: "A")
        let args = PipelineRunner.exiftoolArguments(for: dng, meta: meta)
        #expect(!args.contains { $0.contains("GPS") })
    }

    // MARK: - Address-less (Osorterade AI-only)

    @Test("Utan adress skrivs varken Headline eller Title, men AI-taggar skrivs")
    func addressLess_onlyWritesAITags() {
        let jpg = URL(fileURLWithPath: "/tmp/x.jpg")
        let meta = IPTCFileMetadata(address: nil, eventTitle: nil, description: "En AI-beskrivning", aiTags: ["kök", "vardagsrum"])
        let args = PipelineRunner.exiftoolArguments(for: jpg, meta: meta)
        #expect(!args.contains { $0.hasPrefix("-IPTC:Headline") })
        #expect(!args.contains { $0.hasPrefix("-XMP:Title") })
        #expect(args.contains("-IPTC:Keywords+=kök"))
        #expect(args.contains("-XMP:Subject+=kök"))
        #expect(args.contains("-IPTC:Caption-Abstract=En AI-beskrivning"))
    }
}
