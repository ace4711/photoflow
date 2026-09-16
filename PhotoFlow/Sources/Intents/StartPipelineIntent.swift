import AppIntents
import Foundation

/// Fas 3f: startar PhotoFlow-pipelinen fran Genvagar/Spotlight/Siri.
/// `openAppWhenRun = true` — pipelinen kors i huvudappens process (det finns
/// ingen separat App Intents-extension i det har projektet, se
/// `project.yml`), och anvandaren ska se dashboarden kora precis som vid en
/// manuell start.
struct StartPipelineIntent: AppIntent {
    static let title: LocalizedStringResource = "Bearbeta bilder med PhotoFlow"
    static let description = IntentDescription(
        "Startar PhotoFlow-pipelinen (DNG-konvertering, HDR, kalendermatchning, metadata) for en mapp med NEF-filer."
    )
    static let openAppWhenRun: Bool = true

    /// Mapp med NEF-filer. Standard (nar inget valts): appens konfigurerade
    /// inputmapp (`AppSettings.shared.inputDirectory`) — motsvarar samma
    /// mapp dashboardens egen "Valj mapp"-knapp normalt pekar pa.
    @Parameter(
        title: "Mapp",
        description: "Mapp med NEF-filer att bearbeta. Lamna tom for att anvanda den mapp som ar konfigurerad i PhotoFlow installningar.",
        supportedContentTypes: [.folder]
    )
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Bearbeta bilder i \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runner = AppServices.shared.runner else {
            return .result(dialog: "PhotoFlow kunde inte startas.")
        }

        let inputDir = folder?.fileURL ?? AppSettings.shared.inputDirectory
        guard let inputDir else {
            return .result(dialog: "Ingen mapp vald, och ingen inputmapp ar konfigurerad i PhotoFlow installningar.")
        }

        runner.start(inputDir: inputDir, outputDir: AppSettings.shared.outputDirectory)
        return .result(dialog: "Startar PhotoFlow-bearbetning av \(inputDir.lastPathComponent).")
    }
}
