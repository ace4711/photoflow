import Foundation

/// Det workern berättar om (för indikator och notiser).
nonisolated enum ReelWorkerEvent: Sendable, Equatable {
    /// Inget jobb just nu (long-poll gav 204).
    case waiting
    case started(objectId: String)
    case progress(objectId: String, fraction: Double)
    /// Filmen är renderad, uppladdad och sparad i FILM-mappen.
    case rendered(objectId: String, address: String, file: URL)
    /// Mäklaren ändrade efter godkännandet; jobbet avbröts och filen slängdes.
    case superseded(objectId: String)
    case failed(objectId: String, message: String)
    /// Nätverks-/serverfel; workern försöker igen (eller slutar om nyckeln nekas).
    case error(String)
}

nonisolated enum ReelWorkerOutcome: Sendable, Equatable {
    case idle
    case rendered(URL)
    case superseded
    case failed(String)
    case error(String)
    /// Nyckeln nekades (401/403): fortsatta försök vore meningslösa.
    case unauthorized(String)
}

/// Renderworkern: hämtar godkända filmer ur serverns renderkö och renderar dem här på Macen, där
/// originalbilderna finns. Ett jobb går så här:
///
/// claim → slå upp FILM-mappen (appindexet `objectId → mapp`) → servern spec `store → local` via
/// sha256 (`ReelSyncMerger`) → `ReelRenderer.export` till FILM-mappen → ladda upp MP4 → klar.
/// Under renderingen skickas en heartbeat var 60:e sekund; 409 `superseded` avbryter renderingen och
/// kastar filen. `ProcessInfo.beginActivity` hindrar App Nap från att strypa renderingen.
///
/// Workern körs bara medan appen är igång (en `Task` som styrs av `ReelWorkerController`).
actor ReelRenderWorker {

    typealias Export = @Sendable (_ spec: ReelSpec, _ specDirectory: URL, _ output: ReelSpec.Output,
                                  _ url: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

    private let api: any ReelRenderQueueAPI
    private let indexURL: URL
    private let heartbeatInterval: Duration
    private let pollWait: Int
    private let export: Export
    private let onEvent: @Sendable (ReelWorkerEvent) -> Void
    private let retryDelay: @Sendable (Int) -> Duration

    init(api: any ReelRenderQueueAPI,
         indexURL: URL = ReelRemoteIndex.defaultURL,
         heartbeatInterval: Duration = .seconds(60),
         pollWait: Int = 25,
         retryDelay: @escaping @Sendable (Int) -> Duration = { .seconds(min(5 << min($0, 4), 60)) },
         export: @escaping Export = { spec, dir, output, url, progress in
             try await ReelRenderer.export(spec: spec, specDirectory: dir, output: output, to: url, progress: progress)
         },
         onEvent: @escaping @Sendable (ReelWorkerEvent) -> Void = { _ in }) {
        self.api = api
        self.indexURL = indexURL
        self.heartbeatInterval = heartbeatInterval
        self.pollWait = pollWait
        self.retryDelay = retryDelay
        self.export = export
        self.onEvent = onEvent
    }

    /// Slingan: hämtar och renderar jobb tills tasken avbryts. Vid nätverksfel väntar den med växande
    /// paus; nekas nyckeln (401/403) slutar den, eftersom nya försök bara skulle hamra på servern.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            let outcome = await runOnce()
            switch outcome {
            case .unauthorized:
                return
            case .error:
                failures += 1
                do { try await Task.sleep(for: retryDelay(failures)) } catch { return }
            default:
                failures = 0
            }
        }
    }

    /// Ett varv: ett long-poll-anrop och, om det gav ett jobb, hela jobbet.
    @discardableResult
    func runOnce() async -> ReelWorkerOutcome {
        let job: ReelRenderJob?
        do {
            job = try await api.claim(wait: pollWait)
        } catch is CancellationError {
            return .idle
        } catch {
            if Task.isCancelled { return .idle }
            let message = error.localizedDescription
            onEvent(.error(message))
            if case ReelServerError.api(let status, _, _) = error, status == 401 || status == 403 { return .unauthorized(message) }
            return .error(message)
        }
        guard let job else {
            onEvent(.waiting)
            return .idle
        }
        return await process(job)
    }

    // MARK: Ett jobb

    private func process(_ job: ReelRenderJob) async -> ReelWorkerOutcome {
        let objectId = job.objectId
        onEvent(.started(objectId: objectId))

        guard let directory = ReelRemoteIndex.directory(for: objectId, at: indexURL) else {
            return await fail(job, "Filmens mapp finns inte på den här Macen.")
        }
        let state = ReelRemoteState.load(from: directory)
        let files: [String: URL]
        if let source = state?.sourceDirectory(relativeTo: directory) {
            files = await ReelFileIndex.build(sourceDirectory: source)
        } else {
            files = [:]
        }
        let local = (try? Data(contentsOf: directory.appendingPathComponent("reel.json"))).flatMap { try? ReelSpec.decode(from: $0) }
        let merged = ReelSyncMerger.merge(remote: job.spec, local: local, files: files, specDirectory: directory,
                                          analyses: ReelImageAnalyzer.loadCache(from: directory))
        guard merged.isComplete else {
            return await fail(job, "\(merged.missing.count) bild(er) i filmen finns inte på den här Macen.")
        }
        guard let output = merged.spec.outputs.first(where: { $0.id == job.outputId }) else {
            return await fail(job, "Exportprofilen \"\(job.outputId)\" finns inte i specen.")
        }

        let target = directory.appendingPathComponent("reel_\(output.aspect.replacingOccurrences(of: ":", with: "x")).mp4")
        let duration = ReelTimeline.totalDuration(merged.spec)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "PhotoFlow renderar en objektfilm")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Heartbeat parallellt med renderingen; superseded avbryter renderingen.
        let superseded = Flag()
        let spec = merged.spec
        let export = self.export
        let onEvent = self.onEvent
        let renderTask = Task {
            let gate = ProgressGate()
            try await export(spec, directory, output, target) { p in
                if gate.advance(to: Int(p * 100)) { onEvent(.progress(objectId: objectId, fraction: p)) }
            }
        }
        let api = self.api
        let interval = heartbeatInterval
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                do { try await api.heartbeat(jobId: job.jobId) }
                catch ReelServerError.superseded { superseded.set(); renderTask.cancel(); return }
                catch { /* tillfälligt nätverksfel: leasen är 10 min, nästa heartbeat provar igen */ }
            }
        }
        // Om workern själv avbryts (appen stängs, reglaget stängs av) ska renderingen också avbrytas.
        let renderResult: Result<Void, Error> = await withTaskCancellationHandler {
            do { try await renderTask.value; return .success(()) } catch { return .failure(error) }
        } onCancel: { renderTask.cancel() }
        heartbeat.cancel()

        if superseded.value {
            try? FileManager.default.removeItem(at: target)
            onEvent(.superseded(objectId: objectId))
            return .superseded
        }
        if case .failure(let error) = renderResult {
            if error is CancellationError || Task.isCancelled { return .idle }
            return await fail(job, error.localizedDescription)
        }

        do {
            try await api.uploadOutput(jobId: job.jobId, file: target, width: output.width, height: output.height, duration: duration)
        } catch ReelServerError.superseded {
            try? FileManager.default.removeItem(at: target)
            onEvent(.superseded(objectId: objectId))
            return .superseded
        } catch {
            if Task.isCancelled { return .idle }
            return await fail(job, "Uppladdningen misslyckades: \(error.localizedDescription)")
        }
        onEvent(.rendered(objectId: objectId, address: merged.spec.property.address, file: target))
        return .rendered(target)
    }

    private func fail(_ job: ReelRenderJob, _ message: String) async -> ReelWorkerOutcome {
        _ = try? await api.fail(jobId: job.jobId, message: message)
        onEvent(.failed(objectId: job.objectId, message: message))
        return .failed(message)
    }
}

/// En flagga som kan sättas från en annan tråd.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Släpper bara igenom ökande heltalsprocent (renderingens förlopp kommer från en bakgrundstråd).
nonisolated final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func advance(to v: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v > value else { return false }
        value = v
        return true
    }
}
