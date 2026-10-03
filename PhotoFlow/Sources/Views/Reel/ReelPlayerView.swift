import SwiftUI
import AppKit
import AVKit

/// Spelarfönstret: filmen i rätt proportioner (9:16 får ett högt fönster) med AVPlayerViews egna
/// kontroller (spela/pausa/skrubba), mellanslag för spela/pausa och knapparna Visa i Finder, Dela och
/// Öppna i Bildspel i verktygsfältet. Spelar den lokala MP4:n, annars serverns rendering via signerad URL.
struct ReelPlayerView: View {
    let request: ReelPlayerRequest

    @State private var model = ReelPlayerModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Color.black
            switch model.state {
            case .loading:
                ProgressView().controlSize(.large).tint(.white)
            case .failed(let message):
                ContentUnavailableView("Kan inte spela", systemImage: "exclamationmark.triangle", description: Text(message))
                    .foregroundStyle(.white)
            case .ready(let source):
                PlayerSurface(url: source.url)
            }
        }
        .background(WindowAspect(ratio: request.aspectRatio))
        .frame(minWidth: 200, minHeight: 200)
        .navigationTitle(request.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let file = localFile {
                    Button("Visa i Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    FilmShareButton(url: file)
                }
                if let launch = launchRequest {
                    Button("Öppna i Bildspel", systemImage: "slider.horizontal.3") {
                        openWindow(id: ReelWindow.id, value: launch)
                    }
                }
            }
        }
        .task(id: request) { await model.load(request) }
    }

    private var localFile: URL? {
        if case .ready(.local(let url)) = model.state { return url }
        return nil
    }

    /// Bildspelsfönstret för filmens mapp (källmappen om den finns, annars mappväljaren).
    private var launchRequest: ReelLaunchRequest? {
        guard let path = request.folderPath else { return nil }
        let dir = URL(fileURLWithPath: path)
        let output = request.outputPath.map { URL(fileURLWithPath: $0) }
        let folder = ReelFilmFolder(
            directory: dir, address: Self.address(from: dir), clipCount: nil, revision: nil, specDuration: nil,
            remote: ReelRemoteState.load(from: dir), films: [], updatedAt: .distantPast)
        return ReelLaunchRequest.forFilmFolder(folder, outputDirectory: output)
    }

    private static func address(from dir: URL) -> String {
        let name = dir.lastPathComponent
        return name.hasSuffix(AddressFolderLayout.reelSuffix) ? String(name.dropLast(AddressFolderLayout.reelSuffix.count)) : name
    }
}

extension ReelPlayerModel.Source {
    var url: URL {
        switch self { case .local(let url), .remote(let url): return url }
    }
}

/// AVPlayerView som spelar/pausar på mellanslag och tar tangentbordsfokus när den visas.
final class SpacePlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ", let player else { super.keyDown(with: event); return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> SpacePlayerView {
        let view = SpacePlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: SpacePlayerView, context: Context) {}

    static func dismantleNSView(_ view: SpacePlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Låser fönstrets proportioner till filmens och ger det en rimlig startstorlek (ett högt fönster
/// för 9:16, ett brett för 16:9), så att filmen inte letterboxas.
private struct WindowAspect: NSViewRepresentable {
    let ratio: Double

    func makeNSView(context: Context) -> NSView { AspectView(ratio: ratio) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class AspectView: NSView {
        let ratio: Double
        private var configured = false

        init(ratio: Double) {
            self.ratio = ratio
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }
            configured = true
            window.contentAspectRatio = NSSize(width: ratio * 1000, height: 1000)
            let visible = window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            var height = min(720, visible.height - 160)
            var width = height * ratio
            if width > visible.width * 0.8 { width = visible.width * 0.8; height = width / ratio }
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
        }
    }
}
