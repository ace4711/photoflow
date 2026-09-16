import SwiftUI

@main
struct PhotoFlowApp: App {
    @StateObject private var pipeline = PipelineState()
    @StateObject private var deps = DependencyManager.shared
    @State private var showDependencyAlert = false

    var body: some Scene {
        WindowGroup {
            ContentView()
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
