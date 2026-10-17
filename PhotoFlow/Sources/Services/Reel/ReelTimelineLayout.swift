import Foundation

/// Ren geometri för redigerarens tidslinje: var varje klippblock och varje övergång hamnar
/// för en viss skala (pixlar per sekund), samt träffbestämning och dragmatematik. Ingen vy
/// här, så allt går att testa. Tidsmodellen är den normativa (`ReelTimeline.clipStarts`,
/// `ReelTimeline.transition`, `docs/reel-spec-v1.md` avsnitt 3): en övergång ligger *inom*
/// båda klippens längd, så blocken överlappar varandra med övergångens effektiva längd.
nonisolated enum ReelTimelineLayout {

    /// Ett klippblock. `x` och `width` i pixlar, `start` och `duration` i sekunder.
    nonisolated struct Block: Equatable, Sendable {
        var index: Int
        var assetID: String
        var start: Double
        var duration: Double
        var x: Double
        var width: Double
        var end: Double { x + width }
    }

    /// Övergången in till klipp `index` (första klippet har ingen). `duration` är den effektiva
    /// längden efter klampning mot de två klippens längder, 0 för hårt klipp. `type` är också
    /// den effektiva: en övergång som klampats till längd 0 räknas som `cut`.
    nonisolated struct Join: Equatable, Sendable {
        var index: Int
        var assetID: String
        var start: Double
        var duration: Double
        var x: Double
        var width: Double
        var type: ReelSpec.TransitionType
        var direction: ReelSpec.Direction?
        /// Övergången är satt för hand (`transitionLocked`).
        var locked: Bool
        /// Den inställda längden före klampning (0 om den saknas), och taket specen klampar den mot:
        /// `min(D[i−1], D[i])` (spec avsnitt 3). Dragningen i `draggedTransition` använder dem.
        var configuredDuration: Double
        var limit: Double
        /// Chipets mittpunkt: mitt i överlappet (vid ett hårt klipp i skarven).
        var centerX: Double { x + width / 2 }
    }

    nonisolated struct Layout: Equatable, Sendable {
        var blocks: [Block]
        var joins: [Join]
        var pixelsPerSecond: Double
        var totalDuration: Double
        var contentWidth: Double { totalDuration * pixelsPerSecond }
    }

    /// Vad en punkt på tidslinjen träffar.
    nonisolated enum Hit: Equatable, Sendable {
        case clip(Int)
        /// Högerkanten på klipp `index` (dra = ändra längd).
        case clipEdge(Int)
        case transition(Int)
        /// Tom yta; tiden i sekunder (för att flytta spelhuvudet).
        case empty(time: Double)
    }

    /// Minsta skala: korta klipp ska gå att greppa även när filmen är lång.
    static let minimumPixelsPerSecond = 36.0
    /// Längdsteg vid dragning av kanten (sekunder).
    static let durationStep = 0.1
    static let chipHalfWidth = 11.0
    static let edgeTolerance = 5.0

    // MARK: Skala och tid

    /// Skalan som får filmen att fylla `availableWidth`, men aldrig under `minimum`.
    static func pixelsPerSecond(totalDuration: Double, availableWidth: Double,
                                minimum: Double = minimumPixelsPerSecond) -> Double {
        guard totalDuration > 0, availableWidth > 0 else { return minimum }
        return max(availableWidth / totalDuration, minimum)
    }

    static func x(forTime t: Double, pixelsPerSecond: Double) -> Double { t * pixelsPerSecond }

    static func time(atX x: Double, pixelsPerSecond: Double, totalDuration: Double? = nil) -> Double {
        let t = max(x, 0) / max(pixelsPerSecond, 0.0001)
        return totalDuration.map { min(t, $0) } ?? t
    }

    // MARK: Layout

    static func layout(_ spec: ReelSpec, pixelsPerSecond pps: Double) -> Layout {
        let starts = ReelTimeline.clipStarts(spec)
        var blocks: [Block] = []
        var joins: [Join] = []
        for (i, clip) in spec.timeline.enumerated() {
            blocks.append(.init(index: i, assetID: clip.asset, start: starts[i], duration: clip.duration,
                                x: starts[i] * pps, width: clip.duration * pps))
            guard i > 0 else { continue }
            let effective = ReelTimeline.transition(spec, at: i)
            let configured = clip.transitionIn ?? spec.style.defaultTransition
            joins.append(.init(index: i, assetID: clip.asset, start: starts[i],
                               duration: effective?.duration ?? 0,
                               x: starts[i] * pps, width: (effective?.duration ?? 0) * pps,
                               type: effective == nil ? .cut : configured.type,
                               direction: effective == nil ? nil : configured.direction,
                               locked: clip.transitionLocked == true,
                               configuredDuration: configured.duration,
                               limit: min(spec.timeline[i - 1].duration, clip.duration)))
        }
        return .init(blocks: blocks, joins: joins, pixelsPerSecond: pps,
                     totalDuration: ReelTimeline.totalDuration(spec))
    }

    // MARK: Träffbestämning

    /// Vad punkten `x` (pixlar från tidslinjens vänsterkant) träffar. `overChip` = y ligger i
    /// chipens band, och bara då kan en övergång träffas. Ordning: övergångschip, högerkant,
    /// klippblock (överst är det senare klippet i ett överlapp), annars tom yta.
    static func hit(_ layout: Layout, x: Double, overChip: Bool,
                    chipHalfWidth: Double = chipHalfWidth, edgeTolerance: Double = edgeTolerance) -> Hit {
        if overChip,
           let join = layout.joins.filter({ abs(x - $0.centerX) <= chipHalfWidth })
                .min(by: { abs(x - $0.centerX) < abs(x - $1.centerX) }) {
            return .transition(join.index)
        }
        if let block = layout.blocks.filter({ abs(x - $0.end) <= edgeTolerance })
            .min(by: { abs(x - $0.end) < abs(x - $1.end) }) {
            return .clipEdge(block.index)
        }
        if let block = layout.blocks.last(where: { x >= $0.x && x < $0.end }) {
            return .clip(block.index)
        }
        return .empty(time: time(atX: x, pixelsPerSecond: layout.pixelsPerSecond, totalDuration: layout.totalDuration))
    }

    // MARK: Dragning

    /// Längd efter att högerkanten dragits `dx` pixlar: snäppt till 0,1 s och inom `range`.
    static func draggedDuration(from original: Double, dx: Double, pixelsPerSecond: Double,
                                range: ClosedRange<Double>) -> Double {
        let raw = original + dx / max(pixelsPerSecond, 0.0001)
        let snapped = (raw / durationStep).rounded() * durationStep
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Längsta/kortaste övergång i redigeraren, och steget vid dragning (sekunder).
    static let transitionStep = 0.05

    /// Övergångens längd när chipet dragits `dx` pixlar i sidled. Chipet sitter mitt i överlappet
    /// vars högerkant (föregående klipps slut) ligger still medan vänsterkanten följer längden, så
    /// att chipet ska följa pekaren 1:1 betyder dragning åt vänster längre övergång och
    /// `Δlängd = −2·dx / skala`. Snäpper till 0,05 s, håller sig inom 0,2–1,5 s och klampas mot
    /// `limit` (de två klippens kortaste längd) så att man inte kan dra in i det som specen ändå
    /// kortar bort; är taket under 0,2 s blir det 0,2 s (inspektören visar då att den kortas).
    static func draggedTransition(from original: Double, dx: Double, pixelsPerSecond: Double, limit: Double) -> Double {
        let range = ReelMotionPlanner.transitionRange
        let raw = original - 2 * dx / max(pixelsPerSecond, 0.0001)
        let snapped = (raw / transitionStep).rounded() * transitionStep
        let ceiling = max(range.lowerBound, min(range.upperBound, limit))
        return min(max(snapped, range.lowerBound), ceiling)
    }

    /// Platsen (som `ReelEditorModel.moveClip(_:to:)` förstår den, alltså i listan efter att
    /// klippet tagits bort) när block `index` dragits `dx` pixlar i sidled: klippet hamnar efter
    /// alla andra block vars mittpunkt ligger till vänster om dess egen.
    static func dropIndex(_ layout: Layout, dragging index: Int, dx: Double) -> Int {
        guard layout.blocks.indices.contains(index) else { return index }
        let dragged = layout.blocks[index]
        let center = dragged.x + dragged.width / 2 + dx
        return layout.blocks.filter { $0.index != index && $0.x + $0.width / 2 < center }.count
    }
}
