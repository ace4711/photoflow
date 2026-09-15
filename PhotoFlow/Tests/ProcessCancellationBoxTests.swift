import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `ProcessCancellationBox`, the helper that bridges a `Process` (which
/// has no concept of Swift concurrency cancellation) to `withTaskCancellationHandler`
/// inside `PipelineRunner.runProcess`. Before this fix, `PipelineRunner.cancel()`
/// only terminated whichever single `Process` happened to be running at that exact
/// instant, and `startPipeline` simply moved on to its next step afterwards — so
/// cancel/pause didn't actually stop the pipeline.
struct ProcessCancellationBoxTests {

    @Test("register lyckas innan cancel() anropats")
    func register_succeedsBeforeCancel() {
        let box = ProcessCancellationBox()
        let process = Process()
        #expect(box.register(process) == true)
        #expect(box.isCancelled == false)
    }

    @Test("register misslyckas efter cancel() — processen ska aldrig startas")
    func register_failsAfterCancel() {
        let box = ProcessCancellationBox()
        box.cancel()
        let process = Process()
        #expect(box.register(process) == false)
        #expect(box.isCancelled == true)
    }

    @Test("cancel() efter register() terminerar den registrerade processen")
    func cancel_afterRegister_terminatesProcess() {
        let box = ProcessCancellationBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try? process.run()
        #expect(process.isRunning == true)

        #expect(box.register(process) == true)
        box.cancel()

        // terminate() delivers SIGTERM asynchronously — wait briefly for the
        // process to actually exit rather than asserting isRunning immediately.
        process.waitUntilExit()
        #expect(process.isRunning == false)
        #expect(box.isCancelled == true)
    }
}
