import Foundation
import Observation

/// Äger renderworkern medan appen är igång: startar den när "Rendera godkända filmer automatiskt"
/// är på och server + render-nyckel finns, stoppar den när reglaget stängs av. Håller det som
/// inställningarna och menyn visar (väntar / renderar / fel) och skickar en notis när en film är klar.
@MainActor
@Observable
final class ReelWorkerController {

    static let shared = ReelWorkerController()

    enum Status: Equatable {
        case off
        case waiting
        case rendering(objectId: String, fraction: Double)
        case error(String)
    }

    private(set) var status: Status = .off
    /// Senast färdiga film (adress), för en rad i inställningarna.
    private(set) var lastRendered: String?
    @ObservationIgnored var config = ObjektfilmConfig()
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Läser inställningarna och startar eller stoppar workern. Anropas vid appstart och när något ändras.
    func apply() {
        stop()
        guard config.autoRender else { return }
        let client: ReelServerClient
        do { client = try config.client(.render) } catch {
            status = .error(error.localizedDescription)
            return
        }
        status = .waiting
        let worker = ReelRenderWorker(api: client, onEvent: { event in
            Task { @MainActor in ReelWorkerController.shared.handle(event) }
        })
        task = Task.detached(priority: .utility) { await worker.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        status = .off
    }

    private func handle(_ event: ReelWorkerEvent) {
        guard task != nil else { return }
        switch event {
        case .waiting: status = .waiting
        case .started(let id): status = .rendering(objectId: id, fraction: 0)
        case .progress(let id, let f): status = .rendering(objectId: id, fraction: f)
        case .rendered(_, let address, let file):
            lastRendered = address
            status = .waiting
            NotificationService.shared.notifyReelRendered(address: address, folder: file.deletingLastPathComponent())
        case .superseded, .failed: status = .waiting
        case .error(let message): status = .error(message)
        }
    }
}
