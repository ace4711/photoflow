import CoreGraphics
import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelMotionPlanner`: rörelsetyp, riktning, tempotak, klampning och takt.
struct ReelMotionPlannerTests {
    private let vertical = 1080.0 / 1920.0

    private func image(_ id: String, s: Double?, exterior: Bool = false, focusX: Double = 0.5,
                       w: Int = 6000, h: Int = 4000) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: w, height: h, focus: .init(x: focusX, y: 0.5), salientWidth: s, isExterior: exterior)
    }

    @Test("Motiv som ryms i ramen: zoom in mot motivet (cover)")
    func zoomWhenSubjectFits() {
        let clip = ReelMotionPlanner.plan([image("a", s: 0.30, focusX: 0.6)], frameAspect: vertical)[0]
        #expect(ReelMotionPlanner.kind(of: image("a", s: 0.30), frameAspect: vertical) == .zoom)
        #expect(clip.fit == .cover)
        #expect(clip.motion.from.zoom == 1)
        #expect(clip.motion.to.zoom > 1.05)
        #expect(abs(clip.motion.to.cx - 0.6) < 0.05)
    }

    @Test("Motiv bredare än ramen: panorering över motivet")
    func panWhenWiderThanFrame() {
        let img = image("a", s: 0.7)
        #expect(ReelMotionPlanner.kind(of: img, frameAspect: vertical) == .pan)
        let clip = ReelMotionPlanner.plan([img], frameAspect: vertical)[0]
        #expect(clip.fit == .cover)
        #expect(abs(clip.motion.to.cx - clip.motion.from.cx) > 0.05)
        #expect(clip.motion.from.zoom == 1 && clip.motion.to.zoom == 1)
    }

    @Test("Bred exteriör: contain-blur med svag zoom. Bred interiör panoreras")
    func containBlurForWideExterior() {
        let ext = image("e", s: 0.95, exterior: true)
        let clip = ReelMotionPlanner.plan([ext], frameAspect: vertical)[0]
        #expect(clip.fit == .containBlur)
        #expect(max(clip.motion.from.zoom, clip.motion.to.zoom) <= ReelMotionPlanner.containZoomAmount + 1e-9)
        #expect(ReelMotionPlanner.kind(of: image("i", s: 0.95, exterior: false), frameAspect: vertical) == .pan)
    }

    @Test("Bred ram (16:9): ingenting att panorera, så motivet zoomas")
    func landscapeFrameZooms() {
        #expect(ReelMotionPlanner.kind(of: image("a", s: 0.7), frameAspect: 16.0 / 9) == .zoom)
    }

    @Test("Panorering och zoom alternerar mellan klippen")
    func alternatingDirections() {
        // Minst 40 % zoom (se `zoomMix`): av 4 smala-nog motiv blir en zoom, resten panoreras.
        let pans = (0..<4).map { image("p\($0)", s: 0.7 + Double($0) * 0.05) }
        let clips = ReelMotionPlanner.plan(pans, frameAspect: vertical)
        let signs = clips.filter { $0.motion.to.zoom == $0.motion.from.zoom }.map { $0.motion.to.cx - $0.motion.from.cx }
        #expect(signs.count == 3)
        for i in 1..<signs.count { #expect(signs[i] * signs[i - 1] < 0) }

        let zooms = (0..<4).map { image("z\($0)", s: 0.3) }
        let zc = ReelMotionPlanner.plan(zooms, frameAspect: vertical)
        let dirs = zc.map { $0.motion.to.zoom > $0.motion.from.zoom }
        for i in 1..<dirs.count { #expect(dirs[i] != dirs[i - 1]) }
    }

    @Test("Tempotaket: panorering högst 10 % av bildbredden/s, zoom högst 4 %/s")
    func tempoCap() {
        let images = [image("a", s: 0.9), image("b", s: 0.3), image("c", s: 0.75), image("d", s: 0.95, exterior: true),
                      image("e", s: 0.6)]
        for aspect in [vertical, 1.0, 16.0 / 9] {
            for clip in ReelMotionPlanner.plan(images, frameAspect: aspect) {
                let pan = abs(clip.motion.to.cx - clip.motion.from.cx) / clip.duration
                #expect(pan <= ReelMotionPlanner.maxPanPerSecond + 1e-9)
                let zoom = pow(max(clip.motion.to.zoom, clip.motion.from.zoom) /
                               min(clip.motion.to.zoom, clip.motion.from.zoom), 1 / clip.duration) - 1
                #expect(zoom <= ReelMotionPlanner.maxZoomPerSecond + 1e-9)
            }
        }
    }

    @Test("Utsnittet ligger alltid inom bilden, även med fokus i kanten och udda bilder")
    func neverOutsideImage() {
        let sizes: [(Int, Int)] = [(6000, 4000), (4000, 6000), (3000, 3000), (8000, 2000)]
        for (w, h) in sizes {
            for fx in [0.0, 0.05, 0.5, 0.95, 1.0] {
                for s in [0.2, 0.7, 0.95] {
                    for ext in [false, true] {
                        let img = image("a", s: s, exterior: ext, focusX: fx, w: w, h: h)
                        for aspect in [vertical, 1.0, 16.0 / 9] {
                            let clip = ReelMotionPlanner.plan([img, img], frameAspect: aspect)[1]
                            for key in [clip.motion.from, clip.motion.to] {
                                let c = CGPoint(x: key.cx, y: key.cy)
                                let r: CGRect = clip.fit == .cover
                                    ? ReelTimeline.cropRect(imageSize: img.size, frameAspect: aspect, center: c, zoom: key.zoom)
                                    : ReelTimeline.containCrop(center: c, zoom: key.zoom)
                                #expect(r.minX >= -1e-9 && r.minY >= -1e-9 && r.maxX <= 1 + 1e-9 && r.maxY <= 1 + 1e-9)
                                // Nyckeln är redan klampad: renderaren behöver inte flytta den.
                                #expect(abs(r.midX - key.cx) < 1e-9 && abs(r.midY - key.cy) < 1e-9)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Takt: första 3,0 s, mitten 2,4–2,8 s, sista 3,2–3,5 s, övergångar 0,4–0,6 s")
    func rhythm() {
        let images = [image("a", s: 0.3), image("b", s: 0.7), image("c", s: 0.3), image("d", s: 0.95, exterior: true),
                      image("e", s: 0.3, exterior: true)]
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical)
        #expect(clips.count == 5)
        #expect(clips[0].duration == 3.0)
        #expect(clips[0].transitionIn == nil)
        for c in clips[1..<4] { #expect((2.4...2.8).contains(c.duration)) }
        #expect((3.2...3.5).contains(clips[4].duration))
        for c in clips.dropFirst() {
            let d = c.transitionIn?.duration ?? 0
            #expect((0.4...0.6).contains(d))
        }
        #expect(clips[4].transitionIn?.type == .crossfade)
    }

    @Test("Push efter panorering, i panoreringens riktning")
    func pushFollowsPan() {
        let clips = ReelMotionPlanner.plan([image("a", s: 0.7), image("b", s: 0.3), image("c", s: 0.3)], frameAspect: vertical)
        // Första panorerar åt höger (mittpunkten ökar) → innehållet rör sig åt vänster → push åt vänster.
        #expect(clips[0].motion.to.cx > clips[0].motion.from.cx)
        #expect(clips[1].transitionIn?.type == .push)
        #expect(clips[1].transitionIn?.direction == .left)
        #expect(clips[2].transitionIn?.type == .crossfade)
    }

    @Test("Utan analys används bildens mitt och en rimlig rörelse")
    func missingAnalysis() {
        let img = ReelMotionPlanner.Image(assetID: "a", width: 6000, height: 4000, focus: nil, salientWidth: nil, isExterior: false)
        let clip = ReelMotionPlanner.plan([img], frameAspect: vertical)[0]
        #expect(clip.fit == .cover)
        #expect(abs((clip.motion.from.cx + clip.motion.to.cx) / 2 - 0.5) < 0.05)
    }

    @Test("Zoomblandning: av 5 interiörer med bred saliency blir minst 2 zoomar")
    func zoomMix() {
        let images = (0..<5).map { image("i\($0)", s: 0.85 + Double($0) * 0.02) }
        let kinds = ReelMotionPlanner.kinds(images, frameAspect: vertical)
        #expect(kinds.filter { $0 == .zoom }.count == 2)
        // Det smalaste motivet zoomas först.
        #expect(kinds[0] == .zoom && kinds[1] == .zoom)
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical)
        #expect(clips.filter { $0.motion.to.zoom != $0.motion.from.zoom }.count >= 2)
        #expect(clips.filter { $0.motion.to.zoom == $0.motion.from.zoom }.count >= 2)
    }

    @Test("Tätare fokusbox avgör: smal huvudbox ger zoom trots bred union")
    func focusWidthDecides() {
        var img = image("a", s: 0.9)
        img.focusWidth = 0.25
        #expect(ReelMotionPlanner.kind(of: img, frameAspect: vertical) == .zoom)
    }

    @Test("Panoreringen täcker minst 0,25 av bildbredden när motivet är bredare än ramen")
    func minimumPanTravel() {
        // s - w = 0,40 - 0,375 är liten, men panoreringen ska ändå vara minst 0,25.
        let clip = ReelMotionPlanner.plan([image("a", s: 0.40), image("b", s: 0.9), image("c", s: 0.3)], frameAspect: vertical)[0]
        #expect(ReelMotionPlanner.kind(of: image("a", s: 0.40), frameAspect: vertical) == .pan)
        #expect(abs(clip.motion.to.cx - clip.motion.from.cx) >= ReelMotionPlanner.minPanTravel - 1e-9)
        // Och taket på 10 %/s ger över 0,25 för vanliga klipp.
        #expect(ReelMotionPlanner.maxPanPerSecond * ReelMotionPlanner.panDuration >= ReelMotionPlanner.minPanTravel)
    }

    @Test("Förval av rörelse och längd följer med och märks i klippet")
    func presetsAndDurationOverride() {
        let images = [image("a", s: 0.3), image("b", s: 0.3), image("c", s: 0.3)]
        let overrides: [String: ReelMotionPlanner.ClipOverride] = [
            "a": .init(preset: .zoomOut),
            "b": .init(preset: .panLeft, duration: 4.5),
            "c": .init(preset: .contain)]
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical, overrides: overrides)
        #expect(clips[0].motion.from.zoom > clips[0].motion.to.zoom)
        #expect(clips[0].motionPreset == "zoomOut" && clips[0].durationLocked == nil)
        #expect(clips[1].motion.to.cx < clips[1].motion.from.cx)
        #expect(clips[1].duration == 4.5 && clips[1].durationLocked == true)
        #expect(clips[2].fit == .containBlur)
        // Utan förval är klippet omärkt.
        #expect(ReelMotionPlanner.plan(images, frameAspect: vertical).allSatisfy { $0.motionPreset == nil })
    }
}
