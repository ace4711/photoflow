import Foundation
import Combine
import AppKit
import CoreServices

@MainActor
class WatchService: ObservableObject {
    @Published var isWatching: Bool = false
    @Published var detectedVolumes: [URL] = []
    @Published var newFilesFound: Int = 0
    @Published var lastCheckTime: Date?
    @Published var statusMessage: String = "Vantar..."
    @Published var logLines: [String] = []

    /// Fallback-pollning (`AppSettings.watchIntervalSeconds`, default 60 s) —
    /// FSEvents (`fsEventStream` nedan) är den primära bevakningsmekanismen
    /// och reagerar i praktiken inom sekunder, men timern körs ändå parallellt
    /// som skyddsnät ifall FSEvents skulle missa något (t.ex. efter att
    /// strömmen tappat händelser, `kFSEventStreamEventFlagKernelDropped`).
    private var watchTimer: Timer?
    private var volumeObserver: Any?
    private var unmountObserver: Any?
    private let settings = AppSettings.shared
    private let audio = AudioService.shared

    /// FSEvents-ström för inputmappen (rekursiv, upptäcker även filer som
    /// landar i undermappar, t.ex. kamerans "100NIKON"-liknande mappnamn).
    /// Vi bryr oss inte om VILKEN sökväg som ändrades — varje händelse
    /// (oavsett innehåll) matar bara `fsEventDebouncer` och en efterföljande
    /// omkontroll skannar mappen på samma sätt som fallback-pollningen redan
    /// gjorde.
    private var fsEventStream: FSEventStreamRef?
    private var watchedInputPath: String?
    private let fsEventDebouncer = FSEventDebouncer(interval: 2.0)
    private var debounceTickTimer: Timer?

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

        // Fallback-pollning — se kommentaren vid `watchTimer`.
        let interval = TimeInterval(settings.watchIntervalSeconds)
        log("Fallback-kontrollintervall: \(settings.watchIntervalSeconds) sekunder (FSEvents är primär bevakning)")

        watchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForNewFiles()
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

        // Watch for volume unmounts, so we can clear transient per-volume
        // state (e.g. `detectedVolumes`) and log it — a card can be pulled
        // mid-session.
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.handleVolumeUnmounted(volumeURL)
            }
        }

        // Primary watching: FSEvents on the input directory (recursive),
        // debounced ~2s so a whole card copy settles before we react.
        if let inputDir = settings.inputDirectory {
            startFSEventsWatching(path: inputDir.path)
        }
        debounceTickTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.fsEventDebouncer.tick() else { return }
                self.log("FSEvents: ändringar upptäckta, kontrollerar (efter debounce)...")
                await self.checkForNewFiles()
            }
        }

        // Initial check immediately
        Task { @MainActor [weak self] in
            await self?.checkForNewFiles()
        }
    }

    func stopWatching() {
        isWatching = false
        watchTimer?.invalidate()
        watchTimer = nil
        debounceTickTimer?.invalidate()
        debounceTickTimer = nil
        stopFSEventsWatching()
        if let observer = volumeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            volumeObserver = nil
        }
        if let observer = unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            unmountObserver = nil
        }
        log("Bevakning stoppad")
    }

    // MARK: - FSEvents

    /// Startar (eller, om redan igång med en annan sökväg, startar om) en
    /// rekursiv FSEvents-bevakning av `path`. Vi struntar i vilka sökvägar
    /// som faktiskt ändrades i callbacken — varje händelse matar bara
    /// debouncern, och den efterföljande omkontrollen skannar mappen precis
    /// som fallback-pollningen gör.
    private func startFSEventsWatching(path: String) {
        guard watchedInputPath != path else { return }
        stopFSEventsWatching()
        watchedInputPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, _, _, _, _) in
            guard let info = clientCallBackInfo else { return }
            let service = Unmanaged<WatchService>.fromOpaque(info).takeUnretainedValue()
            service.fsEventDebouncer.recordEvent()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            log("FSEvents: kunde inte skapa bevakningsström för \(path), förlitar mig på fallback-pollning")
            watchedInputPath = nil
            return
        }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        log("FSEvents: bevakar \(path) rekursivt")
    }

    private func stopFSEventsWatching() {
        watchedInputPath = nil
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    private func handleVolumeUnmounted(_ volumeURL: URL) {
        log("Media bortkopplat: \(volumeURL.lastPathComponent)")
        detectedVolumes.removeAll { $0 == volumeURL }
    }

    private func checkForNewFiles() async {
        lastCheckTime = Date()

        // Om inputmappens sökväg ändrats sedan senast (t.ex. användaren bytte
        // mapp i Inställningar medan bevakningen redan var igång): flytta
        // FSEvents-strömmen dit i stället för att fortsätta bevaka den gamla.
        if isWatching, let inputDir = settings.inputDirectory {
            startFSEventsWatching(path: inputDir.path)
        }

        // Check input directory
        if let inputDir = settings.inputDirectory {
            await checkDirectory(inputDir)
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

    private func checkDirectory(_ dir: URL) async {
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

        // Vänta tills filstorlekarna slutat växa innan filerna räknas som
        // färdigkopierade — viktigt vid kopiering direkt från ett SD-kort
        // (t.ex. Bild-tagning/Finder) rakt in i inputmappen, där en fil kan
        // dyka upp i en FSEvents-händelse/pollning mitt i skrivningen. Se
        // `stableFiles(_:sizesBefore:sizesAfter:)` för den rena logiken.
        let stableNEFs = await stableFiles(among: unprocessedNEFs)
        let stillGrowing = unprocessedNEFs.count - stableNEFs.count
        if stillGrowing > 0 {
            log("Kontroll: \(stillGrowing) fil(er) verkar fortfarande kopieras, väntar till nästa kontroll")
        }
        if stableNEFs.isEmpty {
            return
        }

        // We have unprocessed files!
        newFilesFound = stableNEFs.count

        if outputExists {
            log("HITTADE: \(stableNEFs.count) nya NEF-filer (utover redan bearbetade)")
        } else {
            log("HITTADE: \(stableNEFs.count) NEF-filer att bearbeta i \(dir.lastPathComponent)")
        }

        // Spela bara "behöver din hjälp" om pipelinen INTE startar automatiskt.
        // Om autoStart är på körs pipelinen vidare och spelar ljudet
        // när den faktiskt behöver användarens uppmärksamhet (granskning/gallring).
        if !settings.autoStartPipeline {
            audio.playNeedsAttention()
        }

        // Mark as processed so we don't trigger again
        for f in stableNEFs {
            processedFiles.markProcessed(source: f.deletingLastPathComponent().path, key: Self.fileKey(for: f))
        }
        processedFiles.save()

        // Trigger callback - use nefSourceDir (the folder containing the actual NEF files)
        if settings.autoStartPipeline {
            log("Startar automatisk bearbetning av \(nefSourceDir.lastPathComponent)...")
            onNewFilesDetected?(nefSourceDir, stableNEFs)
        } else {
            log("Automatisk bearbetning avstaengd - starta manuellt")
        }
    }

    /// Väntar `Self.stabilityCheckDelay` sekunder och jämför filstorlekar före
    /// och efter — returnerar bara de filer vars storlek var oförändrad
    /// (dvs. inte längre växer). Filer som fortfarande kopieras lämnas kvar
    /// till nästa kontroll (nästa debounce-utlösning eller fallback-poll)
    /// snarare än att räknas som nya direkt.
    private func stableFiles(among files: [URL]) async -> [URL] {
        let before = Self.currentFileSizes(for: files)
        try? await Task.sleep(nanoseconds: UInt64(Self.stabilityCheckDelay * 1_000_000_000))
        let after = Self.currentFileSizes(for: files)
        return Self.stableFiles(files, sizesBefore: before, sizesAfter: after)
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

    // MARK: - Stabilitetskontroll (ren logik, se `WatchServiceStabilityTests`)

    /// Hur länge vi väntar mellan de två storleksmätningarna i
    /// `stableFiles(among:)`.
    static let stabilityCheckDelay: TimeInterval = 1.0

    nonisolated static func currentFileSizes(for files: [URL]) -> [URL: Int64] {
        var result: [URL: Int64] = [:]
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                result[file] = Int64(size)
            }
        }
        return result
    }

    /// En fil anses klar kopierad om den syntes i båda mätningarna med
    /// identisk storlek. Saknas den i endera mätningen (t.ex. borttagen,
    /// eller ett läsfel) räknas den INTE som stabil — hellre vänta en
    /// kontroll till än att skicka en trasig/ofullständig fil till pipelinen.
    nonisolated static func isFileStable(sizeBefore: Int64?, sizeAfter: Int64?) -> Bool {
        guard let sizeBefore, let sizeAfter else { return false }
        return sizeBefore == sizeAfter
    }

    nonisolated static func stableFiles(_ files: [URL], sizesBefore: [URL: Int64], sizesAfter: [URL: Int64]) -> [URL] {
        files.filter { isFileStable(sizeBefore: sizesBefore[$0], sizeAfter: sizesAfter[$0]) }
    }
}

/// Samlar ihop en skur av FSEvents-händelser till en enda omkontroll, körd
/// `interval` sekunder efter den SENASTE händelsen — en hel kortkopiering rör
/// inputmappen många gånger i följd under några sekunder, och en omkontroll
/// per enskild händelse vore både onödigt och skulle kunna råka fånga en fil
/// mitt i kopiering.
///
/// Klockan är injicerbar (`recordEvent(at:)`/`tick(now:)` tar ett explicit
/// `Date`), så beslutslogiken går att enhetstesta helt utan riktiga timers
/// eller `sleep` — se `WatchServiceDebounceTests`. I produktion drivs
/// `tick(now:)` av en kort repeterande `Timer` (var 0.3:e sekund) i
/// `WatchService`.
final class FSEventDebouncer {
    let interval: TimeInterval
    private var lastEventAt: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Anropas för varje rå FSEvents-händelse.
    func recordEvent(at time: Date = Date()) {
        lastEventAt = time
    }

    /// Anropas periodiskt. Returnerar `true` exakt en gång per skur — första
    /// gången minst `interval` sekunder har passerat sedan senast
    /// registrerade händelse — och nollställer sig själv så nästa skur
    /// upptäcks på nytt.
    func tick(now: Date = Date()) -> Bool {
        guard let lastEventAt, now.timeIntervalSince(lastEventAt) >= interval else { return false }
        self.lastEventAt = nil
        return true
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
