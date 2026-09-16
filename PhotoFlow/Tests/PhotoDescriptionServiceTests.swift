import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Tester för `PhotoDescriptionService` (Fas 3d). Genererar en enkel
/// syntetisk "rumsbild" (himmel/mark-liknande färgytor + en rektangel) med
/// Core Graphics i stället för att bero på en riktig fastighetsbild — det
/// finns ingen bildfixtur i `Tests/Fixtures` sedan tidigare och det här
/// undviker att lägga in en riktig kundbild i repot. Innehållet behöver
/// inte vara fotorealistiskt: testet verifierar bara att anropskedjan
/// (CGImage → `Attachment` → `LanguageModelSession` → `RoomTags`) fungerar
/// och mäter tid, inte att modellens svenska beskrivning är "korrekt".
///
/// Hoppar sig själv utan att fela om `PhotoDescriptionService.isAvailable`
/// är falskt (kräver Apple Intelligence + macOS 27, se den typens
/// dokumentation) — samma mönster som `TranslationServiceTests`/
/// `DictationServiceTests` för sina on-device-modeller.
struct PhotoDescriptionServiceTests {
    private func makeSyntheticImageFile() throws -> URL {
        let width = 800, height = 600
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestSetupError.contextCreationFailed }

        // "Himmel" (övre halva, ljusblå) + "mark/golv" (undre halva, brun) +
        // en grå rektangel som kan tolkas som en byggnad/fasad.
        ctx.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.35, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

        guard let cgImage = ctx.makeImage() else { throw TestSetupError.contextCreationFailed }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoDescriptionServiceTests_\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TestSetupError.contextCreationFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestSetupError.contextCreationFailed }
        return url
    }

    private enum TestSetupError: Error { case contextCreationFailed }

    @Test("describe(imageAt:) ger rimlig RoomTags-struktur för en syntetisk bild, mäter tid")
    func describe_syntheticImage_returnsRoomTags() async throws {
        guard PhotoDescriptionService.isAvailable else {
            return
        }

        let imageURL = try makeSyntheticImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let start = Date()
        let result = await PhotoDescriptionService.shared.describe(imageAt: imageURL)
        let elapsed = Date().timeIntervalSince(start)
        print("[PhotoDescriptionServiceTests] describe() tog \(String(format: "%.2f", elapsed))s")

        let tags = try #require(result, "Modellen gav inget resultat för en giltig bild")
        print("[PhotoDescriptionServiceTests] room=\(tags.room) category=\(tags.category) features=\(tags.features) caption=\(tags.caption)")
        #expect(!tags.room.isEmpty)
        #expect(!tags.caption.isEmpty)
        #expect(tags.category == "Interiör" || tags.category == "Exteriör")
    }

    @Test("describe(imageAt:) för en obefintlig fil ger nil, inte en krasch")
    func describe_missingFile_returnsNil() async {
        guard PhotoDescriptionService.isAvailable else {
            return
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does_not_exist_\(UUID().uuidString).jpg")
        let result = await PhotoDescriptionService.shared.describe(imageAt: missing)
        #expect(result == nil)
    }
}
