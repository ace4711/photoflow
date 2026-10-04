import Foundation
import CryptoKit

/// Metadata to write to one output file via `ExiftoolMetadataArguments` /
/// `PipelineRunner.exiftoolArguments`.
/// `address`/`eventTitle`/`description` are `nil` when the field should not be
/// touched at all (e.g. AI-only files in "Osorterade" that have no calendar match).
/// All strings are expected to already be NFC-normalized by the caller
/// (`MetadataPlan.fileMetadata` does that).
nonisolated struct IPTCFileMetadata: Equatable, Hashable, Sendable {
    var address: String?
    var eventTitle: String?
    var description: String?
    var latitude: Double?
    var longitude: Double?
    var aiTags: [String] = []
}

/// Adress- och kalenderdata för en adressmapp, så som metadatasteget skriver den:
/// NFC-normaliserad, med koordinat bara när geokodningen (eller en manuell rättning)
/// gav en (0,0 räknas som "ingen GPS", precis som förut).
nonisolated struct AddressMetadata: Equatable, Sendable {
    var address: String
    var eventTitle: String
    var bookingInfo: String
    var latitude: Double?
    var longitude: Double?

    var hasGPS: Bool { latitude != nil && longitude != nil }
}

/// AI-taggar och -beskrivning för en bild (nyckel i uppslaget = basnamnet, `DSC_0012`).
nonisolated struct AITagData: Equatable, Sendable {
    var tags: [String]
    var description: String
}

/// Den gemensamma metadataberäkningen per fil (fas 1b). Används både av metadatasteget
/// (`writeIPTCMetadata`) och när HDR- och förbättrade filer skapas, så att taggarna blir
/// exakt desamma oavsett vem som skriver dem. Ren: inga sidoeffekter, ingen aktör.
nonisolated enum MetadataPlan {
    /// Mappen för bilder utan kalendermatchning.
    static let unsortedFolderName = "Osorterade"

    /// Metadata för en fil med basnamnet `baseName` (utan filändelse) i adressmappen
    /// `folder` (`nil` = "Osorterade"). `nil` tillbaka = metadatasteget skriver ingenting
    /// till filen (Osorterade-filer utan AI-taggar).
    ///
    /// Regler (oförändrade från metadatasteget före fas 1b):
    /// - Adressmapp: adress, händelsetitel, beskrivning "adress — bokningsinfo" (+ " — AI-beskrivning"
    ///   om bilden har AI-taggar), GPS om adressen har koordinater, AI-taggar.
    /// - Osorterade: bara AI-taggar och AI-beskrivning, och bara när AI-taggning är på och bilden har taggar.
    static func fileMetadata(baseName: String, folder: AddressMetadata?, aiLookup: [String: AITagData],
                             aiTaggingEnabled: Bool) -> IPTCFileMetadata? {
        let aiData = aiLookup[baseName]
        guard let folder else {
            guard aiTaggingEnabled, let aiData else { return nil }
            let nfcDesc = aiData.description.precomposedStringWithCanonicalMapping
            return IPTCFileMetadata(
                address: nil,
                eventTitle: nil,
                description: nfcDesc.isEmpty ? nil : nfcDesc,
                latitude: nil,
                longitude: nil,
                aiTags: aiData.tags.map { $0.precomposedStringWithCanonicalMapping }
            )
        }
        let description = [folder.address, folder.bookingInfo].filter { !$0.isEmpty }.joined(separator: " — ")
        let combinedDesc: String
        if let aiData {
            combinedDesc = [description, aiData.description.precomposedStringWithCanonicalMapping]
                .filter { !$0.isEmpty }.joined(separator: " — ")
        } else {
            combinedDesc = description
        }
        return IPTCFileMetadata(
            address: folder.address,
            eventTitle: folder.eventTitle,
            description: combinedDesc,
            latitude: folder.hasGPS ? folder.latitude : nil,
            longitude: folder.hasGPS ? folder.longitude : nil,
            aiTags: (aiData?.tags ?? []).map { $0.precomposedStringWithCanonicalMapping }
        )
    }

    /// Adressmetadata per adressmapp (nyckel = mappnamnet). Samma härledning som
    /// metadatasteget gjort sedan tidigare: nyckeln är mappen för bokningens första fotodatum,
    /// adress/titel tas från den första bokning som hamnar i samma mapp, bokningsinfo och
    /// koordinat från den första bokning som gav nyckeln. `resolve` ger (bokningsinfo, koordinat)
    /// för en bokning (geokodning/manuell rättning — se `PipelineRunner.resolveAddressMetadata`).
    static func addressMetadata(
        mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)],
        folderForDate: (Date) -> String?,
        resolved: [String: (bookingInfo: String?, latitude: Double, longitude: Double)]
    ) -> [String: AddressMetadata] {
        var result: [String: AddressMetadata] = [:]
        for mapping in mappings {
            let key = folderForDate(mapping.photoDateRange.lowerBound) ?? mapping.address
            guard result[key] == nil, let info = resolved[key] else { continue }
            let owner = mappings.first { folderForDate($0.photoDateRange.lowerBound) == key }
            let hasGPS = info.latitude != 0 || info.longitude != 0
            result[key] = AddressMetadata(
                address: (owner?.address ?? key).precomposedStringWithCanonicalMapping,
                eventTitle: (owner?.eventTitle ?? "").precomposedStringWithCanonicalMapping,
                bookingInfo: (info.bookingInfo ?? "").precomposedStringWithCanonicalMapping,
                latitude: hasGPS ? info.latitude : nil,
                longitude: hasGPS ? info.longitude : nil
            )
        }
        return result
    }
}

/// exiftool-raderna för IPTC/XMP/GPS-fälten i `IPTCFileMetadata` — delade av metadatasteget
/// (`PipelineRunner.exiftoolArguments`) och skrivningen när HDR-/förbättrade filer skapas
/// (`HDRWriter.writeMetadata`), så att båda vägarna skriver exakt samma taggar.
nonisolated enum ExiftoolMetadataArguments {
    /// Taggtilldelningarna (utan filnamn, `-overwrite_*` och `-execute`). `isNEF`: XMP-sidecar
    /// för en NEF, som bara har XMP-motsvarigheterna till IPTC-fälten.
    static func tagLines(for meta: IPTCFileMetadata, isNEF: Bool) -> [String] {
        var lines: [String] = []

        if let lat = meta.latitude, let lon = meta.longitude {
            let latRef = lat >= 0 ? "N" : "S"
            let lonRef = lon >= 0 ? "E" : "W"
            if isNEF {
                // XMP:GPSLatitudeRef/GPSLongitudeRef don't exist as separate tags
                // (verified with exiftool 13.50 — "doesn't exist or isn't writable").
                // exiftool accepts a signed "value N/S/E/W" string directly on the
                // XMP:GPSLatitude/GPSLongitude tags instead.
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
            // -=/+= idiom: removes the tag first if present, then re-adds it, so
            // re-running this step doesn't pile up duplicate keywords (verified
            // with exiftool 13.50 — plain += duplicates on every re-run).
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
        return lines
    }
}

/// `metadata_stamps.json` i outputmappen (fas 1b): vilken metadata som skrivits till varje fil,
/// så att metadatasteget kan hoppa över filer som redan fick rätt metadata när de skapades
/// (HDR, förbättrade) eller vid en tidigare körning.
///
/// Nyckel = filens sökväg relativt outputmappen (för NEF: symlänken i ÖVRIGA, vars XMP-sidecar
/// är det som skrivs). Värde = fingerprint av de skrivna värdena (`fingerprint(for:isNEF:)`,
/// inkl. `metadataMarkerVersion`) + filens inod efter skrivningen. Varken storlek eller
/// ändringstid används: metadataskrivningen ändrar båda. Inoden ändras däremot inte av
/// metadatasteget (`-overwrite_original_in_place`), men den byts när filen ersätts av en ny
/// (DNG-konverteraren och HDR flyttar in en färdig fil, förhandsbilder skrivs nya), så en
/// omgjord fil med en gammal stämpel skrivs om i stället för att hoppas över.
nonisolated struct MetadataStamps: Codable, Equatable {
    struct Stamp: Codable, Equatable {
        var fingerprint: String
        var inode: UInt64?
    }

    static let fileName = "metadata_stamps.json"
    static let formatVersion = 1

    var version = MetadataStamps.formatVersion
    var files: [String: Stamp] = [:]

    static func url(in outputDir: URL) -> URL { outputDir.appendingPathComponent(fileName) }

    /// Tom mängd om filen saknas, inte går att läsa eller har ett annat format.
    static func load(from outputDir: URL) -> MetadataStamps {
        guard let data = try? Data(contentsOf: url(in: outputDir)),
              let stamps = try? JSONDecoder().decode(MetadataStamps.self, from: data),
              stamps.version == formatVersion else { return MetadataStamps() }
        return stamps
    }

    func save(to outputDir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url(in: outputDir), options: .atomic)
    }

    /// Sökvägen relativt outputmappen (nil om filen inte ligger i den).
    static func relativePath(of file: URL, in outputDir: URL) -> String? {
        let base = outputDir.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
    }

    /// Filen som exiftool faktiskt skriver: XMP-sidecaren för en NEF, annars filen själv.
    static func writtenFile(for file: URL) -> URL {
        file.pathExtension.lowercased() == "nef" ? file.deletingPathExtension().appendingPathExtension("xmp") : file
    }

    /// Inoden för den skrivna filen (symlänkar följs: DNG och förhandsbilder i adressmapparna
    /// är länkar till `dng/` och `previews/`). nil om filen saknas.
    static func inode(of file: URL) -> UInt64? {
        var info = stat()
        guard stat(writtenFile(for: file).path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// Fingerprint av det som skrivs till filen.
    static func fingerprint(for meta: IPTCFileMetadata, isNEF: Bool) -> String {
        var canonical = "v=\(PipelineRunner.metadataMarkerVersion)\u{1F}nef=\(isNEF)"
        canonical += "\u{1F}address=\(meta.address ?? "\u{0}")"
        canonical += "\u{1F}event=\(meta.eventTitle ?? "\u{0}")"
        canonical += "\u{1F}description=\(meta.description ?? "\u{0}")"
        canonical += "\u{1F}lat=\(meta.latitude.map { "\($0)" } ?? "-")\u{1F}lon=\(meta.longitude.map { "\($0)" } ?? "-")"
        canonical += "\u{1F}tags=\(meta.aiTags.joined(separator: "\u{1E}"))"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Sant om `file` redan har exakt den här metadatan enligt stämpeln (samma värden och samma fil).
    func matches(_ file: URL, meta: IPTCFileMetadata, outputDir: URL) -> Bool {
        guard let key = Self.relativePath(of: file, in: outputDir), let stamp = files[key] else { return false }
        let isNEF = file.pathExtension.lowercased() == "nef"
        guard stamp.fingerprint == Self.fingerprint(for: meta, isNEF: isNEF) else { return false }
        guard let inode = stamp.inode, inode == Self.inode(of: file) else { return false }
        return true
    }

    /// Stämplar `file` med `meta` (anropas efter att exiftool skrivit filen).
    mutating func record(_ file: URL, meta: IPTCFileMetadata, outputDir: URL) {
        guard let key = Self.relativePath(of: file, in: outputDir) else { return }
        let isNEF = file.pathExtension.lowercased() == "nef"
        files[key] = Stamp(fingerprint: Self.fingerprint(for: meta, isNEF: isNEF), inode: Self.inode(of: file))
    }

    mutating func remove(_ file: URL, outputDir: URL) {
        guard let key = Self.relativePath(of: file, in: outputDir) else { return }
        files.removeValue(forKey: key)
    }

    /// Flyttar stämpeln med filen (sorteringen flyttar HDR- och förbättrade filer till adressmapparna).
    /// En stämpel på målet tas bort även när källan saknar stämpel: målet ersätts av källfilen.
    mutating func move(from source: URL, to destination: URL, outputDir: URL) {
        guard let destKey = Self.relativePath(of: destination, in: outputDir) else { return }
        let stamp = Self.relativePath(of: source, in: outputDir).flatMap { files.removeValue(forKey: $0) }
        files[destKey] = stamp
    }

    /// Tar bort stämplarna för alla filer direkt under mapparna `folderNames` (relativt outputmappen).
    /// Returnerar antalet borttagna.
    @discardableResult
    mutating func removeAll(inFolders folderNames: Set<String>) -> Int {
        let normalized = Set(folderNames.map { $0.precomposedStringWithCanonicalMapping })
        let keys = files.keys.filter { key in
            guard let slash = key.lastIndex(of: "/") else { return false }
            return normalized.contains(String(key[..<slash]))
        }
        for key in keys { files.removeValue(forKey: key) }
        return keys.count
    }
}
