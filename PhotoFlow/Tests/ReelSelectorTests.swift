import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelSelector` med syntetiska kandidater (ingen Vision, inga bildfiler).
struct ReelSelectorTests {

    /// Enhetsvektor i 40 dimensioner: olika `axis` ger avståndet √2 (helt olika bilder).
    private func vec(_ axis: Int, tweak: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 40)
        v[axis % 40] = 1
        v[(axis + 1) % 40] = tweak
        return v
    }

    private func cand(_ id: String, room: String?, category: String? = nil, q: Double = 0.7, axis: Int,
                      tweak: Float = 0, sharp: Double? = nil, horizon: Double? = nil) -> ReelCandidate {
        ReelCandidate(id: id, filename: "\(id).jpg", quality: q, horizonDegrees: horizon, sharpness: sharp,
                      featureVector: vec(axis, tweak: tweak), salientWidth: 0.4, meanLuminance: 0.45,
                      room: room, category: category ?? inferredCategory(room))
    }

    private func inferredCategory(_ room: String?) -> String? {
        guard let room else { return nil }
        return ["Fasad", "Trädgård", "Altan", "Tomt", "Balkong", "Utsikt", "Uteplats"].contains(room) ? "Exteriör" : "Interiör"
    }

    /// En villa med alla rumstyper.
    private func villa() -> [ReelCandidate] {
        [cand("fasad", room: "Fasad", q: 0.9, axis: 0),
         cand("trad", room: "Trädgård", q: 0.8, axis: 1),
         cand("vard", room: "Vardagsrum", q: 0.85, axis: 2),
         cand("kok", room: "Kök", q: 0.8, axis: 3),
         cand("sov", room: "Sovrum", q: 0.75, axis: 4),
         cand("bad", room: "Badrum", q: 0.7, axis: 5),
         cand("hall", room: "Hall", q: 0.6, axis: 6)]
    }

    /// Rumstyperna i `sel.picks` i visningsordning.
    private func types(_ sel: ReelSelector.Selection, _ list: [ReelCandidate]) -> [String] {
        sel.picks.map { p in ReelSelector.roomType(list.first { $0.id == p.candidateID }?.room) ?? "okänt" }
    }

    private func ids(_ sel: ReelSelector.Selection) -> [String] { sel.picks.map(\.candidateID) }

    @Test("Nyttobilder med låg kvalitet filtreras bort och får en förklaring")
    func utilityRemoved() {
        var list = villa()
        list.append(ReelCandidate(id: "kvitto", filename: "kvitto.jpg", quality: 0.2, isUtility: true,
                                  featureVector: vec(9), room: "Kök", category: "Interiör"))
        let sel = ReelSelector.select(list)
        #expect(!sel.picks.contains { $0.candidateID == "kvitto" })
        #expect(sel.excluded.contains { $0.candidateID == "kvitto" && $0.kind == .utility })
    }

    @Test("Dubbletter: bara den bästa i gruppen behålls")
    func duplicatesRemoved() {
        var list = villa()
        list.append(cand("kok2", room: "Kök", q: 0.5, axis: 3))   // identisk feature print som "kok"
        let sel = ReelSelector.select(list)
        #expect(sel.excluded.contains { $0.candidateID == "kok2" && $0.kind == .duplicate })
        #expect(sel.picks.contains { $0.candidateID == "kok" })
        #expect(!sel.picks.contains { $0.candidateID == "kok2" })
    }

    @Test("Villa med bra fasad: fasaden öppnar, även när ett rum har lite högre poäng (inom marginalen)")
    func houseOpensWithGoodFacade() {
        var list = villa()
        list[0].quality = 0.80   // fasad: 0,0275 under vardagsrummet (0,85)
        let sel = ReelSelector.select(list)
        #expect(sel.template == .house)
        #expect(sel.picks.first?.candidateID == "fasad")
        #expect(sel.picks.first?.slot == .opening)
        #expect(sel.picks.last?.slot == .closing)
        #expect(sel.picks.last?.candidateID == "trad")
    }

    @Test("Villa med svag fasad (marginalen överskriden): bästa hjältebilden öppnar och fasaden kommer med senare")
    func houseOpensWithBestHeroWhenFacadeIsWeak() {
        var list = villa()
        list[0].quality = 0.6
        list[2].quality = 0.99
        let sel = ReelSelector.select(list)
        #expect(sel.template == .house)
        #expect(sel.picks.first?.candidateID == "vard")
        #expect(sel.picks.first?.reason.contains("fasaden") == true)
        #expect(ids(sel).contains("fasad"))
        #expect(ids(sel).firstIndex(of: "fasad")! > 0)
    }

    @Test("Marginalen är en vikt: en större marginal släpper fram fasaden")
    func facadeMarginIsAWeight() {
        var list = villa()
        list[0].quality = 0.6
        list[2].quality = 0.99
        var w = ReelSelector.Weights()
        w.facadeOpeningMargin = 0.5
        #expect(ReelSelector.select(list, weights: w).picks.first?.candidateID == "fasad")
    }

    @Test("Lägenhet med ett fint badrum öppnar inte med badrummet")
    func apartmentNeverOpensWithBathroom() {
        let list = [cand("bad", room: "Badrum", q: 1.0, axis: 0),
                    cand("vard", room: "Vardagsrum", q: 0.7, axis: 1),
                    cand("kok", room: "Kök", q: 0.65, axis: 2),
                    cand("sov", room: "Sovrum", q: 0.8, axis: 3),
                    cand("hall", room: "Hall", q: 0.9, axis: 4)]
        let sel = ReelSelector.select(list)
        #expect(sel.template == .apartment)
        #expect(sel.picks.first?.candidateID == "vard")
        // Hjältebilden slår ett bättre sovrum, och fasad prioriteras inte i en lägenhet.
        #expect(sel.picks.first?.reason.hasPrefix("Öppning: Vardagsrum") == true)
    }

    @Test("Badrum, hall och okänt rum öppnar bara när det inte finns något annat")
    func utilityOpensOnlyAsLastResort() {
        let list = [cand("bad", room: "Badrum", q: 0.9, axis: 0), cand("hall", room: "Hall", q: 0.8, axis: 1),
                    cand("okant", room: nil, q: 0.99, axis: 2), cand("sov", room: "Sovrum", q: 0.5, axis: 3)]
        // Inget hjälterum: sovrummet (vanligt rum) öppnar före badrum och nyttorum.
        #expect(ReelSelector.select(list).picks.first?.candidateID == "sov")
        #expect(ReelSelector.select(Array(list.prefix(3))).picks.first?.candidateID == "bad")
    }

    @Test("Lägenhetsmallen: ingen fasad, öppnar med starkaste rummet")
    func apartmentTemplate() {
        let list = [cand("vard", room: "Vardagsrum", q: 0.9, axis: 0),
                    cand("kok", room: "Kök", q: 0.8, axis: 1),
                    cand("sov", room: "Sovrum", q: 0.7, axis: 2),
                    cand("bad", room: "Badrum", q: 0.7, axis: 3),
                    cand("balk", room: "Balkong", q: 0.75, axis: 4),
                    cand("hall", room: "Hall", q: 0.5, axis: 5)]
        let sel = ReelSelector.select(list)
        #expect(sel.template == .apartment)
        #expect(sel.picks.first?.candidateID == "vard")
        #expect(sel.picks.last?.candidateID == "balk")
        #expect(sel.picks.count == 5)
        #expect(!ids(sel).contains("hall"))
    }

    @Test("MMR väljer hellre en annorlunda bild av samma rum än en som liknar en redan vald")
    func mmrAvoidsLookAlike() {
        // Två sovrum: "sov1" har högre poäng men liknar vardagsrummet; "sov2" är något sämre men annorlunda.
        var list = villa()
        list[2] = cand("vard", room: "Vardagsrum", q: 0.85, axis: 2)
        list[4] = cand("sov1", room: "Sovrum", q: 0.80, axis: 2, tweak: 0.05)
        list.append(cand("sov2", room: "Sovrum", q: 0.78, axis: 7))
        let sel = ReelSelector.select(list)
        #expect(ids(sel).contains("sov2"))
        #expect(!ids(sel).contains("sov1"))
    }

    @Test("Utan rumstyper: rätt antal, inga upprepningar och inga felmärkta rum")
    func fallbackWithoutRooms() {
        let list = (0..<9).map { cand("b\($0)", room: nil, category: nil, q: 0.5 + Double($0) / 40, axis: $0) }
        let sel = ReelSelector.select(list)
        #expect(sel.picks.count == 5)
        #expect(Set(ids(sel)).count == 5)
        #expect(sel.picks.first?.reason.contains("ingen hjältebild") == true)
        #expect(sel.picks.dropFirst().dropLast().allSatisfy { $0.slot == .room && $0.roomType == nil })
    }

    @Test("Bara Visions grova kategori: exteriör föredras i öppningen och avslutningen")
    func fallbackWithCategoryOnly() {
        var list = (0..<8).map { cand("i\($0)", room: nil, category: "Interiör", q: 0.8, axis: $0) }
        list.append(cand("e1", room: nil, category: "Exteriör", q: 0.5, axis: 8))
        list.append(cand("e2", room: nil, category: "Exteriör", q: 0.5, axis: 9))
        let sel = ReelSelector.select(list)
        // Utan rum finns ingen fasad → lägenhetsmall; avslutningen reserv, men urvalet blir fullt och unikt.
        #expect(sel.template == .apartment)
        #expect(sel.picks.count == 5)
    }

    @Test("Antalet följer inställningen och klampas till 3–12")
    func countRespected() {
        let list = (0..<14).map { cand("b\($0)", room: $0 == 0 ? "Fasad" : nil, q: 0.5 + Double($0) / 50, axis: $0) }
        #expect(ReelSelector.select(list, count: 3).picks.count == 3)
        #expect(ReelSelector.select(list, count: 5).picks.count == 5)
        #expect(ReelSelector.select(list, count: 8).picks.count == 8)
        #expect(ReelSelector.select(list, count: 1).picks.count == 3)
        #expect(ReelSelector.select(list, count: 20).picks.count == 12)
        // Få kandidater: allt som finns tas med.
        #expect(ReelSelector.select(Array(list.prefix(4)), count: 5).picks.count == 4)
    }

    @Test("Varje val har en svensk motivering som beskriver den nya logiken")
    func reasonsPresent() {
        let list = villa()
        let sel = ReelSelector.select(list)
        func pts(_ id: String) -> String { ReelSelector.fmt(sel.scores[id]!) }
        #expect(sel.picks.allSatisfy { !$0.reason.isEmpty })
        #expect(sel.picks.first?.reason == "Öppning: Fasad, poäng \(pts("fasad")) (bästa hjältebilden)")
        #expect(sel.picks.last?.reason == "Avslut: Trädgård, skiljer sig från öppningen, poäng \(pts("trad"))")
        #expect(sel.picks.first { $0.candidateID == "kok" }?.reason == "Kök, enda bilden, poäng \(pts("kok"))")
        #expect(sel.scores.count == list.count)
    }

    @Test("Motivering för bästa/näst bästa bild av ett rum och för fasad som håller mot en starkare hjältebild")
    func reasonTexts() {
        var list = villa()
        list[0].quality = 0.8      // fasad 0,0275 under vardagsrummet
        list.append(cand("kok2", room: "Kök", q: 0.7, axis: 8))
        list.append(cand("kok3", room: "Kök", q: 0.6, axis: 9))
        let sel = ReelSelector.select(list, count: 9)
        func pts(_ id: String) -> String { ReelSelector.fmt(sel.scores[id]!) }
        #expect(sel.picks.first?.reason == "Öppning: Fasad, poäng \(pts("fasad")) (bästa hjältebild \(pts("vard")))")
        #expect(sel.picks.first { $0.candidateID == "kok" }?.reason == "Kök, bästa av 3, poäng \(pts("kok"))")
        #expect(sel.picks.first { $0.candidateID == "kok2" }?.reason == "Kök, näst bästa av 3, poäng \(pts("kok2"))")
        #expect(sel.picks.first { $0.candidateID == "kok3" }?.reason == "Kök, bild 3 av 3, poäng \(pts("kok3"))")
        #expect(ReelSelector.slotLabel("opening") == "Öppning")
        #expect(ReelSelector.slotLabel("closing") == "Avslut")
        #expect(ReelSelector.slotLabel("vardagsrum") == "Vardagsrum")
    }

    @Test("Horisontfiltret gäller bara exteriörer")
    func horizonOnlyForExterior() {
        var list = villa()
        list.append(cand("sned", room: "Tomt", q: 0.95, axis: 8, horizon: 5))
        list.append(cand("inne", room: "Sovrum", q: 0.5, axis: 9, horizon: 8))
        let sel = ReelSelector.select(list)
        #expect(sel.excluded.contains { $0.candidateID == "sned" && $0.kind == .horizon })
        #expect(!sel.excluded.contains { $0.candidateID == "inne" })
    }

    @Test("Skärpa under 25:e percentilen filtreras bort")
    func sharpnessPercentile() {
        var list = villa()
        for i in list.indices { list[i].sharpness = Double(100 + i * 10) }   // fasad minst skarp
        let sel = ReelSelector.select(list)
        #expect(sel.excluded.contains { $0.candidateID == "fasad" && $0.kind == .sharpness })
        #expect(!sel.picks.contains { $0.candidateID == "fasad" })
    }

    @Test("Kurerat läge behåller lite oskarpare bilder och tar bara bort en tydligt oskarp")
    func curatedKeepsSlightlySofter() {
        var list = villa()
        for i in list.indices { list[i].sharpness = Double(100 + i * 10) }   // fasad minst skarp, 100 mot median 130
        let curated = ReelSelector.select(list, curated: true)
        #expect(curated.excluded.isEmpty)
        #expect(curated.picks.contains { $0.candidateID == "fasad" })
        // Samma bilder utan kurerat läge: fasaden faller bort på percentilen (som förut).
        let plain = ReelSelector.select(list)
        #expect(plain.excluded.contains { $0.candidateID == "fasad" && $0.kind == .sharpness })
        // En tydligt oskarp bild (under 35 % av medianen) tas bort även i kurerat läge.
        list[1].sharpness = 20
        let blurry = ReelSelector.select(list, curated: true)
        #expect(blurry.excluded.map(\.candidateID) == ["trad"])
        #expect(blurry.excluded.first?.kind == .sharpness && blurry.excluded.first?.reason.contains("Tydligt oskarp") == true)
    }

    @Test("Kurerat läge: rimlighetsventilen tar fortfarande tillbaka en oskarp bild när det är för få kvar")
    func curatedValveStillWorks() {
        var list = Array(villa().prefix(5))
        for i in list.indices { list[i].sharpness = 200 }
        list[0].sharpness = 10
        let sel = ReelSelector.select(list, count: 5, curated: true)
        #expect(sel.picks.count == 5 && sel.excluded.isEmpty)
    }

    @Test("Blir för få kvar tas mjuka bortfall tillbaka")
    func softExclusionsReinstated() {
        var list = Array(villa().prefix(5))
        for i in list.indices { list[i].sharpness = Double(100 + i * 10) }
        let sel = ReelSelector.select(list, count: 5)
        #expect(sel.picks.count == 5)
        #expect(sel.excluded.isEmpty)
    }

    @Test("Skymningsbild föredras som avslutning")
    func duskClosing() {
        var list = villa()
        var dusk = cand("skymning", room: "Altan", q: 0.7, axis: 8)
        dusk.meanLuminance = 0.25
        dusk.captureHour = 20
        list.append(dusk)
        let sel = ReelSelector.select(list)
        #expect(sel.picks.last?.candidateID == "skymning")
        #expect(sel.picks.last?.reason.contains("skymning") == true)
    }

    @Test("Nyttobild med god kvalitet är ett mjukt avdrag: badrummet filtreras inte bort och kan väljas")
    func utilityIsSoft() {
        var list = villa()
        list.removeAll { $0.id == "bad" || $0.id == "sov" }
        list.append(cand("sov", room: "Sovrum", q: 0.6, axis: 4))
        var bad = cand("bad", room: "Badrum", q: 0.9, axis: 5)
        bad.isUtility = true
        list.append(bad)
        let sel = ReelSelector.select(list, count: 6)
        #expect(!sel.excluded.contains { $0.candidateID == "bad" })
        #expect(sel.picks.contains { $0.candidateID == "bad" })
        let plain = ReelSelector.baseScore(cand("x", room: "Badrum", q: 0.9, axis: 5), sharpnessPercentile: 0.5, weights: .init())
        #expect(sel.scores["bad"]! < plain)
    }

    @Test("Rumstyper normaliseras: synonymer är samma rum")
    func roomTypeSynonyms() {
        #expect(ReelSelector.roomType("Köket") == ReelSelector.roomType("Kök"))
        #expect(ReelSelector.roomType("Allrum") == "vardagsrum")
        #expect(ReelSelector.roomType("Öppen plan") == "vardagsrum")
        #expect(ReelSelector.roomType("Sällskapsrum") == "vardagsrum")
        #expect(ReelSelector.roomType("Kök och vardagsrum") == "kök")
        #expect(ReelSelector.roomType("Toalett") == "badrum")
        #expect(ReelSelector.roomType("Fasad") != ReelSelector.roomType("Trädgård"))
        #expect(ReelSelector.roomType(nil) == nil)
    }

    @Test("Rumstyper normaliseras också för utsikt, nyttorum och generiska utomhusnamn")
    func roomTypeNewTypes() {
        #expect(ReelSelector.roomType("Havsutsikt") == "utsikt")
        #expect(ReelSelector.roomType("Balkong") == "uteplats")
        #expect(ReelSelector.roomType("Takterrass") == "uteplats")
        #expect(ReelSelector.roomType("Fasadbild") == "fasad")
        #expect(ReelSelector.roomType("Trädgård/tomt") == "trädgård")
        #expect(ReelSelector.roomType("Tvättstuga") == "tvättstuga")
        #expect(ReelSelector.roomType("Källare") == "förråd")
        #expect(ReelSelector.roomType("Exteriör") == "utomhus")
        #expect(ReelSelector.roomType("Utanför") == "utomhus")
    }

    @Test("Kategori som säger emot rummet: ett tydligt interiört rumsnamn vinner över kategorin Exteriör")
    func interiorRoomBeatsExteriorCategory() {
        let c = cand("v", room: "Vardagsrum", category: "Exteriör", q: 0.9, axis: 11, horizon: 6)
        #expect(ReelSelector.roomType(c.room) == "vardagsrum")
        #expect(ReelSelector.isExterior(c) == false)
        // Ingen horisontfiltrering, och aldrig ett avslut utomhus.
        var list = villa()
        list.append(c)
        let sel = ReelSelector.select(list)
        #expect(!sel.excluded.contains { $0.candidateID == "v" })
        #expect(sel.picks.last?.candidateID == "trad")
        // Övriga fall är oförändrade: kategorin går före rum utan tydlig inomhusbetydelse.
        #expect(ReelSelector.isExterior(cand("u", room: "Utsikt", category: "Interiör", axis: 1)) == false)
        #expect(ReelSelector.isExterior(cand("t", room: "Okänt", category: "Exteriör", axis: 2)) == true)
    }

    @Test("En av varje: 25 bilder blir en per rumstyp i visningsordning, antal 5–8")
    func oneOfEachInDisplayOrder() {
        var list: [ReelCandidate] = []
        var n = 0
        func add(_ room: String, _ qs: [Double]) {
            for q in qs { list.append(cand("p\(n)", room: room, q: q, axis: n)); n += 1 }
        }
        add("Vardagsrum", [0.95, 0.9, 0.85, 0.8])
        add("Kök", [0.9, 0.85, 0.8])
        add("Sovrum", [0.9, 0.85])
        add("Badrum", [0.95, 0.9, 0.85])
        add("Balkong", [0.9, 0.85])
        add("Fasad", [0.9, 0.88, 0.8])
        add("Tvättstuga", [0.9])
        add("Hall", [0.9, 0.85])
        add("Trädgård", [0.9, 0.85, 0.8])
        add("Matplats", [0.9, 0.85])
        #expect(list.count == 25)
        let sel = ReelSelector.select(list)
        let t = types(sel, list)
        #expect((5...8).contains(sel.picks.count))
        #expect(Set(t).count == t.count, "en per rumstyp: \(t)")
        #expect(t.first == "fasad")
        #expect(sel.picks.first?.slot == .opening)
        #expect(sel.picks.last?.slot == .closing)
        #expect(["uteplats", "trädgård"].contains(t.last ?? ""))
        #expect(!t.contains("tvättstuga") && !t.contains("hall"))
        // Inomhus i ordningen vardagsrum, kök, matplats, sovrum, badrum.
        let indoor = t.filter { ["vardagsrum", "kök", "matplats", "sovrum", "badrum"].contains($0) }
        let wanted = ["vardagsrum", "kök", "matplats", "sovrum", "badrum"].filter(indoor.contains)
        #expect(indoor == wanted)
        #expect(t.firstIndex(of: "vardagsrum")! < t.firstIndex(of: "kök")!)
        // Bästa bilden per typ, inte en sämre.
        #expect(ids(sel).contains("p0"))
        #expect(sel.picks.first { $0.candidateID == "p0" }?.reason.contains("bästa av 4") == true)
    }

    @Test("Antalet är automatiskt: minst 5 med få rumstyper, högst 8 med många")
    func autoCountIsClamped() {
        let few = [cand("a", room: "Vardagsrum", axis: 0), cand("b", room: "Kök", axis: 1)]
            + (2..<9).map { cand("k\($0)", room: "Kök", q: 0.5 + Double($0) / 50, axis: $0) }
        #expect(ReelSelector.select(few).picks.count == 5)
        let rooms = ["Fasad", "Vardagsrum", "Kök", "Matplats", "Sovrum", "Balkong", "Utsikt", "Trädgård", "Badrum", "Uteplats"]
        let many = rooms.enumerated().map { cand("m\($0.offset)", room: $0.element, q: 0.95, axis: $0.offset) }
        #expect(ReelSelector.select(many).picks.count == 8)
        // Tre bilder totalt: allt som finns.
        #expect(ReelSelector.select(Array(few.prefix(3))).picks.count == 3)
    }

    @Test("Rumstyper som saknas ger inga felmärkta platser")
    func missingRoomsGiveNoMislabeledSlots() {
        // Ingen vardagsrum, kök eller sovrum: bara fasad, utsikt och trädgård.
        let list = [cand("f", room: "Fasad", axis: 0), cand("u", room: "Utsikt", q: 0.8, axis: 1),
                    cand("t", room: "Trädgård", q: 0.75, axis: 2), cand("u2", room: "Utsikt", q: 0.7, axis: 3),
                    cand("f2", room: "Fasad", q: 0.6, axis: 4)]
        let sel = ReelSelector.select(list)
        for p in sel.picks {
            let c = list.first { $0.id == p.candidateID }!
            if p.slot == .room { #expect(p.roomType == ReelSelector.roomType(c.room)) }
            #expect(!p.reason.contains("reserv"))
            #expect(!p.reason.hasPrefix("Kök") && !p.reason.hasPrefix("Vardagsrum"))
        }
        #expect(!sel.picks.contains { $0.slotKey == "vardagsrum" || $0.slotKey == "kök" })
    }

    @Test("En andra bild av samma typ väljs först när alla rumstyper har fått en")
    func secondImageOnlyWhenTypesRunOut() {
        var list = villa()
        list.removeAll { $0.id == "hall" }
        list[5].quality = 0.95                       // badrum som är bra nog
        list.append(cand("vard2", room: "Vardagsrum", q: 0.84, axis: 7))
        list.append(cand("kok2", room: "Kök", q: 0.79, axis: 8))
        list.append(cand("sov2", room: "Sovrum", q: 0.74, axis: 9))
        list.append(cand("fasad2", room: "Fasad", q: 0.85, axis: 10))
        // Sex rumstyper (fasad, vardagsrum, kök, sovrum, trädgård, badrum): upp till 6 bilder är en per typ.
        let six = ReelSelector.select(list, count: 6)
        #expect(Set(types(six, list)).count == 6)
        let seven = ReelSelector.select(list, count: 7)
        #expect(Set(types(seven, list)).count == 6)
        let ten = ReelSelector.select(list, count: 10)
        let t = types(ten, list)
        #expect(ten.picks.count == 10)
        #expect(Set(t).count == 6)
        #expect(t.filter { $0 == "vardagsrum" }.count == 2 && t.filter { $0 == "kök" }.count == 2)
    }

    @Test("Badrum tas bara med om bilden är bra; ett svagt badrum kommer sist")
    func bathroomOnlyWhenGood() {
        var list = villa()
        list.removeAll { $0.id == "hall" }
        list[5].quality = 0.6                        // svagt badrum
        list.append(cand("vard2", room: "Vardagsrum", q: 0.8, axis: 7))
        list.append(cand("kok2", room: "Kök", q: 0.75, axis: 8))
        let auto = ReelSelector.select(list)
        #expect(!ids(auto).contains("bad"))
        list[5].quality = 0.97                       // bra badrum
        let good = ReelSelector.select(list)
        #expect(ids(good).contains("bad"))
        // Badrummet är sist bland inomhusbilderna.
        let t = types(good, list)
        #expect(t.firstIndex(of: "badrum")! > t.firstIndex(of: "sovrum")!)
    }

    @Test("Nyttorum tas med först när inget annat finns")
    func utilityRoomsLast() {
        let list = [cand("v", room: "Vardagsrum", axis: 0), cand("k", room: "Kök", axis: 1), cand("s", room: "Sovrum", axis: 5),
                    cand("h", room: "Hall", q: 0.95, axis: 2), cand("t", room: "Tvättstuga", q: 0.95, axis: 3),
                    cand("kn", room: "Kontor", q: 0.95, axis: 4)]
        #expect(!ids(ReelSelector.select(list, count: 3)).contains { ["h", "t", "kn"].contains($0) })
        // Fast antal över vad de riktiga rummen räcker till: nyttorummen fyller upp.
        #expect(ReelSelector.select(list, count: 5).picks.count == 5)
        #expect(ReelSelector.select(list, count: 5).picks.contains { ["h", "t", "kn"].contains($0.candidateID) })
    }

    @Test("Avslutet skiljer sig från öppningen och är utomhus; finns ingen utomhusbild blir det en annan hjältebild, aldrig badrum")
    func closingRules() {
        let indoor = [cand("v", room: "Vardagsrum", q: 0.9, axis: 0), cand("k", room: "Kök", q: 0.8, axis: 1),
                      cand("s", room: "Sovrum", q: 0.7, axis: 2), cand("b", room: "Badrum", q: 0.99, axis: 3),
                      cand("m", room: "Matplats", q: 0.6, axis: 4)]
        let sel = ReelSelector.select(indoor)
        #expect(sel.picks.first?.candidateID == "v")
        #expect(sel.picks.last?.slot == .closing)
        #expect(sel.picks.last?.candidateID == "k")
        #expect(sel.picks.last?.reason.contains("ingen utomhusbild") == true)
        // Med en utomhusbild: den är avslutet, och öppningen är inte också avslut.
        let withOutdoor = indoor + [cand("balk", room: "Balkong", q: 0.6, axis: 5)]
        let sel2 = ReelSelector.select(withOutdoor)
        #expect(sel2.picks.last?.candidateID == "balk")
        #expect(sel2.picks.last?.reason.hasPrefix("Avslut: Balkong, skiljer sig från öppningen, poäng 0,") == true)
        #expect(sel2.picks.first?.candidateID != sel2.picks.last?.candidateID)
    }

    @Test("Samma rum flera gånger: fördelas över rumstyperna när det finns få")
    func repeatsAreSpread() {
        var list: [ReelCandidate] = []
        var n = 0
        func add(_ room: String, _ q: Double) { list.append(cand("d\(n)", room: room, category: "Interiör", q: q, axis: n)); n += 1 }
        for q in [0.85, 0.84, 0.83, 0.82, 0.81] { add("Kök", q) }
        for q in [0.78, 0.77, 0.76] { add("Vardagsrum", q) }
        for q in [0.75, 0.74, 0.73] { add("Sovrum", q) }
        let sel = ReelSelector.select(list, count: 6)
        var counts: [String: Int] = [:]
        for t in types(sel, list) { counts[t, default: 0] += 1 }
        #expect(sel.picks.count == 6)
        #expect(counts.values.max() == 2, "\(counts)")
        #expect(counts.count == 3)
    }

    @Test("Rumsstraffet är mjukt: en klart bättre bild av samma rum får fortfarande användas när alternativen är dåliga")
    func roomPenaltyIsSoft() {
        let list = [cand("k1", room: "Kök", q: 0.9, axis: 0), cand("k2", room: "Köket", q: 0.9, axis: 1),
                    cand("v", room: "Vardagsrum", q: 0.9, axis: 2), cand("b", room: "Badrum", q: 0.05, axis: 3),
                    cand("s", room: "Sovrum", q: 0.05, axis: 4), cand("h", room: "Hall", q: 0.05, axis: 5)]
        let sel = ReelSelector.select(list, count: 4)
        #expect(sel.picks.count == 4)
        #expect(Set(sel.picks.map(\.candidateID)).count == 4)
        #expect(ids(sel).contains("k2"))
    }
}
