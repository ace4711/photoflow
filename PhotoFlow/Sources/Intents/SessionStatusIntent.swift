import AppIntents
import Foundation

/// Fas 3f: laser upp status for den pagaende/senaste sessionen via en
/// talad/skriven dialog — aktuellt steg, antal bilder, antal ogranskade och
/// senaste matchade adress. Ingen `openAppWhenRun` — ren fraga, andrar inget.
struct SessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Status for PhotoFlow"
    static let description = IntentDescription(
        "Berattar vad PhotoFlow gor just nu: aktuellt steg, antal bilder, antal ogranskade och senaste matchade adress."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let pipeline = AppServices.shared.pipeline else {
            return .result(dialog: "PhotoFlow ar inte igang.")
        }

        let stepTitle = pipeline.currentStep.title
        let total = pipeline.allPhotos.count

        guard total > 0 else {
            let dialog: IntentDialog = pipeline.isRunning
                ? "PhotoFlow: \(stepTitle). Inga bilder inlasta an."
                : "PhotoFlow ar redo. Ingen session pagar just nu."
            return .result(dialog: dialog)
        }

        let unreviewed = pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count
        let address = pipeline.matchedAddress ?? "ingen adress hittad an"

        return .result(dialog: "PhotoFlow: \(stepTitle). \(total) bilder, \(unreviewed) ogranskade. Senaste adress: \(address).")
    }
}
