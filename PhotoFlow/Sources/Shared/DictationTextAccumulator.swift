import Foundation

/// Ren, testbar textlogik för `DictationTranscriber`-baserad diktering —
/// utbruten ur macOS-appens `DictationService` (Fas 3c) till `Sources/Shared`
/// i Fas 7 så samma logik kan återanvändas av `PhotoFlowField` (iOS) i
/// stället för att skrivas om från grunden. Ingen `Speech`/`AVFoundation`-
/// import behövs här — bara ren `String`-hantering, se `DictationService`s
/// (macOS) och den kommande fält-dikteringstjänstens (iOS) klasskommentarer
/// för hur `SpeechAnalyzer`/`DictationTranscriber` faktiskt anropas på
/// respektive plattform.
enum DictationTextAccumulator {
    /// Stop words that end dictation (case-insensitive).
    static let stopWords: Set<String> = ["stopp", "stop", "stopp.", "stop."]

    /// Given den hittills ackumulerade slutgiltiga texten och ett nytt
    /// resultats text/`isFinal`-flagga: returnerar det uppdaterade
    /// `(finalizedText, volatileText)`-paret. Varje `DictationTranscriber`-
    /// resultats `text` är bara den NYA textbiten sedan senaste finalisering,
    /// inte hela sessionens text från början (verifierat mot en riktig
    /// körning, se `DictationService`s klasskommentar) — därför läggs
    /// `finalizedText` till, ersätts inte.
    static func accumulate(
        finalizedText: String, volatileText: String, newText: String, isFinal: Bool
    ) -> (finalizedText: String, volatileText: String) {
        if isFinal {
            return (finalizedText + newText, "")
        } else {
            return (finalizedText, newText)
        }
    }

    /// Om `combined`s sista mellanslagsseparerade ord (skiftlägesokänsligt)
    /// är ett stoppord: returnerar texten med det ordet borttaget. `nil` om
    /// inget stoppord hittades.
    static func stripTrailingStopWord(from combined: String, stopWords: Set<String> = DictationTextAccumulator.stopWords) -> String? {
        let words = combined.split(separator: " ")
        guard let last = words.last, stopWords.contains(last.lowercased()) else { return nil }
        return words.dropLast().joined(separator: " ")
    }
}
