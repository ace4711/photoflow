import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Rum/kategori/särdrag/bildtext för en fastighetsfoto, genererat av Apples
/// on-device Foundation Models direkt från bildpixlarna (multimodal
/// bildinmatning via `Attachment<ImageAttachmentContent>` — verifierat i SDK:n,
/// tillagt i macOS 27/WWDC26; syns INTE på macOS 26, se
/// `PhotoDescriptionService.isAvailable`).
@Generable
struct RoomTags: Sendable {
    @Guide(description: "Rumstyp eller motiv på svenska, t.ex. 'Kök', 'Vardagsrum', 'Fasad', 'Trädgård'")
    var room: String
    @Guide(description: "Antingen 'Interiör' eller 'Exteriör'")
    var category: String
    // OBS (Fas 3d): tidigare lydelse "tom lista om inget sticker ut" fick
    // modellen att bokstavligen returnera strängen "tom lista" som ett
    // element i listan i stället för en faktiskt tom array — se
    // FORBATTRINGAR.md. Omformulerat till en storleksbegränsning i stället
    // för att nämna "tom"/"[]" alls.
    @Guide(description: "0 till 4 korta svenska särdrag/detaljer, t.ex. 'öppen spis', 'havsutsikt', 'parkettgolv'. Hitta inte på särdrag som inte syns.", .count(0...4))
    var features: [String]
    @Guide(description: "Kort, saklig svensk bildtext lämplig för en mäklarannons, max en mening")
    var caption: String
}

/// Genererar svenska mäklarvänliga bildbeskrivningar från preview-JPEG:er via
/// Apples on-device Foundation Models (Fas 3d), som ett komplement till
/// `VisionTaggingService`s snabba men grova Vision-klassificering: Vision ger
/// rumstyp/kategori från en klassificerare, den här tjänsten ger en riktig
/// svensk bildtext och några extra särdrag genom att faktiskt "titta" på
/// bilden med en språkmodell.
///
/// `actor` — samma resonemang som `BookingTitleParser`/`PhotoQualityService`:
/// oberoende I/O-bundna jobb, ingen anledning att köra på huvudtråden.
actor PhotoDescriptionService {
    static let shared = PhotoDescriptionService()

    /// Bildinmatning (`Attachment<ImageAttachmentContent>`) kräver macOS 27 —
    /// finns inte i macOS 26-SDK:t även om resten av FoundationModels gör det
    /// (deployment target är 26.0, så det här måste kollas explicit både med
    /// `#available` och i retur-typen av det här villkoret). `static`
    /// medlemmar av en `actor` är inte isolerade, så kan anropas synkront
    /// direkt från t.ex. `SettingsView`.
    static var isAvailable: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return BookingTitleParser.isModelAvailable
    }

    /// Uppmätt tid för senaste modellanrop (Fas 3d) — bara för
    /// loggning/dokumentation.
    private(set) var lastCallDuration: TimeInterval?

    /// Beskriv en enskild bild. Returnerar `nil` om modellen inte är
    /// tillgänglig, bilden inte kunde läsas, eller modellanropet misslyckas
    /// (kontextgräns/guardrails/etc — loggas men stoppar aldrig pipelinen).
    /// Ingen nätverkstrafik: allt körs on-device.
    func describe(imageAt url: URL) async -> RoomTags? {
        guard #available(macOS 27.0, *) else { return nil }
        guard Self.isAvailable else { return nil }
        guard let cgImage = Self.loadCGImage(url) else {
            print("[PhotoDescriptionService] Kunde inte läsa bild: \(url.lastPathComponent)")
            return nil
        }

        let start = Date()
        defer { lastCallDuration = Date().timeIntervalSince(start) }

        do {
            let session = LanguageModelSession(instructions: """
                Du beskriver bostadsfoton på svenska åt en mäklare, kortfattat och \
                sakligt, för användning i en fastighetsannons. Ange rumstyp eller \
                motiv, om bilden är en interiör- eller exteriörbild, eventuella \
                synliga särdrag, och en kort bildtext.
                """)
            let response = try await session.respond(
                to: Prompt {
                    "Beskriv den här bilden för en mäklarannons."
                    Attachment(cgImage)
                },
                generating: RoomTags.self
            )
            return response.content
        } catch {
            print("[PhotoDescriptionService] Modellanrop misslyckades för \(url.lastPathComponent): \(error) — hoppar över bildbeskrivning för denna bild")
            return nil
        }
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
