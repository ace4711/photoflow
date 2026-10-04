import Foundation
import CoreLocation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PhotoFlow

/// Fas 1b: den gemensamma metadataberäkningen (`MetadataPlan`), stämplarna
/// (`MetadataStamps`, `metadata_stamps.json`) och skrivningen av metadata när HDR- och
/// förbättrade filer skapas (`HDRWriter.writeMetadata`, ersätter `copyEXIF`).
@MainActor
struct MetadataPlanTests {

    // MARK: - Hjälpare

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataPlanTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, _ text: String = "x") {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    /// Det metadatasteget gjorde före fas 1b för en fil i en adressmapp (eller i Osorterade när
    /// `folder` är nil): metadatat byggdes inne i `writeIPTCMetadata` och argumenten av den gamla
    /// `exiftoolArguments`. Kopierat ordagrant från commit 81bde1f, för att visa att den
    /// utbrutna beräkningen ger exakt samma argument.
    private func legacyArguments(file: URL, folder: (address: String, eventTitle: String, bookingInfo: String?, lat: Double, lon: Double)?,
                                 aiTagLookup: [String: (tags: [String], description: String)], aiTaggingEnabled: Bool) -> [String]? {
        let baseName = file.deletingPathExtension().lastPathComponent
        let meta: (address: String?, eventTitle: String?, description: String?, latitude: Double?, longitude: Double?, aiTags: [String])
        if let folder {
            let address = folder.address.precomposedStringWithCanonicalMapping
            let eventTitle = folder.eventTitle.precomposedStringWithCanonicalMapping
            let bookingInfo = (folder.bookingInfo ?? "").precomposedStringWithCanonicalMapping
            let description = [address, bookingInfo].filter { !$0.isEmpty }.joined(separator: " — ")
            let hasGPS = folder.lat != 0 || folder.lon != 0
            let aiData = aiTagLookup[baseName]
            let nfcTags = (aiData?.tags ?? []).map { $0.precomposedStringWithCanonicalMapping }
            let combinedDesc: String
            if let aiData {
                combinedDesc = [description, aiData.description.precomposedStringWithCanonicalMapping]
                    .filter { !$0.isEmpty }.joined(separator: " — ")
            } else {
                combinedDesc = description
            }
            meta = (address, eventTitle, combinedDesc, hasGPS ? folder.lat : nil, hasGPS ? folder.lon : nil, nfcTags)
        } else {
            guard aiTaggingEnabled, let aiData = aiTagLookup[baseName] else { return nil }
            let nfcTags = aiData.tags.map { $0.precomposedStringWithCanonicalMapping }
            let nfcDesc = aiData.description.precomposedStringWithCanonicalMapping
            meta = (nil, nil, nfcDesc.isEmpty ? nil : nfcDesc, nil, nil, nfcTags)
        }

        let isNEF = file.pathExtension.lowercased() == "nef"
        let sidecarURL = file.deletingPathExtension().appendingPathExtension("xmp")
        let sidecarExists = isNEF && FileManager.default.fileExists(atPath: sidecarURL.path)
        var lines: [String] = []
        if isNEF {
            if sidecarExists { lines.append("-overwrite_original") }
        } else {
            lines.append("-overwrite_original_in_place")
        }
        lines.append("-charset")
        lines.append("iptc=UTF8")
        if let lat = meta.latitude, let lon = meta.longitude {
            let latRef = lat >= 0 ? "N" : "S"
            let lonRef = lon >= 0 ? "E" : "W"
            if isNEF {
                lines.append("-XMP:GPSLatitude=\(abs(lat)) \(latRef)")
                lines.append("-XMP:GPSLongitude=\(abs(lon)) \(lonRef)")
            } else {
                lines.append("-GPSLatitude=\(abs(lat))")
                lines.append("-GPSLatitudeRef=\(latRef)")
                lines.append("-GPSLongitude=\(abs(lon))")
                lines.append("-GPSLongitudeRef=\(lonRef)")
            }
        }
        if let address = meta.address, !address.isEmpty {
            if isNEF {
                lines.append("-XMP:Title=\(address)")
                lines.append("-XMP-iptcCore:Location=\(address)")
                lines.append("-XMP-iptcCore:Sublocation=\(address)")
            } else {
                lines.append("-IPTC:Headline=\(address)")
                lines.append("-IPTC:ObjectName=\(address)")
                lines.append("-XMP:Title=\(address)")
                lines.append("-IPTC:Sub-location=\(address)")
            }
        }
        if let eventTitle = meta.eventTitle, !eventTitle.isEmpty {
            lines.append(isNEF ? "-XMP:Instructions=\(eventTitle)" : "-IPTC:SpecialInstructions=\(eventTitle)")
        }
        for tag in meta.aiTags {
            if isNEF {
                lines.append("-XMP:Subject-=\(tag)")
                lines.append("-XMP:Subject+=\(tag)")
            } else {
                lines.append("-IPTC:Keywords-=\(tag)")
                lines.append("-IPTC:Keywords+=\(tag)")
                lines.append("-XMP:Subject-=\(tag)")
                lines.append("-XMP:Subject+=\(tag)")
            }
        }
        if let description = meta.description, !description.isEmpty {
            if isNEF {
                lines.append("-XMP:Description=\(description)")
            } else {
                lines.append("-IPTC:Caption-Abstract=\(description)")
                lines.append("-XMP:Description=\(description)")
            }
        }
        if isNEF && !sidecarExists {
            lines.append("-o")
            lines.append(sidecarURL.path)
        }
        lines.append(isNEF && sidecarExists ? sidecarURL.path : file.path)
        lines.append("-execute")
        return lines
    }

    private func newArguments(file: URL, folder: AddressMetadata?, aiLookup: [String: AITagData], aiTaggingEnabled: Bool) -> [String]? {
        let baseName = file.deletingPathExtension().lastPathComponent
        guard let meta = MetadataPlan.fileMetadata(baseName: baseName, folder: folder, aiLookup: aiLookup,
                                                   aiTaggingEnabled: aiTaggingEnabled) else { return nil }
        let args = PipelineRunner.exiftoolArguments(for: file, meta: meta)
        // Enda skillnaden mot före fas 1b: IPTC:CodedCharacterSet=UTF8 när IPTC-fält skrivs (inte NEF).
        let charset = ExiftoolMetadataArguments.iptcCharsetLine
        let isNEF = file.pathExtension.lowercased() == "nef"
        let hasIPTC = args.contains { $0.hasPrefix("-IPTC:") && $0 != charset }
        #expect(args.contains(charset) == (!isNEF && hasIPTC), "\(file.lastPathComponent)")
        return args.filter { $0 != charset }
    }

    // MARK: - Gemensam beräkning = samma argument som förut

    @Test("Den utbrutna metadataberäkningen ger samma exiftool-argument som metadatasteget före fas 1b (plus IPTC-teckenuppsättningen)")
    func sharedComputation_matchesLegacyArguments() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // NFD-sträng ("ö" som o + kombinerande trema) för att täcka NFC-normaliseringen.
        let nfdAddress = "Lindvägen 12".decomposedStringWithCanonicalMapping
        let legacyAI: [String: (tags: [String], description: String)] = [
            "DSC_0001": (["Exteriör", "Trädgård".decomposedStringWithCanonicalMapping], "Ett rött hus"),
            "DSC_0002": (["Kök"], "")
        ]
        let newAI = legacyAI.mapValues { AITagData(tags: $0.tags, description: $0.description) }
        let sidecarNEF = dir.appendingPathComponent("DSC_0002.NEF")
        touch(dir.appendingPathComponent("DSC_0002.xmp"))

        let files = ["DSC_0001.dng", "DSC_0001.jpg", "DSC_0001.NEF", "DSC_0003.dng", "hdr_group_7.tiff", "hdr_group_7.jpg",
                     "DSC_0001_enh.tiff", "hdr_group_7_enh.jpg"].map { dir.appendingPathComponent($0) } + [sidecarNEF]
        let folders: [(address: String, eventTitle: String, bookingInfo: String?, lat: Double, lon: Double)] = [
            (nfdAddress, "Lindvägen 12, Tyresö, villa", "villa ca 169 kvm", 59.2, 18.3),
            ("Storgatan 1", "", nil, 0, 0),              // ingen GPS, ingen titel/bokningsinfo
            ("Södra vägen 3", "Visning", "", -33.86, -70.9)
        ]
        for aiEnabled in [true, false] {
            for file in files {
                for folder in folders {
                    let hasGPS = folder.lat != 0 || folder.lon != 0
                    let newFolder = AddressMetadata(
                        address: folder.address.precomposedStringWithCanonicalMapping,
                        eventTitle: folder.eventTitle.precomposedStringWithCanonicalMapping,
                        bookingInfo: (folder.bookingInfo ?? "").precomposedStringWithCanonicalMapping,
                        latitude: hasGPS ? folder.lat : nil, longitude: hasGPS ? folder.lon : nil
                    )
                    let legacy = legacyArguments(file: file, folder: folder, aiTagLookup: aiEnabled ? legacyAI : [:], aiTaggingEnabled: aiEnabled)
                    let new = newArguments(file: file, folder: newFolder, aiLookup: aiEnabled ? newAI : [:], aiTaggingEnabled: aiEnabled)
                    #expect(legacy == new, "\(file.lastPathComponent) i \(folder.address), AI \(aiEnabled)")
                }
                // Osorterade
                let legacy = legacyArguments(file: file, folder: nil, aiTagLookup: aiEnabled ? legacyAI : [:], aiTaggingEnabled: aiEnabled)
                let new = newArguments(file: file, folder: nil, aiLookup: aiEnabled ? newAI : [:], aiTaggingEnabled: aiEnabled)
                #expect(legacy == new, "\(file.lastPathComponent) i Osorterade, AI \(aiEnabled)")
            }
        }
    }

    @Test("Adressmetadata per mapp: varje bokning nycklas med sin egen mapp, GPS 0,0 = ingen GPS")
    func addressMetadata_keysEachMappingByItsOwnFolder() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = [
            ("Gatan 1", "Gatan 1, Ort", t0...t0.addingTimeInterval(600)),
            // Startar inom den förras marginal — fick förut den förras mapp och försvann ur metadatan.
            ("Gatan 2", "Gatan 2", t0.addingTimeInterval(602)...t0.addingTimeInterval(900)),
            ("Vägen 3".decomposedStringWithCanonicalMapping, "", t0.addingTimeInterval(5000)...t0.addingTimeInterval(6000)),
            // Samma adress igen (paus mitt i): samma mapp, första bokningen äger den.
            ("Gatan 1", "Gatan 1, Ort (forts.)", t0.addingTimeInterval(7000)...t0.addingTimeInterval(7100))
        ]
        let result = MetadataPlan.addressMetadata(mappings: mappings, resolved: [
            "Gatan 1": ("villa", 59.1, 18.1),
            "Gatan 2": (nil, 59.2, 18.2),
            CalendarService.sanitizeFolderName(mappings[2].address): (nil, 0, 0)
        ])
        #expect(result.count == 3)
        #expect(result["Gatan 1"] == AddressMetadata(address: "Gatan 1", eventTitle: "Gatan 1, Ort", bookingInfo: "villa", latitude: 59.1, longitude: 18.1))
        #expect(result["Gatan 2"] == AddressMetadata(address: "Gatan 2", eventTitle: "Gatan 2", bookingInfo: "", latitude: 59.2, longitude: 18.2))
        let third = result[CalendarService.sanitizeFolderName(mappings[2].address)]
        #expect(third?.address == "Vägen 3".precomposedStringWithCanonicalMapping)
        #expect(third?.hasGPS == false)
        #expect(third?.latitude == nil)
    }

    @Test("Adressmetadata för den riktiga sessionens sex bokningar ger sex adresser (förut fyra)")
    func addressMetadata_realSessionGivesSixAddresses() {
        let mappings = RealSessionFixture.mappings
        var resolved: [String: (bookingInfo: String?, latitude: Double, longitude: Double)] = [:]
        for (i, m) in mappings.enumerated() { resolved[CalendarService.sanitizeFolderName(m.address)] = (nil, 59 + Double(i) / 100, 18) }
        let result = MetadataPlan.addressMetadata(mappings: mappings, resolved: resolved)
        #expect(result.count == 6)
        #expect(Set(result.keys) == Set(mappings.map(\.address)))
        #expect(result["Kyndelgränd 19"]?.address == "Kyndelgränd 19")
        #expect(result["Tjärnstigen 55A"]?.eventTitle == "Tjärnstigen 55A")
    }

    @Test("Metadata vid skapandet: okänd mapp, okända AI-taggar och Osorterade utan AI ger nil; adressmapp ger samma som metadatasteget")
    func creationMetadata_onlyWhenKnown() {
        let folder = AddressMetadata(address: "Gatan 1", eventTitle: "T", bookingInfo: "b", latitude: 1, longitude: 2)
        let context = PipelineRunner.CreationMetadataContext(
            addressMeta: ["Gatan 1": folder], aiLookup: nil, photoBaseNames: ["DSC_0001"], aiTaggingEnabled: true
        )
        let hdr = URL(fileURLWithPath: "/tmp/out/hdr/hdr_group_3.tiff")
        #expect(PipelineRunner.creationMetadata(for: hdr, folderName: "Gatan 1", context: context)
                == MetadataPlan.fileMetadata(baseName: "hdr_group_3", folder: folder, aiLookup: [:], aiTaggingEnabled: true))
        #expect(PipelineRunner.creationMetadata(for: hdr, folderName: "Okänd mapp", context: context) == nil)
        #expect(PipelineRunner.creationMetadata(for: hdr, folderName: "Osorterade", context: context) == nil)
        // En fil som heter som en bild kan ha AI-taggar: okänt så länge bilderna inte är inlästa.
        let photoNamed = URL(fileURLWithPath: "/tmp/out/hdr/DSC_0001.tiff")
        #expect(PipelineRunner.creationMetadata(for: photoNamed, folderName: "Gatan 1", context: context) == nil)
    }

    @Test("Adressmappen för en fil som redan är sorterad, nil i stagingmapparna")
    func addressFolderName_containing() {
        #expect(PipelineRunner.addressFolderName(containing: URL(fileURLWithPath: "/o/Gatan 1 ÖVRIGA/hdr_group_1.tiff")) == "Gatan 1")
        #expect(PipelineRunner.addressFolderName(containing: URL(fileURLWithPath: "/o/Gatan 1 TITTBILDER/hdr_group_1.jpg")) == "Gatan 1")
        #expect(PipelineRunner.addressFolderName(containing: URL(fileURLWithPath: "/o/Osorterade FÖRBÄTTRADE/DSC_1_enh.jpg")) == "Osorterade")
        #expect(PipelineRunner.addressFolderName(containing: URL(fileURLWithPath: "/o/hdr/hdr_group_1.tiff")) == nil)
        #expect(PipelineRunner.addressFolderName(containing: URL(fileURLWithPath: "/o/enhanced/DSC_1_enh.tiff")) == nil)
    }

    @Test("Första bildens fotodatum ur bracket_groups.json som loadBracketGroups räknar det")
    func firstPhotoDate_matchesLoadBracketGroups() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        #expect(PipelineRunner.firstPhotoDate(ofGroup: ["datetimes": ["2026-10-02 09:01:02", "2026-10-02 09:01:05"], "date_start": "2026-10-02 09:00:00"])
                == formatter.date(from: "2026-10-02 09:01:02"))
        #expect(PipelineRunner.firstPhotoDate(ofGroup: ["datetimes": ["trasig"], "date_start": "2026-10-02 09:00:00"])
                == formatter.date(from: "2026-10-02 09:00:00"))
        #expect(PipelineRunner.firstPhotoDate(ofGroup: ["date_start": "2026-10-02 09:00:00"]) == formatter.date(from: "2026-10-02 09:00:00"))
        #expect(PipelineRunner.firstPhotoDate(ofGroup: [:]) == nil)
    }

    @Test("Lyckade exiftool-kommandon tolkas per fil ur -progress-utdatan")
    func succeededTargets_parsesProgressOutput() {
        let output = """
        ======== /x/Gatan 1/a.dng [1/1]
            1 image files updated
        ======== /x/b [1].jpg [1/1]
            1 image files unchanged
        ======== /x/c.dng [1/1]
        Error: File not found - /x/c.dng
            0 image files updated
            1 files weren't updated due to errors
        ======== /x/d.NEF [1/1]
        '/x/d.NEF' --> '/x/d.xmp'

            1 image files created
        ======== /x/e.dng [1/1]
        """
        #expect(PipelineRunner.succeededExiftoolTargets(in: output) == ["/x/Gatan 1/a.dng", "/x/b [1].jpg", "/x/d.NEF"])
    }

    // MARK: - Stämplar

    @Test("Stämpel matchar samma metadata och samma fil; ändrad adress, GPS, taggar eller ersatt fil matchar inte")
    func stamps_matchOnlySameContentAndFile() throws {
        let outputDir = tempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let file = outputDir.appendingPathComponent("Gatan 1 ÖVRIGA/hdr_group_1.tiff")
        touch(file)
        let meta = IPTCFileMetadata(address: "Gatan 1", eventTitle: "T", description: "Gatan 1 — villa", latitude: 59.1, longitude: 18.1, aiTags: ["Kök"])

        var stamps = MetadataStamps()
        #expect(!stamps.matches(file, meta: meta, outputDir: outputDir))
        stamps.record(file, meta: meta, outputDir: outputDir)
        #expect(stamps.files.keys.contains("Gatan 1 ÖVRIGA/hdr_group_1.tiff"))
        #expect(stamps.matches(file, meta: meta, outputDir: outputDir))

        var other = meta; other.address = "Gatan 2"
        #expect(!stamps.matches(file, meta: other, outputDir: outputDir))
        other = meta; other.latitude = 59.2
        #expect(!stamps.matches(file, meta: other, outputDir: outputDir))
        other = meta; other.aiTags = ["Kök", "Hall"]
        #expect(!stamps.matches(file, meta: other, outputDir: outputDir))
        other = meta; other.description = "Gatan 1"
        #expect(!stamps.matches(file, meta: other, outputDir: outputDir))

        // Spara/ladda.
        stamps.save(to: outputDir)
        #expect(MetadataStamps.load(from: outputDir) == stamps)

        // Skriva i filen (som metadatasteget, in place) ändrar varken stämpel eller identitet...
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile(); handle.write(Data("mer".utf8)); try handle.close()
        #expect(stamps.matches(file, meta: meta, outputDir: outputDir))
        // ...men en ny fil på samma plats (omgjord HDR/DNG) gör det.
        let replacement = outputDir.appendingPathComponent("ny.tiff")
        touch(replacement, "ny")
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        #expect(!stamps.matches(file, meta: meta, outputDir: outputDir))
    }

    @Test("Stämpeln följer filen när sorteringen flyttar den; NEF identifieras av sin XMP-sidecar")
    func stamps_moveAndSidecar() throws {
        let outputDir = tempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let meta = IPTCFileMetadata(address: "Gatan 1", eventTitle: nil, description: "Gatan 1")
        let staging = outputDir.appendingPathComponent("hdr/hdr_group_1.tiff")
        let dest = outputDir.appendingPathComponent("Gatan 1 ÖVRIGA/hdr_group_1.tiff")
        touch(staging)
        var stamps = MetadataStamps()
        stamps.record(staging, meta: meta, outputDir: outputDir)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: dest)
        stamps.move(from: staging, to: dest, outputDir: outputDir)
        #expect(stamps.files["hdr/hdr_group_1.tiff"] == nil)
        #expect(stamps.matches(dest, meta: meta, outputDir: outputDir))

        // NEF: utan sidecar ingen identitet, med sidecar matchar stämpeln.
        let nef = outputDir.appendingPathComponent("Gatan 1 ÖVRIGA/DSC_0001.NEF")
        touch(nef)
        stamps.record(nef, meta: meta, outputDir: outputDir)
        #expect(!stamps.matches(nef, meta: meta, outputDir: outputDir))
        touch(outputDir.appendingPathComponent("Gatan 1 ÖVRIGA/DSC_0001.xmp"))
        stamps.record(nef, meta: meta, outputDir: outputDir)
        #expect(stamps.matches(nef, meta: meta, outputDir: outputDir))
        try FileManager.default.removeItem(at: outputDir.appendingPathComponent("Gatan 1 ÖVRIGA/DSC_0001.xmp"))
        #expect(!stamps.matches(nef, meta: meta, outputDir: outputDir))
    }

    @Test("Adressrättning tar bort stämplarna för den gamla och den nya adressens mappar, inga andra")
    func correctAddress_invalidatesStampsForAffectedFolders() {
        let outputDir = tempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let iso = ISO8601DateFormatter()
        let entry: [String: Any] = ["address": "Fel Gatan 1", "event_title": "Fel Gatan 1",
                                    "range_start": iso.string(from: Date()), "range_end": iso.string(from: Date().addingTimeInterval(3600))]
        try? JSONSerialization.data(withJSONObject: [entry]).write(to: outputDir.appendingPathComponent("calendar_matches.json"))

        var stamps = MetadataStamps()
        let stamp = MetadataStamps.Stamp(fingerprint: "f", inode: 1)
        stamps.files = [
            "Fel Gatan 1/DSC_0001.dng": stamp,
            "Fel Gatan 1 ÖVRIGA/hdr_group_1.tiff": stamp,
            "Fel Gatan 1 FÖRBÄTTRADE/DSC_0002_enh.jpg": stamp,
            "Rätt Gatan 2 TITTBILDER/DSC_0003.jpg": stamp,
            "Annan Väg 3/DSC_0004.dng": stamp,
            "hdr/hdr_group_2.tiff": stamp
        ]
        stamps.save(to: outputDir)

        let state = PipelineState()
        state.outputDirectory = outputDir
        state.allMatchedAddresses = [(address: "Fel Gatan 1", eventTitle: "Fel Gatan 1", hasGPS: false, coordinate: nil)]
        state.correctAddress(at: 0, newAddress: "Rätt Gatan 2", coordinate: CLLocationCoordinate2D(latitude: 59, longitude: 18))

        let after = MetadataStamps.load(from: outputDir)
        #expect(Set(after.files.keys) == ["Annan Väg 3/DSC_0004.dng", "hdr/hdr_group_2.tiff"])
    }

    // MARK: - Med exiftool

    /// En liten RGB-bild som TIFF + JPEG via `HDRWriter.write` (samma väg som HDR och Förbättra).
    private func writeImagePair(tiff: URL, jpeg: URL) throws {
        let width = 16, height = 12
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = Float(i % width) / Float(width)
            pixels[i * 4 + 1] = Float(i / width) / Float(height)
            pixels[i * 4 + 2] = 0.5
            pixels[i * 4 + 3] = 1
        }
        try HDRWriter.write(pixels: pixels, width: width, height: height, tiffURL: tiff, jpegURL: jpeg)
    }

    @discardableResult
    private func exiftool(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolLocator.exiftool!)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Alla taggar (`-j -G1 -a -struct`) utom flyktiga, med samma filter som scripts/compare-outputs.py.
    private func tags(of file: URL) throws -> [String: String] {
        // Läses med -charset iptc=UTF8 så att jämförelsen med filer skrivna före CodedCharacterSet fungerar.
        let json = try exiftool(["-j", "-G1", "-a", "-struct", "-charset", "iptc=UTF8", file.path])
        let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
        let volatile = try NSRegularExpression(pattern:
            #"^(XMP-xmpMM:|XMP-xmp:(MetadataDate|ModifyDate)$|XMP-photoshop:DocumentAncestors|[A-Za-z0-9]+:ModifyDate$|IFD0:(Compression|StripOffsets|StripByteCounts|RowsPerStrip)$)"#)
        var result: [String: String] = [:]
        for (key, value) in array.first ?? [:] {
            let group = key.split(separator: ":").first.map(String.init) ?? key
            if ["File", "System", "ExifTool", "SourceFile"].contains(group) { continue }
            if volatile.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil { continue }
            result[key] = "\(value)"
        }
        return result
    }

    private func makeSourceRAW(in dir: URL) throws -> URL {
        let source = dir.appendingPathComponent("source.jpg")
        let scratch = dir.appendingPathComponent("scratch.tiff")
        try writeImagePair(tiff: scratch, jpeg: source)
        try exiftool(["-overwrite_original", "-DateTimeOriginal=2026:10:02 09:01:02", "-CreateDate=2026:10:02 09:01:02",
                      "-ModifyDate=2026:10:02 09:01:03", "-SubSecTimeOriginal=42", "-Make=NIKON CORPORATION", "-Model=NIKON Z 8",
                      "-LensModel=NIKKOR Z 14-24mm f/2.8 S", "-FNumber=8", "-ApertureValue=8", "-ISO=64", "-FocalLength=14",
                      "-ExposureTime=1/125", "-Artist=Ska inte kopieras", source.path])
        return source
    }

    @Test("writeMetadata utan IPTC-data ger samma EXIF som copyEXIF gjorde",
          .enabled(if: ToolLocator.exiftool != nil, "exiftool saknas (brew install exiftool) — testet kör riktiga exiftool-anrop"))
    func writeMetadata_withoutMeta_sameEXIFAsCopyEXIF() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceRAW(in: dir)
        let old = (dir.appendingPathComponent("old.tiff"), dir.appendingPathComponent("old.jpg"))
        let new = (dir.appendingPathComponent("new.tiff"), dir.appendingPathComponent("new.jpg"))
        try writeImagePair(tiff: old.0, jpeg: old.1)
        try FileManager.default.copyItem(at: old.0, to: new.0)
        try FileManager.default.copyItem(at: old.1, to: new.1)

        // copyEXIF före fas 1b, ordagrant.
        try exiftool(["-TagsFromFile", source.path,
                      "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-SubSecTimeOriginal",
                      "-Make", "-Model", "-LensModel",
                      "-FNumber", "-ApertureValue", "-ISO", "-FocalLength", "-ExposureTime",
                      "-overwrite_original", "-P", old.0.path, old.1.path])
        #expect(HDRWriter.writeMetadata(from: source, outputs: [(new.0, nil), (new.1, nil)], exiftoolPath: ToolLocator.exiftool!))

        for (a, b) in [(old.0, new.0), (old.1, new.1)] {
            let oldTags = try tags(of: a), newTags = try tags(of: b)
            #expect(oldTags == newTags, "\(b.lastPathComponent)")
            #expect(newTags["ExifIFD:DateTimeOriginal"] == "2026:10:02 09:01:02")
            #expect(newTags["IFD0:Model"] == "NIKON Z 8")
            #expect(newTags["IFD0:Artist"] == nil)
            #expect(newTags["IPTC:Headline"] == nil)
        }
    }

    @Test("writeMetadata med IPTC-data = copyEXIF + metadatasteget i två omgångar, och lägger till IPTC/XMP/GPS",
          .enabled(if: ToolLocator.exiftool != nil, "exiftool saknas (brew install exiftool) — testet kör riktiga exiftool-anrop"))
    func writeMetadata_withMeta_sameAsTwoPassFlow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSourceRAW(in: dir)
        let old = (dir.appendingPathComponent("old.tiff"), dir.appendingPathComponent("old.jpg"))
        let new = (dir.appendingPathComponent("new.tiff"), dir.appendingPathComponent("new.jpg"))
        try writeImagePair(tiff: old.0, jpeg: old.1)
        try FileManager.default.copyItem(at: old.0, to: new.0)
        try FileManager.default.copyItem(at: old.1, to: new.1)
        let folder = AddressMetadata(address: "Lindvägen 12", eventTitle: "Lindvägen 12, Tyresö, villa ca 169 kvm",
                                     bookingInfo: "villa ca 169 kvm", latitude: 59.2345678, longitude: 18.2987654)
        let meta = MetadataPlan.fileMetadata(baseName: "hdr_group_1", folder: folder, aiLookup: [:], aiTaggingEnabled: true)!

        // Före fas 1b: copyEXIF, sedan metadatasteget (argfil, in place).
        try exiftool(["-TagsFromFile", source.path,
                      "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-SubSecTimeOriginal",
                      "-Make", "-Model", "-LensModel",
                      "-FNumber", "-ApertureValue", "-ISO", "-FocalLength", "-ExposureTime",
                      "-overwrite_original", "-P", old.0.path, old.1.path])
        let argfile = dir.appendingPathComponent("args.txt")
        let lines = PipelineRunner.exiftoolArguments(for: old.0, meta: meta) + PipelineRunner.exiftoolArguments(for: old.1, meta: meta)
        try lines.joined(separator: "\n").write(to: argfile, atomically: true, encoding: .utf8)
        try exiftool(["-@", argfile.path])

        // Fas 1b: ett anrop.
        #expect(HDRWriter.writeMetadata(from: source, outputs: [(new.0, meta), (new.1, meta)], exiftoolPath: ToolLocator.exiftool!))

        for (a, b) in [(old.0, new.0), (old.1, new.1)] {
            let oldTags = try tags(of: a), newTags = try tags(of: b)
            let diff = Set(oldTags.keys).union(newTags.keys).filter { oldTags[$0] != newTags[$0] }
                .map { "\($0): \(oldTags[$0] ?? "-") ≠ \(newTags[$0] ?? "-")" }.sorted()
            #expect(oldTags == newTags, "\(b.lastPathComponent): \(diff)")
            #expect(newTags["IPTC:Headline"] == "Lindvägen 12")
            #expect(newTags["XMP-dc:Title"] == "Lindvägen 12")
            #expect(newTags["IPTC:SpecialInstructions"] == "Lindvägen 12, Tyresö, villa ca 169 kvm")
            #expect(newTags["XMP-dc:Description"] == "Lindvägen 12 — villa ca 169 kvm")
            #expect(newTags["GPS:GPSLatitudeRef"] == "North")
            #expect(newTags["GPS:GPSLatitude"] != nil)
            #expect(newTags["ExifIFD:DateTimeOriginal"] == "2026:10:02 09:01:02")
        }
    }

    @Test("tagLines: IPTC:CodedCharacterSet=UTF8 med IPTC-fälten för JPEG/TIFF/DNG, aldrig i NEF:s XMP-sidecar")
    func tagLines_declareIPTCCharset() {
        let full = IPTCFileMetadata(address: "Lillvägen 24", eventTitle: "T", description: "D", latitude: 59, longitude: 18, aiTags: ["Kök"])
        for isNEF in [false, true] {
            let lines = ExiftoolMetadataArguments.tagLines(for: full, isNEF: isNEF)
            #expect(lines.contains("-IPTC:CodedCharacterSet=UTF8") == !isNEF)
            #expect(lines.contains { $0.hasPrefix("-IPTC:") } == !isNEF)
        }
        for name in ["DSC_0001.jpg", "hdr_group_1.tiff", "DSC_0001.dng"] {
            let args = PipelineRunner.exiftoolArguments(for: URL(fileURLWithPath: "/tmp/x/\(name)"), meta: full)
            #expect(args.contains("-IPTC:CodedCharacterSet=UTF8"), "\(name)")
        }
        let nef = PipelineRunner.exiftoolArguments(for: URL(fileURLWithPath: "/tmp/x/DSC_0001.NEF"), meta: full)
        #expect(!nef.contains { $0.contains("CodedCharacterSet") })
        // Bara GPS (inga IPTC-fält): ingen deklaration.
        let gpsOnly = ExiftoolMetadataArguments.tagLines(for: IPTCFileMetadata(latitude: 1, longitude: 2), isNEF: false)
        #expect(!gpsOnly.contains("-IPTC:CodedCharacterSet=UTF8"))
    }

    @Test("Markörversionen ingår i stämplarnas fingerprint: version 3 ogiltigförklarar stämplar från version 2")
    func markerVersion_invalidatesStamps() throws {
        #expect(PipelineRunner.metadataMarkerVersion == 3)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Gatan 1 ÖVRIGA/hdr_group_1.tiff")
        touch(file)
        let meta = IPTCFileMetadata(address: "Gatan 1", eventTitle: "", description: "Gatan 1")
        // En stämpel som version 2 skrev den (samma kanoniska form, v=2).
        var canonical = "v=2\u{1F}nef=false"
        canonical += "\u{1F}address=Gatan 1\u{1F}event=\u{1F}description=Gatan 1\u{1F}lat=-\u{1F}lon=-\u{1F}tags="
        let v2 = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let v3 = MetadataStamps.fingerprint(for: meta, isNEF: false)
        #expect(v2 != v3)
        var stamps = MetadataStamps()
        stamps.files["Gatan 1 ÖVRIGA/hdr_group_1.tiff"] = .init(fingerprint: v2, inode: MetadataStamps.inode(of: file))
        #expect(!stamps.matches(file, meta: meta, outputDir: dir))
        stamps.record(file, meta: meta, outputDir: dir)
        #expect(stamps.matches(file, meta: meta, outputDir: dir))
    }

    @Test("IPTC med å/ä/ö läses rätt av exiftool UTAN -charset (CodedCharacterSet = UTF8)",
          .enabled(if: ToolLocator.exiftool != nil, "exiftool saknas (brew install exiftool) — testet kör riktiga exiftool-anrop"))
    func iptcRoundTrip_withoutCharsetOption() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("DSC_0001.jpg")
        try writeImagePair(tiff: dir.appendingPathComponent("scratch.tiff"), jpeg: jpeg)
        let meta = IPTCFileMetadata(address: "Lillvägen 24", eventTitle: "Lillvägen 24, högst upp", description: "Lillvägen 24 — Kök")
        let argfile = dir.appendingPathComponent("args.txt")
        try PipelineRunner.exiftoolArguments(for: jpeg, meta: meta).joined(separator: "\n").write(to: argfile, atomically: true, encoding: .utf8)
        try exiftool(["-@", argfile.path])
        let read = { (tag: String) in try self.exiftool(["-s3", "-IPTC:\(tag)", jpeg.path]).trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(try read("Sub-location") == "Lillvägen 24")
        #expect(try read("Headline") == "Lillvägen 24")
        #expect(try read("SpecialInstructions") == "Lillvägen 24, högst upp")
        #expect(try read("CodedCharacterSet") == "UTF8")
    }

    @Test("Metadatasteget stämplar filerna, hoppar över matchande stämplar och skriver om vid ändrad GPS; utan stämplar skrivs allt",
          .enabled(if: ToolLocator.exiftool != nil, "exiftool saknas (brew install exiftool) — testet kör riktiga exiftool-anrop"))
    func writeIPTCMetadata_usesStamps() async throws {
        let outputDir = tempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let fm = FileManager.default
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let address = "Testgatan 1"
        let extras = AddressFolderLayout.extrasDir(in: outputDir, folderName: address)
        let previews = AddressFolderLayout.previewDir(in: outputDir, folderName: address)
        try fm.createDirectory(at: extras, withIntermediateDirectories: true)
        try fm.createDirectory(at: previews, withIntermediateDirectories: true)
        let tiff = extras.appendingPathComponent("hdr_group_1.tiff")
        let jpeg = previews.appendingPathComponent("hdr_group_1.jpg")
        try writeImagePair(tiff: tiff, jpeg: jpeg)

        let state = PipelineState()
        state.outputDirectory = outputDir
        // Rättad koordinat (ingen geokodning över nätet) och tom titel (ingen bokningstolkning).
        state.correctedCoordinates[address] = CLLocationCoordinate2D(latitude: 59.5, longitude: 18.5)
        let runner = PipelineRunner(state: state)
        runner.calendarMappings = [(address: address, eventTitle: "", photoDateRange: t0...t0.addingTimeInterval(600))]

        // 1. Ingen stämpelfil (som en äldre session): allt skrivs, och stämplas.
        await runner.writeIPTCMetadata()
        #expect(try tags(of: tiff)["IPTC:Headline"] == address)
        var stamps = MetadataStamps.load(from: outputDir)
        #expect(Set(stamps.files.keys) == ["\(address) ÖVRIGA/hdr_group_1.tiff", "\(address) TITTBILDER/hdr_group_1.jpg"])
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("metadata_written.json").path))

        // 2. Markören borta (t.ex. nya HDR-filer flyttade), stämplarna stämmer: inget skrivs om.
        try fm.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: tiff.path)
        await runner.writeIPTCMetadata()
        #expect((try fm.attributesOfItem(atPath: tiff.path)[.modificationDate] as? Date) == t0)
        #expect(state.stepStatuses[.writeIPTCTags]?.logEntries.contains { $0.text.contains("har redan rätt metadata") } == true)
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("metadata_written.json").path))

        // 3. Ändrad GPS (manuell rättning): stämpeln matchar inte, filen skrivs om.
        try fm.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
        state.correctedCoordinates[address] = CLLocationCoordinate2D(latitude: 58.25, longitude: 17.75)
        await runner.writeIPTCMetadata()
        #expect((try fm.attributesOfItem(atPath: tiff.path)[.modificationDate] as? Date) != t0)
        let gps = try exiftool(["-n", "-s3", "-GPSLatitude", tiff.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(gps == "58.25")
        stamps = MetadataStamps.load(from: outputDir)
        let expected = MetadataPlan.fileMetadata(
            baseName: "hdr_group_1",
            folder: AddressMetadata(address: address, eventTitle: "", bookingInfo: "", latitude: 58.25, longitude: 17.75),
            aiLookup: [:], aiTaggingEnabled: true)!
        #expect(stamps.matches(tiff, meta: expected, outputDir: outputDir))

        // 4. Stämplarna borta (gammal markör utan stämplar, eller "Kör om"): full körning igen.
        try fm.removeItem(at: outputDir.appendingPathComponent("metadata_written.json"))
        try fm.removeItem(at: MetadataStamps.url(in: outputDir))
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: tiff.path)
        await runner.writeIPTCMetadata()
        #expect((try fm.attributesOfItem(atPath: tiff.path)[.modificationDate] as? Date) != t0)
        #expect(MetadataStamps.load(from: outputDir).files.count == 2)
    }

    @Test("Sorteringen flyttar stämpeln med den förbättrade filen")
    func moveUnsortedEnhanced_movesStamp() {
        let outputDir = tempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let staging = AddressFolderLayout.enhancedStagingDir(in: outputDir).appendingPathComponent("DSC_0009_enh.jpg")
        touch(staging)
        let meta = IPTCFileMetadata(address: nil, eventTitle: nil, description: "x", aiTags: ["Kök"])
        var stamps = MetadataStamps()
        stamps.record(staging, meta: meta, outputDir: outputDir)
        stamps.save(to: outputDir)

        let state = PipelineState()
        state.outputDirectory = outputDir
        let runner = PipelineRunner(state: state)
        runner.moveUnsortedEnhanced(outputDir: outputDir)

        let dest = AddressFolderLayout.enhancedDir(in: outputDir, folderName: "Osorterade").appendingPathComponent("DSC_0009_enh.jpg")
        let after = MetadataStamps.load(from: outputDir)
        #expect(after.files["enhanced/DSC_0009_enh.jpg"] == nil)
        #expect(after.matches(dest, meta: meta, outputDir: outputDir))
    }
}
