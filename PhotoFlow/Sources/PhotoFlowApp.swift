import SwiftUI

@main
struct PhotoFlowApp: App {
    @StateObject private var pipeline = PipelineState()
    // Fas 3e: flyttad hit från `ContentView` så både huvudfönstret och
    // `MenuBarExtra`-menyn delar samma bevaknings-/pipeline-state (se
    // `ContentView`s klasskommentar för `RunnerWrapper`).
    @StateObject private var runner = RunnerWrapper()
    @ObservedObject private var settings = AppSettings.shared

    /// Samma UserDefaults-nyckel som `AppSettings.showMenuBarExtra`, men
    /// deklarerad direkt som `@AppStorage` här i stället för proxad via
    /// `$settings.showMenuBarExtra`. Nödvändigt: att binda
    /// `MenuBarExtra(isInserted:)` mot en `Binding` som går via en
    /// `@ObservedObject`-klass (`AppSettings`, en vanlig klass med
    /// `@AppStorage`-properties men INGEN `@Published`) gav en oändlig
    /// uppdateringsloop (`AppGraph.graphDidChange()` → om och om igen,
    /// verifierat i scratchpad: 97 % CPU/hängning respektive
    /// `EXC_BAD_ACCESS`/stack-overflow under `xcodebuild test`, som
    /// startar hela appen som testvärd via `TEST_HOST`). Ett `@AppStorage`
    /// direkt på `App`-structen är däremot den avsedda, native användningen
    /// av property wrappern och orsakar ingen loop.
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    /// Namngiven `WindowGroup`-id så menyradens "Öppna PhotoFlow" kan öppna
    /// huvudfönstret igen via `openWindow(id:)` om användaren stängt det —
    /// utan en `MenuBarExtra` (eller annan scen) hade appen annars avslutats
    /// automatiskt när sista fönstret stängs.
    private static let mainWindowID = "main"
    /// Fönster-id för bildspelsredigeraren (se `ReelWindow.id`).
    private static let reelWindowID = ReelWindow.id

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(runner: runner)
                .environmentObject(pipeline)
                .frame(minWidth: 1200, minHeight: 800)
                .task {
                    await startupChecks()
                }
                // Fas 7: dubbelklick på en .photoflownotes-fil i Finder (eller
                // "Öppna med" → PhotoFlow) — se CFBundleDocumentTypes i
                // project.yml. `DashboardView` observerar `pendingFieldNotesImportURL`
                // och kör själva importen (samma väg som verktygsfältsknappen).
                .onOpenURL { url in
                    pipeline.pendingFieldNotesImportURL = url
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)

        // Objektfilm: eget fönster per källa. Öppnas från dashboardens verktygsfält och Historik
        // med `openWindow(id: "reel", value: ReelLaunchRequest)`.
        WindowGroup("Bildspel", id: Self.reelWindowID, for: ReelLaunchRequest.self) { $request in
            ReelEditorView(request: request ?? ReelLaunchRequest())
        }
        .defaultSize(width: 1200, height: 900)

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarExtraContent(pipeline: pipeline, runner: runner, mainWindowID: Self.mainWindowID)
        } label: {
            MenuBarExtraLabel(watcher: runner.watcher, pipeline: pipeline)
        }
    }

    private func startupChecks() async {
        // Fas 3f: registrera denna app-instans state hos `AppServices` sa App
        // Intents (StartPipelineIntent m.fl., se Sources/Intents/) kan na
        // samma `runner`/`pipeline` som resten av appen. Kors har (i stallet
        // for direkt i `body`) eftersom ett void-statement i `body` inte kan
        // stå i `WindowGroup`s @SceneBuilder-context ("type '()' cannot
        // conform to 'Scene'") — `.task` racker gott, intents kraver aldrig
        // att AppServices ar registrerad innan fonstret ens hunnit visas.
        AppServices.shared.register(pipeline: pipeline, runner: runner)

        // Fas 6: rensa (tyst, ingen dialog) sessionshistorikposter vars
        // outputmapp inte längre finns på disk — se
        // `SessionHistoryStore.pruneMissingOutputDirectories`s dokkommentar.
        SessionHistoryStore.pruneMissingOutputDirectories()

        // Startkontrollen (mappar, kalender, verktyg, Lightroom) ersätter den
        // tidigare verktygsvarningen: öppnas av sig själv bara om något blockerar,
        // annars syns resultatet i verktygsfältet. Läser bara — begär ingen
        // behörighet (se nedan).
        let preflight = PreflightModel.shared
        let report = await preflight.run(includeTools: true)
        if !report.blockers.isEmpty {
            preflight.isPresented = true
        }

        // Behörigheter begärs INTE vid appstart. Kalenderåtkomst frågas när
        // kalendersteget faktiskt körs (eller via knappen i Inställningar), och
        // taligenkänning när dikteringspanelen öppnas första gången. Att fråga
        // i förväg gav en dialog vid varje start, innan användaren ens valt en
        // mapp — och dialogen säger mer när man ser vad den ska användas till.

        // Notisbehörighet begärs INTE här — se `NotificationService`s
        // klasskommentar: den begärs lat, första gången en notis faktiskt
        // ska skickas (i praktiken: första gången pipeline-läget används).
        NotificationService.shared.onReviewNowRequested = { [weak pipeline] in
            pipeline?.reviewRequestedFromNotification = true
        }
    }
}

/// Ikonen i menyraden — kamera i vila, öga när bevakningen är aktiv, en
/// utropstecken-cirkel när pipelinen väntar på att användaren ska granska
/// (Fas 5: tidigare visade ikonen bara bevaknings-läget, aldrig att
/// resultatet stod och väntade — man fick öppna huvudfönstret för att se
/// det). En egen liten `View` (i stället för att bygga `Image` direkt inline
/// i `MenuBarExtra`s `label`-closure) så `@ObservedObject`-egenskaperna
/// faktiskt ger en prenumeration SwiftUI kan diffa mot; annars läses värdena
/// bara en gång och ikonen skulle aldrig uppdateras.
private struct MenuBarExtraLabel: View {
    @ObservedObject var watcher: WatchService
    @ObservedObject var pipeline: PipelineState

    var body: some View {
        if MenuBarStatus.needsAttention(pipeline) {
            Image(systemName: "exclamationmark.circle.fill")
        } else {
            Image(systemName: watcher.isWatching ? "eye.fill" : "camera")
        }
    }
}

/// Delad statuslogik mellan menyradens ikon och dess textrad (Fas 5) — en
/// enda källa till "väntar det något på användaren?" så de två aldrig kan gå
/// isär.
private enum MenuBarStatus {
    static func needsAttention(_ pipeline: PipelineState) -> Bool {
        pipeline.stepStatuses[.manualReview]?.phase == .needsAttention
    }
}

/// Menyinnehållet: status, starta/stoppa bevakning, öppna appen/outputmappen,
/// avsluta.
private struct MenuBarExtraContent: View {
    @ObservedObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    let mainWindowID: String

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = AppSettings.shared

    private var watcher: WatchService { runner.watcher }

    var body: some View {
        Text(statusText)

        Divider()

        Button(watcher.isWatching ? "Stoppa bevakning" : "Starta bevakning") {
            if watcher.isWatching {
                runner.stopWatchingForSDCards()
            } else {
                runner.startWatchingForSDCards()
            }
        }

        Button("Öppna PhotoFlow") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: mainWindowID)
        }

        Button("Öppna outputmapp") {
            openOutputFolder()
        }
        .disabled(outputFolder == nil)

        Divider()

        Button("Avsluta") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Fas 5: speglar nu det faktiska pipeline-läget (steg + antal) i stället
    /// för att bara visa bevaknings-status — tidigare uppdaterades texten
    /// inte alls medan en körning pågick (dokumenterat som kvarstående i
    /// Fas 3e). Prioritetsordning: väntar på granskning (viktigast — kräver
    /// användaren) > körning pågår > bevakningsstatus.
    private var statusText: String {
        if MenuBarStatus.needsAttention(pipeline) {
            let unreviewed = pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count
            return unreviewed > 0
                ? "Väntar på granskning · \(unreviewed) bilder"
                : "Väntar på granskning"
        }

        if pipeline.isRunning {
            let step = pipeline.currentStep.title
            if pipeline.isPaused {
                return "Pausad · \(step)"
            }
            if pipeline.totalFiles > 0 {
                return "\(step) · \(pipeline.currentFileIndex)/\(pipeline.totalFiles)"
            }
            return step
        }

        guard watcher.isWatching else { return "Bevakning avstängd" }
        return watcher.newFilesFound > 0
            ? "Bevakar · \(watcher.newFilesFound) nya"
            : "Bevakar · 0 nya"
    }

    private var outputFolder: URL? {
        let folder = settings.outputDirectory ?? settings.inputDirectory?.appendingPathComponent("processed")
        guard let folder, FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    private func openOutputFolder() {
        guard let outputFolder else { return }
        NSWorkspace.shared.open(outputFolder)
    }
}
