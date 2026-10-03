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
        /// Feature print-avstånd under detta räknas som dubblett.
        var duplicateThreshold = PhotoQualityService.duplicateDistanceThreshold
        /// Likhet över detta mellan avslutning och öppning undviks när det finns alternativ.
        var maxClosingSimilarity = 0.85
    }

    nonisolated enum Template: String, Sendable, Equatable {
        case house, apartment
    }

    nonisolated enum Slot: String, Sendable, Equatable {
        case opening, livingRoom, kitchen, feature, closing

        var label: String {
            switch self {
            case .opening: return "Öppning"
            case .livingRoom: return "Vardagsrum"
            case .kitchen: return "Kök"
            case .feature: return "Särdrag"
            case .closing: return "Avslut"
            }
        }
    }

    nonisolated struct Pick: Sendable, Equatable {
        var candidateID: String
        var slot: Slot
        /// Svensk motivering, t.ex. "Öppning: Fasad, kvalitet 0,82".
        var reason: String
        /// Grundpoängen (0...1).
        var score: Double
    }

    nonisolated struct Exclusion: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable { case utility, horizon, sharpness, duplicate }
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
    private static let livingKeywords = ["vardagsrum", "allrum", "vardag"]
    private static let kitchenKeywords = ["kök"]
    private static let featureRoomKeywords = ["sovrum", "badrum", "matplats", "matsal", "altan", "uteplats", "terrass",
                                              "balkong", "veranda", "bastu", "pool", "tvättstuga", "kontor", "arbetsrum"]
    private static let closingExteriorKeywords = ["trädgård", "tradgard", "uteplats", "altan", "terrass", "balkong",
                                                  "veranda", "pool", "tomt", "utsikt", "sjö", "brygga", "strand"]
    private static let apartmentClosingKeywords = ["balkong", "utsikt", "terrass", "altan", "uteplats"]
    private static let bonusKeywords = ["utsikt", "öppen spis", "sjötomt", "terrass", "kakelugn", "bastu", "pool",
                                        "havsutsikt", "sjöutsikt", "brygga", "strand", "kamin", "balkong", "altan",
                                        "takhöjd", "stuckatur", "braskamin"]

    private static func matches(_ room: String?, _ keywords: [String]) -> Bool {
        guard let r = room?.lowercased(), !r.isEmpty else { return false }
        return keywords.contains { r.contains($0) }
    }

    /// Själva byggnaden (inte tomt/trädgård): öppningen väljs helst bland dessa.
    private static func isStrictFacade(_ room: String?) -> Bool {
        guard let r = room?.lowercased() else { return false }
        return r == "hus" || r.hasPrefix("hus ") || matches(r, ["fasad", "villa"])
    }

    private static func isFacadeRoom(_ room: String?) -> Bool {
        guard let r = room?.lowercased() else { return false }
        return r == "hus" || r.hasPrefix("hus ") || matches(r, facadeKeywords)
    }

    /// true = exteriör, false = interiör, nil = okänt. Kategorin går före rummet.
    static func isExterior(_ c: ReelCandidate) -> Bool? {
        if let cat = c.category?.lowercased() {
            if cat.contains("exter") { return true }
            if cat.contains("inter") { return false }
        }
        if isFacadeRoom(c.room) || matches(c.room, ["altan", "uteplats", "terrass", "balkong", "veranda", "pool", "utsikt"]) {
            return true
        }
        if matches(c.room, livingKeywords + kitchenKeywords + ["sovrum", "badrum", "matplats", "hall", "entré"]) { return false }
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

    static func select(_ candidates: [ReelCandidate], count requested: Int = 5, weights: Weights = Weights()) -> Selection {
        let count = min(max(requested, 3), 8)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pct = sharpnessPercentiles(candidates)
        var scores: [String: Double] = [:]
        for c in candidates { scores[c.id] = baseScore(c, sharpnessPercentile: pct[c.id] ?? 0.5, weights: weights) }

        // Steg 1: hårda filter.
        var excluded: [Exclusion] = []
        var removed = Set<String>()
        func exclude(_ c: ReelCandidate, _ kind: Exclusion.Kind, _ reason: String) {
            removed.insert(c.id)
            excluded.append(.init(candidateID: c.id, kind: kind, reason: reason))
        }
        // Skärpegräns: percentilen räknas över alla kandidater som har skärpa (minst 4).
        var sharpCut: Double?
        let sharpValues = candidates.compactMap(\.sharpness).sorted()
        if sharpValues.count >= 4 {
            let pos = weights.sharpnessCutPercentile * Double(sharpValues.count - 1)
            let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
            sharpCut = sharpValues[lo] + (sharpValues[hi] - sharpValues[lo]) * (pos - Double(lo))
        }
        for c in candidates {
            if c.isUtility { exclude(c, .utility, "Nyttobild (kvitto, dokument eller liknande)"); continue }
            if isExterior(c) == true, let h = c.horizonDegrees, abs(h) > weights.maxHorizonDegrees {
                exclude(c, .horizon, "Horisonten lutar \(String(format: "%.1f", abs(h)).replacingOccurrences(of: ".", with: ","))° (exteriör)"); continue
            }
            if let cut = sharpCut, let s = c.sharpness, s < cut {
                exclude(c, .sharpness, "Oskarp jämfört med övriga i objektet"); continue
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
            guard let best = PhotoQualityService.bestIndex(in: idxs,
                                                          qualityScore: { alive[$0].quality },
                                                          sharpness: { alive[$0].sharpness }) else { continue }
            for i in idxs where i != best {
                exclude(alive[i], .duplicate, "Dubblett av \(alive[best].filename)")
            }
        }

        // Rimlighetsventil: för få kvar → ta tillbaka mjuka bortfall (skärpa, horisont), bästa först.
        var survivors = candidates.filter { !removed.contains($0.id) }
        if survivors.count < count {
            let soft = excluded.filter { $0.kind == .sharpness || $0.kind == .horizon }
                .compactMap { byID[$0.candidateID] }
                .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
            for c in soft.prefix(count - survivors.count) {
                survivors.append(c)
                excluded.removeAll { $0.candidateID == c.id }
            }
            let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
            survivors.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }

        // Steg 3: mall.
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

        // Steg 3–5: platser, MMR och reservlogik.
        var picks: [Pick] = []
        var pickedIDs: [String] = []
        // Avslutningen väljs före särdragsplatserna, så att de inte tar den bästa
        // balkongen/trädgården; visningsordningen återställs efteråt.
        let slotList = slots(template: template, count: count)
        var queue = slotList.indices.filter { slotList[$0] != .feature && slotList[$0] != .closing }
            + slotList.indices.filter { slotList[$0] == .closing } + slotList.indices.filter { slotList[$0] == .feature }
        var positions: [Int] = []   // platsens index i `slotList` för varje val
        var deferred = Set<Int>()   // platser som blivit särdragsplatser och fylls sist
        var q = 0
        while q < queue.count {
            let position = queue[q]
            q += 1
            var slot = slotList[position]
            // Är vardagsrummet/köket redan med (t.ex. som öppning i en lägenhet) blir platsen en
            // särdragsplats, som fylls efter övriga platser så att den inte tar avslutningens bild.
            let have = pickedIDs.compactMap { byID[$0]?.room }
            if (slot == .livingRoom && have.contains(where: { matches($0, livingKeywords) }))
                || (slot == .kitchen && have.contains(where: { matches($0, kitchenKeywords) })) {
                if !deferred.contains(position) { deferred.insert(position); queue.append(position); continue }
                slot = .feature
            }
            let pool = survivors.filter { !pickedIDs.contains($0.id) }
            guard !pool.isEmpty else { break }
            let pickedRooms = Set(pickedIDs.compactMap { byID[$0]?.room?.lowercased() })
            let tiers = tiers(for: slot, template: template, pickedRooms: pickedRooms)

            var chosenTier = tiers.count - 1
            var tierPool = pool
            for (t, pred) in tiers.enumerated() {
                let p = pool.filter(pred)
                if !p.isEmpty { chosenTier = t; tierPool = p; break }
            }
            // Avslutningen får inte likna öppningen när det finns alternativ.
            if slot == .closing, let first = pickedIDs.first {
                let different = tierPool.filter { similarity($0.id, first) <= weights.maxClosingSimilarity }
                if !different.isEmpty { tierPool = different }
            }

            func mmr(_ c: ReelCandidate) -> Double {
                let maxSim = pickedIDs.map { similarity(c.id, $0) }.max() ?? 0
                var rel = scores[c.id] ?? 0
                if slot == .closing && isDusk(c) { rel += 0.08 }
                return weights.lambda * rel - (1 - weights.lambda) * maxSim
            }
            guard let best = tierPool.max(by: { mmr($0) < mmr($1) }) else { break }
            let maxSim = pickedIDs.map { similarity(best.id, $0) }.max()
            let fallback = chosenTier == tiers.count - 1 && tiers.count > 1
            picks.append(Pick(candidateID: best.id, slot: slot,
                              reason: reason(slot: slot, c: best, score: scores[best.id] ?? 0,
                                             fallback: fallback, maxSim: maxSim),
                              score: scores[best.id] ?? 0))
            pickedIDs.append(best.id)
            positions.append(position)
        }

        // Visningsordning: platsernas ordning.
        let ordered = zip(picks, positions).sorted { $0.1 < $1.1 }.map(\.0)
        return Selection(template: template, picks: ordered, excluded: excluded, scores: scores)
    }

    // MARK: - Platser och nivåer

    static func slots(template: Template, count: Int) -> [Slot] {
        switch count {
        case ...3: return [.opening, .livingRoom, .closing]
        case 4: return [.opening, .livingRoom, .kitchen, .closing]
        default: return [.opening, .livingRoom, .kitchen] + Array(repeating: .feature, count: count - 4) + [.closing]
        }
    }

    /// Kandidatvillkor i prioritetsordning; sista nivån tar alla (reservlogiken).
    private static func tiers(for slot: Slot, template: Template, pickedRooms: Set<String>) -> [(ReelCandidate) -> Bool] {
        let unpicked: (ReelCandidate) -> Bool = { c in
            guard let r = c.room?.lowercased(), !r.isEmpty else { return false }
            return !pickedRooms.contains(r)
        }
        let any: (ReelCandidate) -> Bool = { _ in true }
        switch (slot, template) {
        case (.opening, .house):
            return [{ isExterior($0) == true && isStrictFacade($0.room) },
                    { isExterior($0) == true && isFacadeRoom($0.room) },
                    { isExterior($0) == true }, any]
        case (.opening, .apartment):
            return [any]
        case (.livingRoom, _):
            return [{ matches($0.room, livingKeywords) }, any]
        case (.kitchen, _):
            return [{ matches($0.room, kitchenKeywords) }, any]
        case (.feature, _):
            return [{ matches($0.room, featureRoomKeywords) && unpicked($0) },
                    { unpicked($0) }, any]
        case (.closing, .house):
            return [{ isExterior($0) == true && (matches($0.room, closingExteriorKeywords) || isDusk($0)
                                                   || featureText($0).contains("utsikt")) && !isStrictFacade($0.room) },
                    { isExterior($0) == true }, any]
        case (.closing, .apartment):
            return [{ matches($0.room, apartmentClosingKeywords) || featureText($0).contains("utsikt") || isDusk($0) },
                    any]
        }
    }

    private static func reason(slot: Slot, c: ReelCandidate, score: Double, fallback: Bool, maxSim: Double?) -> String {
        let what = c.room ?? c.category ?? "okänt motiv"
        var parts = ["\(slot.label): \(what)", c.quality.map { "kvalitet \(fmt($0))" } ?? "poäng \(fmt(score))"]
        if slot == .closing && isDusk(c) { parts.append("skymningsbild") }
        let bonus = bonusKeywords.filter { featureText(c).contains($0) }
        if slot == .feature || slot == .opening, let b = bonus.first { parts.append("särdrag: \(b)") }
        if fallback { parts.append("reserv: ingen bild med rätt rum, bästa tillgängliga") }
        else if let s = maxSim, s < 0.5, slot != .opening { parts.append("skiljer sig från tidigare bilder") }
        return parts.joined(separator: ", ")
    }
}
