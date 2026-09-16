import AppIntents
import Foundation

/// Fas 3f: oppnar PhotoFlow i granskningslaget for aktuell session. Aterbrukar
/// samma mekanism som notisknappen "Granska nu" fran Fas 3e
/// (`NotificationService`): satter `PipelineState.reviewRequestedFromNotification`,
/// som `DashboardView` redan observerar for att vaxla till granskningsvyn —
/// ingen ny koppling behovdes.
struct ShowReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Granska bilder i PhotoFlow"
    static let description = IntentDescription("Oppnar PhotoFlow i granskningslaget for den aktuella sessionen.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let pipeline = AppServices.shared.pipeline else {
            return .result(dialog: "PhotoFlow kunde inte startas.")
        }

        guard !pipeline.allPhotos.isEmpty else {
            return .result(dialog: "Det finns inga bilder att granska an.")
        }

        pipeline.reviewRequestedFromNotification = true
        return .result(dialog: "Oppnar granskning i PhotoFlow.")
    }
}
