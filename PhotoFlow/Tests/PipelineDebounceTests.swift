import Foundation
import Testing
@testable import PhotoFlow

/// Fas 1a (#6): debounce av manifestskrivningen och buffrad `pipeline.log`.
/// Minnestillståndet är alltid aktuellt; bara disken släpar högst ett intervall,
/// och ingenting går förlorat vid stegavslut, fel, flush eller pipelinens slut.
@MainActor
struct PipelineDebounceTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineDebounceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskProcessed(_ dir: URL, _ step: DashboardStep) -> Int? {
        SessionManifestStore.load(from: dir)?.steps[step.manifestKey]?.processedCount
    }

    @Test("En svit förloppsuppdateringar slås ihop och det SISTA värdet hamnar på disk")
    func burst_writesLastValue() async throws {
        let dir = tempDir()
        let state = PipelineState()
        state.manifestWriteInterval = 0.3
        state.outputDirectory = dir

        for i in 1...50 { state.updateStepProgress(.convertToDNG, processed: i, total: 50) }

        // Första uppdateringen skrevs direkt; resten väntar på intervallet.
        #expect(diskProcessed(dir, .convertToDNG) == 1)
        #expect(state.sessionManifest?.steps[DashboardStep.convertToDNG.manifestKey]?.processedCount == 50)

        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(diskProcessed(dir, .convertToDNG) == 50)
        #expect(state.manifestWriteCount == 2)
    }

    @Test("completeStep skriver direkt, även mitt i ett debounce-intervall")
    func completeStep_forcesWrite() {
        let dir = tempDir()
        let state = PipelineState()
        state.manifestWriteInterval = 60
        state.outputDirectory = dir

        state.updateStepProgress(.createHDR, processed: 1, total: 9)
        state.updateStepProgress(.createHDR, processed: 5, total: 9)
        #expect(diskProcessed(dir, .createHDR) == 1)

        state.completeStep(.createHDR, count: 9)
        let record = SessionManifestStore.load(from: dir)?.steps[DashboardStep.createHDR.manifestKey]
        #expect(record?.phase == "complete")
        #expect(record?.processedCount == 9)
    }

    @Test("Fel och avbrott (fasbyte som inte är aktiv/köad) skrivs direkt")
    func errorAndCancel_forceWrite() {
        let dir = tempDir()
        let state = PipelineState()
        state.manifestWriteInterval = 60
        state.outputDirectory = dir

        state.updateStep(.enhancePhotos, phase: .active)       // första skrivningen (direkt)
        state.updateStepProgress(.enhancePhotos, processed: 3, total: 10) // debounceas
        state.updateStep(.enhancePhotos, phase: .error("fel"))
        #expect(SessionManifestStore.load(from: dir)?.steps[DashboardStep.enhancePhotos.manifestKey]?.phase.hasPrefix("error") == true)

        state.updateStepProgress(.aiTagging, processed: 2, total: 10)
        state.updateStep(.aiTagging, phase: .idle)              // avbrutet
        #expect(SessionManifestStore.load(from: dir)?.steps[DashboardStep.aiTagging.manifestKey]?.phase == "idle")
    }

    @Test("flushManifest skriver en väntande ändring, och är en no-op när inget väntar")
    func flush_writesPending() {
        let dir = tempDir()
        let state = PipelineState()
        state.manifestWriteInterval = 60
        state.outputDirectory = dir

        state.updateStepProgress(.convertToDNG, processed: 1, total: 4)
        state.updateStepProgress(.convertToDNG, processed: 3, total: 4)
        #expect(diskProcessed(dir, .convertToDNG) == 1)
        let before = state.manifestWriteCount

        state.flushManifest()
        #expect(diskProcessed(dir, .convertToDNG) == 3)
        #expect(state.manifestWriteCount == before + 1)

        state.flushManifest()
        #expect(state.manifestWriteCount == before + 1)
    }

    @Test("reset() skriver en väntande ändring till den gamla sessionens mapp")
    func reset_flushesPendingToOldDirectory() {
        let dir = tempDir()
        let state = PipelineState()
        state.manifestWriteInterval = 60
        state.outputDirectory = dir

        state.updateStepProgress(.convertToDNG, processed: 1, total: 4)
        state.updateStepProgress(.convertToDNG, processed: 4, total: 4)
        state.reset()
        #expect(diskProcessed(dir, .convertToDNG) == 4)
    }

    // MARK: - pipeline.log

    @Test("pipeline.log: raderna hamnar direkt i filen men fsync görs högst en gång per intervall")
    func pipelineLog_throttlesFsync() throws {
        let dir = tempDir()
        let logURL = dir.appendingPathComponent("pipeline.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let runner = PipelineRunner(state: PipelineState())
        runner.pipelineLogHandle = FileHandle(forWritingAtPath: logURL.path)

        for i in 0..<200 { runner.writePipelineLogLine("rad \(i)") }

        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("rad 0"))
        #expect(text.contains("rad 199"))
        // Första raden synkas direkt (inget tidigare fsync), resten väntar på intervallet.
        #expect(runner.pipelineLogSyncCount == 1)
        #expect(runner.pipelineLogNeedsSync)

        runner.flushPipelineLog()
        #expect(runner.pipelineLogSyncCount == 2)
        #expect(!runner.pipelineLogNeedsSync)
        runner.flushPipelineLog()
        #expect(runner.pipelineLogSyncCount == 2)
    }
}
