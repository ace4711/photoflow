import Foundation
import Observation

/// Vymodellen för spelaren: väljer vad som ska spelas. Lokala MP4:n först; saknas den hämtas en ny
/// signerad URL till serverns rendering (de gäller bara en timme, så de sparas aldrig).
@Observable
final class ReelPlayerModel {

    enum Source: Equatable {
        case local(URL)
        case remote(URL)
    }

    enum State: Equatable {
        case loading
        case ready(Source)
        case failed(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored var serviceFactory: () -> ReelStatusService? = { ReelStatusService.live() }

    func load(_ request: ReelPlayerRequest) async {
        state = .loading
        if let path = request.filePath, FileManager.default.fileExists(atPath: path) {
            state = .ready(.local(URL(fileURLWithPath: path)))
            return
        }
        guard let objectId = request.objectId else {
            state = .failed("Filmfilen finns inte längre på disk.")
            return
        }
        guard let service = serviceFactory() else {
            state = .failed("Filmfilen saknas här och Objektfilm-servern är inte inställd (Inställningar → Objektfilm).")
            return
        }
        switch await service.lookup(objectId, force: true) {
        case .info(let info):
            let render = request.renderId.flatMap { id in info.renders.first { $0.renderId == id && $0.url != nil } }
                ?? info.playableRender()
            if let url = render?.url { state = .ready(.remote(url)) }
            else { state = .failed("Servern har ingen renderad film att spela än.") }
        case .gone:
            state = .failed("Filmen finns inte längre på servern.")
        case .unreachable:
            state = .failed("Servern svarar inte, och filmfilen saknas lokalt.")
        }
    }
}
