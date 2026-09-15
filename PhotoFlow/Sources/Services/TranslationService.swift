import Foundation
import Translation

/// Översättning på enheten via Apples Translation-ramverk (Fas 3c) — ersätter
/// den tidigare implementationen som POST:ade anteckningstexten till Googles
/// inofficiella `translate.googleapis.com`-endpoint (ingen data lämnar enheten
/// längre, och ingen tyst fallback till Google om något går fel).
///
/// `TranslationSession` skapas normalt via SwiftUI-modifieraren
/// `.translationTask(configuration:action:)` (verifierat i SDK:n: den bor i
/// cross-import-overlayen `_Translation_SwiftUI`, som automatiskt blir
/// tillgänglig när både `Translation` och `SwiftUI` importeras i samma fil —
/// se `DictationPanelView`). Det finns visserligen även ett direkt
/// `TranslationSession(installedSource:target:)`-init i SDK:n, men det
/// kräver att språkmodellen redan är nedladdad och saknar
/// `canRequestDownloads`/system-UI-vägen för att faktiskt hämta en modell —
/// SwiftUI-modifieraren är alltså den enda vägen som kan trigga en riktig
/// nedladdning, vilket är precis vad vi behöver första gången ett språkpar
/// används.
///
/// Eftersom `.translationTask` bara triggas om av en förändring i
/// `configuration` (identitet/`Equatable`, inklusive `version` som
/// `invalidate()` stegar upp), fungerar den här klassen som en liten kö med
/// exakt en väntande förfrågan i taget: `translate(_:from:to:)` sätter
/// `configuration` (eller anropar `invalidate()` om språkparet är oförändrat)
/// och väntar på en `CheckedContinuation` som löses in av
/// `performPendingTranslation(using:)` när `.translationTask`s closure körs
/// med en riktig session.
@MainActor
final class TranslationService: ObservableObject {
    /// Bunden till `.translationTask(_:action:)` i `DictationPanelView`.
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published var isTranslating = false
    @Published var error: String?
    /// Kort svensk statustext för långsamma delsteg (idag bara
    /// nedladdning av språkmodell) — visas i panelen i stället för att bara
    /// se ut som att appen hänger.
    @Published var statusText: String?

    private var pendingText = ""
    private var pendingTargetDisplayName = ""
    private var pendingContinuation: CheckedContinuation<String, Never>?

    /// Översätter `text` från `source` till `target`. Returnerar tom sträng
    /// vid fel (`error` sätts då till ett svenskt, användbart felmeddelande —
    /// inga tysta fallbacks).
    func translate(_ text: String, from source: PhotoNote.NoteLanguage, to target: PhotoNote.NoteLanguage) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        error = nil
        statusText = nil
        isTranslating = true
        pendingText = trimmed
        pendingTargetDisplayName = target.displayName

        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        let targetLanguage = Locale.Language(identifier: target.rawValue)

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            pendingContinuation = continuation
            if configuration?.source == sourceLanguage, configuration?.target == targetLanguage {
                // Samma språkpar som förra gången — `invalidate()` stegar upp
                // configurationens interna version, vilket räcker för att
                // SwiftUI ska köra `.translationTask`s closure igen med den
                // nya `pendingText`en.
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
            }
        }
    }

    /// Anropas från `.translationTask(configuration:) { session in ... }` i
    /// `DictationPanelView` varje gång `configuration` ändras/ogiltigförklaras.
    /// Löser in den väntande `translate(_:from:to:)`-anropets continuation.
    func performPendingTranslation(using session: sending TranslationSession) async {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        let text = pendingText
        defer { isTranslating = false }

        do {
            if let source = session.sourceLanguage, let target = session.targetLanguage {
                let availability = await LanguageAvailability().status(from: source, to: target)
                switch availability {
                case .unsupported:
                    throw TranslationError.unsupportedLanguagePairing
                case .supported:
                    // Modellen finns men är inte nedladdad än.
                    statusText = "Laddar ner språkmodell (\(pendingTargetDisplayName))…"
                case .installed:
                    break
                @unknown default:
                    break
                }
            }
            // Laddar ner ev. saknad modell (no-op om redan installerad).
            try await session.prepareTranslation()
            statusText = nil
            let response = try await session.translate(text)
            continuation.resume(returning: response.targetText)
        } catch {
            statusText = nil
            self.error = Self.swedishErrorMessage(error)
            continuation.resume(returning: "")
        }
    }

    private static func swedishErrorMessage(_ error: Error) -> String {
        switch error {
        case TranslationError.unsupportedSourceLanguage:
            return "Källspråket stöds inte av Apples översättning på den här enheten."
        case TranslationError.unsupportedTargetLanguage:
            return "Målspråket stöds inte av Apples översättning på den här enheten."
        case TranslationError.unsupportedLanguagePairing:
            return "Den här språkkombinationen stöds inte av Apples översättning."
        case TranslationError.unableToIdentifyLanguage:
            return "Kunde inte identifiera språket i texten."
        case TranslationError.nothingToTranslate:
            return "Ingen text att översätta."
        case TranslationError.notInstalled:
            return "Språkmodellen är inte nedladdad och kunde inte laddas ner just nu."
        case TranslationError.internalError:
            return "Ett internt fel uppstod i Apples översättningsmotor."
        default:
            return "Översättning misslyckades: \(error.localizedDescription)"
        }
    }
}
