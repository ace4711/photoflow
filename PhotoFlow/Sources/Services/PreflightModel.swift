import AppKit
import EventKit

/// Kör startkontrollen (`Preflight`) mot appens riktiga tillstånd och utför
/// åtgärdsknapparna. Ägs av `DashboardView`, `PhotoFlowApp.startupChecks` och
/// Inställningar → Mappar via `shared`.
///
/// Kontrollen körs om av sig själv (med en kort fördröjning så att en serie
/// ändringar bara ger en körning) när en disk ansluts eller matas ut, när
/// appen blir aktiv igen och när en inställning ändras. Verktygen (som startar
/// externa processer för att läsa versionsnummer) kontrolleras bara vid start
/// och när användaren trycker "Kontrollera igen".
@MainActor
final class PreflightModel: ObservableObject {
    static let shared = PreflightModel()

    @Published private(set) var report: Preflight.Report = .empty
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?
    /// Sätts när kontrollen ska visas (vid start med en blockerande brist, eller
    /// när Kör/bevakning stoppades av en) — `DashboardView` visar arket.
    @Published var isPresented = false
    /// Resultat av den senaste åtgärden, visas i arket (t.ex. "Starta om Lightroom").
    @Published var actionMessage: String?

    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoFlow")
    }

    static var lightroomPluginLink: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin")
    }

    static let lightroomAppPath = "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app"
    private static let calendarPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRun() }
            })
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, UserDefaults.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRun() }
            })
        }
    }

    // MARK: - Körning

    /// Kör om kontrollen strax — samlar ihop täta händelser (flera inställningar
    /// som sparas på en gång, en disk som monteras med flera volymer).
    func scheduleRun() {
        guard lastRun != nil else { return }  // inte förrän den första körningen gjorts
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    @discardableResult
    func run(includeTools: Bool = false) async -> Preflight.Report {
        isRunning = true
        defer { isRunning = false }
        if includeTools || DependencyManager.shared.checks.isEmpty {
            await DependencyManager.shared.runChecksAndWait()
        }
        let input = gatherInput()
        let result = await Task.detached { Preflight.evaluate(input, probe: .live) }.value
        report = result
        lastRun = Date()
        return result
    }

    /// Kör kontrollen och visar den om något blockerar. Returnerar `true` om
    /// Kör/bevakning INTE ska starta.
    func blocksStart() async -> Bool {
        let result = await run()
        if !result.blockers.isEmpty {
            isPresented = true
            return true
        }
        return false
    }

    private func gatherInput() -> Preflight.Input {
        let settings = AppSettings.shared
        return Preflight.Input(
            inputDir: settings.inputDirectory,
            outputDir: settings.outputDirectory,
            supportDir: Self.supportDirectory,
            lightroomPluginLink: Self.lightroomPluginLink,
            lightroomInstalled: FileManager.default.fileExists(atPath: Self.lightroomAppPath),
            sdCards: settings.sdCardSearchPaths.map(\.lastPathComponent),
            calendar: gatherCalendar(settings),
            tools: gatherTools(settings),
            modelAvailable: BookingTitleParser.isModelAvailable,
            aiDescriptionsEnabled: settings.aiTaggingEnabled && settings.aiDescriptionsEnabled
        )
    }

    private func gatherCalendar(_ settings: AppSettings) -> Preflight.CalendarInput {
        let access: Preflight.CalendarAccess
        switch CalendarService.authorizationStatus {
        case .fullAccess: access = .full
        case .writeOnly: access = .writeOnly
        case .denied, .restricted: access = .denied
        default: access = .notDetermined
        }
        var input = Preflight.CalendarInput(
            enabled: settings.calendarMatchEnabled, access: access,
            selected: settings.calendarNames, available: [],
            recentEventCount: 0, recentWithoutAddress: []
        )
        guard input.enabled, access == .full else { return input }
        input.available = CalendarService.shared.availableCalendarNames()
        let events = CalendarService.shared.previewEvents(daysBack: input.recentDays)
        input.recentEventCount = events.count
        input.recentWithoutAddress = events.compactMap { event in
            let title = event.title ?? ""
            return CalendarService.extractAddress(from: title) == nil ? title : nil
        }
        return input
    }

    private func gatherTools(_ settings: AppSettings) -> [Preflight.ToolInput] {
        DependencyManager.shared.checks.compactMap { check in
            // OpenCV är valfritt, utom när den äldre OpenCV-motorn är vald för HDR.
            let required = check.importance == .required
                || (check.name.hasPrefix("OpenCV") && settings.hdrMergeEnabled && settings.hdrEngine == "opencv")
            guard required else { return nil }
            let ok = check.status != .missing
            return Preflight.ToolInput(
                name: check.name, required: true, ok: ok,
                detail: ok ? [check.description, check.version].compactMap { $0 }.joined(separator: " · ") : check.detail
            )
        }
    }

    // MARK: - Åtgärder

    /// Utför de åtgärder som inte rör pipelinens tillstånd. Välj mapp och
    /// Inställningar-flikar hanteras av `DashboardView`, som äger det tillståndet.
    func perform(_ fix: Preflight.Fix) async {
        actionMessage = nil
        switch fix {
        case .createFolder(let url):
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                actionMessage = "Skapade \(url.path)"
            } catch {
                actionMessage = "Kunde inte skapa mappen: \(error.localizedDescription)"
            }
        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .relinkLightroomPlugin:
            relinkLightroomPlugin()
        case .requestCalendarAccess:
            let granted = await CalendarService.shared.requestAccess()
            if !granted {
                actionMessage = "Åtkomst gavs inte. Slå på den under Systeminställningar → Integritet och säkerhet → Kalendrar."
            }
        case .openCalendarPrivacy:
            NSWorkspace.shared.open(Self.calendarPrivacyURL)
        case .chooseInput, .chooseOutput, .openSettings:
            return
        }
        await run()
    }

    /// Länkar in ett valt `PhotoFlowLR.lrplugin` i Lightrooms Modules-mapp. Ersätter
    /// bara en befintlig symlänk — en riktig mapp på samma plats lämnas orörd.
    private func relinkLightroomPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Välj PhotoFlowLR.lrplugin (ligger i projektmappen)"
        panel.prompt = "Länka in"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let fm = FileManager.default
        guard chosen.pathExtension == "lrplugin",
              fm.fileExists(atPath: chosen.appendingPathComponent("Info.lua").path) else {
            actionMessage = "\"\(chosen.lastPathComponent)\" är inte ett Lightroom-plugin (ingen Info.lua)."
            return
        }
        let link = Self.lightroomPluginLink
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                actionMessage = "Det finns redan en riktig mapp på \(link.path). Ta bort den i Finder först."
                return
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: chosen)
            actionMessage = "Pluginet är länkat. Starta om Lightroom Classic så laddas det."
        } catch {
            actionMessage = "Kunde inte länka pluginet: \(error.localizedDescription)"
        }
    }
}
