import Foundation

/// Synkar skicka-mappar: `<outputDir>/<adress>/<adress> skicka/` med kopior av de DNG-filer
/// fotografen valt att skicka till en extern redigerare.
///
/// Reglerna i korthet: originalen (NEF och pipelinens DNG) ändras aldrig; kopior skrivs via
/// temporär fil + atomisk omdöpning av den *upplösta* källan (aldrig symlänken); appen tar bara
/// bort filer den själv lagt dit och som är oförändrade sedan dess (spåras i
/// `edit_send_manifest.json` i outputDir, utanför skicka-mappen så redigeraren slipper den).
nonisolated enum SendFolderSync {
    static let folderSuffix = " skicka"
    static let manifestFileName = "edit_send_manifest.json"
    /// Tolerans för ändringsdatum (filsystem och JSON avrundar olika).
    static let modifiedTolerance: TimeInterval = 1.0

    static func folderName(address: String) -> String { "\(address)\(folderSuffix)" }

    static func folder(in outputDir: URL, address: String) -> URL {
        outputDir
            .appendingPathComponent(address, isDirectory: true)
            .appendingPathComponent(folderName(address: address), isDirectory: true)
    }

    nonisolated struct Request: Sendable, Equatable {
        var address: String
        var nefURL: URL
        var dngURL: URL?
        /// DNG-namnet: NEF-basnamn + ".dng" (gemener-ändelse som DNG Converter skriver).
        var fileName: String {
            nefURL.deletingPathExtension().lastPathComponent + ".dng"
        }
    }

    nonisolated struct Record: Codable, Equatable, Sendable {
        var size: Int64
        var modified: Date
        var source: String
    }

    nonisolated struct Manifest: Codable, Equatable, Sendable {
        var version: Int = 1
        /// Nyckel = sökväg relativ outputDir, t.ex. "Gatan 1/Gatan 1 skicka/DSC_1234.dng".
        var files: [String: Record] = [:]

        static func load(from outputDir: URL) -> Manifest {
            let url = outputDir.appendingPathComponent(SendFolderSync.manifestFileName)
            guard let data = try? Data(contentsOf: url) else { return Manifest() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(Manifest.self, from: data)) ?? Manifest()
        }

        func save(to outputDir: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: outputDir.appendingPathComponent(SendFolderSync.manifestFileName), options: .atomic)
        }
    }

    nonisolated enum Action: Equatable, Sendable {
        case copy(source: URL, destination: URL)
        case convertAndCopy(nef: URL, destination: URL)
        case keep(URL)
        case conflict(URL, reason: String)
        case identicalForeign(URL)
        case remove(URL)
        case keepModified(URL)
    }

    nonisolated struct AddressSummary: Equatable, Sendable {
        var address: String
        var folder: URL
        var fileCount: Int
        var bytes: Int64
        var copied: Int
        var removed: Int
    }

    nonisolated struct Summary: Equatable, Sendable {
        var addresses: [AddressSummary]
        var conflicts: [String]
        var warnings: [String]
        var errors: [String]
    }

    typealias Converter = @Sendable (_ nef: URL, _ dngDir: URL) async throws -> URL

    nonisolated struct SyncError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Hjälpare

    private static func isValidAddress(_ address: String) -> Bool {
        !address.isEmpty && address != "." && address != ".." && !address.contains("/")
    }

    private static func key(address: String, fileName: String) -> String {
        "\(address)/\(folderName(address: address))/\(fileName)"
    }

    private static func relativeKey(of url: URL, outputDir: URL) -> String? {
        let prefix = outputDir.path.hasSuffix("/") ? outputDir.path : outputDir.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return String(url.path.dropFirst(prefix.count))
    }

    private static func attributes(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return (size, date)
    }

    private static func exists(_ url: URL) -> Bool {
        // lstat-liknande: en trasig symlänk räknas också som "finns" (något ligger i vägen).
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// "Vår fil": posten finns och storlek + ändringsdatum matchar.
    private static func isOurs(key: String, url: URL, manifest: Manifest) -> Bool {
        guard let record = manifest.files[key], let attrs = attributes(url) else { return false }
        return attrs.size == record.size && abs(attrs.modified.timeIntervalSince(record.modified)) <= modifiedTolerance
    }

    private static func resolvedSource(_ request: Request) -> URL? {
        guard let dng = request.dngURL else { return nil }
        let resolved = dng.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return resolved
    }

    private static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let x = attributes(a), let y = attributes(b), x.size == y.size else { return false }
        return FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    // MARK: - Planering

    static func plan(requests: [Request], outputDir: URL, manifest: Manifest) -> [Action] {
        var actions: [Action] = []
        var desiredKeys = Set<String>()

        for request in requests where isValidAddress(request.address) {
            let k = key(address: request.address, fileName: request.fileName)
            guard desiredKeys.insert(k).inserted else { continue }
            let destination = folder(in: outputDir, address: request.address)
                .appendingPathComponent(request.fileName)
            let source = resolvedSource(request)

            if exists(destination) {
                if isOurs(key: k, url: destination, manifest: manifest) {
                    actions.append(.keep(destination))
                } else if let source, identical(source, destination) {
                    actions.append(.identicalForeign(destination))
                } else if manifest.files[k] != nil {
                    actions.append(.conflict(destination, reason: "\(request.fileName) har ändrats sedan appen kopierade den och skiljer sig från källan"))
                } else {
                    actions.append(.conflict(destination, reason: "\(request.fileName) finns redan i \(folderName(address: request.address)) men är inte kopierad av appen och skiljer sig från källan"))
                }
            } else if let source {
                actions.append(.copy(source: source, destination: destination))
            } else {
                actions.append(.convertAndCopy(nef: request.nefURL, destination: destination))
            }
        }

        for (k, _) in manifest.files.sorted(by: { $0.key < $1.key }) where !desiredKeys.contains(k) {
            let comps = k.split(separator: "/").map(String.init)
            // Bara filer som ligger i en skicka-mapp rörs, aldrig något annat.
            guard comps.count == 3, !comps.contains(".."), comps[1].hasSuffix(folderSuffix) else { continue }
            let url = outputDir.appendingPathComponent(k)
            guard exists(url) else { continue }
            actions.append(isOurs(key: k, url: url, manifest: manifest) ? .remove(url) : .keepModified(url))
        }
        return actions
    }

    // MARK: - Standardkonverterare

    static let adobeConverter: Converter = { nef, dngDir in
        let converterPath = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"
        guard FileManager.default.isExecutableFile(atPath: converterPath) else {
            throw SyncError(message: "Adobe DNG Converter saknas. Installera den från Adobe för att kunna konvertera \(nef.lastPathComponent).")
        }
        let fm = FileManager.default
        let partial = dngDir.appendingPathComponent(".partial-skicka", isDirectory: true)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: partial) }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: converterPath)
            process.arguments = ["-c", "-d", partial.path, nef.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            throw SyncError(message: "DNG-konverteringen av \(nef.lastPathComponent) misslyckades (kod \(status)).")
        }
        let moved = try PipelineRunner.promotePartialDNGs(from: partial, to: dngDir)
        let wanted = nef.deletingPathExtension().lastPathComponent.lowercased()
        guard let result = moved.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == wanted
        }) else {
            throw SyncError(message: "DNG Converter skapade ingen fil för \(nef.lastPathComponent).")
        }
        return result
    }

    // MARK: - Utförande

    @concurrent
    static func execute(_ actions: [Action], requests: [Request], outputDir: URL, manifest: Manifest,
                        converter: Converter = adobeConverter,
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> (Summary, Manifest) {
        let fm = FileManager.default
        var manifest = manifest
        let dngDir = outputDir.appendingPathComponent("dng", isDirectory: true)

        struct Tally { var fileCount = 0; var bytes: Int64 = 0; var copied = 0; var removed = 0 }
        var tallies: [String: Tally] = [:]
        var touchedFolders = Set<URL>()
        var conflicts: [String] = []
        var warnings: [String] = []
        var errors: [String] = []

        func addressOf(folder: URL) -> String {
            let name = folder.lastPathComponent
            return name.hasSuffix(folderSuffix) ? String(name.dropLast(folderSuffix.count)) : name
        }
        func note(_ destination: URL, copied: Bool) {
            let a = addressOf(folder: destination.deletingLastPathComponent())
            var t = tallies[a] ?? Tally()
            t.fileCount += 1
            t.bytes += attributes(destination)?.size ?? 0
            if copied { t.copied += 1 }
            tallies[a] = t
        }
        func touch(_ destination: URL) {
            let dir = destination.deletingLastPathComponent()
            touchedFolders.insert(dir)
            let a = addressOf(folder: dir)
            if tallies[a] == nil { tallies[a] = Tally() }
        }
        func recordCopy(_ destination: URL, source: URL) {
            guard let k = relativeKey(of: destination, outputDir: outputDir), let attrs = attributes(destination) else { return }
            manifest.files[k] = Record(size: attrs.size, modified: attrs.modified, source: source.path)
        }
        func copyAtomically(from source: URL, to destination: URL) throws {
            let dir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let temp = dir.appendingPathComponent(".\(destination.lastPathComponent).partial")
            try? fm.removeItem(at: temp)
            do {
                try fm.copyItem(at: source.resolvingSymlinksInPath(), to: temp)
                guard !exists(destination) else {
                    throw SyncError(message: "\(destination.lastPathComponent) dök upp under kopieringen och skrevs inte över.")
                }
                try fm.moveItem(at: temp, to: destination)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }

        let total = actions.count
        var done = 0
        var converted: [String: URL] = [:]   // NEF-sökväg -> DNG i dng/

        for action in actions {
            switch action {
            case .keep(let url):
                touch(url); note(url, copied: false)
            case .identicalForeign(let url):
                touch(url); note(url, copied: false)
            case .conflict(let url, let reason):
                touch(url)
                conflicts.append(reason)
            case .keepModified(let url):
                warnings.append("\(url.lastPathComponent) i \(url.deletingLastPathComponent().lastPathComponent) är ändrad efter kopieringen och togs inte bort.")
            case .remove(let url):
                let a = addressOf(folder: url.deletingLastPathComponent())
                touchedFolders.insert(url.deletingLastPathComponent())
                do {
                    try fm.removeItem(at: url)
                    if let k = relativeKey(of: url, outputDir: outputDir) { manifest.files[k] = nil }
                    var t = tallies[a] ?? Tally(); t.removed += 1; tallies[a] = t
                } catch {
                    errors.append("Kunde inte ta bort \(url.lastPathComponent): \(error.localizedDescription)")
                }
            case .copy(let source, let destination):
                touch(destination)
                do {
                    try copyAtomically(from: source, to: destination)
                    recordCopy(destination, source: source.resolvingSymlinksInPath())
                    note(destination, copied: true)
                } catch {
                    errors.append("Kunde inte kopiera \(destination.lastPathComponent): \(error.localizedDescription)")
                }
            case .convertAndCopy(let nef, let destination):
                touch(destination)
                do {
                    var dng = converted[nef.path]
                    if dng == nil {
                        let existing = dngDir.appendingPathComponent(destination.lastPathComponent)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: existing.path, isDirectory: &isDir), !isDir.boolValue {
                            dng = existing
                        } else {
                            try fm.createDirectory(at: dngDir, withIntermediateDirectories: true)
                            dng = try await converter(nef, dngDir)
                        }
                        converted[nef.path] = dng
                    }
                    guard let dng else { throw SyncError(message: "Ingen DNG skapades.") }
                    try copyAtomically(from: dng, to: destination)
                    recordCopy(destination, source: dng.resolvingSymlinksInPath())
                    note(destination, copied: true)
                } catch {
                    errors.append("Kunde inte konvertera/kopiera \(nef.lastPathComponent): \(error.localizedDescription)")
                }
            }
            done += 1
            progress(done, total)
        }

        // Städa tomma skicka-mappar (bara om helt tomma, bortsett från .DS_Store).
        for dir in touchedFolders where dir.lastPathComponent.hasSuffix(folderSuffix) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path),
                  names.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? fm.removeItem(at: dir)
        }

        // Poster vars fil försvunnit tas bort ur manifestet utan varning.
        for k in manifest.files.keys where !exists(outputDir.appendingPathComponent(k)) {
            manifest.files[k] = nil
        }
        do { try manifest.save(to: outputDir) } catch {
            errors.append("Kunde inte spara \(manifestFileName): \(error.localizedDescription)")
        }

        let addresses = tallies.keys.sorted().map { a in
            let t = tallies[a]!
            return AddressSummary(address: a, folder: folder(in: outputDir, address: a),
                                  fileCount: t.fileCount, bytes: t.bytes, copied: t.copied, removed: t.removed)
        }
        return (Summary(addresses: addresses, conflicts: conflicts, warnings: warnings, errors: errors), manifest)
    }
}
