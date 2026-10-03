import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject var settings = AppSettings.shared
    // Startkontrollen: mappar, kalender, verktyg — se `Preflight`/`PreflightView`.
    @ObservedObject private var preflight = PreflightModel.shared
    @State private var showLog: Bool = true
    @State private var showReview: Bool = false
    @State private var showSettings: Bool = false
    // Fas 9: vilken flik Inställningar ska öppnas på — satt av ett stegkorts
    // infopopover ("Öppna inställningar"), 0 (Mappar) annars.
    @State private var settingsInitialTab: Int = 0
    // Fas 6: "Historik" i verktygsfältet — se SessionHistoryView.
    @State private var showHistory: Bool = false
    @State private var nefCount: Int = 0
    @State private var hasProcessedOutput: Bool = false
    // Fas 7: fältanteckningsimport — se importFieldNotes()/handleFieldNotesImport(at:).
    @State private var fieldNotesImportResult: FieldNotesImportResult?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        Group {
            if showReview {
                reviewContent
            } else {
                dashboardContent
            }
        }
        .toolbar {
            if showReview {
                reviewToolbarContent
            } else {
                dashboardToolbarContent
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(initialTab: settingsInitialTab)
                .frame(width: 700, height: 620)
        }
        .sheet(isPresented: $preflight.isPresented) {
            PreflightView(model: preflight, onFix: handlePreflightFix)
        }
        .sheet(isPresented: $showHistory) {
            SessionHistoryView(runner: runner, onOpened: { showReview = true })
        }
        .onAppear { refreshFileCount() }
        .onChange(of: pipeline.currentStep) { _, newStep in
            if showReview && newStep == .done {
                showReview = false
            }
        }
        .onChange(of: pipeline.reviewRequestedFromNotification) { _, requested in
            guard requested else { return }
            showReview = true
            pipeline.reviewRequestedFromNotification = false
        }
        .onChange(of: pipeline.pendingFieldNotesImportURL) { _, url in
            guard let url else { return }
            handleFieldNotesImport(at: url)
            pipeline.pendingFieldNotesImportURL = nil
        }
        .alert(
            fieldNotesImportResult?.title ?? "",
            isPresented: Binding(
                get: { fieldNotesImportResult != nil },
                set: { isPresented in if !isPresented { fieldNotesImportResult = nil } }
            ),
            presenting: fieldNotesImportResult
        ) { _ in
            Button("OK") { fieldNotesImportResult = nil }
        } message: { result in
            Text(result.message)
        }
        .onChange(of: settings.inputDirectoryPath) { _, _ in refreshFileCount() }
        .onChange(of: settings.outputDirectoryPath) { _, _ in refreshFileCount() }
        // Antalet på Kör-knappen: kortkopiering och körningar ändrar inputmappen,
        // och startkontrollen körs om när appen blir aktiv.
        .onChange(of: pipeline.isRunning) { _, _ in refreshFileCount() }
        .onChange(of: pipeline.stepStatuses[.copyToInput]?.phase) { _, _ in refreshFileCount() }
        .onChange(of: preflight.lastRun) { _, _ in refreshFileCount() }
        .onChange(of: showSettings) { _, showing in
            if !showing { refreshFileCount() }
        }
    }

    // MARK: - Dashboard content

    private var dashboardContent: some View {
        VStack(spacing: 12) {
            if let blocker = preflight.report.blockers.first {
                preflightBanner(blocker)
                    .padding(.horizontal, 20)
            }

            if settings.calendarMatchEnabled {
                AddressBanner()
                    .padding(.horizontal, 20)
            }

            // Ritas om var 5:e sekund så att prognoserna räknar ner medan något pågår.
            TimelineView(.periodic(from: .now, by: 5)) { context in
            let eta = pipeline.eta(now: context.date)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DashboardStep.allCases) { step in
                    let status = Self.withEstimate(pipeline.stepStatuses[step] ?? .idle, eta?.perStep[step])
                    StepCardView(
                        step: step,
                        status: status,
                        onTap: { handleStepTap(step) },
                        onRerun: { runner.rerunStep(step) },
                        // Fas 10: skickar bara de tre färdigräknade talen (O(1)
                        // läsningar från PipelineState) i stället för hela
                        // `pipeline.allPhotos` (upp till ~2100 `PhotoItem`) —
                        // se `CullStats`/`StepCardView`s doc-kommentar.
                        cullStats: (step == .manualReview && !pipeline.allPhotos.isEmpty)
                            ? CullStats(accepted: pipeline.acceptedCount, rejected: pipeline.rejectedCount, unreviewed: pipeline.unreviewedCount)
                            : nil,
                        onOpenSettings: { tab in
                            settingsInitialTab = tab
                            showSettings = true
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)

            if showLog {
                Divider()
                logPanel
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Review content (replaces dashboard, supports resize + fullscreen)

    @State private var showDeleteReviewConfirm: Bool = false

    private var reviewContent: some View {
        Group {
            if pipeline.currentStep == .culling || !settings.hdrMergeEnabled {
                PreviewCullView()
                    .environmentObject(runner)
            } else {
                BracketReviewView(runner: runner)
            }
        }
        .environmentObject(pipeline)
        .alert("Radera all granskningsdata?", isPresented: $showDeleteReviewConfirm) {
            Button("Radera", role: .destructive) {
                clearAllReviewData()
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Detta raderar alla gallringsbeslut (ja/nej) och dikterade anteckningar. Kan inte angras.")
        }
    }

    // MARK: - Dashboard toolbar (Fas 3g: riktiga verktygsfältsobjekt i stället
    // för en handbyggd HStack med egen `controlBackgroundColor`-bakgrund, som
    // annars krockar med Xcode 27:s automatiska Liquid Glass-fönsterdesign.)

    @ToolbarContentBuilder
    private var dashboardToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            folderButton(
                icon: "folder",
                label: "Input",
                path: settings.inputDirectory?.lastPathComponent,
                color: .blue,
                detail: nefCount > 0 ? "\(nefCount) NEF" : nil,
                alert: hasBlocker(prefix: "input.")
            ) {
                pickInputFolder()
            }

            folderButton(
                icon: "folder.fill",
                label: "Output",
                path: settings.outputDirectory?.lastPathComponent ?? pipeline.outputDirectory?.lastPathComponent,
                color: .green,
                detail: hasProcessedOutput ? "Bearbetat" : nil,
                alert: hasBlocker(prefix: "output.")
            ) {
                pickOutputFolder()
            }

            Button(action: { preflight.isPresented = true }) {
                HStack(spacing: 5) {
                    Image(systemName: PreflightView.icon(for: preflight.report.worst))
                        .foregroundStyle(PreflightView.color(for: preflight.report.worst))
                    Text(preflight.report.checks.isEmpty ? "Startkontroll" : preflight.report.summary)
                        .font(.caption)
                }
            }
            .help("Startkontroll — mappar, kalender, verktyg och Lightroom")
        }

        if pipeline.isRunning || pipeline.stepStatuses[.copyToInput]?.phase == .active {
            ToolbarItem(placement: .principal) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let eta = pipeline.eta(now: context.date)
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(Self.etaHeadline(eta, fallback: pipeline.currentStep.title, now: context.date))
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .monospacedDigit()
                    }
                    .help(Self.etaBreakdown(eta))
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if pipeline.isRunning {
                Button(action: { runner.togglePause() }) {
                    Label(
                        pipeline.isPaused ? "Fortsätt" : "Pausa",
                        systemImage: pipeline.isPaused ? "play.fill" : "pause.fill"
                    )
                }
            }

            runButton
            watchButton
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { withAnimation { showLog.toggle() } }) {
                Image(systemName: "text.alignleft")
            }
            .tint(showLog ? .accentColor : nil)
            .help("Visa/dölj logg")

            Button(action: { showHistory = true }) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Historik — tidigare sessioner")

            Button(action: { importFieldNotes() }) {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("Importera fältanteckningar… (.photoflownotes från PhotoFlow Fält)")

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("Inställningar")
        }
    }

    /// Kör-knappen är en handling, inte ett läge: den är blå (framträdande)
    /// bara när det finns bilder att köra, så att den inte ser "intryckt" ut.
    /// Förut hette den "Auto" och var alltid blå.
    @ViewBuilder
    private var runButton: some View {
        let button = Button(action: { startPipeline() }) {
            if pipeline.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Kör…")
                }
            } else {
                Label(nefCount > 0 ? "Kör \(nefCount) bilder" : "Kör", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .disabled(pipeline.isRunning || settings.inputDirectory == nil)
        .help(pipeline.isRunning
              ? "Pipelinen kör"
              : "Kör pipelinen nu på bilderna i inputmappen (slår också på minneskortsbevakningen)")
        if nefCount > 0 && !pipeline.isRunning {
            button.buttonStyle(.borderedProminent).tint(.accentColor)
        } else {
            button
        }
    }

    /// Bevakningen är ett läge: orange och ifylld när den är på.
    @ViewBuilder
    private var watchButton: some View {
        let on = pipeline.isWatchMode
        let button = Button(action: { toggleWatchMode() }) {
            Label(on ? "Bevakar" : "Bevaka", systemImage: on ? "eye.fill" : "eye")
                .labelStyle(.titleAndIcon)
        }
        .help(on
              ? "Bevakningen är på: nya minneskort och nya filer i inputmappen körs automatiskt. Klicka för att stänga av."
              : "Slå på bevakning: nya minneskort kopieras och körs automatiskt. Bilder som redan ligger i inputmappen körs med Kör.")
        if on {
            button.buttonStyle(.borderedProminent).tint(.orange)
        } else {
            button
        }
    }

    // MARK: - Review toolbar

    @ToolbarContentBuilder
    private var reviewToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: { showReview = false }) {
                Label("Tillbaka", systemImage: "chevron.left")
            }
        }

        ToolbarItem(placement: .principal) {
            Text(pipeline.currentStep == .culling || !settings.hdrMergeEnabled ? "Gallring" : "Bracket-granskning")
                .font(.system(.headline, design: .rounded))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Fas 10: cachade O(1)-räknare i stället för tre `.filter{}.count`
            // genomlöpningar av `pipeline.allPhotos` per omritning.
            StatPill(icon: "checkmark.circle.fill", count: pipeline.acceptedCount, color: .green)
            StatPill(icon: "xmark.circle.fill", count: pipeline.rejectedCount, color: .red)
            StatPill(icon: "questionmark.circle", count: pipeline.unreviewedCount, color: .gray)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button(action: { showDeleteReviewConfirm = true }) {
                Label("Radera granskningsdata", systemImage: "trash")
            }
            .tint(.red)
            .help("Radera alla gallringsbeslut och anteckningar")
        }
    }

    // MARK: - Folder button (toolbar)

    private func folderButton(icon: String, label: String, path: String?, color: Color, detail: String?, alert: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: alert ? "exclamationmark.triangle.fill" : icon)
                    .foregroundStyle(alert ? .red : color)
                VStack(alignment: .leading, spacing: 1) {
                    if let path {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    } else {
                        Text("Välj \(label.lowercased())mapp...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundStyle(color.opacity(0.8))
                    }
                }
            }
        }
        .help(path == nil ? "Välj \(label.lowercased())mapp" : path!)
    }

    // MARK: - Log panel

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Logg")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { copyLogToClipboard() }) {
                    Label("Kopiera", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Kopiera loggen till urklipp")
                Text("\(pipeline.logLines.count) rader")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(pipeline.logLines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.timeString)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(line.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(logColor(line.type))
                            }
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(minHeight: 200, maxHeight: 300)
                .onChange(of: pipeline.logLines.count) { _, _ in
                    if let last = pipeline.logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: - Actions

    private func pickInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Valj mappen med NEF-filer"
        panel.prompt = "Valj"
        if let dir = settings.inputDirectory {
            panel.directoryURL = dir
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.inputDirectory = url
            pipeline.inputDirectory = url
            refreshFileCount()
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Valj outputmapp"
        panel.prompt = "Valj"
        if let dir = settings.outputDirectory {
            panel.directoryURL = dir
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url
            pipeline.outputDirectory = url
        }
    }

    // MARK: - Fas 7: fältanteckningsimport

    private func importFieldNotes() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.photoFlowFieldNotes]
        panel.message = "Välj en .photoflownotes-fil (exporterad från PhotoFlow Fält)"
        panel.prompt = "Importera"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleFieldNotesImport(at: url)
    }

    private func handleFieldNotesImport(at url: URL) {
        guard let bundle = FieldNoteBundle.loadFrom(url) else {
            pipeline.appendLog("Kunde inte läsa fältanteckningsfilen \"\(url.lastPathComponent)\" — filen kanske inte är en giltig .photoflownotes-export.", type: .error)
            fieldNotesImportResult = .failure(
                "Filen \"\(url.lastPathComponent)\" kunde inte läsas som en fältanteckningsexport (.photoflownotes)."
            )
            return
        }
        guard let runner = runner.runner else { return }

        let summary = runner.importFieldNotes(bundle)

        // Applicera GPS-förslagen på matchande adresser (om någon) — samma väg
        // som en manuell rättning i AddressBanner (PipelineState.correctAddress),
        // så metadataskrivningen använder den riktiga positionen i stället för
        // den geokodade adressen.
        for corrected in summary.correctedAddresses {
            if let idx = pipeline.allMatchedAddresses.firstIndex(where: { $0.address == corrected.address }) {
                pipeline.correctAddress(at: idx, newAddress: corrected.address, coordinate: corrected.coordinate)
            }
        }

        fieldNotesImportResult = .success(summary)
    }

    private func handleStepTap(_ step: DashboardStep) {
        switch step {
        case .manualReview:
            if !pipeline.bracketGroups.isEmpty || !pipeline.allPhotos.isEmpty {
                // If HDR is disabled, go straight to culling
                if !settings.hdrMergeEnabled {
                    pipeline.currentStep = .culling
                }
                showReview = true
            }
        case .importToLightroom:
            if !pipeline.bracketGroups.isEmpty {
                runner.sendToLightroom(groups: pipeline.bracketGroups)
            }
        default:
            break
        }
    }

    private func toggleWatchMode() {
        guard !pipeline.isWatchMode else {
            setWatchMode(false)
            return
        }
        Task {
            if await preflight.blocksStart() {
                pipeline.appendLog("Bevakningen startades inte — startkontrollen hittade något som måste åtgärdas först.", type: .error)
                return
            }
            setWatchMode(true)
        }
    }

    private func setWatchMode(_ on: Bool) {
        pipeline.isWatchMode = on
        if pipeline.isWatchMode {
            runner.startWatchingForSDCards()
            for step in DashboardStep.allCases {
                if isStepEnabled(step) {
                    pipeline.updateStep(step, phase: .watching)
                }
            }
        } else {
            runner.stopWatchingForSDCards()
            for step in DashboardStep.allCases {
                let current = pipeline.stepStatuses[step]?.phase ?? .idle
                if current == .watching {
                    pipeline.updateStep(step, phase: .idle)
                }
            }
        }
    }

    private func startPipeline() {
        Task {
            if await preflight.blocksStart() {
                pipeline.appendLog("Startkontrollen hittade något som måste åtgärdas först — se Startkontroll.", type: .error)
                return
            }
            startPipelineUnchecked()
        }
    }

    private func startPipelineUnchecked() {
        // Always start SD card watching in auto mode
        runner.startWatchingForSDCards()

        let inputDir = pipeline.inputDirectory ?? settings.inputDirectory
        guard let inputDir else {
            // No input dir yet — watcher will trigger pipeline when SD card is found
            pipeline.appendLog("Vantar pa SD-kort eller inputmapp...", type: .info)
            pipeline.updateStep(.watchSources, phase: .watching)
            return
        }
        pipeline.inputDirectory = inputDir
        if pipeline.outputDirectory == nil {
            pipeline.outputDirectory = settings.outputDirectory
        }
        runner.start(inputDir: inputDir, outputDir: pipeline.outputDirectory ?? settings.outputDirectory)
    }

    private func isStepEnabled(_ step: DashboardStep) -> Bool {
        if !settings.hdrMergeEnabled && step == .createHDR { return false }
        if !settings.aiTaggingEnabled && step == .aiTagging { return false }
        if !settings.calendarMatchEnabled && (step == .findCalendarInfo || step == .writeIPTCTags) { return false }
        return true
    }

    // MARK: - Prognos

    private static func withEstimate(_ status: StepStatus, _ estimate: TimeInterval?) -> StepStatus {
        var copy = status
        copy.estimatedRemaining = estimate
        return copy
    }

    /// "Konvertera DNG · ~11 min kvar · allt klart ~16:45".
    private static func etaHeadline(_ eta: PipelineState.ETA?, fallback: String, now: Date) -> String {
        guard let eta, let current = eta.current else { return fallback }
        var parts = [current.title]
        if let left = eta.currentRemaining {
            parts.append("~\(StepTiming.format(left)) kvar")
        }
        if eta.remaining > 0, eta.perStep.count > 1 || eta.currentRemaining == nil {
            let finish = now.addingTimeInterval(eta.remaining).formatted(date: .omitted, time: .shortened)
            parts.append("allt klart ~\(finish)" + (eta.unknown.isEmpty ? "" : "+"))
        }
        return parts.joined(separator: " · ")
    }

    private static func etaBreakdown(_ eta: PipelineState.ETA?) -> String {
        guard let eta else { return "" }
        var lines = PipelineState.automaticSteps.compactMap { step in
            eta.perStep[step].map { "\(step.title): ~\(StepTiming.format($0))" }
        }
        if !eta.perStep.isEmpty {
            lines.append("Totalt kvar: ~\(StepTiming.format(eta.remaining)) (exklusive granskning)")
        }
        if !eta.unknown.isEmpty {
            lines.append("Inga tidigare tider för: \(eta.unknown.map(\.title).joined(separator: ", ")) — räknas inte med.")
        }
        lines.append("Prognosen bygger på tidigare körningar och takten hittills.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Startkontroll

    private func hasBlocker(prefix: String) -> Bool {
        preflight.report.blockers.contains { $0.id.hasPrefix(prefix) }
    }

    private func preflightBanner(_ blocker: Preflight.Check) -> some View {
        let others = preflight.report.blockers.count - 1
        return HStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.title + (others > 0 ? " (+\(others) till)" : ""))
                    .font(.body.weight(.semibold))
                Text(blocker.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Visa startkontroll") { preflight.isPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4), lineWidth: 1))
    }

    /// Åtgärder från startkontrollen som rör tillstånd den här vyn äger.
    private func handlePreflightFix(_ fix: Preflight.Fix) {
        switch fix {
        case .chooseInput:
            pickInputFolder()
            Task { await preflight.run() }
        case .chooseOutput:
            pickOutputFolder()
            Task { await preflight.run() }
        case .openSettings(let tab, _):
            preflight.isPresented = false
            // Ett ark i taget: vänta tills startkontrollen hunnit stängas.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                settingsInitialTab = tab
                showSettings = true
            }
        default:
            Task { await preflight.perform(fix) }
        }
    }

    private func refreshFileCount() {
        guard let inputDir = settings.inputDirectory else {
            nefCount = 0
            hasProcessedOutput = false
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? []
        var count = files.filter { $0.pathExtension.uppercased() == "NEF" }.count
        if count == 0 {
            let subdirs = files.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "processed" }
            for sub in subdirs {
                let subFiles = (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                count += subFiles.filter { $0.pathExtension.uppercased() == "NEF" }.count
            }
        }
        nefCount = count

        let outputDir = settings.outputDirectory ?? inputDir.appendingPathComponent("processed")
        hasProcessedOutput = FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("bracket_groups.json").path)
    }

    private func clearAllReviewData() {
        guard let outputDir = pipeline.outputDirectory ?? settings.outputDirectory else { return }

        // Delete cull decisions
        let cullFile = outputDir.appendingPathComponent("cull_decisions.json")
        try? FileManager.default.removeItem(at: cullFile)

        // Delete notes
        let notesFile = outputDir.appendingPathComponent("photo_notes.json")
        try? FileManager.default.removeItem(at: notesFile)

        // Reset in-memory state. allPhotos is the single source of truth for cull
        // decisions — BracketGroup only stores photoIDs, so resetting it here is
        // enough for both BracketReviewView and PreviewCullView to see the change.
        // Fas 10: går via `clearAllCullDecisions()` i stället för en manuell
        // per-index-loop, så PipelineState's cachade räknare (acceptedCount/
        // rejectedCount) nollställs korrekt och en väntande debounced
        // gallringsskrivning inte kan skriva tillbaka de precis raderade
        // besluten till disk efteråt.
        pipeline.clearAllCullDecisions()

        pipeline.appendLog("All granskningsdata raderad.", type: .warning)
    }

    private func copyLogToClipboard() {
        let text = pipeline.logLines.map { "[\($0.timeString)] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pipeline.appendLog("Logg kopierad till urklipp (\(pipeline.logLines.count) rader)", type: .info)
    }

    private func logColor(_ type: LogLine.LogType) -> Color {
        switch type {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

/// Resultatet av ett fältanteckningsimportförsök (Fas 7) — visas i en
/// `.alert` på `DashboardView` (se `handleFieldNotesImport(at:)`).
private enum FieldNotesImportResult {
    case success(FieldNotesImportSummary)
    case failure(String)

    var title: String {
        switch self {
        case .success: return "Fältanteckningar importerade"
        case .failure: return "Kunde inte importera fältanteckningar"
        }
    }

    var message: String {
        switch self {
        case .success(let summary):
            var lines = ["\(summary.totalNotes) anteckningar, \(summary.matchedPhotoCount) matchade bilder, \(summary.sessionNoteCount) sessionsanteckningar."]
            if !summary.correctedAddresses.isEmpty {
                let addresses = summary.correctedAddresses.map(\.address).joined(separator: ", ")
                lines.append("GPS-position rättad från fältanteckningarna för: \(addresses).")
            }
            return lines.joined(separator: "\n\n")
        case .failure(let message):
            return message
        }
    }
}
