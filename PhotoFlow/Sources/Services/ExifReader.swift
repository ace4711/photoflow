import Foundation
import ImageIO

/// One photo's EXIF fields as read by `ExifReader`, used as input to
/// `BracketAnalyzer`. Mirrors exactly the fields the old embedded Python script
/// pulled from exiftool's CSV output.
struct ExifRecord: Codable, Sendable, Equatable {
    var filename: String
    /// Exposure time formatted the way exiftool prints it (e.g. "1/60", "0.6", "2")
    /// — kept as a string because `bracket_groups.json`'s `"exposures"` array has
    /// always stored it this way, and old sessions' JSON must stay parseable.
    var exposureTime: String
    var exposureSeconds: Double
    var fNumber: Double
    var iso: Int
    var dateTimeOriginal: Date
    /// Fractional seconds parsed from SubSecTimeOriginal (e.g. "5" -> 0.5, "50" -> 0.50).
    var subsec: Double
    /// TIFF/EXIF orientation (1 = normal, matches `kCGImagePropertyTIFFOrientation`).
    var orientation: Int

    /// `dateTimeOriginal` plus `subsec`, as a Unix timestamp — this is exactly
    /// Python's `precise_ts = dt.timestamp() + subsec_val`, used by
    /// `BracketAnalyzer` to measure time gaps between shots at sub-second
    /// precision.
    var preciseTimestamp: Double {
        dateTimeOriginal.timeIntervalSince1970 + subsec
    }
}

enum ExifReaderError: LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "exiftool-fel vid EXIF-läsning: \(msg)"
        }
    }
}

/// Reads the EXIF fields bracket analysis needs directly from NEF files via
/// ImageIO, replacing the old `exiftool -csv ...` + embedded Python parsing.
///
/// ## ExposureTime is a documented exception
/// `kCGImagePropertyExifExposureTime` was verified against exiftool's raw EXIF
/// rational (`exiftool -v3`, tag 0x829a) on 142 real bracket-sequence NEFs
/// (Nikon, scratchpad session `chronas_session`): FNumber, ISO,
/// DateTimeOriginal and SubSecTimeOriginal matched exiftool exactly on all 142
/// files, but ExposureTime did **not** — 17 of 142 files (12%) with a true
/// exposure time in the 0.3–0.4s range (raw rationals like 10/25 = 0.4s or
/// 3/10 = 0.3s) were misread by ImageIO as exactly 1/3 s (0.3333...), a ~0.3–0.4
/// EV error. This is large enough to change bracket classification (unique EV
/// levels, HDR subset selection), so `ExposureTime` alone falls back to a
/// single batched `exiftool -csv -FileName -ExposureTime -@ -` call; every
/// other field is read via ImageIO. See FORBATTRINGAR.md ("Fas 2a") for the
/// full comparison.
// Pure/stateless (no actor-isolated state) and deliberately run off the main
// actor: `readAll` fans out ImageIO reads across up to `maxConcurrentReads`
// concurrent tasks for throughput on multi-hundred-photo shoots. Under
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor this would otherwise be inferred
// MainActor-isolated, silently serializing all that work back onto the main
// thread.
nonisolated enum ExifReader {
    /// Cap on simultaneous ImageIO reads — plenty of parallelism without
    /// spawning hundreds of threads for a multi-hundred-photo shoot.
    private static let maxConcurrentReads = 8

    /// Reads EXIF for every file in `nefFiles`, in parallel (up to
    /// `maxConcurrentReads` at a time). Files that fail to parse (unreadable,
    /// missing DateTimeOriginal) are silently skipped — matches the old Python
    /// script's `if not dt: continue`.
    static func readAll(nefFiles: [URL], exiftoolPath: String) async throws -> [ExifRecord] {
        let exposureTimes = try exiftoolExposureTimes(for: nefFiles, exiftoolPath: exiftoolPath)

        return try await withThrowingTaskGroup(of: ExifRecord?.self) { group in
            var results: [ExifRecord] = []
            results.reserveCapacity(nefFiles.count)

            var iterator = nefFiles.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask {
                    readImageIOFields(url: url, exposureTimeOverride: exposureTimes[url.lastPathComponent])
                }
            }
            for _ in 0..<maxConcurrentReads { addNext() }

            while let record = try await group.next() {
                if let record { results.append(record) }
                addNext()
            }
            return results
        }
    }

    // MARK: - ImageIO

    private static func readImageIOFields(url: URL, exposureTimeOverride: String?) -> ExifRecord? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        guard let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
              let date = parseEXIFDate(dateString) else {
            return nil
        }

        let fNumber = (exif?[kCGImagePropertyExifFNumber] as? Double) ?? 0
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? 0
        let subsecDigitsRaw = (exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String) ?? ""
        let orientation = (tiff?[kCGImagePropertyTIFFOrientation] as? Int) ?? 1

        let exposureTimeString: String
        let exposureSeconds: Double
        if let override = exposureTimeOverride, let parsed = try? parseExposureString(override) {
            // exiftool's own printed string — see the fallback rationale above.
            exposureTimeString = override
            exposureSeconds = parsed
        } else {
            let seconds = (exif?[kCGImagePropertyExifExposureTime] as? Double) ?? 0
            exposureTimeString = formatExposureTime(seconds)
            exposureSeconds = seconds
        }

        return ExifRecord(
            filename: url.lastPathComponent,
            exposureTime: exposureTimeString,
            exposureSeconds: exposureSeconds,
            fNumber: fNumber,
            iso: iso,
            dateTimeOriginal: date,
            subsec: parseSubsec(subsecDigitsRaw),
            orientation: orientation
        )
    }

    // MARK: - exiftool fallback (ExposureTime only)

    /// Reads just `ExposureTime` for every file via one batched exiftool
    /// invocation (paths piped over stdin, same as the old pipeline, to avoid
    /// argument-list limits with large file counts).
    private static func exiftoolExposureTimes(for files: [URL], exiftoolPath: String) throws -> [String: String] {
        guard !files.isEmpty else { return [:] }

        let pathsList = files.map(\.path).joined(separator: "\n")
        let csv = try runProcessCapturingStdout(
            executablePath: exiftoolPath,
            arguments: ["-csv", "-FileName", "-ExposureTime", "-@", "-"],
            stdinData: pathsList.data(using: .utf8)
        )

        var result: [String: String] = [:]
        for row in parseCSV(csv) {
            guard let filename = row["FileName"], let exposureTime = row["ExposureTime"] else { continue }
            result[filename] = exposureTime
        }
        return result
    }

    /// Minimal synchronous process runner used only for the exiftool fallback
    /// above. Uses temp files for stdin/stdout, same reasoning as
    /// `PipelineRunner.runProcess`: pipes have small kernel buffers and can
    /// deadlock `waitUntilExit()` when the parent still holds the write end.
    private static func runProcessCapturingStdout(executablePath: String, arguments: [String], stdinData: Data?) throws -> String {
        let tmpDir = NSTemporaryDirectory()
        let uid = UUID().uuidString
        let stdoutFile = URL(fileURLWithPath: tmpDir + uid + ".stdout")
        let stderrFile = URL(fileURLWithPath: tmpDir + uid + ".stderr")
        defer {
            try? FileManager.default.removeItem(at: stdoutFile)
            try? FileManager.default.removeItem(at: stderrFile)
        }
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        process.standardError = try FileHandle(forWritingTo: stderrFile)

        var stdinFile: URL?
        if let stdinData {
            let file = URL(fileURLWithPath: tmpDir + uid + ".stdin")
            try stdinData.write(to: file)
            stdinFile = file
            process.standardInput = try FileHandle(forReadingFrom: file)
        }
        defer { if let stdinFile { try? FileManager.default.removeItem(at: stdinFile) } }

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errMsg = (try? String(contentsOf: stderrFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExifReaderError.processFailed(errMsg.isEmpty ? "exit \(process.terminationStatus)" : errMsg)
        }
        return (try? String(contentsOf: stdoutFile, encoding: .utf8)) ?? ""
    }

    /// Tiny CSV parser sufficient for exiftool's `-csv` output (quoted fields
    /// with embedded commas/quotes, one header row). Not a general-purpose CSV
    /// parser — exiftool never emits newlines inside a field for these tags.
    static func parseCSV(_ text: String) -> [[String: String]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else { return [] }
        let header = parseCSVLine(String(headerLine))
        var rows: [[String: String]] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(String(line))
            guard !fields.isEmpty else { continue }
            var row: [String: String] = [:]
            for (i, key) in header.enumerated() where i < fields.count {
                row[key] = fields[i]
            }
            rows.append(row)
        }
        return rows
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - Parsing helpers (mirror the old Python script exactly)

    /// EXIF's `DateTimeOriginal` format ("yyyy:MM:dd HH:mm:ss") parsed the same
    /// way Python's `datetime.strptime(s, "%Y:%m:%d %H:%M:%S")` did: no explicit
    /// time zone, so (like the old code) it's interpreted in the system's
    /// current time zone.
    static func parseEXIFDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string.trimmingCharacters(in: .whitespaces))
    }

    /// SubSecTimeOriginal can have 1-3 digits ("5" = .5s, "50" = .50s, "500" =
    /// .500s) — treated as decimal digits after "0.", not as an integer count
    /// of centiseconds (which is wrong for anything but exactly 2 digits).
    static func parseSubsec(_ raw: String) -> Double {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return 0 }
        return Double("0.\(digits)") ?? 0
    }

    enum ExposureParseError: Error { case invalid }

    /// Parses an exiftool-formatted exposure string ("1/60", "0.6", "2") back
    /// into seconds — same logic as the old Python `parse_exposure`.
    static func parseExposureString(_ s: String) throws -> Double {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/")
            guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 else {
                throw ExposureParseError.invalid
            }
            return num / den
        }
        guard let value = Double(trimmed) else { throw ExposureParseError.invalid }
        return value
    }

    /// Formats seconds the way exiftool's `PrintExposureTime` does (verified
    /// against `Image::ExifTool::Exif::PrintExposureTime` in exiftool 13.50):
    /// fractions below 0.25001s as "1/N", everything else as a decimal with
    /// trailing ".0" stripped. Only used as a last-resort fallback when the
    /// exiftool CSV lookup has no entry for a file.
    static func formatExposureTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0" }
        if seconds < 0.25001 {
            return "1/\(Int((1 / seconds).rounded()))"
        }
        var formatted = String(format: "%.1f", seconds)
        if formatted.hasSuffix(".0") {
            formatted.removeLast(2)
        }
        return formatted
    }
}
