import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelSelector` med syntetiska kandidater (ingen Vision, inga bildfiler).
struct ReelSelectorTests {

    /// Enhetsvektor i 12 dimensioner: olika `axis` ger avståndet √2 (helt olika bilder).
    private func vec(_ axis: Int, tweak: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 12)
        v[axis % 12] = 1
        v[(axis + 1) % 12] = tweak
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
        return ["Fasad", "Trädgård", "Altan", "Tomt"].contains(room) ? "Exteriör" : "Interiör"
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

    @Test("Villamallen öppnar med fasaden även om ett rum har högre poäng")
    func houseStartsWithFacade() {
        var list = villa()
        list[0].quality = 0.6
        list[2].quality = 0.99
        let sel = ReelSelector.select(list)
        #expect(sel.template == .house)
        #expect(sel.picks.first?.candidateID == "fasad")
        #expect(sel.picks.first?.slot == .opening)
        #expect(sel.picks.last?.slot == .closing)
        #expect(sel.picks.last?.candidateID == "trad")
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
    }

    @Test("MMR väljer hellre en annorlunda bild än en som liknar en redan vald")
    func mmrAvoidsLookAlike() {
        // "sov" liknar vardagsrummet (nästan samma vektor) och har högre poäng än "bad".
        var list = villa()
        list[2] = cand("vard", room: "Vardagsrum", q: 0.85, axis: 2)
        list[4] = cand("sov", room: "Sovrum", q: 0.80, axis: 2, tweak: 0.05)
        list[5] = cand("bad", room: "Badrum", q: 0.74, axis: 5)
        let sel = ReelSelector.select(list)
        let feature = sel.picks.first { $0.slot == .feature }
        #expect(feature?.candidateID == "bad")
    }

    @Test("Utan rumstyper används reservlogiken: rätt antal, inga upprepningar, reserv i motiveringen")
    func fallbackWithoutRooms() {
        let list = (0..<9).map { cand("b\($0)", room: nil, category: nil, q: 0.5 + Double($0) / 40, axis: $0) }
        let sel = ReelSelector.select(list)
        #expect(sel.picks.count == 5)
        #expect(Set(sel.picks.map(\.candidateID)).count == 5)
        #expect(sel.picks.dropFirst().allSatisfy { $0.reason.contains("reserv") })
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

    @Test("Antalet följer inställningen och klampas till 3–8")
    func countRespected() {
        let list = (0..<14).map { cand("b\($0)", room: $0 == 0 ? "Fasad" : nil, q: 0.5 + Double($0) / 50, axis: $0) }
        #expect(ReelSelector.select(list, count: 3).picks.count == 3)
        #expect(ReelSelector.select(list, count: 5).picks.count == 5)
        #expect(ReelSelector.select(list, count: 8).picks.count == 8)
        #expect(ReelSelector.select(list, count: 1).picks.count == 3)
        #expect(ReelSelector.select(list, count: 20).picks.count == 8)
        // Få kandidater: allt som finns tas med.
        #expect(ReelSelector.select(Array(list.prefix(4)), count: 5).picks.count == 4)
    }

    @Test("Varje val har en svensk motivering")
    func reasonsPresent() {
        let sel = ReelSelector.select(villa())
        #expect(sel.picks.allSatisfy { !$0.reason.isEmpty })
        #expect(sel.picks.first?.reason == "Öppning: Fasad, kvalitet 0,90")
        #expect(sel.picks.last?.reason.hasPrefix("Avslut: Trädgård") == true)
        #expect(sel.scores.count == villa().count)
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

    @Test("Nyttobild med god kvalitet är ett mjukt avdrag: badrum kan väljas som särdrag")
    func utilityIsSoft() {
        var list = villa()
        list.removeAll { $0.id == "bad" || $0.id == "sov" }
        list.append(cand("sov", room: "Sovrum", q: 0.6, axis: 4))
        var bad = cand("bad", room: "Badrum", q: 0.9, axis: 5)
        bad.isUtility = true
        list.append(bad)
        let sel = ReelSelector.select(list)
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

    @Test("Samma rum flera gånger: högst en bild per rumstyp när det finns andra rum")
    func oneImagePerRoomType() {
        // Provkörningens mönster: många kök och vardagsrum (med varierande stavning), några badrum.
        var list: [ReelCandidate] = []
        var n = 0
        func add(_ room: String, _ q: Double) { list.append(cand("c\(n)", room: room, category: "Interiör", q: q, axis: n)); n += 1 }
        for (room, q) in [("Kök", 0.85), ("Köket", 0.84), ("Kök", 0.83), ("Vardagsrum", 0.82), ("Allrum", 0.81),
                          ("Öppen plan", 0.80), ("Badrum", 0.7), ("Sovrum", 0.7), ("Kontor", 0.65), ("Hall", 0.6)] {
            add(room, q)
        }
        let sel = ReelSelector.select(list)
        let types = sel.picks.compactMap { p in ReelSelector.roomType(list.first { $0.id == p.candidateID }?.room) }
        #expect(sel.picks.count == 5)
        #expect(Set(types).count == types.count, "rumstyper: \(types)")
    }

    @Test("Rumsstraffet är mjukt: en klart bättre bild av samma rum får fortfarande användas när alternativen är dåliga")
    func roomPenaltyIsSoft() {
        let list = [cand("k1", room: "Kök", q: 0.9, axis: 0), cand("k2", room: "Köket", q: 0.9, axis: 1),
                    cand("v", room: "Vardagsrum", q: 0.9, axis: 2), cand("b", room: "Badrum", q: 0.05, axis: 3),
                    cand("s", room: "Sovrum", q: 0.05, axis: 4), cand("h", room: "Hall", q: 0.05, axis: 5)]
        let sel = ReelSelector.select(list, count: 4)
        #expect(sel.picks.count == 4)
        #expect(Set(sel.picks.map(\.candidateID)).count == 4)
    }
}
