import Foundation

extension PipelineRunner {
    // MARK: - Process helpers

    func runProcess(
        executablePath: String,
        arguments: [String],
        outputFile: URL? = nil,
        stdinData: Data? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> String {
        // Bridges Process (not itself cancellable) to Swift concurrency task
        // cancellation: withTaskCancellationHandler's onCancel closure runs
        // immediately on the cancelling side, possibly before the process has even
        // been created on the background queue below — the box lets `onCancel`
        // record that and terminate the process as soon as it exists.
        let box = ProcessCancellationBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let tmpDir = NSTemporaryDirectory()
                    let uid = UUID().uuidString

                    // Use temp files instead of pipes to completely avoid pipe buffer deadlocks.
                    // Pipes have limited kernel buffers (~64KB) and can cause Process/waitUntilExit
                    // to hang when the parent holds write-end file descriptors.

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments

                    // stdout → caller-specified file or temp file
                    let stdoutFile: URL
                    if let outputFile {
                        stdoutFile = outputFile
                    } else {
                        stdoutFile = URL(fileURLWithPath: tmpDir + uid + ".stdout")
                    }
                    FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
                    guard let stdoutHandle = FileHandle(forWritingAtPath: stdoutFile.path) else {
                        continuation.resume(throwing: PipelineError.processError("Kunde inte skapa stdout-fil"))
                        return
                    }
                    process.standardOutput = stdoutHandle

                    // stderr → temp file
                    let stderrFile = URL(fileURLWithPath: tmpDir + uid + ".stderr")
                    FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
                    guard let stderrHandle = FileHandle(forWritingAtPath: stderrFile.path) else {
                        continuation.resume(throwing: PipelineError.processError("Kunde inte skapa stderr-fil"))
                        return
                    }
                    process.standardError = stderrHandle

                    // stdin → write data to temp file and use as stdin
                    if let stdinData {
                        let stdinFile = URL(fileURLWithPath: tmpDir + uid + ".stdin")
                        try? stdinData.write(to: stdinFile)
                        if let stdinHandle = FileHandle(forReadingAtPath: stdinFile.path) {
                            process.standardInput = stdinHandle
                        }
                    }

                    // Register with the cancellation box before run() — if the task was
                    // already cancelled, box.register bails out (and terminates/no-ops)
                    // without launching the process at all.
                    guard box.register(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    Task { @MainActor in
                        self?.currentTask = process
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    // No pipes → waitUntilExit cannot deadlock
                    process.waitUntilExit()

                    // Close file handles
                    stdoutHandle.closeFile()
                    stderrHandle.closeFile()

                    // Read results from files
                    let output: String
                    if outputFile != nil {
                        output = "" // caller reads from outputFile directly
                    } else {
                        output = (try? String(contentsOf: stdoutFile, encoding: .utf8)) ?? ""
                        try? FileManager.default.removeItem(at: stderrFile)
                        try? FileManager.default.removeItem(at: stdoutFile)
                    }

                    let stderrData = (try? Data(contentsOf: stderrFile)) ?? Data()
                    try? FileManager.default.removeItem(at: stderrFile)

                    // Clean up stdin temp file
                    let stdinFile = URL(fileURLWithPath: tmpDir + uid + ".stdin")
                    try? FileManager.default.removeItem(at: stdinFile)

                    if box.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        let errorMsg = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: PipelineError.processError(
                            errorMsg.isEmpty ? "Process exited with code \(process.terminationStatus)" : errorMsg
                        ))
                    } else {
                        continuation.resume(returning: output)
                    }
                }
            }
        }, onCancel: {
            box.cancel()
        })
    }
}

/// Bridges a `Process` (which has no concept of Swift concurrency cancellation)
/// to a `Task`'s cancellation via `withTaskCancellationHandler`. The `onCancel`
/// closure of that API can run on any thread and, if the task was already
/// cancelled, runs synchronously before the operation closure even starts — so
/// `register`/`cancel` need their own lock rather than relying on `runProcess`'s
/// background queue for safety.
final class ProcessCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Called once the `Process` object exists, right before `run()`. Returns
    /// `false` if the task was already cancelled by then — the caller should
    /// bail out without ever starting the process.
    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    /// Called from `withTaskCancellationHandler`'s `onCancel`. Terminates the
    /// process immediately if it's already running; if it hasn't been created
    /// yet, `register` will pick up `cancelled` and refuse to start it.
    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        proc?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
