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
    /// Delas av alla renderare som modellen skapar: bilderna laddas inte om och `CIContext` (dyr att
    /// skapa) återanvänds när bara rörelse, längd eller övergång ändrats.
    @ObservationIgnored private let cache: ReelImageCache
    @ObservationIgnored private let context = ReelRenderer.makeContext()
    @ObservationIgnored private var previewSize = CGSize(width: 360, height: 640)
    @ObservationIgnored private var pendingTime: Double?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Där pågående uppspelning stannar (filmens slut om hela filmen spelas).
    @ObservationIgnored private var stopTime: Double?

    init(cache: ReelImageCache = .shared) {
        self.cache = cache
    }

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
        // Förhandsvisningens egen storlek räcker som maxOutputSize: bilderna laddas inte i
        // exportens upplösning (som vid dragning av zoom skulle ge stora omladdningar).
        let size = Self.previewSize(for: output)
        renderer = ReelRenderer(spec: spec, specDirectory: specDirectory, maxOutputSize: size,
                                cache: cache, context: context)
        previewSize = Self.previewSize(for: output)
        aspect = Double(output.width) / Double(max(output.height, 1))
        duration = ReelTimeline.totalDuration(spec)
        time = min(time, duration)
        request(time)
    }

    /// En spec med bara klipp `assetID` (utan övergång), för förhandsvisning under dragning i
    /// rörelseeditorn: tid 0 är exakt klippets startnyckel och tid `duration` exakt slutnyckeln,
    /// oberoende av övergångarna till grannklippen. nil om klippet saknas.
    static func isolatedClipSpec(_ spec: ReelSpec, assetID: String, motion: ReelSpec.Motion) -> ReelSpec? {
        guard var clip = spec.timeline.first(where: { $0.asset == assetID }) else { return nil }
        clip.motion = motion
        clip.transitionIn = nil
        var isolated = spec
        isolated.timeline = [clip]
        return isolated
    }

    /// Visar ett enskilt klipps start- (`atEnd` = false) eller slutbild med en rörelse som ännu inte
    /// sparats. Specen i redigeringsmodellen rörs inte; anropa `setSpec` med den riktiga specen när
    /// dragningen är slut.
    func showTransient(_ spec: ReelSpec, assetID: String, motion: ReelSpec.Motion, atEnd: Bool, specDirectory: URL?) {
        guard let isolated = Self.isolatedClipSpec(spec, assetID: assetID, motion: motion) else { return }
        setSpec(isolated, specDirectory: specDirectory)
        seek(to: atEnd ? ReelTimeline.totalDuration(isolated) : 0)
    }

    func seek(to t: Double) {
        pause()
        time = min(max(t, 0), duration)
        request(time)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Fönstret som "Förhandsvisa" spelar för en övergång: från `margin` före övergångens start till
    /// `margin` efter dess slut, klampat till filmen.
    static func transitionWindow(start: Double, duration: Double, total: Double, margin: Double = 1) -> (from: Double, to: Double) {
        (max(start - margin, 0), min(start + duration + margin, total))
    }

    /// Spelar från `from` till `to` (sekunder) och stannar där.
    func play(from: Double, to: Double) {
        guard renderer != nil, duration > 0 else { return }
        let end = min(max(to, 0), duration)
        let begin = min(max(from, 0), end)
        pause()
        time = begin
        request(begin)
        startPlaying(stopAt: end)
    }

    func play() {
        guard renderer != nil, duration > 0 else { return }
        if time >= duration - 0.01 { time = 0 }
        startPlaying(stopAt: nil)
    }

    private func startPlaying(stopAt: Double?) {
        stopTime = stopAt
        isPlaying = true
        let startTime = time
        let started = Date()
        playTask?.cancel()
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = startTime + Date().timeIntervalSince(started)
                let end = min(self.stopTime ?? self.duration, self.duration)
                if t >= end {
                    self.time = end
                    self.request(end)
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
