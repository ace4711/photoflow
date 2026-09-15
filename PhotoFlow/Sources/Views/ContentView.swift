import SwiftUI

struct ContentView: View {
    @EnvironmentObject var pipeline: PipelineState
    @StateObject private var runner: RunnerWrapper = RunnerWrapper()

    var body: some View {
        DashboardView(runner: runner)
            .environmentObject(pipeline)
            .onAppear {
                runner.setup(state: pipeline)
            }
    }
}

@MainActor
class RunnerWrapper: ObservableObject {
    var runner: PipelineRunner?
    private var state: PipelineState?
    let watcher = WatchService()

    func setup(state: PipelineState) {
        self.state = state
        if runner == nil {
            runner = PipelineRunner(state: state)
        }
        // Wire up watcher to auto-start pipeline when new files detected
        watcher.onNewFilesDetected = { [weak self] sourceDir, files in
            Task { @MainActor in
                guard let self else { return }
                // If source is on a volume (SD card), copy to input dir first
                if sourceDir.path.hasPrefix("/Volumes/") {
                    await self.copyFromSDCardAndStart(sourceDir: sourceDir, files: files)
                } else {
                    // Use configured output dir to avoid creating output inside input
                    let outputDir = AppSettings.shared.outputDirectory
                    self.start(inputDir: sourceDir, outputDir: outputDir)
                }
            }
        }
    }

    func startWatchingForSDCards() {
        guard !watcher.isWatching else { return }
        watcher.startWatching()
        state?.updateStep(.watchSources, phase: .watching)
        state?.appendLog("SD-kortsbevakning aktiverad", type: .info)
    }

    func stopWatchingForSDCards() {
        watcher.stopWatching()
    }

    /// Copy NEF files from SD card to input directory using rsync, then start pipeline
    func copyFromSDCardAndStart(sourceDir: URL, files: [URL]) async {
        guard let state else { return }

        let settings = AppSettings.shared
        guard let inputDir = settings.inputDirectory else {
            state.appendLog("Kan inte kopiera — ingen inputmapp konfigurerad.", type: .error)
            return
        }

        try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        state.updateStep(.copyToInput, phase: .active)
        state.appendStepLog(.copyToInput, "Kopierar \(files.count) NEF-filer från \(sourceDir.path)...")
        state.appendLog("rsync: Kopierar \(files.count) filer från SD-kort till \(inputDir.lastPathComponent)...", type: .info)

        let srcPath = sourceDir.path.hasSuffix("/") ? sourceDir.path : sourceDir.path + "/"
        let dstPath = inputDir.path.hasSuffix("/") ? inputDir.path : inputDir.path + "/"
        let totalFiles = files.count

        // Run rsync entirely off main thread to avoid deadlock
        let (exitCode, copiedCount) = await Task.detached { () -> (Int32, Int) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = [
                "--archive",
                "--progress",
                "--include=*/",
                "--include=*.NEF",
                "--include=*.nef",
                "--exclude=*",
                "--prune-empty-dirs",
                srcPath,
                dstPath
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    state.updateStep(.copyToInput, phase: .error(error.localizedDescription))
                    state.appendLog("rsync: \(error.localizedDescription)", type: .error)
                }
                return (-1, 0)
            }

            // Read and parse output on this background thread
            let outputHandle = pipe.fileHandleForReading
            var copied = 0
            var buffer = ""

            while true {
                let chunk = outputHandle.availableData
                guard !chunk.isEmpty else { break }
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                buffer += text

                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])

                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    if trimmed.uppercased().hasSuffix(".NEF") && !trimmed.hasPrefix(" ") {
                        copied += 1
                        let current = copied
                        let filename = trimmed
                        await MainActor.run {
                            state.updateStepProgress(.copyToInput, processed: current, total: totalFiles)
                            if current <= 3 || current % 50 == 0 || current == totalFiles {
                                state.appendStepLog(.copyToInput, "[\(current)/\(totalFiles)] \(filename)")
                            }
                        }
                    }
                }
            }

            process.waitUntilExit()
            return (process.terminationStatus, copied)
        }.value

        if exitCode == 0 {
            state.completeStep(.copyToInput, count: copiedCount)
            state.appendLog("rsync: Kopiering klar — \(copiedCount) filer", type: .success)
            start(inputDir: inputDir)
        } else if exitCode > 0 {
            state.updateStep(.copyToInput, phase: .error("rsync avslutades med kod \(exitCode)"))
            state.appendLog("rsync: Fel vid kopiering (kod \(exitCode))", type: .error)
        }
    }

    func start(inputDir: URL, outputDir: URL? = nil) {
        guard let runner else { return }
        Task {
            await runner.startPipeline(inputDir: inputDir, outputDir: outputDir)
        }
    }

    func loadExistingSession(inputDir: URL, outputDir: URL? = nil) {
        guard let runner else { return }
        Task {
            await runner.loadExistingSession(inputDir: inputDir, outputDir: outputDir)
        }
    }

    func cancel() {
        runner?.cancel()
    }

    func togglePause() {
        runner?.togglePause()
    }

    func sendToLightroom(groups: [BracketGroup]) {
        guard let runner else { return }
        Task {
            await runner.sendToLightroom(groups: groups)
        }
    }

    func reMergeHDR(group: BracketGroup) {
        guard let runner else { return }
        Task {
            await runner.reMergeHDR(group: group)
        }
    }

    func exportToAddressFolders() {
        guard let runner else { return }
        Task {
            await runner.exportToAddressFolders()
        }
    }

    func rerunStep(_ step: DashboardStep) {
        guard let runner else { return }
        Task {
            await runner.rerunStep(step)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var pipeline: PipelineState
    @ObservedObject var runner: RunnerWrapper
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back to launcher
            Button(action: { pipeline.appMode = .launcher }) {
                Label("Tillbaka till start", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Pipeline steps
            List {
                Section("Pipeline") {
                    ForEach(PipelineStep.allCases) { step in
                        let isDisabled = isStepDisabled(step)
                        HStack(spacing: 12) {
                            stepIcon(for: step, disabled: isDisabled)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title)
                                    .font(.system(.body, design: .rounded))
                                    .fontWeight(step == pipeline.currentStep ? .bold : .regular)
                                    .strikethrough(isDisabled, color: .secondary)
                                if isDisabled {
                                    Text("Avaktiverad i inställningar")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .foregroundColor(isDisabled ? .secondary.opacity(0.5) : stepColor(for: step))
                        .listRowBackground(
                            step == pipeline.currentStep && !isDisabled
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                    }
                }

                if !pipeline.bracketGroups.isEmpty {
                    Section("Bracket-grupper (\(pipeline.bracketGroups.filter { $0.isBracket }.count) HDR)") {
                        ForEach(pipeline.bracketGroups) { group in
                            HStack {
                                Image(systemName: group.isBracket ? "square.stack.3d.up" : "photo")
                                    .foregroundColor(group.isBracket ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.label)
                                        .font(.caption)
                                    Text("\(group.selectedCount)/\(group.photos.count) valda")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Log area
            VStack(alignment: .leading, spacing: 4) {
                Text("Logg")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

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
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 150)
                    .onChange(of: pipeline.logLines.count) { _, _ in
                        if let last = pipeline.logLines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
    }

    private func isStepDisabled(_ step: PipelineStep) -> Bool {
        if !settings.hdrMergeEnabled && (step == .mergingHDR || step == .reviewingBrackets) {
            return true
        }
        if !settings.aiTaggingEnabled && step == .taggingPhotos {
            return true
        }
        return false
    }

    @ViewBuilder
    private func stepIcon(for step: PipelineStep, disabled: Bool = false) -> some View {
        if disabled {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary.opacity(0.4))
        } else {
            let current = pipeline.currentStep
            if step.rawValue < current.rawValue {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if step == current && pipeline.isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: step.systemImage)
            }
        }
    }

    private func stepColor(for step: PipelineStep) -> Color {
        let current = pipeline.currentStep
        if step.rawValue < current.rawValue { return .green }
        if step == current { return .accentColor }
        return .secondary
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

// MARK: - Done View

struct DoneView: View {
    @EnvironmentObject var pipeline: PipelineState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            Text("Klart!")
                .font(.system(size: 48, weight: .bold, design: .rounded))
            if let dir = pipeline.outputDirectory {
                Text(dir.path)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button("Öppna i Finder") {
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Tillbaka till start") {
                        pipeline.reset()
                        pipeline.appMode = .launcher
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
