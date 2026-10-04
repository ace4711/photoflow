import AppIntents
import Foundation

/// Fas 3f: laser upp status for den pagaende/senaste sessionen via en
/// talad/skriven dialog — aktuellt steg, antal bilder, antal ogranskade och
/// senaste matchade adress. Ingen `openAppWhenRun` — ren fraga, andrar inget.
/// Fas 6: nar ingen session ar inladdad i minnet fragar den istallet
/// historikregistret (`SessionHistoryStore`) sa svaret blir mer an bara
/// "ingen session pagar".
struct SessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Status för PhotoFlow"
    static let description = IntentDescription(
        "Berättar vad PhotoFlow gör just nu: aktuellt steg, antal bilder, antal ogranskade och senaste matchade adress."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let pipeline = AppServices.shared.pipeline else {
            return .result(dialog: "PhotoFlow är inte igång.")
        }

        let stepTitle = pipeline.currentStep.title
        let total = pipeline.allPhotos.count

        guard total > 0 else {
            if pipeline.isRunning {
                return .result(dialog: "PhotoFlow: \(stepTitle). Inga bilder inlästa än.")
            }
            // Fas 6: aven utan en pagaende/inladdad session i minnet kan vi
            // nu saga nagot mer anvandbart an "ingen session pagar" genom
            // att fraga historikregistret (SessionHistoryStore) — t.ex. hur
            // manga bilder som star ogranskade sedan sist, over ALLA kanda
            // sessioner, inte bara den som rakar vara inladdad just nu.
            let history = SessionHistoryStore.load()
            guard !history.isEmpty else {
                return .result(dialog: "PhotoFlow är redo. Ingen session pågår just nu.")
            }
            let unreviewedTotal = history.reduce(0) { $0 + $1.unreviewedCount }
            let dialog: IntentDialog = unreviewedTotal > 0
                ? "PhotoFlow är redo. Ingen session pågår just nu, men \(unreviewedTotal) bilder står ogranskade över \(history.count) tidigare session(er)."
                : "PhotoFlow är redo. Ingen session pågår just nu. \(history.count) tidigare session(er) i historiken, alla granskade."
            return .result(dialog: dialog)
        }

        let unreviewed = pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count
        let address = pipeline.matchedAddress ?? "ingen adress hittad än"

        return .result(dialog: "PhotoFlow: \(stepTitle). \(total) bilder, \(unreviewed) ogranskade. Senaste adress: \(address).")
    }
}
