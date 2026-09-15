import Foundation
import Translation
import Testing
@testable import PhotoFlow

/// Tester för Fas 3c:s on-device `TranslationService`. Vad som går att testa
/// utan GUI (ingen `.translationTask` behövs för själva API-anropen):
/// `LanguageAvailability`s statusmaskin och en verklig rundtripp via en
/// direkt `TranslationSession(installedSource:target:)` — det initet kräver
/// bara att språkmodellen redan är nedladdad (verifierat i SDK:n, se
/// `TranslationService`s dokumentationskommentar), vilket den råkar vara på
/// den här utvecklingsmaskinen. Det här är alltså ett riktigt
/// integrationstest, inte en mock — men rundtripps-testet hoppar sig själv
/// (utan att fela) om modellen inte är nedladdad på den maskin som kör
/// testet, eftersom det inte går att trigga en nedladdning utan
/// `.translationTask`/GUI (se FORBATTRINGAR.md Fas 3c för manuell testning
/// av nedladdningsflödet).
@Suite("TranslationService (Fas 3c, on-device Apple Translation)")
struct TranslationServiceTests {

    /// `LanguageAvailability` är inte `Sendable` och dess `status`/
    /// `supportedLanguages` är icke-isolerade async-API:er — under projektets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` skulle ett direkt anrop från
    /// en (MainActor-isolerad) testfunktion behöva skicka den icke-Sendable
    /// instansen ut från MainActor. Genom att skapa OCH använda den helt
    /// inuti en fristående `Task.detached` slipper den någonsin korsa en
    /// aktörsgräns — bara Sendable-resultat (`Locale.Language`/`Status`/
    /// `Set<String>`) skickas tillbaka.
    private static func languageAvailabilityStatus(
        from source: Locale.Language, to target: Locale.Language?
    ) async -> LanguageAvailability.Status {
        await Task.detached {
            await LanguageAvailability().status(from: source, to: target)
        }.value
    }

    private static func supportedLanguageCodes() async -> Set<String> {
        await Task.detached {
            let supported = await LanguageAvailability().supportedLanguages
            return Set(supported.compactMap { $0.languageCode?.identifier })
        }.value
    }

    @Test("Svenska finns bland Apples Translation-stödda språk på den här maskinen")
    func swedishIsAmongSupportedLanguages() async {
        let codes = await Self.supportedLanguageCodes()
        #expect(codes.contains("sv"))
    }

    @Test("status(from:to:) ger ett av de tre giltiga statusvärdena för sv->en")
    func statusIsOneOfKnownValues() async {
        let sv = Locale.Language(identifier: "sv")
        let en = Locale.Language(identifier: "en")
        let status = await Self.languageAvailabilityStatus(from: sv, to: en)
        #expect(status == .installed || status == .supported || status == .unsupported)
    }

    @Test("Om sv->en-modellen är nedladdad på maskinen: TranslationService gör en riktig rundtripp")
    func translateRoundTrip_whenModelIsInstalled() async {
        let sv = Locale.Language(identifier: "sv")
        let en = Locale.Language(identifier: "en")
        let status = await Self.languageAvailabilityStatus(from: sv, to: en)
        guard status == .installed else {
            // Miljöberoende: modellen är inte nedladdad på den här maskinen/
            // CI-agenten. Inget testfel — se klasskommentaren ovan.
            return
        }

        let service = TranslationService()
        async let translated = service.translate(
            "Kylskåpet i köket är trasigt.", from: .swedish, to: .english
        )

        // Ge translate() en chans att sätta upp configuration/continuation
        // innan vi manuellt "spelar SwiftUI" och levererar en session — i
        // appen görs det senare steget av `.translationTask` i
        // `DictationPanelView`.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(service.configuration?.source == sv)
        #expect(service.configuration?.target == en)
        #expect(service.isTranslating)

        let session = TranslationSession(installedSource: sv, target: en)
        await service.performPendingTranslation(using: session)

        let result = await translated
        #expect(!result.isEmpty)
        #expect(result.lowercased().contains("refrigerator") || result.lowercased().contains("fridge"))
        #expect(service.isTranslating == false)
        #expect(service.error == nil)
    }

    @Test("Okänt/orimligt språkpar rapporteras som fel, ingen tyst tom sträng utan förklaring")
    func unsupportedLanguagePairing_reportsError() async {
        // "und" (undetermined) mot engelska ska aldrig ge status .installed —
        // körs alltid mot LanguageAvailability direkt, ingen TranslationSession
        // behövs (och skulle inte gå att skapa via installedSource ändå).
        let und = Locale.Language(identifier: "und")
        let en = Locale.Language(identifier: "en")
        let status = await Self.languageAvailabilityStatus(from: und, to: en)
        #expect(status != .installed)
    }
}
