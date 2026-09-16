import Foundation

extension PipelineRunner {
    // MARK: - Lightroom HDR Integration

    /// Shared bridge folder between this app and `PhotoFlowLR.lrplugin`
    /// (`HDRMergeCore.lua`'s `bridgeDir()` — must match exactly).
    ///
    /// Fas 4: previously this used `NSTemporaryDirectory()` while the plugin
    /// used `LrPathUtils.getStandardFilePath("temp")` — on an unsandboxed
    /// setup those happen to resolve to the same per-user `$TMPDIR`, but
    /// that's an assumption about both processes' environments, not a
    /// guarantee (different launch contexts/macOS versions can hand out
    /// different `$TMPDIR` values to different processes). Both sides now
    /// use this fixed, well-known location instead, removing the ambiguity.
    /// Same `~/Library/Application Support/PhotoFlow` folder (and the same
    /// lookup pattern) `BookingTitleParser` already uses for its cache.
    static var lightroomBridgeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("PhotoFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var triggerFileURL: URL { lightroomBridgeDirectory.appendingPathComponent("lr_trigger.json") }
    private static var doneFileURL: URL { lightroomBridgeDirectory.appendingPathComponent("lr_done.json") }
    private static var statusFileURL: URL { lightroomBridgeDirectory.appendingPathComponent("lr_status.json") }

    /// Sends selected bracket groups to Lightroom Classic for HDR merge.
    /// Creates a staging folder with the selected files and opens Lightroom + Finder.
    func sendToLightroom(groups: [BracketGroup]) async {
        state.appendLog("Förbereder HDR-grupper för Lightroom...", type: .info)

        // Build trigger JSON for the Lightroom plugin
        var triggerGroups: [[String: Any]] = []
        var groupIndex = 0
        for group in groups where group.isBracket {
            let selectedPhotos = state.photos(in: group).filter { $0.accepted }
            guard selectedPhotos.count >= 2 else { continue }
            groupIndex += 1
            let files = selectedPhotos.map { $0.nefURL.path }
            triggerGroups.append([
                "group_id": groupIndex,
                "files": files,
                "output_dir": state.outputDirectory?.appendingPathComponent("hdr").path ?? ""
            ])
        }

        guard !triggerGroups.isEmpty else {
            state.appendLog("Inga bracket-grupper med valda bilder att skicka.", type: .warning)
            return
        }

        let totalFiles = triggerGroups.reduce(0) { $0 + (($1["files"] as? [String])?.count ?? 0) }
        state.appendLog("Skickar \(triggerGroups.count) bracket-grupper (\(totalFiles) filer) till Lightroom...", type: .info)

        // Write trigger file that the Lightroom plugin's background poller reads.
        let triggerURL = Self.triggerFileURL
        let triggerData: [String: Any] = ["groups": triggerGroups]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: triggerData, options: .prettyPrinted)
            try jsonData.write(to: triggerURL)
            state.appendLog("Trigger-fil skriven: \(triggerURL.path)", type: .info)
        } catch {
            state.appendLog("Kunde inte skriva trigger-fil: \(error.localizedDescription)", type: .error)
            return
        }

        // Remove any old completion marker
        try? FileManager.default.removeItem(at: Self.doneFileURL)
        try? FileManager.default.removeItem(at: Self.statusFileURL)

        // Make sure Lightroom is running — its plugin (InitPlugin.lua, Fas 4)
        // actually polls for the trigger file every 5 seconds now, so no
        // further manual step is needed there.
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-b", "com.adobe.LightroomClassicCC7"]
        try? openProc.run()

        state.appendLog("Trigger-fil skriven med \(triggerGroups.count) grupper.", type: .success)
        state.appendLog("PhotoFlow-pluginet pollar automatiskt (var 5:e sekund) — inget mer krävs i Lightroom. Om inget händer inom en minut: kör \"Library → Plug-in Extras → Kör HDR-sammanslagning från PhotoFlow (manuell koll)\" som fallback.", type: .info)

        // Poll for completion
        Task {
            await waitForLightroomCompletion()
        }

        audio.playStepComplete()
    }

    /// Polls for the Lightroom plugin's completion marker file.
    private func waitForLightroomCompletion() async {
        let doneURL = Self.doneFileURL
        // Poll every 5 seconds for up to 10 minutes
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if FileManager.default.fileExists(atPath: doneURL.path) {
                if let data = try? Data(contentsOf: doneURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    await MainActor.run {
                        state.appendLog("Lightroom HDR klar! Status: \(status)", type: .success)
                        audio.playAllDone()
                    }
                }
                try? FileManager.default.removeItem(at: doneURL)
                return
            }
        }
        await MainActor.run {
            state.appendLog("Timeout: fick inget svar från Lightroom-pluginet efter 10 min.", type: .warning)
        }
    }
}
