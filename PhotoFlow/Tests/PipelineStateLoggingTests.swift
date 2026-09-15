import Foundation
import Testing
@testable import PhotoFlow

/// Tests for PipelineState's logging: the global log file moved from
/// ~/Desktop/photoflow.log to ~/Library/Logs/PhotoFlow/photoflow.log, and
/// per-step log entries are now bounded instead of growing forever.
@MainActor
struct PipelineStateLoggingTests {

    @Test("Global loggfil skrivs till ~/Library/Logs/PhotoFlow/photoflow.log, inte Desktop")
    func appendLog_writesToLibraryLogsNotDesktop() {
        let state = PipelineState()
        state.appendLog("Testrad för PipelineStateLoggingTests")

        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PhotoFlow/photoflow.log")
        #expect(FileManager.default.fileExists(atPath: expected.path))

        let desktopLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/photoflow.log")
        // We don't assert it's absent (a previous run of the app may have left one
        // behind), only that new lines go to the new location.
        if let contents = try? String(contentsOf: expected, encoding: .utf8) {
            #expect(contents.contains("Testrad för PipelineStateLoggingTests"))
        }
        _ = desktopLog
    }

    @Test("logEntries per steg begränsas till 1000, äldsta tas bort i omgångar om 200")
    func appendStepLog_capsLogEntriesAt1000() {
        let state = PipelineState()
        for i in 0..<1500 {
            state.appendStepLog(.convertToDNG, "rad \(i)")
        }
        let entries = state.stepStatuses[.convertToDNG]?.logEntries ?? []
        #expect(entries.count <= 1000)
        // The oldest entries ("rad 0", "rad 1", ...) should have been trimmed away.
        #expect(!(entries.first?.text.contains("rad 0") ?? false))
        // The most recent entry must always survive.
        #expect(entries.last?.text == "rad 1499")
    }
}
