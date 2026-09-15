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
        // PipelineRunner.start owns the Task itself (pipelineTask), so cancel()
        // can actually cancel it — a Task created here instead would be
        // un-cancellable from RunnerWrapper.cancel().
        runner?.start(inputDir: inputDir, outputDir: outputDir)
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
