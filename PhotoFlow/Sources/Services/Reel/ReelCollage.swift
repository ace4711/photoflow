import Foundation

/// Kollage i urvalet (R6c): två bilder i samma filmruta (stapel i 9:16, sida vid sida i 16:9) i stället
/// för en bild med stora suddiga band eller en hård beskärning. Ren logik på `ReelCandidate`:
/// `ReelSelector.select` anropar `pairs` efter att bilderna valts, och planeraren
/// (`ReelMotionPlanner.collageActive`) använder samma geometriregler när klippet byggs.
///
/// Reglerna (värden i `ReelSelector.Weights` och `ReelMotionPlanner`):
/// - Ankare (bilden som behöver en partner): en vald bild som i formatet annars blir contain-blur eller
///   vars motiv inte ryms i cover-utsnittet (`ReelMotionPlanner.needsCollage`). Öppning och avslut är
///   aldrig kollage: de är filmens första och sista intryck och ska fylla hela rutan (beslut R6c).
/// - Partner: en annan vald bild eller en av de närmast bortvalda (`collagePoolSize` bäst), med
///   kompatibelt rum (samma typ eller ett par i `collageRoomPairs`), inte nära dubblett
///   (`collageMinDistance`), liknande ljus (`collageMaxLuminanceDiff`) och motiv som ryms i rutan.
/// - Aldrig fasad eller utsikt (`collageExcludedRooms`), aldrig montage, aldrig en låst bild.
/// - Högst `collageMaxShare` av bilderna är ankare (minst ett), så att filmen inte blir bara kollage.
nonisolated enum ReelCollage {

    nonisolated struct Pair: Sendable, Equatable {
        /// Första rutans bild och klippets bild. När båda är valda är det den som kommer först i visningsordningen.
        var anchorID: String
        var partnerID: String
        /// Partnern var en vald bild (kollaget tar då en plats för två rumstyper); annars en extra bild
        /// som urvalet inte valt.
        var partnerPicked: Bool
        /// T.ex. "Kollage: Kök och Matplats, båda ryms i 9:8 (poäng 0,71 och 0,66)".
        var reason: String
    }

    /// Rumstypen får vara med i kollage (inte fasad, utsikt eller okänt).
    static func eligibleRoom(_ c: ReelCandidate, weights w: ReelSelector.Weights) -> Bool {
        guard let t = ReelSelector.roomType(c.room), t != "okänt" else { return false }
        return !w.collageExcludedRooms.contains(t)
    }

    /// Samma rumstyp, eller ett par i `Weights.collageRoomPairs` (kök + matplats, uteplats + trädgård).
    static func compatibleRooms(_ a: ReelCandidate, _ b: ReelCandidate, weights w: ReelSelector.Weights) -> Bool {
        guard let ta = ReelSelector.roomType(a.room), let tb = ReelSelector.roomType(b.room) else { return false }
        if ta == tb { return true }
        return w.collageRoomPairs.contains { Set($0) == Set([ta, tb]) }
    }

    /// Bilden som planerarens indata (geometri), så att urvalet och planeringen avgör samma sak.
    static func plannerImage(_ c: ReelCandidate) -> ReelMotionPlanner.Image {
        ReelMotionPlanner.Image(assetID: c.id, width: c.width ?? 0, height: c.height ?? 0, focus: nil,
                                salientWidth: c.salientWidth,
                                isExterior: ReelSelector.isExterior(c) == true, focusWidth: c.focusWidth,
                                panels: [], room: c.room)
    }

    /// Kan `partner` vara partner till `anchor` i ramen (alla villkor utom att partnern är ledig)?
    static func canPair(anchor: ReelCandidate, partner: ReelCandidate, frameAspect: Double,
                        distance: (String, String) -> Double?, weights w: ReelSelector.Weights) -> Bool {
        guard anchor.id != partner.id, !ReelSelector.isMontage(anchor), !ReelSelector.isMontage(partner),
              eligibleRoom(anchor, weights: w), eligibleRoom(partner, weights: w),
              compatibleRooms(anchor, partner, weights: w) else { return false }
        if let la = anchor.meanLuminance, let lb = partner.meanLuminance, abs(la - lb) > w.collageMaxLuminanceDiff {
            return false
        }
        if let d = distance(anchor.id, partner.id), d <= w.collageMinDistance { return false }
        return ReelMotionPlanner.collageActive(anchor: plannerImage(anchor), partner: plannerImage(partner),
                                               frameAspect: frameAspect, override: nil)
    }

    /// Kollagen för en uppsättning valda bilder. `order` är de valda i visningsordning, `pool` bilderna som
    /// överlevt filtren men inte valts (partnerkandidater, bäst poäng först används). `distance` ger
    /// feature print-avståndet (kvadrerat, som `ReelSelector.euclidean`) mellan två id; nil = okänt.
    static func pairs(order: [ReelCandidate], openingID: String?, closingID: String?, pool: [ReelCandidate],
                      frameAspect: Double, score: (ReelCandidate) -> Double,
                      distance: (String, String) -> Double?, pinned: Set<String>,
                      weights w: ReelSelector.Weights) -> [Pair] {
        guard ReelMotionPlanner.collageLayout(frameAspect: frameAspect) != nil, order.count >= 3 else { return [] }
        func free(_ c: ReelCandidate) -> Bool {
            c.id != openingID && c.id != closingID && !pinned.contains(c.id) && c.width != nil && c.height != nil
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
        // Ankare: de som mest behöver det först (contain-blur, sedan störst överskott av motivbredd).
        func badness(_ c: ReelCandidate) -> Double {
            let image = plannerImage(c)
            let blur = ReelMotionPlanner.kind(of: image, frameAspect: frameAspect) == .containBlur ? 10.0 : 0
            let visible = ReelMotionPlanner.visibleWidth(imageAspect: image.aspect, frameAspect: frameAspect)
            return blur + (c.focusWidth ?? c.salientWidth ?? 0.5) - visible
        }
        let anchors = order.filter { c in
            free(c) && eligibleRoom(c, weights: w)
                && ReelMotionPlanner.needsCollage(plannerImage(c), frameAspect: frameAspect)
        }.sorted { (badness($0), -(position[$0.id] ?? 0)) > (badness($1), -(position[$1.id] ?? 0)) }

        let maxPairs = max(1, Int(Double(order.count) * w.collageMaxShare))
        let poolBest = pool.sorted { score($0) > score($1) }.prefix(w.collagePoolSize)
        var used = Set<String>()
        var result: [Pair] = []
        for a in anchors where result.count < maxPairs && !used.contains(a.id) {
            // Valda bilder före bortvalda vid lika poäng; annars bäst grundpoäng först.
            let candidates = (order.map { ($0, true) } + poolBest.map { ($0, false) }).filter { c, _ in
                free(c) && !used.contains(c.id)
            }.sorted { score($0.0) > score($1.0) || (score($0.0) == score($1.0) && $0.1 && !$1.1) }
            guard let (p, picked) = candidates.first(where: { c, _ in
                canPair(anchor: a, partner: c, frameAspect: frameAspect, distance: distance, weights: w)
            }) else { continue }
            used.insert(a.id); used.insert(p.id)
            // Första rutan = den som kommer först i filmen; en extra bild kommer efter den valda.
            let (first, second) = (picked ? ((position[a.id] ?? 0) <= (position[p.id] ?? 0)) : true) ? (a, p) : (p, a)
            result.append(Pair(anchorID: first.id, partnerID: second.id, partnerPicked: picked,
                               reason: reason(first, second, partnerPicked: picked, frameAspect: frameAspect,
                                              score: score)))
        }
        return result
    }

    /// "Kollage: Kök och Matplats, båda ryms i 9:8 (poäng 0,71 och 0,66)".
    static func reason(_ first: ReelCandidate, _ second: ReelCandidate, partnerPicked: Bool, frameAspect: Double,
                       score: (ReelCandidate) -> Double) -> String {
        let rooms = ReelSelector.montageRooms(ReelCandidate(id: "", filename: "", panelRooms: [first.room ?? "", second.room ?? ""])) ?? "okända rum"
        let layout = ReelMotionPlanner.collageLayout(frameAspect: frameAspect) ?? .stack
        let pane = ReelMotionPlanner.ratioText(ReelMotionPlanner.collagePaneAspect(layout: layout, frameAspect: frameAspect))
        let text = "Kollage: \(rooms), båda ryms i \(pane) (poäng \(ReelSelector.fmt(score(first))) och \(ReelSelector.fmt(score(second))))"
        return partnerPicked ? text : text + ", extra bild utan egen plats"
    }
}
