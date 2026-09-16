import SwiftUI

@main
struct PhotoFlowApp: App {
    @StateObject private var pipeline = PipelineState()
    // Fas 3e: flyttad hit från `ContentView` så både huvudfönstret och
    // `MenuBarExtra`-menyn delar samma bevaknings-/pipeline-state (se
    // `ContentView`s klasskommentar för `RunnerWrapper`).
    @StateObject private var runner = RunnerWrapper()
    @StateObject private var deps = DependencyManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showDependencyAlert = false

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

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(runner: runner)
                .environmentObject(pipeline)
                .frame(minWidth: 1200, minHeight: 800)
                .task {
                    await startupChecks()
                }
                .alert("Verktyg saknas", isPresented: $showDependencyAlert) {
                    Button("Öppna Inställningar") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    Button("Fortsätt ändå", role: .cancel) {}
                } message: {
                    let missing = deps.checks
                        .filter { $0.status == .missing && $0.importance == .required }
                        .map(\.name)
                    Text("Följande verktyg behövs men saknas:\n\(missing.joined(separator: ", "))\n\nÖppna Inställningar → System för att installera.")
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarExtraContent(runner: runner, mainWindowID: Self.mainWindowID)
        } label: {
            MenuBarExtraLabel(watcher: runner.watcher)
        }
    }

    private func startupChecks() async {
        // Run dependency check
        deps.runChecks()

        // Wait for check to finish
        while deps.isChecking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Show alert if critical tools are missing
        if deps.hasMissing {
            showDependencyAlert = true
        }

        // Request permissions
        if AppSettings.shared.calendarMatchEnabled {
            let _ = await CalendarService.shared.requestAccess()
        }
        DictationService.requestAuthorizationOnce()

        // Notisbehörighet begärs INTE här — se `NotificationService`s
        // klasskommentar: den begärs lat, första gången en notis faktiskt
        // ska skickas (i praktiken: första gången pipeline-läget används).
        NotificationService.shared.onReviewNowRequested = { [weak pipeline] in
            pipeline?.reviewRequestedFromNotification = true
        }
    }
}

/// Ikonen i menyraden — kamera i vila, öga när bevakningen är aktiv.
/// En egen liten `View` (i stället för att bygga `Image` direkt inline i
/// `MenuBarExtra`s `label`-closure) så `@ObservedObject var watcher`
/// faktiskt ger en prenumeration SwiftUI kan diffa mot; annars läses
/// `watcher.isWatching` bara en gång och ikonen skulle aldrig uppdateras.
private struct MenuBarExtraLabel: View {
    @ObservedObject var watcher: WatchService

    var body: some View {
        Image(systemName: watcher.isWatching ? "eye.fill" : "camera")
    }
}

/// Menyinnehållet: status, starta/stoppa bevakning, öppna appen/outputmappen,
/// avsluta.
private struct MenuBarExtraContent: View {
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

    private var statusText: String {
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
