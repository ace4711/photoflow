import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoFlow

/// Kollage (R6c): partnerreglerna (varje villkor), urvalets täckning, planering i 9:16/16:9/1:1, formatbyte,
/// auto mot låst, stående bild i 9:16 som aldrig blir contain-blur, redigeringsmodellens rutnät, uteslut,
/// pinna, ta bort och "Föreslå igen", JSON-rundtur (v2) och ett pixeltest av två staplade bilder.
struct ReelCollageTests {

    private let vertical = 1080.0 / 1920.0
    private let square = 1.0
    private let landscape = 1920.0 / 1080.0

    // MARK: - Kandidater

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 40)
        v[axis % 40] = 1
        return v
    }

    /// Liggande 3:2-bild (6000 × 4000) med motivbredd `focus` (andel av bredden). Stående: `portrait`.
    private func cand(_ id: String, room: String?, q: Double = 0.7, axis: Int, focus: Double = 0.6,
                      lum: Double = 0.45, portrait: Bool = false, panelRooms: [String] = []) -> ReelCandidate {
        let exterior = ["Fasad", "Trädgård", "Altan", "Uteplats", "Balkong", "Utsikt"].contains(room ?? "")
        return ReelCandidate(id: id, filename: "\(id).jpg", quality: q, featureVector: vec(axis),
                             salientWidth: focus, meanLuminance: lum, room: room,
                             category: exterior ? "Exteriör" : "Interiör", panelRooms: panelRooms,
                             width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000, focusWidth: focus)
    }

    /// Villa med matplats (kök + matplats är ett kompatibelt par) och en andra köksvinkel.
    private func villa() -> [ReelCandidate] {
        [cand("fasad", room: "Fasad", q: 0.9, axis: 0, focus: 0.9),
         cand("trad", room: "Trädgård", q: 0.8, axis: 1, focus: 0.5),
         cand("vard", room: "Vardagsrum", q: 0.85, axis: 2, focus: 0.35),   // ryms i 9:16 utan kollage
         cand("kok", room: "Kök", q: 0.8, axis: 3),
         cand("matp", room: "Matplats", q: 0.75, axis: 4),
         cand("sov", room: "Sovrum", q: 0.75, axis: 5),
         cand("bad", room: "Badrum", q: 0.7, axis: 6)]
    }

    private func select(_ list: [ReelCandidate], count: Int? = nil, aspect: Double? = nil,
                        pinned: [String] = [], excluded: [String] = []) -> ReelSelector.Selection {
        ReelSelector.select(list, count: count, pinned: pinned, excluded: excluded, frameAspect: aspect ?? vertical)
    }

    private func pairs(_ list: [ReelCandidate], pinned: Set<String> = [], aspect: Double? = nil,
                       opening: String? = "fasad", closing: String? = "trad",
                       distance: @escaping (String, String) -> Double? = { _, _ in nil }) -> [ReelCollage.Pair] {
        let score: (ReelCandidate) -> Double = { $0.quality ?? 0 }
        let order = list.filter { $0.id != "pool" }
        return ReelCollage.pairs(order: order, openingID: opening, closingID: closing, pool: [], frameAspect: aspect ?? vertical,
                                 score: score, distance: distance, pinned: pinned, weights: .init())
    }

    // MARK: - Partnerregler

    @Test("Kök och Matplats blir ett par i 9:16, med förklaring och poäng")
    func kitchenAndDining() throws {
        let found = pairs(villa())
        let pair = try #require(found.first)
        #expect(Set([pair.anchorID, pair.partnerID]) == ["kok", "matp"])
        #expect(pair.anchorID == "kok", "den som kommer först i visningsordningen är ankaret")
        #expect(pair.partnerPicked)
        #expect(pair.reason == "Kollage: Kök och Matplats, båda ryms i 9:8 (poäng 0,80 och 0,75)", "\(pair.reason)")
    }

    @Test("Varje villkor för en partner: rum, ljus, dubblett, motivbredd, orientering, fasad/utsikt, montage, låst")
    func partnerConditions() {
        let weights = ReelSelector.Weights()
        let kok = cand("kok", room: "Kök", axis: 3)
        func ok(_ partner: ReelCandidate, distance: Double? = nil, aspect: Double? = nil) -> Bool {
            ReelCollage.canPair(anchor: kok, partner: partner, frameAspect: aspect ?? vertical,
                                distance: { _, _ in distance }, weights: weights)
        }
        #expect(ok(cand("p", room: "Matplats", axis: 4)))
        #expect(ok(cand("p", room: "Kök", axis: 4)), "samma rumstyp (två vinklar)")
        // Rumstyp: ett okompatibelt rum, okänt rum.
        #expect(!ok(cand("p", room: "Sovrum", axis: 4)))
        #expect(!ok(cand("p", room: nil, axis: 4)))
        // Ljus: 0,45 mot 0,65 (skillnad 0,20) är över gränsen 0,15; 0,55 (0,10) går.
        #expect(!ok(cand("p", room: "Matplats", axis: 4, lum: 0.65)))
        #expect(ok(cand("p", room: "Matplats", axis: 4, lum: 0.55)))
        // Dubblett: feature print-avstånd under gränsen (0,10) går inte, över gränsen går.
        #expect(!ok(cand("p", room: "Matplats", axis: 4), distance: 0.08))
        #expect(ok(cand("p", room: "Matplats", axis: 4), distance: 0.3))
        // Båda motiven ryms i rutan: synlig bredd 0,75 + marginal 0,15 = 0,90.
        #expect(ok(cand("p", room: "Matplats", axis: 4, focus: 0.88)))
        #expect(!ok(cand("p", room: "Matplats", axis: 4, focus: 0.95)))
        #expect(!ReelCollage.canPair(anchor: cand("a", room: "Kök", axis: 3, focus: 0.95), partner: cand("p", room: "Matplats", axis: 4),
                                     frameAspect: vertical, distance: { _, _ in nil }, weights: weights))
        // Orientering: en stående partner i en stapel (och en liggande i sida vid sida) går inte.
        #expect(!ok(cand("p", room: "Matplats", axis: 4, portrait: true)))
        #expect(!ok(cand("p", room: "Matplats", axis: 4), aspect: landscape))
        // Utomhus (panorering + kollage): fasad med fasad (olika vinklar), fasad med trädgård och balkong med
        // utsikt går; fasad med kök går inte. Aldrig montage, aldrig okända mått.
        func outdoor(_ a: String, _ b: String) -> Bool {
            ReelCollage.canPair(anchor: cand("a", room: a, axis: 7), partner: cand("b", room: b, axis: 8), frameAspect: vertical,
                                distance: { _, _ in nil }, weights: weights)
        }
        #expect(outdoor("Fasad", "Fasad") && outdoor("Fasad", "Trädgård") && outdoor("Balkong", "Utsikt") && outdoor("Uteplats", "Trädgård"))
        #expect(!outdoor("Fasad", "Kök") && !outdoor("Utsikt", "Fasad"))
        #expect(!ok(cand("m", room: "Matplats", axis: 4, panelRooms: ["Matplats", "Kök"])))
        var noSize = cand("p", room: "Matplats", axis: 4)
        noSize.width = nil; noSize.height = nil
        #expect(!ok(noSize))
        // Rumspar: uteplats + trädgård går, hall + kök inte, vardagsrum + matplats går.
        func rooms(_ a: String, _ b: String) -> Bool {
            ReelCollage.compatibleRooms(cand("a", room: a, axis: 1), cand("b", room: b, axis: 2), weights: weights)
        }
        #expect(rooms("Uteplats", "Trädgård") && rooms("Vardagsrum", "Matplats") && rooms("Hall", "Entré") && rooms("Badrum", "Badrum"))
        #expect(!rooms("Hall", "Kök") && !rooms("Sovrum", "Badrum"))
    }

    @Test("Låsta bilder, öppning och avslut ingår aldrig i ett kollage")
    func pinnedOpeningClosingNever() {
        func uses(_ id: String, _ found: [ReelCollage.Pair]) -> Bool { found.contains { $0.anchorID == id || $0.partnerID == id } }
        #expect(!uses("kok", pairs(villa(), pinned: ["kok"])), "låst ankare")
        #expect(!uses("matp", pairs(villa(), pinned: ["matp"])), "låst partner")
        #expect(uses("matp", pairs(villa(), pinned: ["kok"])), "matplatsen hittar en annan partner (vardagsrummet)")
        // Kök som öppning/avslut: aldrig med.
        #expect(!uses("kok", pairs(villa(), opening: "kok")))
        #expect(!uses("matp", pairs(villa(), closing: "matp")))
    }

    @Test("Bara bilder som behöver det är ankare: ett smalt motiv i 9:16 ryms redan, 1:1 får inget automatiskt kollage")
    func anchorsNeedIt() {
        // Smalt motiv (0,3 < synlig bredd 0,375 i 9:16): ingen behöver partner.
        let narrow = villa().map { c -> ReelCandidate in var n = c; n.focusWidth = 0.3; n.salientWidth = 0.3; return n }
        #expect(pairs(narrow).isEmpty)
        #expect(pairs(villa(), aspect: square).isEmpty)
        #expect(ReelMotionPlanner.collageLayout(frameAspect: square) == nil)
        #expect(ReelMotionPlanner.collageLayout(frameAspect: vertical) == .stack)
        #expect(ReelMotionPlanner.collageLayout(frameAspect: landscape) == .side)
    }

    @Test("En bortvald bild kan vara partner (extra bild), den bäst poängsatta först")
    func poolPartner() throws {
        let list = villa().filter { $0.id != "matp" }
        let pool = [cand("p1", room: "Kök", q: 0.6, axis: 8), cand("p2", room: "Kök", q: 0.7, axis: 9)]
        let found = ReelCollage.pairs(order: list, openingID: "fasad", closingID: "trad", pool: pool, frameAspect: vertical,
                                      score: { $0.quality ?? 0 }, distance: { _, _ in nil }, pinned: [], weights: .init())
        let pair = try #require(found.first)
        #expect(pair.anchorID == "kok" && pair.partnerID == "p2" && !pair.partnerPicked)
        #expect(pair.reason.hasSuffix("extra bild utan egen plats"), "\(pair.reason)")
        #expect(pair.reason.hasPrefix("Kollage: Kök (två bilder), båda ryms i 9:8"))
    }

    @Test("De närmast bortvalda räknas bland dem med ett rum som passar, inte bland alla bortvalda")
    func poolFilteredByRoom() throws {
        let list = villa().filter { $0.id != "matp" }
        // Tio bortvalda fasadbilder med högre poäng än köksbilden fyller inte poolen åt köket.
        var pool = (0..<10).map { cand("f\($0)", room: "Fasad", q: 0.95, axis: 20 + $0) }
        pool.append(cand("kok2", room: "Kök", q: 0.5, axis: 8))
        let found = ReelCollage.pairs(order: list, openingID: "fasad", closingID: "trad", pool: pool, frameAspect: vertical,
                                      score: { $0.quality ?? 0 }, distance: { _, _ in nil }, pinned: [], weights: .init())
        #expect(found.first?.partnerID == "kok2")
    }

    // MARK: - Urval

    @Test("Urvalet: kollaget är ett klipp men två bilder, båda i picks, och nästa rumstyp får den lediga platsen")
    func selectionCoverage() throws {
        let without = ReelSelector.select(villa(), frameAspect: nil)
        #expect(without.collages.isEmpty)
        let with = select(villa())
        let pair = try #require(with.collages.first)
        #expect(with.collages.count == 1 && pair.partnerPicked)
        let ids = with.picks.map(\.candidateID)
        let anchorAt = try #require(ids.firstIndex(of: pair.anchorID))
        #expect(ids[anchorAt + 1] == pair.partnerID, "partnern ligger direkt efter ankaret")
        // Alla bilder från urvalet utan kollage finns kvar, och klippen är lika många plus en bild till.
        for id in without.picks.map(\.candidateID) { #expect(ids.contains(id), "\(id) försvann: \(ids)") }
        #expect(ids.count - with.collages.count == without.picks.count, "platser (klipp) oförändrade: \(ids)")
        #expect(ids.count == without.picks.count + 1)
        // Båda bilderna har kollageförklaringen och sin egen rumstyp.
        for id in [pair.anchorID, pair.partnerID] {
            let pick = try #require(with.picks.first { $0.candidateID == id })
            #expect(pick.reason == pair.reason)
        }
        #expect(with.picks.first { $0.candidateID == "matp" }?.roomType == "matplats")
        // Öppningen (fasaden) och avslutet är aldrig med i kollaget.
        #expect(with.picks.first?.slot == .opening && !with.collages.contains { $0.anchorID == "fasad" || $0.partnerID == "fasad" })
        #expect(with.picks.last?.slot == .closing)
    }

    @Test("Utan frameAspect, i 1:1 och med färre än tre bilder blir det inget kollage")
    func noCollageWithoutReason() {
        #expect(ReelSelector.select(villa()).collages.isEmpty)                 // frameAspect nil
        #expect(select(villa(), aspect: square).collages.isEmpty)
        #expect(select(Array(villa().prefix(2))).collages.isEmpty)
    }

    @Test("Fast antal: kollaget är en plats (antalet klipp är det begärda), en extra bild kommer ovanpå")
    func fixedCount() throws {
        let sel = select(villa(), count: 5)
        let pair = try #require(sel.collages.first)
        #expect(sel.picks.count - sel.collages.count == 5, "klipp: \(sel.picks.map(\.candidateID))")
        #expect(sel.picks.contains { $0.candidateID == pair.anchorID } && sel.picks.contains { $0.candidateID == pair.partnerID })
    }

    @Test("Högst ungefär en tredjedel av bilderna är ankare, och flera par får olika bilder")
    func maxShare() {
        var list = villa()
        list += [cand("sov2", room: "Sovrum", q: 0.7, axis: 11), cand("bad2", room: "Badrum", q: 0.68, axis: 12),
                 cand("vard2", room: "Vardagsrum", q: 0.8, axis: 13)]
        let sel = select(list, count: 8)
        #expect(sel.collages.count <= max(1, Int(Double(sel.picks.count) * 0.34)))
        let all = sel.collages.flatMap { [$0.anchorID, $0.partnerID] }
        #expect(Set(all).count == all.count, "ingen bild i två kollage")
    }

    @Test("Låst bild blir inget kollage; utesluten bild kommer aldrig tillbaka som partner")
    func pinnedAndExcluded() {
        let pinned = select(villa(), pinned: ["kok"])
        #expect(!pinned.collages.contains { $0.anchorID == "kok" || $0.partnerID == "kok" })
        #expect(pinned.picks.contains { $0.candidateID == "kok" })
        let excluded = select(villa(), excluded: ["matp"])
        #expect(!excluded.picks.contains { $0.candidateID == "matp" } && excluded.collages.allSatisfy { $0.partnerID != "matp" && $0.anchorID != "matp" })
    }

    @Test("Breda utomhusbilder kan vara med i kollage, men aldrig öppning eller avslut")
    func outdoorCollagesNotOpeningClosing() {
        var list = villa()
        list.append(cand("fasad2", room: "Fasad", q: 0.85, axis: 14, focus: 0.5))
        list.append(cand("utsikt", room: "Utsikt", q: 0.85, axis: 15, focus: 0.5))
        let sel = select(list, count: 9)
        let edges = [sel.picks.first, sel.picks.last].compactMap { $0 }
        #expect(edges.map(\.slot) == [.opening, .closing])
        for pair in sel.collages {
            #expect(!edges.map(\.candidateID).contains(pair.anchorID) && !edges.map(\.candidateID).contains(pair.partnerID))
        }
    }

    @Test("Utomhuskollage i 9:16: uteplatsen mitt i filmen får en annan trädgårdsbild som partner, öppning och avslut aldrig")
    func outdoorPairsInSelection() throws {
        var list = villa().filter { $0.id != "matp" }
        list.append(cand("ute", room: "Uteplats", q: 0.8, axis: 14, focus: 0.8))
        list.append(cand("trad2", room: "Trädgård", q: 0.6, axis: 15, focus: 0.8))
        let sel = select(list, aspect: vertical)
        let pair = try #require(sel.collages.first { $0.anchorID == "ute" })
        #expect(pair.partnerID == "trad2" && !pair.partnerPicked)
        #expect(pair.reason.hasPrefix("Kollage: Uteplats och Trädgård, båda ryms i 9:8"), "\(pair.reason)")
        #expect(sel.picks.first?.slot == .opening && sel.picks.last?.slot == .closing)
        // Två fasadvinklar (olika bilder) kan också para ihop sig.
        #expect(ReelCollage.canPair(anchor: cand("a", room: "Fasad", axis: 7, focus: 0.8), partner: cand("b", room: "Fasad", axis: 8, focus: 0.8),
                                    frameAspect: vertical, distance: { _, _ in 0.3 }, weights: .init()))
    }

    @Test("Avslutet väljs bland bilder vars skillnad mot öppningen är känd: en bild utan feature print går efter")
    func closingNeedsKnownDifference() throws {
        // Lillvägen 24: avslutet saknade feature print och var en annan vinkel av öppningens balkong, men
        // likheten räknades som 0 och bilden som "olik".
        var balk = cand("balk", room: "Uteplats", q: 0.9, axis: 1, focus: 0.5)
        balk.featureVector = nil
        let trad = cand("trad", room: "Trädgård", q: 0.7, axis: 2, focus: 0.5)
        let fasad = cand("fasad", room: "Fasad", q: 0.95, axis: 0, focus: 0.5)
        let rest = [cand("vard", room: "Vardagsrum", q: 0.8, axis: 3, focus: 0.3), cand("kok", room: "Kök", q: 0.8, axis: 4, focus: 0.3),
                    cand("sov", room: "Sovrum", q: 0.8, axis: 5, focus: 0.3)]
        let sel = ReelSelector.select([fasad, balk, trad] + rest, frameAspect: nil)
        let closing = try #require(sel.picks.last)
        #expect(closing.candidateID == "trad" && closing.slot == .closing)
        #expect(closing.reason.contains("skiljer sig från öppningen"), "\(closing.reason)")
        // Utan någon känd likhet sägs det rakt ut i stället för att påstå att bilden skiljer sig.
        var noVec = [fasad, balk, trad].map { c -> ReelCandidate in var n = c; n.featureVector = nil; return n }
        noVec += rest
        let sel2 = ReelSelector.select(noVec, frameAspect: nil)
        let closing2 = try #require(sel2.picks.last)
        #expect(closing2.reason.contains("likhet med öppningen okänd"), "\(closing2.reason)")
    }

    @Test("Stående bilder i 16:9: två stående rum blir ett kollage sida vid sida")
    func portraitsInLandscape() throws {
        var list = villa()
        for i in list.indices where ["sov", "bad"].contains(list[i].id) {
            list[i].width = 4000; list[i].height = 6000
        }
        list.append(cand("sov2", room: "Sovrum", q: 0.74, axis: 20, portrait: true))
        list[list.firstIndex { $0.id == "sov" }!].room = "Sovrum"
        let sel = select(list, aspect: landscape)
        let pair = try #require(sel.collages.first)
        #expect(["sov", "sov2"].contains(pair.anchorID) && ["sov", "sov2"].contains(pair.partnerID))
        #expect(pair.reason.contains("Sovrum (två bilder), båda ryms i 8:9"), "\(pair.reason)")
    }

    // MARK: - Planering

    private func image(_ id: String, w: Int = 6000, h: Int = 4000, focus: Double = 0.6, cx: Double = 0.5, room: String? = nil,
                       exterior: Bool = false) -> ReelMotionPlanner.Image {
        .init(assetID: id, width: w, height: h, focus: .init(x: cx, y: 0.5), salientWidth: focus, isExterior: exterior,
              focusWidth: focus, room: room)
    }

    @Test("9:16: ett kollage är stack med två rutor, svag gemensam zoom, ingång och förväntad längd")
    func planVertical() throws {
        let a = image("a", cx: 0.4, room: "Kök"), b = image("b", cx: 0.6, room: "Matplats")
        let clips = ReelMotionPlanner.plan([image("o"), a, image("z")], frameAspect: vertical, collages: ["a": b])
        let clip = clips[1]
        #expect(clip.fit == .panels && clip.layout == .stack && clip.asset == "a" && clip.motionPreset == nil)
        let panels = try #require(clip.panels)
        #expect(panels.map(\.asset) == ["a", "b"] && panels.allSatisfy { $0.source == nil })
        #expect(clip.motion == panels[0].motion)
        #expect(clip.entrance == ReelSpec.Entrance(type: .slide, stagger: 0.3, duration: nil))
        #expect(clip.gutter == nil)
        // Ingen panorering: samma zoom 1,00 → 1,04, mittpunkt vid respektive motivs mitt.
        for (panel, cx) in zip(panels, [0.4, 0.6]) {
            #expect(panel.motion.from.zoom == 1 && abs(panel.motion.to.zoom - 1.04) < 1e-9)
            let size = CGSize(width: 6000, height: 4000)
            let pane = ReelMotionPlanner.collagePaneAspect(layout: .stack, frameAspect: vertical)
            let r0 = ReelTimeline.panelCrop(imageSize: size, source: nil, destAspect: pane,
                                            center: CGPoint(x: panel.motion.from.cx, y: panel.motion.from.cy), zoom: 1)
            #expect(r0.minX >= -1e-9 && r0.maxX <= 1 + 1e-9, "utsnittet ryms i bilden")
            #expect(abs(Double(r0.midX) - cx) < 1e-6, "mitten på motivet (\(cx)): \(r0.midX)")
        }
        // 9:8 i 9:16 (med gutter 0,006 något mer).
        #expect(abs(ReelMotionPlanner.collagePaneAspect(layout: .stack, frameAspect: vertical) - 1.1285) < 0.001)
        #expect(ReelMotionPlanner.ratioText(1.1285) == "9:8" && ReelMotionPlanner.ratioText(0.8861) == "8:9")
        // Längd: 2,5 + 0,3 + 0,6 = 3,4 s; tempo skalar.
        #expect(abs(clip.duration - 3.4) < 1e-9)
        #expect(abs(ReelMotionPlanner.plan([a], frameAspect: vertical, tempo: .fast, collages: ["a": b])[0].duration - 3.4 * 0.85) < 1e-9)
        // Övergången in är mjuk tona (ingången syns), nästa klipp är vanligt.
        #expect(clip.transitionIn?.type == .crossfade && clips[0].fit != .panels && clips[2].fit != .panels)
        // Rutklippet är ett av tre klipp: partnern får inget eget.
        #expect(clips.count == 3)
        // Specen blir v2.
        #expect(ReelComposer.autoCollagePartner(clip) == "b")
    }

    @Test("16:9: två stående bilder blir side; liggande bilder i 16:9 och allt i 1:1 planeras som vanligt")
    func planLandscapeAndSquare() throws {
        let a = image("a", w: 4000, h: 6000, room: "Sovrum"), b = image("b", w: 4000, h: 6000, room: "Sovrum")
        let side = ReelMotionPlanner.plan([a], frameAspect: landscape, collages: ["a": b])[0]
        #expect(side.fit == .panels && side.layout == .side && side.panels?.count == 2)
        // Liggande bilder i 16:9 och 1:1: ingen layout (kollage motiveras inte).
        let l1 = image("l1"), l2 = image("l2")
        #expect(ReelMotionPlanner.plan([l1], frameAspect: landscape, collages: ["l1": l2])[0].fit != .panels)
        #expect(ReelMotionPlanner.plan([l1], frameAspect: square, collages: ["l1": l2])[0].fit != .panels)
        #expect(ReelMotionPlanner.plan([a], frameAspect: square, collages: ["a": b])[0].fit != .panels)
        // Stående bilder i 9:16 (de behöver inget kollage): vanligt klipp.
        #expect(ReelMotionPlanner.plan([a], frameAspect: vertical, collages: ["a": b])[0].fit != .panels)
        // Ett motiv som inte ryms i rutan (0,95 > 0,90): vanligt klipp.
        let wide = image("w", focus: 0.95)
        #expect(ReelMotionPlanner.plan([l1], frameAspect: vertical, collages: ["l1": wide])[0].fit != .panels)
    }

    @Test("Stående bild i 9:16 blir aldrig contain-blur (DSC_9451 i Chronas: 2:3, bred fasad, w = 0,844)")
    func portraitNeverContainBlur() {
        for focus in [0.7, 0.85, 0.93, 1.0] {
            for exterior in [true, false] {
                let p = image("p", w: 3545, h: 5315, focus: focus, exterior: exterior)
                #expect(ReelMotionPlanner.kind(of: p, frameAspect: vertical) != .containBlur, "focus \(focus) \(exterior)")
                let clip = ReelMotionPlanner.plan([p], frameAspect: vertical)[0]
                #expect(clip.fit == .cover)
            }
        }
        // Liggande bred exteriör i 9:16 är fortfarande contain-blur (inget har ändrats där).
        #expect(ReelMotionPlanner.kind(of: image("l", focus: 0.93, exterior: true), frameAspect: vertical) == .pan)
        #expect(ReelMotionPlanner.isWideExteriorPan(image("l", focus: 0.93, exterior: true), frameAspect: vertical))
        // Ett uttryckligt förval (hela bilden) gäller som förut.
        var o = ReelMotionPlanner.ClipOverride(); o.preset = .contain
        #expect(ReelMotionPlanner.plan([image("p", w: 3545, h: 5315)], frameAspect: vertical, overrides: ["p": o])[0].fit == .containBlur)
    }

    @Test("Förvals- och egen rörelse på ankaret, eller ett låst rutklipp, gör att kollaget inte planeras")
    func lockedAnchor() {
        let a = image("a"), b = image("b")
        for preset in [ReelMotionPlanner.Preset.zoomIn, .contain, .panLeft] {
            var o = ReelMotionPlanner.ClipOverride(); o.preset = preset
            #expect(ReelMotionPlanner.plan([a], frameAspect: vertical, overrides: ["a": o], collages: ["a": b])[0].fit != .panels)
        }
        // Längd och övergång är lås som gäller även för kollaget.
        var o = ReelMotionPlanner.ClipOverride()
        o.duration = 5; o.transitionLocked = true; o.transition = .init(type: .cut, direction: nil, duration: 0)
        let clip = ReelMotionPlanner.plan([image("o"), a], frameAspect: vertical, overrides: ["a": o], collages: ["a": b])[1]
        #expect(clip.fit == .panels && clip.duration == 5 && clip.durationLocked == true && clip.transitionIn?.type == .cut)
    }

    // MARK: - Komposition, formatbyte, lås

    private let base = URL(fileURLWithPath: "/Users/test/Objekt/Lindvägen 12", isDirectory: true)
    private var specDir: URL { base.appendingPathComponent("Lindvägen 12 FILM", isDirectory: true) }

    private func item(_ n: Int, room: String, q: Double, focus: Double = 0.6, portrait: Bool = false) -> ReelImageAnalyzer.Item {
        let exterior = ["Fasad", "Trädgård"].contains(room)
        var a = ObjektfilmTestKit.analysis(n + 300, room: room, category: exterior ? "Exteriör" : "Interiör", q: q,
                                           width: portrait ? 4000 : 6000, height: portrait ? 6000 : 4000)
        a.featurePrint = vec(n).withUnsafeBytes { Data($0) }
        a.salientWidth = focus
        a.saliencyBoxes = [.init(x: (1 - focus) / 2, y: 0.2, width: focus, height: 0.6)]
        return .init(url: base.appendingPathComponent("Lindvägen 12 red/\(n).jpg"), analysis: a)
    }

    private func items() -> [ReelImageAnalyzer.Item] {
        [item(0, room: "Fasad", q: 0.9, focus: 0.9), item(1, room: "Trädgård", q: 0.8, focus: 0.5),
         item(2, room: "Vardagsrum", q: 0.85, focus: 0.35), item(3, room: "Kök", q: 0.8), item(4, room: "Matplats", q: 0.75),
         item(5, room: "Sovrum", q: 0.75), item(6, room: "Badrum", q: 0.7)]
    }

    private func compose(format: ReelFormat = .vertical, count: Int? = nil, editor: ReelSpec.EditorState? = nil) -> ReelComposer.Result {
        var options = ReelComposer.Options()
        options.format = format
        options.count = count
        options.curated = true
        options.editor = editor
        return ReelComposer.compose(items: items(), specDirectory: specDir, options: options)
    }

    private func collageIndex(_ spec: ReelSpec) -> Int? { spec.timeline.firstIndex { ReelComposer.autoCollagePartner($0) != nil } }

    private func sha(_ spec: ReelSpec, _ id: String) -> String { spec.assets.first { $0.id == id }!.sha256 }

    @Test("compose i 9:16: kollaget är ett klipp med partnern som extra asset, specen är v2 och går att koda om och om")
    func composeVertical() throws {
        let result = compose()
        let spec = result.spec
        let i = try #require(collageIndex(spec))
        let clip = spec.timeline[i]
        let partner = try #require(ReelComposer.autoCollagePartner(clip))
        #expect(clip.layout == .stack && clip.panels?.count == 2 && clip.entrance?.type == .slide)
        // Partnern är en asset men inget klipps egen bild, och ligger efter klippens egna.
        #expect(!spec.timeline.contains { $0.asset == partner })
        let clipAssets = Set(spec.timeline.map(\.asset))
        #expect(spec.assets.firstIndex { $0.id == partner }! >= clipAssets.count)
        #expect(spec.version == 2 && spec.minReaderVersion == 2)
        let rooms = [clip.asset, partner].map { id in spec.assets.first { $0.id == id }?.analysis?.room }
        #expect(Set(rooms) == ["Kök", "Matplats"])
        // Förklaring i urvalet för båda bilderna.
        let reasons = Dictionary(uniqueKeysWithValues: (spec.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) })
        #expect(reasons[clip.asset]?.hasPrefix("Kollage: Kök och Matplats, båda ryms i 9:8 (poäng") == true)
        #expect(reasons[partner] == reasons[clip.asset])
        // JSON-rundtur, två gånger.
        let decoded = try ReelSpec.decode(from: try spec.jsonData())
        #expect(decoded == spec)
        #expect(try ReelSpec.decode(from: try decoded.jsonData()) == spec)
        // Urvalet innehåller båda, och antalet klipp stämmer med platserna.
        #expect(result.selection.picks.count == spec.timeline.count + 1)
    }

    @Test("compose i 16:9 och 1:1: liggande bilder får inget kollage, specen är v1")
    func composeOtherFormats() {
        for format in [ReelFormat.landscape, .square] {
            let spec = compose(format: format).spec
            #expect(spec.timeline.allSatisfy { $0.fit != .panels } && spec.version == 1 && spec.minReaderVersion == 1, "\(format)")
        }
    }

    @Test("Formatbyte: kollaget upplöses i 16:9 (vald partner får eget klipp) och är v1 igen")
    func formatChangeDissolves() throws {
        let vertical = compose().spec
        let i = try #require(collageIndex(vertical))
        let anchor = vertical.timeline[i].asset
        let partner = try #require(ReelComposer.autoCollagePartner(vertical.timeline[i]))
        let landscape = ReelComposer.rebuild(vertical, order: vertical.timeline.map(\.asset), format: .landscape)
        #expect(landscape.timeline.allSatisfy { $0.fit != .panels } && landscape.version == 1)
        // Den valda partnern (Matplats) blir ett eget klipp direkt efter ankaret.
        #expect(landscape.timeline.map(\.asset).firstIndex(of: partner) == landscape.timeline.map(\.asset).firstIndex(of: anchor)! + 1)
        #expect(landscape.timeline.count == vertical.timeline.count + 1)
        let reasons = Dictionary(uniqueKeysWithValues: (landscape.provenance.autoSelection ?? []).map { ($0.asset, $0.reason) })
        #expect(reasons[anchor] == "Var del av ett kollage som löstes upp")
        // 1:1: också ett vanligt klipp.
        let square = ReelComposer.rebuild(vertical, order: vertical.timeline.map(\.asset), format: .square)
        #expect(square.timeline.allSatisfy { $0.fit != .panels })
        // Omplanering i samma format behåller kollaget oförändrat.
        let again = ReelComposer.rebuild(vertical, order: vertical.timeline.map(\.asset))
        #expect(again.timeline == vertical.timeline)
        #expect(again.assets == vertical.assets)
    }

    @Test("En extra bild (urvalet valde den inte) lämnar filmen när kollaget upplöses; en vald partner får eget klipp")
    func extraPartnerLeavesOnDissolve() throws {
        var list = items().filter { $0.analysis.room != "Matplats" }
        list.append(item(8, room: "Kök", q: 0.6))
        var options = ReelComposer.Options()
        options.curated = true
        let spec = ReelComposer.compose(items: list, specDirectory: specDir, options: options).spec
        let i = try #require(collageIndex(spec))
        let partner = try #require(ReelComposer.autoCollagePartner(spec.timeline[i]))
        let reasons = Dictionary(uniqueKeysWithValues: (spec.provenance.autoSelection ?? []).map { ($0.asset, $0) })
        #expect(reasons[partner]?.slot == "extra" && reasons[partner]?.reason.hasSuffix("extra bild utan egen plats") == true)
        let landscape = ReelComposer.rebuild(spec, order: spec.timeline.map(\.asset), format: .landscape)
        #expect(landscape.timeline.count == spec.timeline.count && !landscape.assets.contains { $0.id == partner })
        #expect(landscape.timeline.allSatisfy { $0.fit != .panels } && landscape.version == 1)
    }

    @Test("Ändra ordning: kollaget följer ankaret; ta bort ankaret: båda bilderna lämnar filmen")
    func reorderAndRemove() throws {
        let spec = compose().spec
        let i = try #require(collageIndex(spec))
        let anchor = spec.timeline[i].asset
        var order = spec.timeline.map(\.asset)
        order.remove(at: i)
        order.insert(anchor, at: 1)
        let moved = ReelComposer.rebuild(spec, order: order)
        #expect(moved.timeline[1].asset == anchor && ReelComposer.autoCollagePartner(moved.timeline[1]) != nil)
        let removed = ReelComposer.rebuild(spec, order: spec.timeline.map(\.asset).filter { $0 != anchor })
        let partner = ReelComposer.autoCollagePartner(spec.timeline[i])!
        #expect(!removed.assets.contains { $0.id == anchor || $0.id == partner })
        #expect(removed.timeline.allSatisfy { $0.fit != .panels })
        #expect(!(removed.provenance.autoSelection ?? []).contains { $0.asset == partner })
    }

    @Test("Fotografens lås: förval på ankaret löser upp kollaget; längd- och övergångslås följer med; custom står kvar")
    func autoVersusLocked() throws {
        let spec = compose().spec
        let i = try #require(collageIndex(spec))
        let anchor = spec.timeline[i].asset
        #expect(ReelComposer.overrides(in: spec).isEmpty)
        #expect(ReelChoiceSummary.summary(spec).lockedChoices == 0)
        // Längd + övergång.
        var edited = spec
        edited.timeline[i].duration = 6; edited.timeline[i].durationLocked = true
        edited.timeline[i].transitionIn = .init(type: .fadeThroughBlack, direction: nil, duration: 0.8)
        edited.timeline[i].transitionLocked = true
        let rebuilt = ReelComposer.rebuild(edited, order: edited.timeline.map(\.asset))
        #expect(rebuilt.timeline[i].fit == .panels && rebuilt.timeline[i].duration == 6 && rebuilt.timeline[i].transitionLocked == true)
        // Förval på ankaret: kollaget löses upp.
        var o = ReelMotionPlanner.ClipOverride(); o.preset = .zoomIn
        let preset = ReelComposer.rebuild(spec, order: spec.timeline.map(\.asset), overrides: [anchor: o])
        #expect(preset.timeline.allSatisfy { $0.fit != .panels } && preset.timeline.count == spec.timeline.count + 1)
        // Fotografens egna rutor (custom) är ett lås som överlever formatbyte.
        var custom = spec
        custom.timeline[i].motionPreset = ReelMotionPlanner.Preset.custom.rawValue
        #expect(ReelComposer.autoCollagePartner(custom.timeline[i]) == nil)
        let landscape = ReelComposer.rebuild(custom, order: custom.timeline.map(\.asset), format: .landscape)
        #expect(landscape.timeline[i].fit == .panels && landscape.timeline[i].panels == custom.timeline[i].panels)
    }

    @Test("Utesluten bild: kollaget löses upp, och \"Föreslå igen\" bildar det inte med en låst bild")
    func excludedAndPinnedInCompose() throws {
        let first = compose().spec
        let i = try #require(collageIndex(first))
        let anchorSha = sha(first, first.timeline[i].asset)
        let partnerSha = sha(first, ReelComposer.autoCollagePartner(first.timeline[i])!)
        // Rebuild med partnern utesluten: ankaret blir ensamt, partnern lämnar filmen.
        var excluded = first
        excluded.editor = .init(excludedAssets: [partnerSha])
        let r1 = ReelComposer.rebuild(excluded, order: first.timeline.map(\.asset))
        #expect(r1.timeline.allSatisfy { $0.fit != .panels } && r1.timeline.count == first.timeline.count)
        #expect(!r1.assets.contains { $0.sha256 == partnerSha })
        // Pinnad ankare vid ny komposition: ingen av dem ingår i ett kollage, bägge finns kvar.
        var editor = ReelSpec.EditorState(); editor.pinnedAssets = [anchorSha]
        let r2 = compose(editor: editor).spec
        #expect(r2.assets.contains { $0.sha256 == anchorSha })
        #expect(!r2.timeline.contains { clip in
            ReelComposer.autoCollagePartner(clip).map { p in [sha(r2, clip.asset), sha(r2, p)].contains(anchorSha) } ?? false
        })
    }

    @Test("Förklaringar: motionReasons, sammandrag och rumsrad nämner kollaget")
    func explanations() throws {
        let spec = compose().spec
        let i = try #require(collageIndex(spec))
        let reason = ReelEditorModel.motionReasons(spec)[i]
        guard case .collage(let layout, let pane, let rooms) = reason else { Issue.record("fel skäl: \(reason)"); return }
        #expect(layout == .stack && abs(pane - 1.1285) < 0.001 && rooms == "Kök och Matplats")
        #expect(reason.text == "Kollage: Kök och Matplats, båda ryms i 9:8 (två bilder staplade, svag gemensam zoom, ingen panorering)")
        #expect(reason.kind == .zoom)
        let summary = ReelChoiceSummary.summary(spec)
        #expect(summary.rows[i].room == "Kök + Matplats")
        #expect(summary.rows[i].motion == "Kollage: stapel")
        #expect(summary.rows[i].locked == false)
        // Alla andra klipp har sina vanliga skäl.
        for (j, r) in ReelEditorModel.motionReasons(spec).enumerated() where j != i {
            if case .collage = r { Issue.record("klipp \(j) ska inte vara kollage") }
        }
    }

    // MARK: - Redigeringsmodell

    private func makeModel() throws -> (ReelEditorModel, URL) {
        let root = try ObjektfilmTestKit.tempDir("ReelCollageModel")
        let source = root.appendingPathComponent("Lindvägen 12 FÄRDIGA")
        let reel = AddressFolderLayout.reelDir(forSource: source)
        let model = ReelEditorModel()
        let list = items().map { item -> ReelImageAnalyzer.Item in
            ReelImageAnalyzer.Item(url: source.appendingPathComponent(item.url.lastPathComponent), analysis: item.analysis)
        }
        model.prepare(items: list, sourceDirectory: source, reelDirectory: reel, address: "Lindvägen 12")
        return (model, root)
    }

    private func modelCollage(_ model: ReelEditorModel) throws -> (index: Int, anchor: String, partner: String, anchorSha: String, partnerSha: String) {
        let spec = try #require(model.spec)
        let i = try #require(collageIndex(spec))
        let anchor = spec.timeline[i].asset
        let partner = try #require(ReelComposer.autoCollagePartner(spec.timeline[i]))
        return (i, anchor, partner, sha(spec, anchor), sha(spec, partner))
    }

    @Test("Rutnätet: båda bilderna är \"i filmen\" på samma klipp, och Bilder-antalet räknar klipp")
    func gridShowsBoth() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try modelCollage(model)
        let rows = model.candidateRows
        let anchorRow = try #require(rows.first { $0.id == c.anchorSha })
        let partnerRow = try #require(rows.first { $0.id == c.partnerSha })
        #expect(anchorRow.clipIndex == c.index && partnerRow.clipIndex == c.index)
        #expect(partnerRow.excludedReason == nil)
        #expect(partnerRow.selectionReason?.hasPrefix("Kollage: Kök och Matplats") == true)
        #expect(model.clipRows.count == model.spec?.timeline.count)
        #expect(model.candidateRows.filter { $0.clipIndex != nil }.count == model.clipRows.count + 1)
        // Partnern räknas som med i filmen: ett klick på den markerar kollagets klipp.
        #expect(model.assetID(forCandidate: c.partnerSha) == c.anchor)
        model.selectCandidate(c.partnerSha)
        #expect(model.selectedAssetID == c.anchor)
    }

    @Test("Utesluta ankaret: partnern tar klippets plats som vanligt klipp; utesluta partnern: ankaret blir ensamt")
    func excludeEitherImage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try modelCollage(model)
        let clips = model.clipRows.count
        // Partnern utesluts.
        model.toggleExcluded(c.partnerSha)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true && model.clipRows.count == clips)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex == nil)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.isUserExcluded == true)
        #expect(model.candidateRows.first { $0.id == c.anchorSha }?.clipIndex == c.index)
        model.undo()
        #expect(collageIndex(model.spec!) == c.index)
        // Ankaret utesluts: partnern tar platsen.
        model.toggleExcluded(c.anchorSha)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true && model.clipRows.count == clips)
        #expect(model.clipRows[c.index].id == c.partner)
        #expect(model.candidateRows.first { $0.id == c.anchorSha }?.clipIndex == nil)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex == c.index)
    }

    @Test("Pinna den ena: den stannar i filmen (kollaget är kvar tills nästa förslag, då är den ensam)")
    func pinEitherImage() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try modelCollage(model)
        model.togglePinned(c.partnerSha)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.isPinned == true)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex != nil)
        model.suggestAgain()
        let spec = try #require(model.spec)
        #expect(spec.assets.contains { $0.sha256 == c.partnerSha })
        #expect(!spec.timeline.contains { clip in
            ReelComposer.autoCollagePartner(clip).map { p in [sha(spec, clip.asset), sha(spec, p)].contains(c.partnerSha) } ?? false
        }, "en låst bild ingår inte i ett automatiskt kollage")
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex != nil)
    }

    @Test("Ta bort kollagets klipp: båda bilderna lämnar filmen")
    func removeClip() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try modelCollage(model)
        model.removeClip(c.anchor)
        #expect(model.candidateRows.first { $0.id == c.anchorSha }?.clipIndex == nil)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex == nil)
        #expect(!(model.spec?.assets ?? []).contains { $0.id == c.partner })
    }

    @Test("Föreslå igen och formatbyte med kollage: samma kollage igen, upplöst i 16:9, och ångra tar tillbaka det")
    func suggestAgainAndFormat() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try modelCollage(model)
        model.suggestAgain()
        let again = try modelCollage(model)
        #expect(Set([again.anchorSha, again.partnerSha]) == Set([c.anchorSha, c.partnerSha]))
        model.setFormat(.landscape)
        #expect(model.spec?.timeline.allSatisfy { $0.fit != .panels } == true)
        #expect(model.candidateRows.first { $0.id == c.partnerSha }?.clipIndex != nil, "den valda partnern har ett eget klipp")
        model.undo()
        #expect(model.format == .vertical && collageIndex(model.spec!) != nil)
        // Fast antal: klippen är antalet.
        model.setCount(5)
        #expect(model.clipRows.count == 5 && model.fixedCount == 5)
    }

    // MARK: - Rendering

    private func writeSolid(_ url: URL, _ w: Int, _ h: Int, _ rgb: (CGFloat, CGFloat, CGFloat)) throws {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("Pixlar: planerarens kollage ritar två bilder staplade (röd uppe, blå nere) med svart gutter, och sida vid sida i 16:9")
    func renderStacked() throws {
        let dir = try ObjektfilmTestKit.tempDir("ReelCollageRender")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSolid(dir.appendingPathComponent("a1.png"), 600, 400, (1, 0, 0))
        try writeSolid(dir.appendingPathComponent("a2.png"), 600, 400, (0, 0, 1))
        try writeSolid(dir.appendingPathComponent("p1.png"), 400, 600, (1, 0, 0))
        try writeSolid(dir.appendingPathComponent("p2.png"), 400, 600, (0, 0, 1))

        func spec(_ assets: [(String, Int, Int)], _ clips: [ReelSpec.Clip], _ output: ReelSpec.Output) -> ReelSpec {
            ReelSpec(
                schema: ReelSpec.schemaName, version: 2, minReaderVersion: 2, id: "t", revision: 1, status: "draft",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                updatedBy: .init(role: "agent", name: nil), property: .init(address: "Test", sessionID: nil, kind: nil),
                assets: assets.map { .init(id: $0.0, sha256: $0.0, width: $0.1, height: $0.2, sources: [.init(kind: .local, path: "\($0.0).png")], analysis: nil) },
                style: .init(defaultTransition: .init(type: .crossfade, direction: nil, duration: 0.4), easing: .linear,
                             background: .init(type: "blur", amount: 0.6)),
                timeline: clips, audio: nil, overlays: [], brand: nil, outputs: [output],
                provenance: .init(generator: "test", autoSelection: nil, edits: nil))
        }
        func pixel(_ r: ReelRenderer, _ image: CIImage, _ x: Int, _ y: Int) -> [Int] {
            var buf = [UInt8](repeating: 0, count: 4)
            r.context.render(image, toBitmap: &buf, rowBytes: 4,
                             bounds: CGRect(x: CGFloat(x), y: image.extent.height - CGFloat(y) - 1, width: 1, height: 1),
                             format: .RGBA8, colorSpace: ReelRenderer.sRGB)
            return buf.map(Int.init)
        }
        func isRed(_ p: [Int]) -> Bool { p[0] > 240 && p[1] < 15 && p[2] < 15 }
        func isBlue(_ p: [Int]) -> Bool { p[2] > 240 && p[0] < 15 && p[1] < 15 }
        func isBlack(_ p: [Int]) -> Bool { p[0] < 6 && p[1] < 6 && p[2] < 6 }

        // 9:16: stapel. Efter ingången (0,9 s) ligger rutorna på plats.
        let out916 = ReelSpec.Output(id: "v", aspect: "9:16", width: 270, height: 480, fps: 30, encoding: nil)
        let a = ReelMotionPlanner.Image(assetID: "a1", width: 600, height: 400, focus: .init(x: 0.5, y: 0.5), salientWidth: 0.5, isExterior: false, focusWidth: 0.5)
        let b = ReelMotionPlanner.Image(assetID: "a2", width: 600, height: 400, focus: .init(x: 0.5, y: 0.5), salientWidth: 0.5, isExterior: false, focusWidth: 0.5)
        let clip = ReelMotionPlanner.plan([a], frameAspect: 270.0 / 480.0, collages: ["a1": b])[0]
        #expect(clip.fit == .panels && clip.layout == .stack)
        let s = spec([("a1", 600, 400), ("a2", 600, 400)], [clip], out916)
        let r = ReelRenderer(spec: s, specDirectory: dir, maxOutputSize: CGSize(width: 270, height: 480))
        let frame = r.renderFrame(at: 1.5, size: CGSize(width: 270, height: 480))
        #expect(isRed(pixel(r, frame, 135, 100)) && isRed(pixel(r, frame, 5, 5)) && isRed(pixel(r, frame, 265, 235)))
        #expect(isBlue(pixel(r, frame, 135, 380)) && isBlue(pixel(r, frame, 5, 474)))
        // Gutter 0,006 av kortsidan 270 px = 1,6 px mitt på höjden (heltalspixlar).
        #expect(isBlack(pixel(r, frame, 135, 239)) || isBlack(pixel(r, frame, 135, 240)))
        // Ingången: vid 0,3 s är den första halvvägs inne (glider från vänster), den andra ännu utanför.
        let early = r.renderFrame(at: 0.3, size: CGSize(width: 270, height: 480))
        #expect(isBlack(pixel(r, early, 200, 100)) && isBlack(pixel(r, early, 135, 380)))

        // 16:9: sida vid sida.
        let out169 = ReelSpec.Output(id: "l", aspect: "16:9", width: 480, height: 270, fps: 30, encoding: nil)
        let p1 = ReelMotionPlanner.Image(assetID: "p1", width: 400, height: 600, focus: .init(x: 0.5, y: 0.5), salientWidth: 0.5, isExterior: false, focusWidth: 0.5)
        let p2 = ReelMotionPlanner.Image(assetID: "p2", width: 400, height: 600, focus: .init(x: 0.5, y: 0.5), salientWidth: 0.5, isExterior: false, focusWidth: 0.5)
        let side = ReelMotionPlanner.plan([p1], frameAspect: 480.0 / 270.0, collages: ["p1": p2])[0]
        #expect(side.layout == .side)
        let s2 = spec([("p1", 400, 600), ("p2", 400, 600)], [side], out169)
        let r2 = ReelRenderer(spec: s2, specDirectory: dir, maxOutputSize: CGSize(width: 480, height: 270))
        let frame2 = r2.renderFrame(at: 1.5, size: CGSize(width: 480, height: 270))
        #expect(isRed(pixel(r2, frame2, 100, 135)) && isBlue(pixel(r2, frame2, 380, 135)))
    }
}
