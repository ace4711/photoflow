import Foundation

// Automatiskt förslag till urvalet för extern redigering. Lärt från fem riktiga
// fotograferingar (~180 grupper, se docs/plan-urval.md). Två oberoende delar:
//
// 1. Exponeringar per grupp (`EditExposureSuggester`): fotografen skickar nästan alltid
//    seriens ljusaste bild, en ungefär ett steg mörkare och en runt 3,5 EV mörkare —
//    från den SISTA bracket-serien om gruppen innehåller flera. Serier utan
//    exponeringsspridning (handhållna exteriörer) ger en bild: den sista.
// 2. Grupper (`EditGroupSuggester`): fotografen tar om samma vy tills hon är nöjd och
//    skickar en per vy, oftast den sista. Nästan identiska kompositioner i följd
//    (Vision-feature print + tidsnärhet) klustras och den sista i varje kluster väljs.
//    Varje kluster ger alltid en grupp, så alla rum/vyer täcks.

/// Väljer vilka exponeringar i en grupp som föreslås för redigering.
nonisolated enum EditExposureSuggester {
    struct Exposure: Equatable, Sendable {
        var file: String
        var seconds: Double
        var rejected: Bool = false

        init(file: String, seconds: Double, rejected: Bool = false) {
            self.file = file
            self.seconds = seconds
            self.rejected = rejected
        }

        var ev: Double { log2(max(seconds, 1e-6)) }
    }

    /// Den mörka bilden siktar på ljusaste minus så här många steg.
    static let darkOffsetEV = 3.5
    /// Mellanbilden siktar på ljusaste minus så här många steg.
    static let midOffsetEV = 1.0
    /// Under detta spann (ljusaste–mörkaste valda) räcker två bilder.
    static let threeFileMinSpanEV = 2.5
    /// Under detta spann är serien ingen bracket (samma exponering upprepad).
    static let bracketMinSpanEV = 0.6
    /// En ny bracket-serie börjar när exponeringen sjunker mer än så här mot förra bilden.
    static let newRunDropEV = 0.5

    /// Sista bracket-serien i tagningsordning (gruppen kan innehålla en omtagning).
    static func lastRun(_ exposures: [Exposure]) -> [Exposure] {
        guard var start = exposures.indices.first else { return [] }
        for i in exposures.indices.dropFirst() where exposures[i].ev < exposures[i - 1].ev - newRunDropEV {
            start = i
        }
        return Array(exposures[start...])
    }

    /// Förslag (filnamn i tagningsordning). `exposures` i gruppens tagningsordning.
    /// Avvisade bilder föreslås aldrig. En grupp utan bracket ger en bild.
    static func suggest(_ exposures: [Exposure]) -> [String] {
        let usable = exposures.filter { !$0.rejected }
        let run = lastRun(usable)
        guard let last = run.last else { return [] }
        let evs = run.map(\.ev)
        guard let maxEV = evs.max(), let minEV = evs.min(), maxEV - minEV >= bracketMinSpanEV else {
            return [last.file]
        }
        // Ljusaste (vid lika: den senare), sedan mörk och mellan mot målen.
        let indexed = Array(run.enumerated())
        let brightest = indexed.max { a, b in a.element.ev != b.element.ev ? a.element.ev < b.element.ev : a.offset < b.offset }!
        let darker = indexed.filter { $0.element.ev < brightest.element.ev - 1e-9 }
        guard !darker.isEmpty else { return [brightest.element.file] }
        let darkTarget = brightest.element.ev - darkOffsetEV
        let dark = darker.min { a, b in
            let da = abs(a.element.ev - darkTarget), db = abs(b.element.ev - darkTarget)
            return da != db ? da < db : a.element.ev > b.element.ev
        }!
        var picked = [dark, brightest]
        if brightest.element.ev - dark.element.ev >= threeFileMinSpanEV {
            let midTarget = brightest.element.ev - midOffsetEV
            let between = darker.filter { $0.element.ev > dark.element.ev + 1e-9 }
            if let mid = between.min(by: { abs($0.element.ev - midTarget) < abs($1.element.ev - midTarget) }) {
                picked.append(mid)
            }
        }
        return picked.sorted { $0.offset < $1.offset }.map(\.element.file)
    }
}

/// Väljer vilka grupper som föreslås för redigering.
nonisolated enum EditGroupSuggester {
    struct Group: Equatable, Sendable {
        var id: Int
        var start: Date
        var end: Date
        /// Kan skickas (minst en bild som inte är avvisad).
        var eligible: Bool = true
    }

    /// Feature print-avstånd (Vision `FeaturePrintObservation.distance`, som är kvadraten
    /// på det euklidiska avståndet) under vilket två grupper räknas som samma komposition.
    /// 0,0625 = 0,25² — valt med lämna-en-ute över fem fotograferingar (alla fem
    /// delningar valde 0,25 i euklidiskt avstånd, se docs/plan-urval.md).
    static let compositionDistance = 0.0625
    /// Längsta paus mellan grupper i samma kluster.
    static let maxGapSeconds: TimeInterval = 120

    /// Klustrar grupper i tagningsordning: en grupp hör till föregående grupps kluster om
    /// de är nästan identiska (`distance` < tröskeln) och tagna nära i tid.
    /// `distance(a, b)` får vara nil (okänt, t.ex. saknad förhandsbild) ⇒ olika.
    static func clusters(_ groups: [Group], distance: (Int, Int) -> Double?,
                         threshold: Double = compositionDistance,
                         maxGap: TimeInterval = maxGapSeconds) -> [[Int]] {
        var result: [[Int]] = []
        for i in groups.indices {
            if i > 0, groups[i].start.timeIntervalSince(groups[i - 1].end) < maxGap,
               let d = distance(i - 1, i), d < threshold {
                result[result.count - 1].append(i)
            } else {
                result.append([i])
            }
        }
        return result
    }

    struct Result: Equatable, Sendable {
        /// Grupp-id som föreslås.
        var selected: Set<Int>
        /// Kluster (grupp-id i ordning) — för förklaring i UI/loggar.
        var clusters: [[Int]]
    }

    /// Den sista valbara gruppen i varje kluster föreslås.
    static func suggest(_ groups: [Group], distance: (Int, Int) -> Double?,
                        threshold: Double = compositionDistance,
                        maxGap: TimeInterval = maxGapSeconds) -> Result {
        let cl = clusters(groups, distance: distance, threshold: threshold, maxGap: maxGap)
        var selected = Set<Int>()
        for c in cl {
            if let pick = c.last(where: { groups[$0].eligible }) { selected.insert(groups[pick].id) }
        }
        return Result(selected: selected, clusters: cl.map { $0.map { groups[$0].id } })
    }
}
