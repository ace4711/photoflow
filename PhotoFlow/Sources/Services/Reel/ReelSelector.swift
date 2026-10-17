import Foundation

/// En bild som urvalet kan välja bland. Bara de analysfält urvalet behöver, så
/// att tester kan bygga syntetiska kandidater utan Vision eller bildfiler.
nonisolated struct ReelCandidate: Sendable, Equatable, Identifiable {
    var id: String
    var filename: String
    /// 0...1 (`PhotoQualityService`).
    var quality: Double?
    var isUtility = false
    var horizonDegrees: Double?
    /// Relativt mått inom objektet.
    var sharpness: Double?
    /// Feature print (se `ReelImageAnalysis.featureVector`).
    var featureVector: [Float]?
    /// Motivets sammanlagda bredd, andel av bildbredden.
    var salientWidth: Double?
    var meanLuminance: Double?
    /// Timme på dygnet då bilden togs (lokal tid), om EXIF finns.
    var captureHour: Int?
    var room: String?
    /// "Interiör" / "Exteriör".
    var category: String?
    var features: [String] = []
    var caption: String?
    /// Montage (R6b): rummet per halva (samma ordning som halvorna, tom sträng = okänt). Tom för vanliga
    /// bilder. `room` är då den viktigaste av halvornas typer (`ReelSelector.primaryPanelIndex`), och
    /// montaget räknas som en plats i urvalet men täcker ingen rumstyp (en extra bild, se `select`).
    var panelRooms: [String] = []
}

/// Automatiskt urval av bilder till ett bildspel (plan 3.2): hårda filter,
/// grundpoäng, berättelsemall med platser, MMR för variation, reservlogik och
/// en motivering per val. Ren logik utan Vision/AppKit, så den går att testa
/// med syntetiska kandidater och kalibrera genom att byta `Weights`.
nonisolated enum ReelSelector {

    // MARK: - Typer

    /// Vikterna är startvärden ur planen och ska kalibreras mot fotografens egna val.
    nonisolated struct Weights: Sendable, Equatable {
        var quality = 0.55
        var sharpness = 0.15
        var feature = 0.10
        var light = 0.10
        var saliency = 0.10
        /// MMR: λ·poäng − (1−λ)·likhet med redan valda.
        var lambda = 0.7
        /// Exteriörer med större lutning än så här filtreras bort.
        var maxHorizonDegrees = 3.0
        /// Skärpa under den här percentilen inom objektet filtreras bort.
        var sharpnessCutPercentile = 0.25
        /// Kurerat läge (fotografens egna, redigerade bilder): bara bilder med mindre än så här stor
        /// andel av medianens skärpa filtreras bort. Chronas väg 7: lägsta riktiga bilden (badrum) har
        /// 0,54 av medianen och ska vara kvar; 0,35 tar bara bort tydligt suddiga bilder.
        var curatedSharpnessFloorRatio = 0.35
        /// Feature print-avstånd under detta räknas som dubblett.
        var duplicateThreshold = PhotoQualityService.duplicateDistanceThreshold
        /// Likhet över detta mellan avslutning och öppning undviks när det finns alternativ.
        var maxClosingSimilarity = 0.85
        /// Nyttobild (Vision) är ett mjukt avdrag på poängen. Hårt bort filtreras en
        /// nyttobild bara om kvaliteten också är lägre än `utilityHardMaxQuality`
        /// (Vision flaggade ~36 % av interiörerna, bland annat badrum och kontor).
        var utilityPenalty = 0.15
        var utilityHardMaxQuality = 0.35
        /// Rumsdiversitet: avdrag i MMR-värdet (λ-viktat), per gång rumstypen redan är vald. Rundorna
        /// ("en av varje", se `select`) gör att en typs andra bild kommer först när alla typer har en;
        /// avdraget avgör i slutfyllningen, när bara nyttorum och svaga badrum finns kvar. Med
        /// standardvärdena väljs en bild av en redan vald typ bara om den har ungefär 0,57 högre
        /// grundpoäng (0,4 / λ) än alternativen.
        var roomRepeatPenalty = 0.4
        /// Villa: fasaden öppnar om dess grundpoäng är högst så här mycket under den bästa
        /// hjältebildens. Annars öppnar den bästa hjältebilden.
        var facadeOpeningMargin = 0.08
        /// Rumstyper som får öppna filmen (lägenhet: den bästa av dem; villa: fasaden om den håller).
        var heroRooms: [String] = ["fasad", "utsikt", "vardagsrum", "kök", "uteplats"]
        /// Urvalsordning för rumstyperna ("en av varje"): först i listan väljs först och kommer med
        /// när antalet inte räcker till alla. Efter listan kommer `extraRooms`, sedan badrum; alla andra
        /// typer (hall, tvättstuga, kontor, förråd, okänt och AI-namn som "Fönster") räknas som
        /// nyttorum och tas bara med när inget annat finns.
        var roomPriority: [String] = ["fasad", "vardagsrum", "kök", "matplats", "sovrum", "uteplats", "utsikt",
                                      "trädgård", "utomhus"]
        /// Särskilda rum som får en egen bild efter `roomPriority` men före badrum.
        var extraRooms: [String] = ["bastu", "pool", "brygga", "strand"]
        /// Ett badrum tas bara med i "en av varje" om dess grundpoäng är minst så här hög (riktiga
        /// objekt: bra badrum 0,65–0,75, svaga 0,4–0,5 eftersom Visions nyttobildsavdrag ofta slår till).
        var bathroomMinScore = 0.65
        /// Automatiskt antal bilder: en per viktig rumstyp som finns, men minst/högst så här många.
        var autoMinCount = 5
        var autoMaxCount = 8
        /// Tillägg på avslutets värde för en skymningsbild.
        var duskClosingBonus = 0.08
    }

    nonisolated enum Template: String, Sendable, Equatable {
        case house, apartment
    }

    /// Rollen en bild har i filmen. Öppning och avslut är roller; övriga bilder är "en av varje" rum
    /// (`Pick.roomType`).
    nonisolated enum Slot: String, Sendable, Equatable {
        case opening, closing, room

        var label: String {
            switch self {
            case .opening: return "Öppning"
            case .closing: return "Avslut"
            case .room: return "Rum"
            }
        }
    }

    nonisolated struct Pick: Sendable, Equatable {
        var candidateID: String
        var slot: Slot
        /// Normaliserad rumstyp (`roomType`), nil om rummet är okänt.
        var roomType: String?
        /// Svensk motivering, t.ex. "Öppning: Fasad, poäng 0,82 (bästa hjältebild 0,85)".
        var reason: String
        /// Grundpoängen (0...1).
        var score: Double

        /// Nyckeln som skrivs i specens `provenance.autoSelection[].slot`: "opening", "closing"
        /// eller rumstypen ("vardagsrum", "kök", ...; "okänt" om rummet saknas).
        var slotKey: String {
            slot == .room ? (roomType ?? "okänt") : slot.rawValue
        }
    }

    /// Visningsnamn för en `slotKey` ("opening" → "Öppning", "vardagsrum" → "Vardagsrum").
    static func slotLabel(_ key: String) -> String {
        if let slot = Slot(rawValue: key), slot != .room { return slot.label }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    nonisolated struct Exclusion: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable { case utility, horizon, sharpness, duplicate, user }
        var candidateID: String
        var kind: Kind
        var reason: String
    }

    nonisolated struct Selection: Sendable, Equatable {
        var template: Template
        /// I föreslagen visningsordning.
        var picks: [Pick]
        var excluded: [Exclusion]
        /// Grundpoäng för alla kandidater (även bortfiltrerade), för UI:t.
        var scores: [String: Double]
    }

    // MARK: - Rumsklassning

    private static let facadeKeywords = ["fasad", "villa", "tomt", "trädgård", "tradgard"]
    private static let livingKeywords = ["vardagsrum", "allrum", "vardag", "öppen plan", "sällskapsrum", "salong"]
    private static let kitchenKeywords = ["kök"]
    /// Rumsnamn som tydligt är inomhus. De går före kategorin "Exteriör" (AI-taggar som "Vardagsrum"
    /// med kategorin "Exteriör" förekommer), både för rumstypen och för `isExterior`.
    private static let clearInteriorKeywords = livingKeywords + kitchenKeywords
        + ["sovrum", "badrum", "toalett", "dusch", "matplats", "matsal", "tvättstuga", "tvättrum", "kontor", "arbetsrum"]
    private static let outdoorTypes: Set<String> = ["uteplats", "utsikt", "trädgård", "utomhus", "fasad"]
    private static let bonusKeywords = ["utsikt", "öppen spis", "sjötomt", "terrass", "kakelugn", "bastu", "pool",
                                        "havsutsikt", "sjöutsikt", "brygga", "strand", "kamin", "balkong", "altan",
                                        "takhöjd", "stuckatur", "braskamin"]

    /// Normaliserad rumstyp (synonymer slås ihop: "Köket" = "Kök", "Allrum"/"Öppen plan" =
    /// "Vardagsrum"). Nil om rummet är okänt. Okända rumsnamn är sin egen typ (gemener).
    static func roomType(_ room: String?) -> String? {
        guard let r = room?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        // Kök före vardagsrum: "Kök och vardagsrum" är i första hand ett kök.
        if matches(r, kitchenKeywords) { return "kök" }
        if matches(r, livingKeywords) { return "vardagsrum" }
        if matches(r, ["sovrum"]) { return "sovrum" }
        if matches(r, ["badrum", "toalett", "dusch", "wc", "tvättrum"]) { return "badrum" }
        if matches(r, ["matplats", "matsal"]) { return "matplats" }
        if matches(r, ["hall", "entré", "tamburen"]) { return "hall" }
        if matches(r, ["kontor", "arbetsrum"]) { return "kontor" }
        if matches(r, ["tvättstuga"]) { return "tvättstuga" }
        if matches(r, ["förråd", "källare", "garage"]) { return "förråd" }
        if isFacadeRoom(r) {
            return matches(r, ["trädgård", "tradgard", "tomt"]) ? "trädgård" : "fasad"
        }
        if matches(r, ["altan", "uteplats", "terrass", "balkong", "veranda"]) { return "uteplats" }
        if matches(r, ["utsikt"]) { return "utsikt" }
        if ["exteriör", "utanför", "utomhus", "ute"].contains(r) { return "utomhus" }
        return r
    }

    private static func matches(_ room: String?, _ keywords: [String]) -> Bool {
        guard let r = room?.lowercased(), !r.isEmpty else { return false }
        return keywords.contains { r.contains($0) }
    }

    private static func isFacadeRoom(_ room: String?) -> Bool {
        guard let r = room?.lowercased() else { return false }
        return r == "hus" || r.hasPrefix("hus ") || matches(r, facadeKeywords)
    }

    /// true = exteriör, false = interiör, nil = okänt. Kategorin går före rummet, utom när rumsnamnet
    /// tydligt är inomhus (`clearInteriorKeywords`): "Vardagsrum" med kategorin "Exteriör" är en
    /// interiör, så den kan inte bli öppning, avslut eller filtreras på horisonten.
    static func isExterior(_ c: ReelCandidate) -> Bool? {
        if matches(c.room, clearInteriorKeywords) { return false }
        if let cat = c.category?.lowercased() {
            if cat.contains("exter") { return true }
            if cat.contains("inter") { return false }
        }
        if isFacadeRoom(c.room) || matches(c.room, ["altan", "uteplats", "terrass", "balkong", "veranda", "pool", "utsikt"]) {
            return true
        }
        if matches(c.room, ["hall", "entré"]) { return false }
        return nil
    }

    private static func featureText(_ c: ReelCandidate) -> String {
        (c.features + [c.caption ?? "", c.room ?? ""]).joined(separator: " ").lowercased()
    }

    /// Skymningsbild: mörkare exteriör, och om EXIF-tid finns på kvällen/morgonen.
    static func isDusk(_ c: ReelCandidate) -> Bool {
        guard isExterior(c) != false, let lum = c.meanLuminance, lum < 0.40, lum > 0.08 else { return false }
        if let h = c.captureHour { return h >= 16 || h < 7 }
        return false
    }

    // MARK: - Poäng

    /// Percentilrank (0...1) för varje kandidats skärpa bland dem som har skärpa; saknad = 0,5.
    static func sharpnessPercentiles(_ candidates: [ReelCandidate]) -> [String: Double] {
        let values = candidates.compactMap(\.sharpness)
        var result: [String: Double] = [:]
        for c in candidates {
            guard let s = c.sharpness, values.count > 1 else { result[c.id] = 0.5; continue }
            let less = values.filter { $0 < s }.count
            let equal = values.filter { $0 == s }.count
            result[c.id] = (Double(less) + Double(equal - 1) / 2) / Double(values.count - 1)
        }
        return result
    }

    static func featureBonus(_ c: ReelCandidate) -> Double {
        let text = featureText(c)
        let hits = bonusKeywords.filter { text.contains($0) }.count
        return hits == 0 ? 0 : (hits == 1 ? 0.7 : 1.0)
    }

    static func lightBonus(_ c: ReelCandidate) -> Double {
        if isDusk(c) { return 1 }
        guard let lum = c.meanLuminance else { return 0.5 }
        return max(0, 1 - abs(lum - 0.45) / 0.45)
    }

    /// Ett tydligt (smalt) motiv ger bättre Ken Burns.
    static func saliencyClarity(_ c: ReelCandidate) -> Double {
        guard let w = c.salientWidth else { return 0.5 }
        return min(max(1 - w, 0), 1)
    }

    static func baseScore(_ c: ReelCandidate, sharpnessPercentile: Double, weights w: Weights) -> Double {
        let q = c.quality ?? 0.5
        return w.quality * q
            + w.sharpness * sharpnessPercentile
            + w.feature * featureBonus(c)
            + w.light * lightBonus(c)
            + w.saliency * saliencyClarity(c)
            - (c.isUtility ? w.utilityPenalty : 0)
    }

    // MARK: - Feature print-avstånd

    /// Samma avstånd som Visions `FeaturePrintObservation.distance(to:)`: *kvadrerat* euklidiskt
    /// avstånd (uppmätt: 0,0521 mot 0,2282² på två riktiga bilder), så att
    /// dubblettgränsen i `PhotoQualityService` gäller oförändrad.
    static func euclidean(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum = 0.0
        for i in a.indices { let d = Double(a[i] - b[i]); sum += d * d }
        return sum
    }

    /// Två decimaler med decimalkomma ("0,82").
    static func fmt(_ x: Double) -> String {
        String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Urval

    /// Största antal bilder i en film (`pinned` kan ändå höja det: alla låsta väljs).
    static let maxCount = 12
    /// Minsta antal bilder när fotografen väljer ett exakt antal.
    static let minCount = 3

    /// Montage: två halvor med var sitt rum (`ReelCandidate.panelRooms`).
    static func isMontage(_ c: ReelCandidate) -> Bool { c.panelRooms.count >= 2 }

    /// Vilken av halvornas rum som är viktigast för urvalet (lägst klass och rang i `Weights.roomPriority`,
    /// sedan särskilda rum, badrum och nyttorum); vid lika den första. Nil om `rooms` är tom. Okänt rum
    /// (nil eller tom sträng) är sämst.
    static func primaryPanelIndex(_ rooms: [String?], weights: Weights = Weights()) -> Int? {
        rooms.indices.min { a, b in
            func key(_ room: String?) -> (tier: Int, rank: Int) {
                guard let t = roomType(room), t != "okänt" else { return (4, 0) }   // okänt rum är sämst
                return roomClass(t, weights)
            }
            let ka = key(rooms[a]), kb = key(rooms[b])
            return (ka.tier, ka.rank, a) < (kb.tier, kb.rank, b)
        }
    }

    /// "Hall och Uteplats" (de olika halvornas rum med stor begynnelsebokstav); nil för vanliga bilder.
    static func montageRooms(_ c: ReelCandidate) -> String? {
        guard isMontage(c) else { return nil }
        var names: [String] = []
        for r in c.panelRooms {
            let t = r.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let name = t.prefix(1).uppercased() + t.dropFirst()
            if !names.contains(where: { $0.lowercased() == name.lowercased() }) { names.append(name) }
        }
        switch names.count {
        case 0: return "okända rum"
        case 1: return "\(names[0]) (två bilder)"
        default: return names.dropLast().joined(separator: ", ") + " och " + names[names.count - 1]
        }
    }

    /// Rumstyp med sorteringsnyckel: (klass, rang). Klass 0 = prioriterad typ, 1 = särskilt rum
    /// (bastu, pool, ...), 2 = badrum, 3 = nyttorum, okänt och övriga namn.
    private static func roomClass(_ type: String?, _ w: Weights) -> (tier: Int, rank: Int) {
        guard let type, type != "okänt" else { return (3, 0) }
        if let i = w.roomPriority.firstIndex(of: type) { return (0, i) }
        if w.extraRooms.contains(type) { return (1, 0) }
        if type == "badrum" { return (2, 0) }
        return (3, 0)
    }

    /// Hur en öppning kom till (för motiveringen).
    private struct OpeningChoice {
        var candidate: ReelCandidate
        enum Kind { case facade, hero, facadeTooWeak(Double), fallback }
        var kind: Kind
        /// Den bästa hjältebildens grundpoäng.
        var bestHero: Double
    }

    private struct ClosingChoice {
        var candidate: ReelCandidate
        enum Kind { case outdoor, hero, other }
        var kind: Kind
    }

    /// `count` är fotografens exakta antal (3...12); nil = automatiskt: en bild per viktig rumstyp som
    /// finns (`Weights.autoMinCount`...`autoMaxCount`). Modellen, kortfattat:
    ///
    /// 1. Öppningen: villa = fasaden om dess grundpoäng är högst `facadeOpeningMargin` under den bästa
    ///    hjältebildens, annars den bästa hjältebilden; lägenhet = den bästa hjältebilden. Aldrig badrum,
    ///    nyttorum eller okänt rum om något annat finns.
    /// 2. Avslutet: den bästa utomhus-/utsikts-/skymningsbilden som skiljer sig från öppningen, annars
    ///    en annan stark hjältebild.
    /// 3. "En av varje": den bästa bilden (grundpoäng och MMR mot redan valda) per rumstyp i
    ///    `Weights.roomPriority`-ordning, badrum sist och bara om bilden är bra, tills antalet är nått.
    ///    En typ utan bilder hoppas över. En andra bild av en typ väljs först när alla typer har fått en.
    ///    Nyttorum tas bara med när inget annat finns.
    /// 4. Visningsordning: öppning, inomhus (vardagsrum, kök, matplats, sovrum, badrum, övriga), ute
    ///    (uteplats, utsikt, trädgård, utomhus, övriga fasadbilder), avslut.
    ///
    /// `pinned` (id = sha256) väljs alltid, även om ett hårt filter annars tagit bort dem; de räknas
    /// mot antalet (är de fler höjs antalet), och de räknas som valda för rundorna och för likheten.
    /// `excluded` tas bort först (`Exclusion.Kind.user`) och kommer aldrig tillbaka, inte heller via
    /// rimlighetsventilen. Både uteslutna och låsta id som inte finns bland kandidaterna ignoreras;
    /// en bild som är båda är utesluten.
    ///
    /// `curated` = bilderna är fotografens egna, redigerade (`<adress> FÄRDIGA`/`red`, vald mapp): då
    /// tas en bild bara bort på skärpan om den är tydligt oskarp i absoluta tal
    /// (`Weights.curatedSharpnessFloorRatio` av medianen), inte för att den ligger under 25:e
    /// percentilen, som alltid träffar några bilder. Övriga filter och rimlighetsventilen är oförändrade.
    static func select(_ candidates: [ReelCandidate], count requested: Int? = nil, weights: Weights = Weights(),
                       curated: Bool = false,
                       pinned pinnedIDs: [String] = [], excluded excludedIDs: [String] = []) -> Selection {
        let userExcluded = Set(excludedIDs)
        var pinnedList: [String] = []
        for c in candidates where pinnedIDs.contains(c.id) && !userExcluded.contains(c.id) && !pinnedList.contains(c.id) {
            pinnedList.append(c.id)
        }
        let pinned = Set(pinnedList)
        let fixedCount = requested.map { min(max($0, minCount), maxCount) }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pct = sharpnessPercentiles(candidates)
        var scores: [String: Double] = [:]
        for c in candidates { scores[c.id] = baseScore(c, sharpnessPercentile: pct[c.id] ?? 0.5, weights: weights) }
        func score(_ c: ReelCandidate) -> Double { scores[c.id] ?? 0 }

        // Steg 1: hårda filter.
        var excluded: [Exclusion] = []
        var removed = Set<String>()
        for c in candidates where userExcluded.contains(c.id) {
            removed.insert(c.id)
            excluded.append(.init(candidateID: c.id, kind: .user, reason: "Utesluten av dig"))
        }
        func exclude(_ c: ReelCandidate, _ kind: Exclusion.Kind, _ reason: String) {
            removed.insert(c.id)
            excluded.append(.init(candidateID: c.id, kind: kind, reason: reason))
        }
        // Skärpegräns över alla kandidater som har skärpa (minst 4): 25:e percentilen, eller i kurerat
        // läge en andel av medianen.
        var sharpCut: Double?
        let sharpValues = candidates.filter { !userExcluded.contains($0.id) }.compactMap(\.sharpness).sorted()
        func quantile(_ q: Double) -> Double {
            let pos = q * Double(sharpValues.count - 1)
            let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
            return sharpValues[lo] + (sharpValues[hi] - sharpValues[lo]) * (pos - Double(lo))
        }
        if sharpValues.count >= 4 {
            sharpCut = curated ? quantile(0.5) * weights.curatedSharpnessFloorRatio
                               : quantile(weights.sharpnessCutPercentile)
        }
        for c in candidates where !userExcluded.contains(c.id) {
            if c.isUtility, (c.quality ?? 0.5) < weights.utilityHardMaxQuality {
                exclude(c, .utility, "Nyttobild med låg kvalitet (kvitto, dokument eller liknande)"); continue
            }
            // Horisontmåttet gäller hela bilden och betyder inget för ett montage (två bilder).
            if isExterior(c) == true, !isMontage(c), let h = c.horizonDegrees, abs(h) > weights.maxHorizonDegrees {
                exclude(c, .horizon, "Horisonten lutar \(String(format: "%.1f", abs(h)).replacingOccurrences(of: ".", with: ","))° (exteriör)"); continue
            }
            if let cut = sharpCut, let s = c.sharpness, s < cut {
                exclude(c, .sharpness, curated ? "Tydligt oskarp (under \(Int((weights.curatedSharpnessFloorRatio * 100).rounded())) % av medianens skärpa)"
                                               : "Oskarp jämfört med övriga i objektet"); continue
            }
        }

        // Dubbletter: klustra över alla som ännu är kvar, behåll bästa per grupp.
        let alive = candidates.filter { !removed.contains($0.id) }
        let groups = PhotoQualityService.clusterDuplicates(
            count: alive.count, threshold: weights.duplicateThreshold,
            distance: { i, j in
                guard let a = alive[i].featureVector, let b = alive[j].featureVector else { return nil }
                return euclidean(a, b)
            })
        var members: [Int: [Int]] = [:]
        for (i, g) in groups.enumerated() { if let g { members[g, default: []].append(i) } }
        for (_, idxs) in members {
            // En fristående bild vinner alltid över ett montage som visar samma sak.
            let singles = idxs.filter { !isMontage(alive[$0]) }
            guard let best = PhotoQualityService.bestIndex(in: singles.isEmpty ? idxs : singles,
                                                          qualityScore: { alive[$0].quality },
                                                          sharpness: { alive[$0].sharpness }) else { continue }
            for i in idxs where i != best {
                exclude(alive[i], .duplicate, isMontage(alive[i]) && !isMontage(alive[best])
                        ? "Visar samma som \(alive[best].filename)" : "Dubblett av \(alive[best].filename)")
            }
        }

        // Låsta bilder är alltid kvar, oavsett hårda filter och dubbletter.
        for id in pinned where removed.contains(id) {
            removed.remove(id)
            excluded.removeAll { $0.candidateID == id }
        }

        // Rimlighetsventil: för få kvar → ta tillbaka mjuka bortfall (skärpa, horisont), bästa först.
        var survivors = candidates.filter { !removed.contains($0.id) }
        let needed = max(fixedCount ?? weights.autoMinCount, pinned.count)
        if survivors.count < needed {
            let soft = excluded.filter { $0.kind == .sharpness || $0.kind == .horizon }
                .compactMap { byID[$0.candidateID] }
                .sorted { score($0) > score($1) }
            for c in soft.prefix(needed - survivors.count) {
                survivors.append(c)
                excluded.removeAll { $0.candidateID == c.id }
            }
            let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
            survivors.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }

        // Mall.
        let template: Template = survivors.contains { isExterior($0) == true && isFacadeRoom($0.room) } ? .house : .apartment

        // Likhet mellan överlevare, normaliserad med största parvisa avståndet.
        var dist: [String: [String: Double]] = [:]
        var maxDist = 0.0
        for i in survivors.indices {
            for j in survivors.indices where j > i {
                guard let a = survivors[i].featureVector, let b = survivors[j].featureVector,
                      let d = euclidean(a, b) else { continue }
                dist[survivors[i].id, default: [:]][survivors[j].id] = d
                dist[survivors[j].id, default: [:]][survivors[i].id] = d
                maxDist = max(maxDist, d)
            }
        }
        func similarity(_ a: String, _ b: String) -> Double {
            guard maxDist > 0, let d = dist[a]?[b] else { return 0 }
            return min(max(1 - d / maxDist, 0), 1)
        }
        func maxSimilarity(_ c: ReelCandidate, to others: [String]) -> Double {
            others.filter { $0 != c.id }.map { similarity(c.id, $0) }.max() ?? 0
        }

        // Rumstyper och deras överlevare (bästa grundpoäng först).
        func typeOf(_ c: ReelCandidate) -> String? { roomType(c.room) }
        func typeKey(_ c: ReelCandidate) -> String { typeOf(c) ?? "okänt" }
        var byType: [String: [ReelCandidate]] = [:]
        for c in survivors { byType[typeKey(c), default: []].append(c) }
        for k in byType.keys { byType[k]?.sort { score($0) > score($1) } }
        func isHero(_ c: ReelCandidate) -> Bool { typeOf(c).map(weights.heroRooms.contains) ?? false }
        func lowestClass(_ pool: [ReelCandidate]) -> [ReelCandidate] {
            guard let low = pool.map({ roomClass(typeOf($0), weights).tier }).min() else { return [] }
            return pool.filter { roomClass(typeOf($0), weights).tier == low }
        }

        // Öppningen (villa: fasaden om den håller, annars bästa hjältebilden).
        func chooseOpening(in pool: [ReelCandidate]) -> OpeningChoice? {
            var heroes = pool.filter(isHero)
            // Ett montage öppnar inte filmen om en enskild bild kan (två korta delar är ingen öppning).
            if heroes.contains(where: { !isMontage($0) }) { heroes = heroes.filter { !isMontage($0) } }
            let pinnedHeroes = heroes.filter { pinned.contains($0.id) }
            if !pinnedHeroes.isEmpty { heroes = pinnedHeroes }
            guard let best = heroes.max(by: { score($0) < score($1) }) else {
                guard let other = lowestClass(pool).max(by: { score($0) < score($1) }) else { return nil }
                return OpeningChoice(candidate: other, kind: .fallback, bestHero: 0)
            }
            if template == .house {
                if let facade = heroes.filter({ typeOf($0) == "fasad" }).max(by: { score($0) < score($1) }) {
                    if score(facade) >= score(best) - weights.facadeOpeningMargin {
                        return OpeningChoice(candidate: facade, kind: .facade, bestHero: score(best))
                    }
                    return OpeningChoice(candidate: best, kind: .facadeTooWeak(score(facade)), bestHero: score(best))
                }
            }
            return OpeningChoice(candidate: best, kind: .hero, bestHero: score(best))
        }

        // Avslutet (bästa utomhus-/utsikts-/skymningsbild som skiljer sig från öppningen, annars en
        // stark hjältebild). Värdet beror bara på öppningen och de låsta, så att samma bild väljs oavsett
        // vilken delmängd som tittas på.
        func chooseClosing(in pool: [ReelCandidate], opening: ReelCandidate?) -> ClosingChoice? {
            let rest = pool.filter { $0.id != opening?.id }
            let against = ([opening?.id].compactMap { $0 }) + pinnedList
            func value(_ c: ReelCandidate) -> Double {
                weights.lambda * (score(c) + (isDusk(c) ? weights.duskClosingBonus : 0))
                    - (1 - weights.lambda) * maxSimilarity(c, to: against)
            }
            func best(_ cs: [ReelCandidate]) -> ReelCandidate? {
                var cs = cs
                if cs.contains(where: { !isMontage($0) }) { cs = cs.filter { !isMontage($0) } }
                let fitting = cs.filter { pinned.contains($0.id) }
                if !fitting.isEmpty { cs = fitting }
                if let o = opening {
                    let different = cs.filter { similarity($0.id, o.id) <= weights.maxClosingSimilarity }
                    if !different.isEmpty { cs = different }
                    // Helst en annan rumstyp än öppningen (inte balkong efter balkong).
                    let otherType = cs.filter { typeOf($0) != typeOf(o) }
                    if !otherType.isEmpty { cs = otherType }
                }
                return cs.max(by: { value($0) < value($1) })
            }
            // Ett montage avslutar inte som utomhusbild (två korta delar är ingen avslutning); det kan bli
            // avslut bara när inget annat finns (`best` föredrar enskilda bilder).
            let outdoor = rest.filter { c in
                isExterior(c) == true && !isMontage(c) && (typeOf(c) != "fasad" || isDusk(c))
            }
            if let c = best(outdoor) { return ClosingChoice(candidate: c, kind: .outdoor) }
            if let c = best(rest.filter(isHero)) { return ClosingChoice(candidate: c, kind: .hero) }
            if let c = best(lowestClass(rest)) { return ClosingChoice(candidate: c, kind: .other) }
            return nil
        }

        // Antal: fotografens, annars en per viktig rumstyp (badrum bara om det är bra).
        func isImportant(_ type: String) -> Bool {
            let cls = roomClass(type, weights)
            if cls.tier <= 1 { return true }
            if cls.tier == 2 { return (byType[type]?.first.map(score) ?? 0) >= weights.bathroomMinScore }
            return false
        }
        let important = byType.keys.filter(isImportant).count
        var target = fixedCount ?? min(max(important, weights.autoMinCount), weights.autoMaxCount)
        target = min(max(target, pinned.count), max(maxCount, pinned.count))

        // Valen. Låsta först, sedan öppning, avslut och "en av varje".
        var pickedIDs: [String] = []
        var picked: [ReelCandidate] = []
        var typeCounts: [String: Int] = [:]
        func add(_ c: ReelCandidate) {
            pickedIDs.append(c.id); picked.append(c)
            typeCounts[typeKey(c), default: 0] += 1
        }
        for id in pinnedList { if let c = byID[id] { add(c) } }

        if picked.count < target, let o = chooseOpening(in: survivors), !pickedIDs.contains(o.candidate.id) { add(o.candidate) }
        if picked.count < target, let c = chooseClosing(in: survivors, opening: chooseOpening(in: picked)?.candidate),
           c.kind == .outdoor, !pickedIDs.contains(c.candidate.id) {
            add(c.candidate)
        }

        func mmr(_ c: ReelCandidate) -> Double {
            var rel = score(c)
            // Rumsdiversitet: samma rumstyp en gång till får ett avdrag som växer med antalet gånger.
            if let n = typeCounts[typeKey(c)], n > 0 { rel -= Double(n) * weights.roomRepeatPenalty / weights.lambda }
            return weights.lambda * rel - (1 - weights.lambda) * maxSimilarity(c, to: pickedIDs)
        }
        func remaining(_ type: String) -> [ReelCandidate] { (byType[type] ?? []).filter { !pickedIDs.contains($0.id) } }
        let orderedTypes = byType.keys.sorted {
            let a = roomClass($0, weights), b = roomClass($1, weights)
            return (a.tier, a.rank, $0) < (b.tier, b.rank, $1)
        }
        // "En av varje": runda 0 ger varje typ sin första bild, runda 1 den andra, osv.
        rounds: for round in 0..<maxCount {
            for type in orderedTypes {
                if picked.count >= target { break rounds }
                let cls = roomClass(type, weights)
                guard cls.tier <= 2, (typeCounts[type] ?? 0) == round else { continue }
                // Ett montage täcker ingen rumstyp: det är en extra bild som tas först när varje typ har en
                // fristående (runda 1 och framåt), eller om typen inte har någon fristående bild alls.
                let standalone = (byType[type] ?? []).contains { !isMontage($0) }
                let pool = remaining(type).filter { round > 0 || !standalone || !isMontage($0) }
                if cls.tier == 2, (pool.map(score).max() ?? 0) < weights.bathroomMinScore { continue }
                guard let best = pool.max(by: { mmr($0) < mmr($1) }) else { continue }
                add(best)
            }
        }
        // Slutfyllning: nyttorum och svaga badrum, när inget annat finns.
        while picked.count < target {
            let left = survivors.filter { !pickedIDs.contains($0.id) }
            guard let best = lowestClass(left).max(by: { mmr($0) < mmr($1) }) else { break }
            add(best)
        }

        // Roller och visningsordning.
        let opening = chooseOpening(in: picked)
        let closing = chooseClosing(in: picked, opening: opening?.candidate)
        func group(_ c: ReelCandidate) -> (Int, Int) {
            let t = typeOf(c)
            if c.id == opening?.candidate.id { return (0, 0) }
            if c.id == closing?.candidate.id { return (3, 0) }
            let outdoor = (t.map(outdoorTypes.contains) ?? false) || isExterior(c) == true
            if outdoor {
                let order = ["uteplats", "utsikt", "trädgård", "utomhus", "fasad"]
                return (2, t.flatMap(order.firstIndex(of:)) ?? order.count)
            }
            let order = ["vardagsrum", "kök", "matplats", "sovrum", "badrum"]
            return (1, t.flatMap(order.firstIndex(of:)) ?? order.count)
        }
        let seq = Dictionary(uniqueKeysWithValues: picked.enumerated().map { ($1.id, $0) })
        let displayOrder = picked.sorted {
            let a = group($0), b = group($1)
            if a != b { return a < b }
            if typeOf($0) != typeOf($1) { return (typeOf($0) ?? "") < (typeOf($1) ?? "") }
            return (seq[$0.id] ?? 0) < (seq[$1.id] ?? 0)
        }

        let picks: [Pick] = displayOrder.map { c in
            let isOpening = c.id == opening?.candidate.id
            let isClosing = c.id == closing?.candidate.id
            let slot: Slot = isOpening ? .opening : (isClosing ? .closing : .room)
            var text: String
            if isOpening, let o = opening {
                text = openingReason(o, score: score(c))
            } else if isClosing, let cl = closing {
                text = closingReason(cl, c: c, score: score(c), opening: opening?.candidate,
                                     similarity: opening.map { similarity(c.id, $0.candidate.id) })
            } else {
                text = roomReason(c, score: score(c), siblings: byType[typeKey(c)] ?? [])
            }
            if pinned.contains(c.id) { text += ", låst av dig" }
            return Pick(candidateID: c.id, slot: slot, roomType: typeOf(c), reason: text, score: score(c))
        }
        return Selection(template: template, picks: picks, excluded: excluded, scores: scores)
    }

    // MARK: - Motiveringar

    private static func label(_ c: ReelCandidate) -> String {
        if let rooms = montageRooms(c) { return "Montage (\(rooms))" }
        let what = (c.room ?? c.category ?? "okänt motiv").trimmingCharacters(in: .whitespaces)
        return what.prefix(1).uppercased() + what.dropFirst()
    }

    private static func specialNote(_ c: ReelCandidate) -> String? {
        bonusKeywords.first { featureText(c).contains($0) }.map { "särdrag: \($0)" }
    }

    private static func openingReason(_ o: OpeningChoice, score: Double) -> String {
        let head = "Öppning: \(label(o.candidate)), poäng \(fmt(score))"
        switch o.kind {
        case .facade:
            return head + (abs(o.bestHero - score) < 0.005 ? " (bästa hjältebilden)" : " (bästa hjältebild \(fmt(o.bestHero)))")
        case .hero:
            return head + " (bästa hjältebilden)"
        case .facadeTooWeak(let facade):
            return head + " (fasaden \(fmt(facade)) når inte upp till bästa hjältebild \(fmt(o.bestHero)))"
        case .fallback:
            return head + " (ingen hjältebild, bästa tillgängliga)"
        }
    }

    private static func closingReason(_ cl: ClosingChoice, c: ReelCandidate, score: Double,
                                      opening: ReelCandidate?, similarity: Double?) -> String {
        var parts = ["Avslut: \(label(c))"]
        switch cl.kind {
        case .outdoor:
            parts.append(opening != nil ? "skiljer sig från öppningen" : "utomhusbild")
            if isDusk(c) { parts.append("skymningsbild") }
        case .hero: parts.append("stark hjältebild, ingen utomhusbild kvar")
        case .other: parts.append("bästa tillgängliga")
        }
        parts.append("poäng \(fmt(score))")
        return parts.joined(separator: ", ")
    }

    private static func roomReason(_ c: ReelCandidate, score: Double, siblings: [ReelCandidate]) -> String {
        if let rooms = montageRooms(c) {
            // "Montage: Hall och Uteplats, poäng 0,72"; räknas som en plats (en extra bild, täcker ingen rumstyp).
            return "Montage: \(rooms), poäng \(fmt(score))"
        }
        let n = siblings.count
        let k = siblings.firstIndex { $0.id == c.id } ?? 0
        var parts = ["\(label(c))"]
        if n <= 1 { parts.append("enda bilden") }
        else if k == 0 { parts.append("bästa av \(n)") }
        else if k == 1 { parts.append("näst bästa av \(n)") }
        else { parts.append("bild \(k + 1) av \(n)") }
        parts.append("poäng \(fmt(score))")
        if let note = specialNote(c) { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}
