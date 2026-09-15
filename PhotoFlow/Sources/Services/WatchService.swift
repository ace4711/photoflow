import Foundation
import Combine
import AppKit

@MainActor
class WatchService: ObservableObject {
    @Published var isWatching: Bool = false
    @Published var detectedVolumes: [URL] = []
    @Published var newFilesFound: Int = 0
    @Published var lastCheckTime: Date?
    @Published var statusMessage: String = "Vantar..."
    @Published var logLines: [String] = []

    private var watchTimer: Timer?
    private var volumeObserver: Any?
    private let settings = AppSettings.shared
    private let audio = AudioService.shared

    /// Files we've already triggered processing for this session
    private var processedFiles: Set<String> = []

    var onNewFilesDetected: ((_ sourceDir: URL, _ files: [URL]) -> Void)?

    private var logFileHandle: FileHandle?
    private var logFileURL: URL?

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())
        let line = "[\(time)] \(message)"
        logLines.append(line)
        if logLines.count > 200 {
            logLines.removeFirst(50)
        }
        statusMessage = message

        // Write to file
        writeToLogFile(line)
    }

    private func setupLogFile() {
        let outputDir = settings.outputDirectory
            ?? settings.inputDirectory?.appendingPathComponent("processed")

        if let dir = outputDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logFileURL = dir.appendingPathComponent("photoflow.log")
        } else {
            let tmpDir = FileManager.default.temporaryDirectory
            logFileURL = tmpDir.appendingPathComponent("photoflow.log")
        }

        guard let url = logFileURL else { return }

        // Create or append
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logFileHandle = FileHandle(forWritingAtPath: url.path)
        logFileHandle?.seekToEndOfFile()

        let separator = "\n--- PhotoFlow session \(Date()) ---\n"
        logFileHandle?.write(separator.data(using: .utf8)!)

        log("Loggfil: \(url.path)")
    }

    private func writeToLogFile(_ line: String) {
        guard let handle = logFileHandle else { return }
        let data = (line + "\n").data(using: .utf8)!
        handle.write(data)
    }

    func startWatching() {
        isWatching = true
        logLines = []
        setupLogFile()
        log("Bevakning startad")

        log("inputDirectoryPath = '\(settings.inputDirectoryPath)'")
        log("outputDirectoryPath = '\(settings.outputDirectoryPath)'")
        log("autoStartPipeline = \(settings.autoStartPipeline)")

        if let inputDir = settings.inputDirectory {
            log("Inputmapp: \(inputDir.path)")
            let exists = FileManager.default.fileExists(atPath: inputDir.path)
            log("  Mappen finns: \(exists)")
            if exists {
                let files = (try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? []
                let nefs = files.filter { $0.pathExtension.uppercased() == "NEF" }
                let subdirs = files.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "processed" }
                log("  Filer: \(files.count), NEF direkt: \(nefs.count), Undermappar: \(subdirs.count)")
                if nefs.isEmpty && !subdirs.isEmpty {
                    for sub in subdirs {
                        let subFiles = (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                        let subNefs = subFiles.filter { $0.pathExtension.uppercased() == "NEF" }
                        if !subNefs.isEmpty {
                            log("  -> \(sub.lastPathComponent): \(subNefs.count) NEF-filer")
                        }
                    }
                }
            }
        } else {
            log("VARNING: Ingen inputmapp konfigurerad - öppna Inställningar")
        }

        if let outputDir = settings.outputDirectory {
            log("Outputmapp: \(outputDir.path)")
            let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
            log("  Redan bearbetad: \(FileManager.default.fileExists(atPath: groupsJSON.path))")
        } else {
            log("Outputmapp: (använder 'processed' i inputmappen)")
        }

        // Periodic check
        let interval = TimeInterval(settings.watchIntervalSeconds)
        log("Kontrollintervall: \(settings.watchIntervalSeconds) sekunder")

        watchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForNewFiles()
            }
        }

        // Watch for volume mounts (SD cards)
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self.log("Nytt media anslutet: \(volumeURL.lastPathComponent)")
                    self.handleNewVolume(volumeURL)
                }
            }
        }

        // Initial check immediately
        checkForNewFiles()
    }

    func stopWatching() {
        isWatching = false
        watchTimer?.invalidate()
        watchTimer = nil
        if let observer = volumeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            volumeObserver = nil
        }
        log("Bevakning stoppad")
    }

    private func checkForNewFiles() {
        lastCheckTime = Date()

        // Check input directory
        if let inputDir = settings.inputDirectory {
            checkDirectory(inputDir)
        } else {
            log("Kontroll: Ingen inputmapp konfigurerad")
        }

        // Check mounted volumes
        let volumes = settings.sdCardSearchPaths
        detectedVolumes = volumes

        if !volumes.isEmpty {
            log("Kontroll: \(volumes.count) volymer anslutna: \(volumes.map { $0.lastPathComponent }.joined(separator: ", "))")
            for volume in volumes {
                searchVolumeForNEFs(volume)
            }
        }
    }

    private func checkDirectory(_ dir: URL) {
        // Find NEF files: first check directly, then search subdirectories
        var allNEFs: [URL] = []
        var nefSourceDir = dir

        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let directNEFs = files.filter { $0.pathExtension.uppercased() == "NEF" }
            if !directNEFs.isEmpty {
                allNEFs = directNEFs
            } else {
                // Search subdirectories one level deep
                let subdirs = files.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "processed" }
                log("Kontroll: Inga NEF direkt i \(dir.lastPathComponent), soker i \(subdirs.count) undermappar...")
                for subdir in subdirs {
                    if let subFiles = try? FileManager.default.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil) {
                        let subNEFs = subFiles.filter { $0.pathExtension.uppercased() == "NEF" }
                        if !subNEFs.isEmpty {
                            log("  \(subdir.lastPathComponent): \(subNEFs.count) NEF-filer")
                            allNEFs.append(contentsOf: subNEFs)
                            nefSourceDir = subdir
                        }
                    }
                }
            }
        } else {
            log("Kontroll: Kunde inte lasa \(dir.lastPathComponent)")
            return
        }

        let unprocessedNEFs = allNEFs.filter { !processedFiles.contains($0.lastPathComponent) }

        if allNEFs.isEmpty {
            log("Kontroll: Inga NEF-filer i \(dir.lastPathComponent) (inkl undermappar)")
            return
        }

        // Check if output already exists and is complete
        let outputDir = settings.outputDirectory ?? nefSourceDir.appendingPathComponent("processed")
        let groupsJSON = outputDir.appendingPathComponent("bracket_groups.json")
        let outputExists = FileManager.default.fileExists(atPath: groupsJSON.path)

        if outputExists && unprocessedNEFs.isEmpty {
            log("Kontroll: \(allNEFs.count) NEF-filer i \(dir.lastPathComponent) - redan bearbetade")
            return
        }

        if unprocessedNEFs.isEmpty {
            log("Kontroll: \(allNEFs.count) NEF-filer i \(dir.lastPathComponent) - redan skickade till bearbetning")
            return
        }

        // We have unprocessed files!
        newFilesFound = unprocessedNEFs.count

        if outputExists {
            log("HITTADE: \(unprocessedNEFs.count) nya NEF-filer (utover redan bearbetade)")
        } else {
            log("HITTADE: \(unprocessedNEFs.count) NEF-filer att bearbeta i \(dir.lastPathComponent)")
        }

        // Spela bara "behöver din hjälp" om pipelinen INTE startar automatiskt.
        // Om autoStart är på körs pipelinen vidare och spelar ljudet
        // när den faktiskt behöver användarens uppmärksamhet (granskning/gallring).
        if !settings.autoStartPipeline {
            audio.playNeedsAttention()
        }

        // Mark as processed so we don't trigger again
        for f in unprocessedNEFs {
            processedFiles.insert(f.lastPathComponent)
        }

        // Trigger callback - use nefSourceDir (the folder containing the actual NEF files)
        if settings.autoStartPipeline {
            log("Startar automatisk bearbetning av \(nefSourceDir.lastPathComponent)...")
            onNewFilesDetected?(nefSourceDir, unprocessedNEFs)
        } else {
            log("Automatisk bearbetning avstaengd - starta manuellt")
        }
    }

    private func searchVolumeForNEFs(_ volumeURL: URL) {
        let dcim = volumeURL.appendingPathComponent("DCIM")
        guard FileManager.default.fileExists(atPath: dcim.path) else {
            log("Volym \(volumeURL.lastPathComponent): Ingen DCIM-mapp")
            return
        }

        guard let enumerator = FileManager.default.enumerator(
            at: dcim,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var nefFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension.uppercased() == "NEF" && !processedFiles.contains(fileURL.lastPathComponent) {
                nefFiles.append(fileURL)
            }
        }

        if nefFiles.isEmpty {
            log("Volym \(volumeURL.lastPathComponent): Inga nya NEF-filer i DCIM")
        } else {
            log("HITTADE: \(nefFiles.count) NEF-filer pa \(volumeURL.lastPathComponent)")
            newFilesFound = nefFiles.count
            audio.speak("Minneskort hittat med \(nefFiles.count) nya bilder")

            for f in nefFiles { processedFiles.insert(f.lastPathComponent) }
            onNewFilesDetected?(dcim, nefFiles)
        }
    }

    private func handleNewVolume(_ volumeURL: URL) {
        searchVolumeForNEFs(volumeURL)
    }
}
