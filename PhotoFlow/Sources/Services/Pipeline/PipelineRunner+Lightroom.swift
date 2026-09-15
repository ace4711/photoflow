import Foundation

extension PipelineRunner {
    // MARK: - Lightroom HDR Integration

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

        // Write trigger file that the Lightroom plugin reads
        let triggerPath = NSTemporaryDirectory() + "photoflow_hdr_trigger.json"
        let triggerData: [String: Any] = ["groups": triggerGroups]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: triggerData, options: .prettyPrinted)
            try jsonData.write(to: URL(fileURLWithPath: triggerPath))
            state.appendLog("Trigger-fil skriven: \(triggerPath)", type: .info)
        } catch {
            state.appendLog("Kunde inte skriva trigger-fil: \(error.localizedDescription)", type: .error)
            return
        }

        // Remove any old completion marker
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "photoflow_hdr_done.json")
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "photoflow_hdr_status.json")

        // The Lightroom plugin auto-polls for the trigger file every 5 seconds.
        // Just make sure Lightroom is running.
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-b", "com.adobe.LightroomClassicCC7"]
        try? openProc.run()

        state.appendLog("Trigger-fil skriven med \(triggerGroups.count) grupper.", type: .success)
        state.appendLog("Kör nu i Lightroom: Library → Plug-in Extras → Kör HDR-sammanslagning från PhotoFlow", type: .warning)

        // Poll for completion
        Task {
            await waitForLightroomCompletion()
        }

        audio.playStepComplete()
    }

    /// Polls for the Lightroom plugin completion marker file.
    private func waitForLightroomCompletion() async {
        let donePath = NSTemporaryDirectory() + "photoflow_hdr_done.json"
        // Poll every 5 seconds for up to 10 minutes
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if FileManager.default.fileExists(atPath: donePath) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: donePath)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    await MainActor.run {
                        state.appendLog("Lightroom HDR klar! Status: \(status)", type: .success)
                        audio.playAllDone()
                    }
                }
                try? FileManager.default.removeItem(atPath: donePath)
                return
            }
        }
        await MainActor.run {
            state.appendLog("Timeout: fick inget svar från Lightroom-pluginet efter 10 min.", type: .warning)
        }
    }
}
