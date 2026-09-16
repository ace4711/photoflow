import AppIntents
import Foundation

/// Fas 3f: laser upp status for den pagaende/senaste sessionen via en
/// talad/skriven dialog — aktuellt steg, antal bilder, antal ogranskade och
/// senaste matchade adress. Ingen `openAppWhenRun` — ren fraga, andrar inget.
/// Fas 6: nar ingen session ar inladdad i minnet fragar den istallet
/// historikregistret (`SessionHistoryStore`) sa svaret blir mer an bara
/// "ingen session pagar".
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
            if pipeline.isRunning {
                return .result(dialog: "PhotoFlow: \(stepTitle). Inga bilder inlasta an.")
            }
            // Fas 6: aven utan en pagaende/inladdad session i minnet kan vi
            // nu saga nagot mer anvandbart an "ingen session pagar" genom
            // att fraga historikregistret (SessionHistoryStore) — t.ex. hur
            // manga bilder som star ogranskade sedan sist, over ALLA kanda
            // sessioner, inte bara den som rakar vara inladdad just nu.
            let history = SessionHistoryStore.load()
            guard !history.isEmpty else {
                return .result(dialog: "PhotoFlow ar redo. Ingen session pagar just nu.")
            }
            let unreviewedTotal = history.reduce(0) { $0 + $1.unreviewedCount }
            let dialog: IntentDialog = unreviewedTotal > 0
                ? "PhotoFlow ar redo. Ingen session pagar just nu, men \(unreviewedTotal) bilder star ogranskade over \(history.count) tidigare session(er)."
                : "PhotoFlow ar redo. Ingen session pagar just nu. \(history.count) tidigare session(er) i historiken, alla granskade."
            return .result(dialog: dialog)
        }

        let unreviewed = pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count
        let address = pipeline.matchedAddress ?? "ingen adress hittad an"

        return .result(dialog: "PhotoFlow: \(stepTitle). \(total) bilder, \(unreviewed) ogranskade. Senaste adress: \(address).")
    }
}
