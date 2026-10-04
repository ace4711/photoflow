import AppIntents
import Foundation

/// Fas 3f: slar av/pa SD-korts-/mappbevakningen. Satter INTE
/// `openAppWhenRun` (default `false`) — om PhotoFlow redan kor (huvudfonster
/// eller bara menyradslage, se Fas 3e) vaxlar den bevakningen utan att
/// tvinga fram/aktivera nagot fonster. Om appen inte kor alls startar
/// systemet den i bakgrunden for att kora intentet (samma app-process, ingen
/// separat extension i det har projektet), men UI kommer inte automatiskt i
/// forgrunden.
struct ToggleWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Starta/stoppa PhotoFlow-bevakning"
    static let description = IntentDescription("Slår på eller av SD-korts-/mappbevakningen i PhotoFlow.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runner = AppServices.shared.runner else {
            return .result(dialog: "PhotoFlow är inte igång.")
        }

        if runner.watcher.isWatching {
            runner.stopWatchingForSDCards()
            return .result(dialog: "PhotoFlow-bevakning avstängd.")
        } else {
            runner.startWatchingForSDCards()
            return .result(dialog: "PhotoFlow-bevakning startad.")
        }
    }
}
