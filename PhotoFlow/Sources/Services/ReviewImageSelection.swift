import Foundation

/// Vilken bild granskningen ska visa som standard för en grupp.
///
/// Slutprodukten är det som faktiskt levereras: finns en förbättrad version
/// (`hdr_group_N_enh.*`, steget efter HDR) är det den, annars den
/// sammanslagna HDR-bilden, och först när ingen av dem finns visas första
/// källexponeringen som förut. Källexponeringarna går alltid att bläddra till.
nonisolated enum ReviewImageSelection {
    enum Choice: Equatable {
        case enhancedHDR(URL)
        case hdr(URL)
        case sourceExposure(index: Int)

        var isFinalProduct: Bool {
            if case .sourceExposure = self { return false }
            return true
        }
    }

    /// Föredrar JPEG (snabb att visa) framför TIFF, som i övriga UI.
    static func preferredURL(_ urls: [URL]) -> URL? {
        urls.first { $0.pathExtension.lowercased() == "jpg" } ?? urls.first
    }

    static func defaultChoice(hdr: AddressFolderLayout.HDRFiles?, enhanced: [URL]) -> Choice {
        if let url = preferredURL(enhanced) { return .enhancedHDR(url) }
        if let url = hdr?.jpeg ?? hdr?.tiff { return .hdr(url) }
        return .sourceExposure(index: 0)
    }

    /// Etikett för bilden som visas. `exposureIndex` är nollbaserad.
    static func label(showingFinal choice: Choice, exposureIndex: Int, exposureCount: Int) -> String {
        switch choice {
        case .enhancedHDR: return "HDR · förbättrad"
        case .hdr: return "HDR"
        case .sourceExposure:
            return "Exponering \(exposureIndex + 1) av \(exposureCount)"
        }
    }
}
