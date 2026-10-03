import Foundation
import Observation
import AppKit
import CoreImage

/// Förhandsvisningen: spelar/pausar/skrubbar specen i låg upplösning med samma
/// `ReelRenderer.renderFrame` som exporten. Varje bildruta renderas utanför huvudtråden
/// (`@concurrent`); modellen visar senaste färdiga bild och hoppar över mellanliggande
/// tider om renderingen inte hinner med, så att huvudtråden aldrig väntar.
@Observable
final class ReelPreviewModel {
    private(set) var frame: NSImage?
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var aspect: Double = 9.0 / 16.0

    @ObservationIgnored private var renderer: ReelRenderer?
    @ObservationIgnored private var previewSize = CGSize(width: 360, height: 640)
    @ObservationIgnored private var pendingTime: Double?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?

    /// Längsta sidan i förhandsvisningen (pixlar).
    static let longEdge: CGFloat = 640

    static func previewSize(for output: ReelSpec.Output) -> CGSize {
        let w = CGFloat(output.width), h = CGFloat(output.height)
        guard w > 0, h > 0 else { return CGSize(width: 360, height: 640) }
        let k = longEdge / max(w, h)
        return CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    }

    /// Byter spec (efter varje redigering). Tiden behålls (klampad) och bilden ritas om.
    func setSpec(_ spec: ReelSpec?, specDirectory: URL?) {
        playTask?.cancel(); playTask = nil; isPlaying = false
        guard let spec, let specDirectory, let output = spec.outputs.first, !spec.timeline.isEmpty else {
            renderer = nil; frame = nil; duration = 0; time = 0
            return
        }
        // Samma maxOutputSize som exporten (bilderna laddas för slutrenderingens skärpa).
        renderer = ReelRenderer(spec: spec, specDirectory: specDirectory,
                                maxOutputSize: CGSize(width: output.width, height: output.height))
        previewSize = Self.previewSize(for: output)
        aspect = Double(output.width) / Double(max(output.height, 1))
        duration = ReelTimeline.totalDuration(spec)
        time = min(time, duration)
        request(time)
    }

    func seek(to t: Double) {
        pause()
        time = min(max(t, 0), duration)
        request(time)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard renderer != nil, duration > 0 else { return }
        if time >= duration - 0.01 { time = 0 }
        isPlaying = true
        let startTime = time
        let started = Date()
        playTask?.cancel()
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = startTime + Date().timeIntervalSince(started)
                if t >= self.duration {
                    self.time = self.duration
                    self.request(self.duration)
                    self.isPlaying = false
                    return
                }
                self.time = t
                self.request(t)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func pause() {
        playTask?.cancel(); playTask = nil
        isPlaying = false
    }

    func stop() {
        pause()
        worker?.cancel(); worker = nil
        renderer = nil
    }

    // MARK: Rendering

    private func request(_ t: Double) {
        pendingTime = t
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let t = self.pendingTime, !Task.isCancelled {
                self.pendingTime = nil
                guard let renderer = self.renderer else { break }
                let size = self.previewSize
                let cg = await Self.render(renderer: renderer, at: t, size: size)
                if let cg, renderer === self.renderer {
                    self.frame = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            self?.worker = nil
        }
    }

    @concurrent
    private static func render(renderer: ReelRenderer, at t: Double, size: CGSize) async -> CGImage? {
        let image = renderer.renderFrame(at: t, size: size)
        return renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: size),
                                              format: .BGRA8, colorSpace: ReelRenderer.sRGB)
    }
}
