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

    /// Files we've already triggered processing for, identified by content (not
    /// just filename — a Nikon restarts its counter at DSC_0001 after a card
    /// format/reuse, so filename alone silently ignored genuinely new photos with
    /// a reused name) and persisted to disk so an app restart doesn't forget and
    /// re-trigger processing for an entire already-handled card.
    private let processedFiles = ProcessedFilesStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PhotoFlow/processed_files.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFlow-processed_files.json")
    )

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
            // Extract the (Sendable) URL from the notification here, in the
            // nonisolated callback, rather than capturing the whole (non-Sendable)
            // Notification into the @MainActor Task below.
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.log("Nytt media anslutet: \(volumeURL.lastPathComponent)")
                self?.handleNewVolume(volumeURL)
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

        let unprocessedNEFs = allNEFs.filter { !processedFiles.isProcessed(source: $0.deletingLastPathComponent().path, key: Self.fileKey(for: $0)) }

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
            processedFiles.markProcessed(source: f.deletingLastPathComponent().path, key: Self.fileKey(for: f))
        }
        processedFiles.save()

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
            guard fileURL.pathExtension.uppercased() == "NEF" else { continue }
            let source = fileURL.deletingLastPathComponent().path
            if !processedFiles.isProcessed(source: source, key: Self.fileKey(for: fileURL)) {
                nefFiles.append(fileURL)
            }
        }

        if nefFiles.isEmpty {
            log("Volym \(volumeURL.lastPathComponent): Inga nya NEF-filer i DCIM")
        } else {
            log("HITTADE: \(nefFiles.count) NEF-filer pa \(volumeURL.lastPathComponent)")
            newFilesFound = nefFiles.count
            audio.speak("Minneskort hittat med \(nefFiles.count) nya bilder")

            for f in nefFiles {
                processedFiles.markProcessed(source: f.deletingLastPathComponent().path, key: Self.fileKey(for: f))
            }
            processedFiles.save()
            onNewFilesDetected?(dcim, nefFiles)
        }
    }

    private func handleNewVolume(_ volumeURL: URL) {
        searchVolumeForNEFs(volumeURL)
    }

    /// A content-derived identity key for a file: "filename|size|mtime". Using
    /// just the filename (the old behavior) breaks the moment a camera restarts
    /// its counter — a Nikon reformatted or overwritten card starts again at
    /// DSC_0001, same name as a long-since-processed file, but completely
    /// different content — and the name-only check silently ignored the new
    /// photo forever. Uses `URLResourceValues` (file size + modification date);
    /// no EXIF read (e.g. DateTimeOriginal) is needed for this.
    nonisolated static func fileKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent)|\(size)|\(mtime)"
    }
}

/// Persists which files (identified by `WatchService.fileKey(for:)`, scoped per
/// source directory) have already triggered pipeline processing, so quitting and
/// relaunching the app doesn't forget and re-trigger auto-processing for an
/// entire already-handled SD card or input folder.
///
/// Not `@MainActor`-isolated on purpose — it does its own locking-free simple
/// mutation and is only ever touched from `WatchService` (which is `@MainActor`),
/// but keeping it a plain class makes it constructible/testable in a plain
/// `@Test` without actor isolation ceremony.
final class ProcessedFilesStore {
    private struct Record: Codable {
        let source: String
        let key: String
    }

    /// Hard cap on total persisted entries (across all sources combined) so the
    /// file can't grow forever across many cards/sessions over time.
    static let maxEntries = 50_000

    private let fileURL: URL
    private var records: [Record] = []
    private var lookup: Set<String> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private static func combinedKey(source: String, key: String) -> String {
        "\(source)\u{1F}\(key)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = decoded
        lookup = Set(decoded.map { Self.combinedKey(source: $0.source, key: $0.key) })
    }

    func isProcessed(source: String, key: String) -> Bool {
        lookup.contains(Self.combinedKey(source: source, key: key))
    }

    func markProcessed(source: String, key: String) {
        let combined = Self.combinedKey(source: source, key: key)
        guard !lookup.contains(combined) else { return }
        records.append(Record(source: source, key: key))
        lookup.insert(combined)

        // Trim oldest entries (across all sources) once over the cap.
        if records.count > Self.maxEntries {
            let overflow = records.count - Self.maxEntries
            for dropped in records.prefix(overflow) {
                lookup.remove(Self.combinedKey(source: dropped.source, key: dropped.key))
            }
            records.removeFirst(overflow)
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
