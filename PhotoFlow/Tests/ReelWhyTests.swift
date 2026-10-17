import Foundation
import Testing
@testable import PhotoFlow

/// Tester för Regi R4, "varför": rörelseskälen (`ReelMotionPlanner.motionReasons`) ska följa exakt
/// samma regel som planeringen, och "Så valde PhotoFlow"-sammandraget (`ReelChoiceSummary`).
struct ReelWhyTests {
    private let vertical = 1080.0 / 1920.0
    private let landscape = 1920.0 / 1080.0

    private func image(_ id: String, s: Double?, focusWidth: Double? = nil, exterior: Bool = false,
                       w: Int = 6000, h: Int = 4000) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: w, height: h, focus: .init(x: 0.5, y: 0.5), salientWidth: s,
              isExterior: exterior, focusWidth: focusWidth)
    }

    /// Rörelsetypen som ett planerat klipp faktiskt fick, avläst ur fit och nycklar.
    private func actualKind(_ clip: ReelSpec.Clip) -> ReelMotionPlanner.Kind {
        if clip.fit == .containBlur { return .containBlur }
        return abs(clip.motion.to.zoom - clip.motion.from.zoom) > 1e-9 ? .zoom : .pan
    }

    /// Syntetiska filmer: blandade motiv, bara breda interiörer (blandningsregeln slår in), smala
    /// bilder i liggande format, okända motivbredder och fotografens förval.
    private var films: [(name: String, images: [ReelMotionPlanner.Image], aspect: Double,
                         overrides: [String: ReelMotionPlanner.ClipOverride])] {
        [("blandad", [image("a1", s: 0.95, exterior: true), image("a2", s: 0.62), image("a3", s: 0.30),
                      image("a4", s: 0.7, focusWidth: 0.3), image("a5", s: 0.9)], vertical, [:]),
         ("breda interiörer", (1...6).map { image("b\($0)", s: 0.5 + Double($0) * 0.05) }, vertical, [:]),
         ("liggande", [image("c1", s: 0.8), image("c2", s: 0.95, exterior: true), image("c3", s: 0.2),
                       image("c4", s: 0.99, w: 4000, h: 6000)], landscape, [:]),
         ("okända motiv", [image("d1", s: nil), image("d2", s: nil), image("d3", s: 0.7)], vertical, [:]),
         ("med förval", [image("e1", s: 0.7), image("e2", s: 0.7), image("e3", s: 0.2), image("e4", s: 0.7)], vertical,
          ["e2": .init(preset: .zoomOut), "e4": .init(preset: .auto, duration: 4)])]
    }

    @Test("Skälet anger samma rörelsetyp som planeraren faktiskt valde, för varje klipp")
    func reasonsMatchPlan() {
        for film in films {
            let clips = ReelMotionPlanner.plan(film.images, frameAspect: film.aspect, overrides: film.overrides)
            let reasons = ReelMotionPlanner.motionReasons(film.images, frameAspect: film.aspect, overrides: film.overrides)
            #expect(reasons.count == clips.count, "\(film.name)")
            for (clip, reason) in zip(clips, reasons) {
                let preset = film.overrides[clip.asset]?.effectivePreset ?? .auto
                if preset != .auto {
                    #expect(reason == .chosenByUser, "\(film.name) \(clip.asset)")
                } else {
                    #expect(reason.kind == actualKind(clip), "\(film.name) \(clip.asset): \(reason.text)")
                    #expect(reason != .chosenByUser)
                }
            }
        }
    }

    @Test("Texterna: panorering, zoom, hela bilden och smal bild")
    func texts() {
        let reasons = ReelMotionPlanner.motionReasons(
            [image("a", s: 0.62), image("b", s: 0.30), image("c", s: 0.95, exterior: true)], frameAspect: vertical)
        // 3:2-bild i 9:16: ramen visar 0,5625 / 1,5 = 37,5 % av bredden.
        #expect(reasons[0].text == "Panorering: motivet (62 % av bredden) är bredare än ramen (38 %)")
        #expect(reasons[1].text == "Zoom: motivet (30 % av bredden) ryms i ramen (38 %)")
        #expect(reasons[2].text == "Panorering: bred utomhusbild, motivet (95 % av bredden), ramen visar 38 %; hela bredden syns över tiden i stället för suddiga band")
        let narrow = ReelMotionPlanner.motionReasons([image("p", s: 0.95, w: 3000, h: 5000)], frameAspect: vertical)
        #expect(narrow == [.narrowImage(frame: 0.9375)])
        #expect(narrow[0].text.hasPrefix("Zoom: ramen visar nästan hela bildens bredd (94 %)"))
        let unknown = ReelMotionPlanner.motionReasons([image("u", s: nil)], frameAspect: vertical)
        #expect(unknown[0].text == "Panorering: motivet (okänd bredd, antas 50 %) är bredare än ramen (38 %)")
    }

    @Test("Blandningsregeln: smalaste breda motiven blir zoom för variation, med eget skäl")
    func variation() {
        let images = (1...5).map { image("v\($0)", s: 0.5 + Double($0) * 0.08) }
        let reasons = ReelMotionPlanner.motionReasons(images, frameAspect: vertical)
        // 40 % av 5 klipp = 2 zoom: de två smalaste (v1, v2).
        #expect(reasons.prefix(2).allSatisfy { if case .variation = $0 { return true } else { return false } })
        #expect(reasons.dropFirst(2).allSatisfy { if case .subjectWider = $0 { return true } else { return false } })
        #expect(reasons[0].text.hasPrefix("Zoom för variation (minst 40 % zoom): motivet (58 % av bredden)"))
        let kinds = ReelMotionPlanner.kinds(images, frameAspect: vertical)
        #expect(kinds == reasons.map(\.kind!))
    }

    @Test("Förval och egen rörelse: \"Vald av dig\"; låst längd ändrar inte skälet")
    func userChoices() {
        let images = [image("a", s: 0.3), image("b", s: 0.3), image("c", s: 0.3)]
        let custom = ReelMotionPlanner.CustomMotion(fit: .cover, motion: .init(from: .init(cx: 0.4, cy: 0.5, zoom: 1),
                                                                               to: .init(cx: 0.6, cy: 0.5, zoom: 1)))
        let reasons = ReelMotionPlanner.motionReasons(images, frameAspect: vertical, overrides: [
            "a": .init(preset: .panLeft), "b": .init(preset: .custom, custom: custom), "c": .init(duration: 5)])
        #expect(reasons[0] == .chosenByUser && reasons[0].text == "Vald av dig")
        #expect(reasons[1] == .chosenByUser)
        #expect(reasons[2].kind == .zoom)
    }

    @Test("Modellen: skälet för ett klipp följer specen och dess lås")
    func modelReason() throws {
        var spec = try sampleSpec()
        let reasons = ReelEditorModel.motionReasons(spec)
        #expect(reasons.count == spec.timeline.count)
        for (clip, reason) in zip(spec.timeline, reasons) { #expect(reason.kind == actualKind(clip)) }
        spec.timeline[1].motionPreset = ReelMotionPlanner.Preset.zoomIn.rawValue
        #expect(ReelEditorModel.motionReasons(spec)[1] == .chosenByUser)
    }

    // MARK: Sammandrag

    private func sampleSpec() throws -> ReelSpec {
        let assets: [ReelSpec.Asset] = [("Fasad", 0.95, "Exteriör"), ("Vardagsrum", 0.7, "Interiör"),
                                        ("Kök", 0.3, "Interiör"), ("Sovrum", 0.4, "Interiör")]
            .enumerated().map { i, a in
                .init(id: "a\(i + 1)", sha256: String(format: "%064x", i), width: 6000, height: 4000, sources: [],
                      analysis: .init(room: a.0, category: a.2, focus: .init(x: 0.5, y: 0.5), salientWidth: a.1))
            }
        let images = ReelComposer.plannerImages(assets)
        let clips = ReelMotionPlanner.plan(images, frameAspect: vertical)
        return ReelSpec(
            schema: ReelSpec.schemaName, version: ReelSpec.currentVersion, minReaderVersion: 1, id: "t", revision: 1,
            status: "draft", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            updatedBy: .init(role: "agent", name: nil), property: .init(address: "X", sessionID: nil, kind: "house"),
            assets: assets, style: ReelComposer.defaultStyle, timeline: clips, audio: nil, overlays: [], brand: nil,
            outputs: [ReelFormat.vertical.output], provenance: .init(generator: "test", autoSelection: nil, edits: nil))
    }

    @Test("Sammandraget: mall, antal, rader med rum, rörelse och övergång")
    func summary() throws {
        let spec = try sampleSpec()
        let s = ReelChoiceSummary.summary(spec)
        #expect(s.template == "Villa")
        #expect(s.clipCount == 4)
        #expect(s.lockedChoices == 0)
        #expect(s.rows.map(\.room) == ["Fasad", "Vardagsrum", "Kök", "Sovrum"])
        #expect(s.rows[0].transition == nil)
        #expect(s.rows[0].motion.hasPrefix("Panorering"))
        #expect(s.rows.dropFirst().allSatisfy { $0.transition != nil })
        #expect(s.rows.allSatisfy { !$0.locked })
        // Rörelsen läses ur nycklarna: samma typ som planeraren valde.
        for (row, clip) in zip(s.rows, spec.timeline) {
            #expect(row.motion == ReelChoiceSummary.motionLabel(clip))
        }
        #expect(s.rows[3].transition == "Mjuk tona 0,60 s")   // längre tona in i sista bilden
    }

    @Test("Sammandraget räknar låsta val och markerar låsta rader")
    func summaryLocks() throws {
        var spec = try sampleSpec()
        spec.timeline[1].durationLocked = true
        spec.timeline[1].motionPreset = "zoomOut"
        spec.timeline[2].transitionLocked = true
        spec.timeline[2].transitionIn = .init(type: .cut, direction: nil, duration: 0)
        spec.editor = .init(pinnedAssets: [spec.assets[3].sha256], excludedAssets: ["x"], orderLocked: true, tempo: nil)
        spec.property.kind = "apartment"
        let s = ReelChoiceSummary.summary(spec)
        #expect(s.template == "Lägenhet")
        #expect(s.lockedChoices == 2 + 1 + 1 + 1 + 1)
        #expect(s.rows.map(\.locked) == [false, true, true, true])
        #expect(s.rows[2].transition == "Hårt klipp")
        spec.property.kind = nil
        #expect(ReelChoiceSummary.summary(spec).template == nil)
    }

    @Test("Etiketter för rörelse och övergång")
    func labels() {
        func clip(_ from: ReelSpec.MotionKey, _ to: ReelSpec.MotionKey, fit: ReelSpec.Fit = .cover,
                  preset: String? = nil) -> ReelSpec.Clip {
            .init(asset: "a", duration: 3, fit: fit, motion: .init(from: from, to: to), transitionIn: nil,
                  motionPreset: preset, durationLocked: nil, transitionLocked: nil)
        }
        let c = ReelSpec.MotionKey(cx: 0.5, cy: 0.5, zoom: 1)
        #expect(ReelChoiceSummary.motionLabel(clip(c, .init(cx: 0.5, cy: 0.5, zoom: 1.1))) == "Zoom in")
        #expect(ReelChoiceSummary.motionLabel(clip(.init(cx: 0.5, cy: 0.5, zoom: 1.1), c)) == "Zoom ut")
        #expect(ReelChoiceSummary.motionLabel(clip(c, .init(cx: 0.6, cy: 0.5, zoom: 1))) == "Panorering →")
        #expect(ReelChoiceSummary.motionLabel(clip(c, .init(cx: 0.4, cy: 0.5, zoom: 1))) == "Panorering ←")
        #expect(ReelChoiceSummary.motionLabel(clip(c, c)) == "Stilla")
        #expect(ReelChoiceSummary.motionLabel(clip(c, c, fit: .containBlur)) == "Hela bilden")
        #expect(ReelChoiceSummary.motionLabel(clip(c, c, preset: "custom")) == "Egen rörelse")
        #expect(ReelChoiceSummary.transitionLabel(.init(type: .push, direction: .right, duration: 0.45)) == "Skjut → 0,45 s")
        #expect(ReelChoiceSummary.transitionLabel(.init(type: .fadeThroughBlack, direction: nil, duration: 0.5)) == "Via svart 0,50 s")
        #expect(ReelChoiceSummary.transitionLabel(nil) == "Hårt klipp")
    }
}
