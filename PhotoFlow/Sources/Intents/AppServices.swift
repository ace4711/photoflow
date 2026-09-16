import Foundation

/// Fas 3f: central atkomstpunkt sa App Intents (som systemet kan skapa/kora
/// helt fristaende fran nagon vy — de har ingen egen kontext att fa
/// `RunnerWrapper`/`PipelineState` injicerat via) kan na EXAKT samma
/// bevaknings-/pipeline-state som den korande app-instansen anvander,
/// samma tanke som `RunnerWrapper` redan flyttades till app-scope for i
/// Fas 3e (se `ContentView`s klasskommentar).
///
/// `PhotoFlowApp.body` registrerar sig har direkt vid varje scen-evaluering
/// (idempotent — samma tva objekt varje gang sa lange appen kor). Referenserna
/// ar `weak` av tva skal: dels ager `PhotoFlowApp` originalen redan via
/// `@StateObject`, dels ska en intent som rakar kora medan appen redan har
/// avslutats aldrig kunna halla appens objekt vid liv i onodan.
///
/// Om appen inte kor an (kallt intent-anrop, t.ex. via Spotlight/Siri innan
/// PhotoFlow nagonsin startats den har sessionen) ar bada `nil` — intents som
/// INTE satter `openAppWhenRun = true` (se `ToggleWatchIntent`/
/// `SessionStatusIntent`) hanterar det genom att svara med en tydlig dialog
/// ("PhotoFlow ar inte igang") i stallet for att krascha eller tyst
/// misslyckas.
@MainActor
final class AppServices {
    static let shared = AppServices()
    private init() {}

    private(set) weak var pipeline: PipelineState?
    private(set) weak var runner: RunnerWrapper?

    func register(pipeline: PipelineState, runner: RunnerWrapper) {
        self.pipeline = pipeline
        self.runner = runner
    }
}
