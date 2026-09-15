import Foundation

@MainActor
class TranslationService: ObservableObject {
    @Published var isTranslating = false
    @Published var error: String?

    func translate(_ text: String, from source: PhotoNote.NoteLanguage, to target: PhotoNote.NoteLanguage) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        isTranslating = true
        error = nil
        defer { isTranslating = false }

        // Google Translate free endpoint (no API key needed for small volumes)
        let sourceLang = source.rawValue  // "sv" or "en"
        let targetLang = target.rawValue

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            error = "Kunde inte koda texten"
            return ""
        }

        let urlString = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(sourceLang)&tl=\(targetLang)&dt=t&q=\(encoded)"

        guard let url = URL(string: urlString) else {
            error = "Ogiltig URL"
            return ""
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                error = "Oversattning misslyckades (HTTP-fel)"
                return ""
            }

            // Response is a nested JSON array: [[["translated text","original text",...],...],...]
            let json = try JSONSerialization.jsonObject(with: data)
            guard let outerArray = json as? [Any],
                  let sentences = outerArray.first as? [[Any]] else {
                error = "Ovantad respons"
                return ""
            }

            // Concatenate all translated sentence parts
            let translated = sentences.compactMap { parts -> String? in
                guard let translatedPart = parts.first as? String else { return nil }
                return translatedPart
            }.joined()

            return translated

        } catch {
            self.error = "Oversattning misslyckades: \(error.localizedDescription)"
            return ""
        }
    }
}
