import Foundation
import Testing
@testable import PhotoFlow

/// Workerns tillståndsmaskin med en låtsasklient och en låtsasrenderare (ingen video, inget nätverk).
struct ReelRenderWorkerTests {

    /// Låtsasserverns renderkö.
    actor MockQueue: ReelRenderQueueAPI {
        var jobs: [ReelRenderJob]
        var claimError: Error?
        var heartbeatError: Error?
        var uploadError: Error?
        private(set) var heartbeats = 0
        private(set) var claims = 0
        private(set) var uploads: [(jobId: String, bytes: Int, width: Int, height: Int)] = []
        private(set) var failures: [String] = []

        init(jobs: [ReelRenderJob] = []) { self.jobs = jobs }
        func setHeartbeatError(_ e: Error?) { heartbeatError = e }
        func setUploadError(_ e: Error?) { uploadError = e }
        func setClaimError(_ e: Error?) { claimError = e }

        func claim(wait: Int) async throws -> ReelRenderJob? {
            claims += 1
            if let claimError { throw claimError }
            if jobs.isEmpty { try await Task.sleep(for: .milliseconds(5)); return nil }
            return jobs.removeFirst()
        }
        func heartbeat(jobId: String) async throws {
            heartbeats += 1
            if let heartbeatError { throw heartbeatError }
        }
        func uploadOutput(jobId: String, file: URL, width: Int, height: Int, duration: Double) async throws {
            if let uploadError { throw uploadError }
            let size = (try? Data(contentsOf: file).count) ?? -1
            uploads.append((jobId, size, width, height))
        }
        func fail(jobId: String, message: String) async throws { failures.append(message) }
    }

    nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ReelWorkerEvent] = []
        func add(_ e: ReelWorkerEvent) { lock.lock(); list.append(e); lock.unlock() }
        var all: [ReelWorkerEvent] { lock.lock(); defer { lock.unlock() }; return list }
    }

    struct Fixture {
        var root: URL
        var reel: URL
        var source: URL
        var indexURL: URL
        var job: ReelRenderJob
    }

    private func fixture(register: Bool = true, deleteImages: Bool = false) throws -> Fixture {
        let root = try ObjektfilmTestKit.tempDir()
        let reel = root.appendingPathComponent("Hus FILM")
        let source = root.appendingPathComponent("Hus FÄRDIGA")
        try FileManager.default.createDirectory(at: reel, withIntermediateDirectories: true)
        let items = try ObjektfilmTestKit.realItems(count: 5, in: source)
        var options = ReelComposer.Options()
        options.count = 3
        options.address = "Testgatan 1"
        let local = ReelComposer.compose(items: items, specDirectory: reel, options: options).spec
        // Servern lagrar bara store-källor.
        let remote = ReelUploadPlanner.storeSpec(local)
        let state = ReelRemoteState(server: "http://x", objectId: "obj-1", reelId: local.id, lastSyncedRevision: 1,
                                    sourceRelativePath: ReelComposer.relativePath(from: reel, to: source))
        try state.save(to: reel)
        let indexURL = root.appendingPathComponent("index.json")
        if register { try ReelRemoteIndex.register(objectId: "obj-1", directory: reel, at: indexURL) }
        if deleteImages { for item in items { try? FileManager.default.removeItem(at: item.url) } }
        let job = ReelRenderJob(jobId: "job-1", objectId: "obj-1", reelId: local.id, revision: 2,
                                outputId: local.outputs[0].id, spec: remote)
        return .init(root: root, reel: reel, source: source, indexURL: indexURL, job: job)
    }

    /// Låtsasrenderare: skriver en liten fil, och kollar att alla bilder har lokala källor som finns.
    private static let fakeExport: ReelRenderWorker.Export = { spec, dir, output, url, progress in
        let renderer = ReelRenderer(spec: spec, specDirectory: dir, maxOutputSize: CGSize(width: output.width, height: output.height))
        for asset in spec.assets where renderer.fileURL(for: asset) == nil { throw ReelRenderError.assetNotFound(id: asset.id) }
        progress(0.5)
        try Data("mp4".utf8).write(to: url)
        progress(1)
    }

    private func worker(_ queue: MockQueue, _ f: Fixture, events: Events, interval: Duration = .seconds(60),
                        export: @escaping ReelRenderWorker.Export = ReelRenderWorkerTests.fakeExport) -> ReelRenderWorker {
        ReelRenderWorker(api: queue, indexURL: f.indexURL, heartbeatInterval: interval, pollWait: 0,
                         retryDelay: { _ in .milliseconds(1) }, export: export, onEvent: { events.add($0) })
    }

    @Test("Inget jobb: workern väntar")
    func idle() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let events = Events()
        let outcome = await worker(MockQueue(), f, events: events).runOnce()
        #expect(outcome == .idle)
        #expect(events.all == [.waiting])
    }

    @Test("Ett godkänt jobb renderas, laddas upp och sparas lokalt i FILM-mappen")
    func happyPath() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        let events = Events()
        let outcome = await worker(queue, f, events: events).runOnce()
        let local = f.reel.appendingPathComponent("reel_9x16.mp4")
        #expect(outcome == .rendered(local))
        #expect(FileManager.default.fileExists(atPath: local.path))
        let uploads = await queue.uploads
        #expect(uploads.count == 1)
        #expect(uploads.first?.jobId == "job-1" && uploads.first?.bytes == 3)
        #expect(uploads.first?.width == 1080 && uploads.first?.height == 1920)
        #expect(await queue.failures.isEmpty)
        let all = events.all
        #expect(all.first == .started(objectId: "obj-1"))
        #expect(all.last == .rendered(objectId: "obj-1", address: "Testgatan 1", file: local))
        #expect(all.contains(.progress(objectId: "obj-1", fraction: 0.5)))
    }

    @Test("Okänd mapp: jobbet markeras som misslyckat med ett svenskt meddelande")
    func unknownFolder() async throws {
        let f = try fixture(register: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        let outcome = await worker(queue, f, events: Events()).runOnce()
        guard case .failed(let message) = outcome else { Issue.record("väntade failed, fick \(outcome)"); return }
        #expect(message.contains("mapp"))
        #expect(await queue.failures == [message])
        #expect(await queue.uploads.isEmpty)
    }

    @Test("Bilder som saknas på Macen: fail, ingen rendering")
    func missingImages() async throws {
        let f = try fixture(deleteImages: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        let outcome = await worker(queue, f, events: Events()).runOnce()
        guard case .failed(let message) = outcome else { Issue.record("väntade failed"); return }
        #expect(message.contains("bild"))
        #expect(await queue.failures.count == 1)
    }

    @Test("Renderingen kastar: fail med felets text")
    func renderError() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        let outcome = await worker(queue, f, events: Events(), export: { _, _, _, _, _ in
            throw ReelRenderError.writerFailed("diskfull")
        }).runOnce()
        guard case .failed(let message) = outcome else { Issue.record("väntade failed"); return }
        #expect(message.contains("diskfull"))
        #expect(await queue.failures.count == 1)
        #expect(await queue.uploads.isEmpty)
    }

    @Test("Heartbeat skickas under rendering, och superseded avbryter den och slänger filen")
    func supersededDuringRender() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        await queue.setHeartbeatError(ReelServerError.superseded("Ersatt."))
        let events = Events()
        let cancelled = Flag()
        let outcome = await worker(queue, f, events: events, interval: .milliseconds(20), export: { _, _, _, url, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(); throw error }
            try Data("mp4".utf8).write(to: url)
        }).runOnce()
        #expect(outcome == .superseded)
        #expect(cancelled.value)
        #expect(await queue.heartbeats >= 1)
        #expect(await queue.uploads.isEmpty)
        #expect(await queue.failures.isEmpty)
        #expect(events.all.last == .superseded(objectId: "obj-1"))
        #expect(!FileManager.default.fileExists(atPath: f.reel.appendingPathComponent("reel_9x16.mp4").path))
    }

    @Test("Tillfälligt nätverksfel i heartbeat avbryter inte renderingen")
    func heartbeatNetworkErrorIsIgnored() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        await queue.setHeartbeatError(ReelServerError.network("nere"))
        let outcome = await worker(queue, f, events: Events(), interval: .milliseconds(10), export: { _, _, _, url, _ in
            try await Task.sleep(for: .milliseconds(120))
            try Data("mp4".utf8).write(to: url)
        }).runOnce()
        guard case .rendered = outcome else { Issue.record("väntade rendered, fick \(outcome)"); return }
        #expect(await queue.heartbeats >= 2)
    }

    @Test("409 superseded vid uppladdning: filen slängs lokalt")
    func supersededAtUpload() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        await queue.setUploadError(ReelServerError.superseded("Ersatt."))
        let outcome = await worker(queue, f, events: Events()).runOnce()
        #expect(outcome == .superseded)
        #expect(!FileManager.default.fileExists(atPath: f.reel.appendingPathComponent("reel_9x16.mp4").path))
        #expect(await queue.failures.isEmpty)
    }

    @Test("Uppladdningen misslyckas: fail (filen får ligga kvar lokalt)")
    func uploadFails() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue(jobs: [f.job])
        await queue.setUploadError(ReelServerError.network("bortkopplad"))
        let outcome = await worker(queue, f, events: Events()).runOnce()
        guard case .failed(let message) = outcome else { Issue.record("väntade failed"); return }
        #expect(message.contains("Uppladdningen"))
        #expect(await queue.failures.count == 1)
    }

    @Test("Nätverksfel vid claim ger error, nekad nyckel ger unauthorized")
    func claimErrors() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let queue = MockQueue()
        await queue.setClaimError(ReelServerError.network("nere"))
        let w = worker(queue, f, events: Events())
        #expect(await w.runOnce() == .error(ReelServerError.network("nere").localizedDescription))
        await queue.setClaimError(ReelServerError.api(status: 401, code: "unauthorized", message: "Ogiltig nyckel."))
        #expect(await w.runOnce() == .unauthorized("Ogiltig nyckel."))
    }

    @Test("Slingan hämtar jobb efter jobb, backar vid fel och slutar vid avbrott eller nekad nyckel")
    func runLoop() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var second = f.job
        second.jobId = "job-2"
        let queue = MockQueue(jobs: [f.job, second])
        let events = Events()
        let w = worker(queue, f, events: events)
        let task = Task { await w.run() }
        // Vänta tills båda jobben är uppladdade.
        for _ in 0..<200 where await queue.uploads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await queue.uploads.map(\.jobId) == ["job-1", "job-2"])
        task.cancel()
        await task.value   // slingan avslutas

        let denied = MockQueue()
        await denied.setClaimError(ReelServerError.api(status: 403, code: "wrong_scope", message: "Fel nyckel."))
        let w2 = worker(denied, f, events: Events())
        await w2.run()     // returnerar av sig själv
        #expect(await denied.claims == 1)
    }
}
