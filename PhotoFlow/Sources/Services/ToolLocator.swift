import Foundation

/// Locates external command-line tools the pipeline shells out to.
///
/// Paths used to be hardcoded (e.g. "/opt/homebrew/bin/exiftool", "/usr/bin/python3")
/// scattered across PipelineRunner. That breaks on an Intel Mac (Homebrew lives in
/// /usr/local/bin there), with pyenv/asdf-managed pythons, or simply if a tool isn't
/// installed yet — instead of a clear "installera X" error, the pipeline would fail
/// deep inside a Process launch with a generic file-not-found error.
enum ToolLocator {
    private static let commonBinDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static func find(_ name: String) -> String? {
        commonBinDirs
            .map { "\($0)/\(name)" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// exiftool — EXIF extraction, preview generation and metadata writing.
    static var exiftool: String? { find("exiftool") }

    /// python3 with `cv2` (OpenCV) and `numpy` importable, needed for Mertens HDR
    /// exposure fusion. Checking this means actually spawning python and trying the
    /// import, so the result is cached for the process lifetime — call
    /// `resetCacheForTesting()` in tests that need a fresh check.
    private static var cachedPython3WithOpenCV: String??

    static var python3WithOpenCV: String? {
        if let cached = cachedPython3WithOpenCV { return cached }
        let result = commonBinDirs
            .map { "\($0)/python3" }
            .first { canImportOpenCV(python3Path: $0) }
        cachedPython3WithOpenCV = result
        return result
    }

    private static func canImportOpenCV(python3Path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: python3Path) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python3Path)
        proc.arguments = ["-c", "import cv2, numpy"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Test-only hook to force a fresh OpenCV check (the result is otherwise cached).
    static func resetCacheForTesting() {
        cachedPython3WithOpenCV = nil
    }
}
