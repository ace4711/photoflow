import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject var settings = AppSettings.shared
    @State private var showLog: Bool = true
    @State private var showReview: Bool = false
    @State private var showSettings: Bool = false
    @State private var nefCount: Int = 0
    @State private var hasProcessedOutput: Bool = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        Group {
            if showReview {
                reviewContent
            } else {
                dashboardContent
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .frame(width: 700, height: 620)
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
        .onChange(of: settings.inputDirectoryPath) { _, _ in refreshFileCount() }
        .onChange(of: settings.outputDirectoryPath) { _, _ in refreshFileCount() }
        .onChange(of: showSettings) { _, showing in
            if !showing { refreshFileCount() }
        }
    }

    // MARK: - Dashboard content

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            VStack(spacing: 12) {
                if settings.calendarMatchEnabled {
                    AddressBanner()
                        .padding(.horizontal, 20)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(DashboardStep.allCases) { step in
                        let status = pipeline.stepStatuses[step] ?? .idle
                        StepCardView(
                            step: step,
                            status: status,
                            onTap: { handleStepTap(step) },
                            onRerun: { runner.rerunStep(step) },
                            allPhotos: step == .manualReview ? pipeline.allPhotos : []
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer(minLength: 0)

                if showLog {
                    Divider()
                    logPanel
                }
            }
        }
    }

    // MARK: - Review content (replaces dashboard, supports resize + fullscreen)

    @State private var showDeleteReviewConfirm: Bool = false

    private var reviewContent: some View {
        VStack(spacing: 0) {
            // Thin top bar with back button
            HStack(spacing: 12) {
                Button(action: { showReview = false }) {
                    Label("Tillbaka", systemImage: "chevron.left")
                        .font(.system(.body, design: .rounded))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 24)

                Text(pipeline.currentStep == .culling || !settings.hdrMergeEnabled ? "Gallring" : "Bracket-granskning")
                    .font(.system(.headline, design: .rounded))

                Spacer()

                HStack(spacing: 8) {
                    StatPill(icon: "checkmark.circle.fill", count: pipeline.allPhotos.filter { $0.accepted }.count, color: .green)
                    StatPill(icon: "xmark.circle.fill", count: pipeline.allPhotos.filter { $0.rejected }.count, color: .red)
                    StatPill(icon: "questionmark.circle", count: pipeline.allPhotos.filter { !$0.accepted && !$0.rejected }.count, color: .gray)

                    Text("\(pipeline.allPhotos.count) totalt")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { showDeleteReviewConfirm = true }) {
                    Label("Radera granskningsdata", systemImage: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .help("Radera alla gallringsbeslut och anteckningar")
                .alert("Radera all granskningsdata?", isPresented: $showDeleteReviewConfirm) {
                    Button("Radera", role: .destructive) {
                        clearAllReviewData()
                    }
                    Button("Avbryt", role: .cancel) {}
                } message: {
                    Text("Detta raderar alla gallringsbeslut (ja/nej) och dikterade anteckningar. Kan inte angras.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if pipeline.currentStep == .culling || !settings.hdrMergeEnabled {
                PreviewCullView()
                    .environmentObject(runner)
            } else {
                BracketReviewView(runner: runner)
            }
        }
        .environmentObject(pipeline)
    }

    // MARK: - Top bar (branding + folders + controls)

    private var topBar: some View {
        HStack(spacing: 16) {
            // Logo
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                Text("PhotoFlow")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }

            Divider().frame(height: 32)

            // Input folder
            folderButton(
                icon: "folder",
                label: "Input",
                path: settings.inputDirectory?.lastPathComponent,
                color: .blue,
                detail: nefCount > 0 ? "\(nefCount) NEF" : nil
            ) {
                pickInputFolder()
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.5))

            // Output folder
            folderButton(
                icon: "folder.fill",
                label: "Output",
                path: settings.outputDirectory?.lastPathComponent ?? pipeline.outputDirectory?.lastPathComponent,
                color: .green,
                detail: hasProcessedOutput ? "Bearbetat" : nil
            ) {
                pickOutputFolder()
            }

            Spacer()

            // Status
            if pipeline.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(pipeline.currentStep.title)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }

            // Pause/Resume
            if pipeline.isRunning {
                Button(action: { runner.togglePause() }) {
                    Label(
                        pipeline.isPaused ? "Fortsatt" : "Pausa",
                        systemImage: pipeline.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
            }

            // Auto mode: run all
            Button(action: { startPipeline() }) {
                Label(
                    pipeline.isRunning ? "Kor..." : "Auto",
                    systemImage: "bolt.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.large)
            .disabled(pipeline.isRunning || settings.inputDirectory == nil)
            .help("Kor hela pipelinen automatiskt")

            // Watch mode
            Button(action: { toggleWatchMode() }) {
                Image(systemName: pipeline.isWatchMode ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            .tint(pipeline.isWatchMode ? .orange : nil)
            .help(pipeline.isWatchMode ? "Stoppa bevakning" : "Bevaka inputmapp")

            // Log toggle
            Button(action: { withAnimation { showLog.toggle() } }) {
                Image(systemName: "text.alignleft")
                    .foregroundColor(showLog ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Visa/dolj logg")

            // Settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Installningar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Folder button

    private func folderButton(icon: String, label: String, path: String?, color: Color, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 1) {
                    if let path {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Valj \(label.lowercased())mapp...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundColor(color.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        pipeline.isWatchMode.toggle()
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
        for i in pipeline.allPhotos.indices {
            pipeline.allPhotos[i].accepted = false
            pipeline.allPhotos[i].rejected = false
        }

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
