import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelTimelineLayout`: positioner, överlapp, hårt klipp, klampning, tid ↔ x,
/// träffbestämning och dragmatematik.
struct ReelTimelineLayoutTests {

    /// Tre klipp à 3, 2 och 4 s. Övergång in till klipp 1: crossfade 1,0 s (låst); in till klipp 2 ärver
    /// standarden (push höger, 0,5 s).
    private func spec(durations: [Double] = [3, 2, 4]) -> ReelSpec {
        let motion = ReelSpec.Motion(from: .init(cx: 0.5, cy: 0.5, zoom: 1), to: .init(cx: 0.5, cy: 0.5, zoom: 1.1))
        var s = try! ReelTimelineTests.example()
        s.timeline = durations.enumerated().map { i, d in
            ReelSpec.Clip(asset: "a\(i + 1)", duration: d, fit: .cover, motion: motion)
        }
        s.style.defaultTransition = .init(type: .push, direction: .right, duration: 0.5)
        if s.timeline.count > 1 {
            s.timeline[1].transitionIn = .init(type: .crossfade, direction: nil, duration: 1.0)
            s.timeline[1].transitionLocked = true
        }
        return s
    }

    @Test("Blocken börjar enligt clipStarts och bredden är längden")
    func positions() {
        let s = spec()
        let l = ReelTimelineLayout.layout(s, pixelsPerSecond: 50)
        #expect(l.blocks.map(\.start) == ReelTimeline.clipStarts(s))
        #expect(l.blocks.map(\.start) == [0, 2, 3.5])
        #expect(l.blocks.map(\.x) == [0, 100, 175])
        #expect(l.blocks.map(\.width) == [150, 100, 200])
        #expect(l.totalDuration == ReelTimeline.totalDuration(s))
        #expect(l.contentWidth == 7.5 * 50)
    }

    @Test("Övergångarna är överlappet mellan blocken, med typ, riktning och lås")
    func joins() {
        let l = ReelTimelineLayout.layout(spec(), pixelsPerSecond: 50)
        #expect(l.joins.count == 2)
        let a = l.joins[0], b = l.joins[1]
        #expect(a.index == 1 && a.assetID == "a2")
        #expect(a.x == 100 && a.width == 50 && a.centerX == 125)
        #expect(a.type == .crossfade && a.locked)
        // Överlappet är exakt där block 0 och 1 överlappar.
        #expect(a.x == l.blocks[1].x && a.x + a.width == l.blocks[0].end)
        #expect(b.type == .push && b.direction == .right && !b.locked)
        #expect(b.duration == 0.5 && b.width == 25)
        #expect(b.x + b.width == l.blocks[1].end)
    }

    @Test("Hårt klipp ger ingen överlappsbredd och chipet ligger i skarven")
    func cut() {
        var s = spec()
        s.timeline[1].transitionIn = .init(type: .cut, direction: nil, duration: 0)
        let l = ReelTimelineLayout.layout(s, pixelsPerSecond: 40)
        #expect(l.joins[0].type == .cut && l.joins[0].duration == 0 && l.joins[0].width == 0)
        #expect(l.blocks[1].x == l.blocks[0].end)
        #expect(l.joins[0].centerX == l.blocks[1].x)
    }

    @Test("Övergången klampas mot det kortaste klippet, och längd 0 räknas som cut")
    func clamping() {
        var s = spec(durations: [3, 0.6, 4])
        s.timeline[1].transitionIn = .init(type: .crossfade, direction: nil, duration: 1.5)
        let l = ReelTimelineLayout.layout(s, pixelsPerSecond: 100)
        #expect(l.joins[0].duration == 0.6)
        #expect(l.blocks[1].start == 2.4)
        // Kortare övergång i ett klipp av längd 0 blir cut.
        var z = spec()
        z.timeline[2].transitionIn = .init(type: .push, direction: .left, duration: 0)
        let lz = ReelTimelineLayout.layout(z, pixelsPerSecond: 100)
        #expect(lz.joins[1].type == .cut && lz.joins[1].direction == nil)
    }

    @Test("Skala: filmen fyller bredden, med minimum")
    func scale() {
        #expect(ReelTimelineLayout.pixelsPerSecond(totalDuration: 10, availableWidth: 1000) == 100)
        #expect(ReelTimelineLayout.pixelsPerSecond(totalDuration: 60, availableWidth: 1000) == ReelTimelineLayout.minimumPixelsPerSecond)
        #expect(ReelTimelineLayout.pixelsPerSecond(totalDuration: 0, availableWidth: 1000) == ReelTimelineLayout.minimumPixelsPerSecond)
    }

    @Test("Tid och x är varandras inverser, klampat")
    func timeAndX() {
        #expect(ReelTimelineLayout.x(forTime: 2.5, pixelsPerSecond: 40) == 100)
        #expect(ReelTimelineLayout.time(atX: 100, pixelsPerSecond: 40) == 2.5)
        #expect(ReelTimelineLayout.time(atX: -20, pixelsPerSecond: 40) == 0)
        #expect(ReelTimelineLayout.time(atX: 5000, pixelsPerSecond: 40, totalDuration: 7.5) == 7.5)
    }

    @Test("Träffbestämning: block, kant, chip och tom yta")
    func hits() {
        let l = ReelTimelineLayout.layout(spec(), pixelsPerSecond: 50)   // block: 0–150, 100–200, 175–375
        #expect(ReelTimelineLayout.hit(l, x: 40, overChip: false) == .clip(0))
        // I ett överlapp vinner det senare klippet (det ritas överst).
        #expect(ReelTimelineLayout.hit(l, x: 110, overChip: false) == .clip(1))
        #expect(ReelTimelineLayout.hit(l, x: 300, overChip: false) == .clip(2))
        // Högerkanten (150) för block 0, och sista blockets kant (375).
        #expect(ReelTimelineLayout.hit(l, x: 148, overChip: false) == .clipEdge(0))
        #expect(ReelTimelineLayout.hit(l, x: 372, overChip: false) == .clipEdge(2))
        // Chipet på övergång 1 (mitt = 125) bara när y är i chipbandet.
        #expect(ReelTimelineLayout.hit(l, x: 128, overChip: true) == .transition(1))
        #expect(ReelTimelineLayout.hit(l, x: 128, overChip: false) == .clip(1))
        // Utanför filmen: tom yta med tid.
        if case .empty(let t) = ReelTimelineLayout.hit(l, x: 500, overChip: false) {
            #expect(t == 7.5)
        } else { Issue.record("förväntade tom yta") }
        if case .empty = ReelTimelineLayout.hit(l, x: -30, overChip: false) {} else { Issue.record("förväntade tom yta vänster om filmen") }
    }

    @Test("Kantdragning snäpper till 0,1 s och håller sig inom intervallet")
    func draggedDuration() {
        let r = ReelEditorModel.durationRange
        #expect(abs(ReelTimelineLayout.draggedDuration(from: 3, dx: 52, pixelsPerSecond: 100, range: r) - 3.5) < 1e-9)
        #expect(abs(ReelTimelineLayout.draggedDuration(from: 3, dx: 13, pixelsPerSecond: 100, range: r) - 3.1) < 1e-9)
        #expect(ReelTimelineLayout.draggedDuration(from: 3, dx: -1000, pixelsPerSecond: 100, range: r) == 1.0)
        #expect(ReelTimelineLayout.draggedDuration(from: 3, dx: 5000, pixelsPerSecond: 100, range: r) == 10.0)
    }

    @Test("Släppplats vid flytt av block")
    func dropIndex() {
        let l = ReelTimelineLayout.layout(spec(durations: [3, 3, 3, 3]), pixelsPerSecond: 50)   // kring 75, 225, 375 ... (med övergångar)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 0, dx: 0) == 0)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 0, dx: 10_000) == 3)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 3, dx: -10_000) == 0)
        // Dras ett halvt block (och lite till) åt höger passerar det nästa blocks mittpunkt.
        let step = l.blocks[1].x + l.blocks[1].width / 2 - (l.blocks[0].x + l.blocks[0].width / 2)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 0, dx: step + 1) == 1)
        #expect(ReelTimelineLayout.dropIndex(l, dragging: 0, dx: step - 1) == 0)
    }

    @Test("Övergångens längd och tak ligger i layouten")
    func joinLimits() {
        let l = ReelTimelineLayout.layout(spec(durations: [3, 0.6, 4]), pixelsPerSecond: 50)
        #expect(l.joins[0].configuredDuration == 1.0 && l.joins[0].limit == 0.6)
        #expect(l.joins[1].configuredDuration == 0.5 && l.joins[1].limit == 0.6)
    }

    @Test("Chipdragning: åt vänster längre (chipet följer pekaren), snäpp 0,05 s")
    func draggedTransition() {
        // 50 px/s: chipet rör sig halva längdändringen, så −10 px ger +0,4 s.
        #expect(abs(ReelTimelineLayout.draggedTransition(from: 0.5, dx: -10, pixelsPerSecond: 50, limit: 3) - 0.9) < 1e-9)
        #expect(abs(ReelTimelineLayout.draggedTransition(from: 0.5, dx: 10, pixelsPerSecond: 50, limit: 3) - 0.2) < 1e-9)
        // 0,5 − 2·(−1)/50 = 0,54 → snäpper till 0,55.
        #expect(abs(ReelTimelineLayout.draggedTransition(from: 0.5, dx: -1, pixelsPerSecond: 50, limit: 3) - 0.55) < 1e-9)
        #expect(abs(ReelTimelineLayout.draggedTransition(from: 0.5, dx: 0, pixelsPerSecond: 50, limit: 3) - 0.5) < 1e-9)
    }

    @Test("Chipdragning klampas till 0,2–1,5 s och till klippens längd")
    func draggedTransitionClamps() {
        #expect(ReelTimelineLayout.draggedTransition(from: 0.5, dx: 10_000, pixelsPerSecond: 50, limit: 3) == 0.2)
        #expect(ReelTimelineLayout.draggedTransition(from: 0.5, dx: -10_000, pixelsPerSecond: 50, limit: 3) == 1.5)
        // Taket från kort klipp (0,8 s) hindrar längre än så.
        #expect(ReelTimelineLayout.draggedTransition(from: 0.5, dx: -10_000, pixelsPerSecond: 50, limit: 0.8) == 0.8)
        // Taket under 0,2 s ger 0,2 s (specen kortar den sedan).
        #expect(ReelTimelineLayout.draggedTransition(from: 0.5, dx: -10_000, pixelsPerSecond: 50, limit: 0.1) == 0.2)
    }

    @Test("Chipets träffzon är kvar på den nya dragytan, och efter dragning flyttas skarven")
    func chipZoneFollowsDraggedLength() {
        var s = spec()
        let before = ReelTimelineLayout.layout(s, pixelsPerSecond: 50)
        #expect(ReelTimelineLayout.hit(before, x: before.joins[0].centerX + 3, overChip: true) == .transition(1))
        s.timeline[1].transitionIn?.duration = ReelTimelineLayout.draggedTransition(from: 1.0, dx: -10, pixelsPerSecond: 50, limit: 2)
        let after = ReelTimelineLayout.layout(s, pixelsPerSecond: 50)
        #expect(abs(after.joins[0].duration - 1.4) < 1e-9)
        // Högerkanten av överlappet ligger kvar (föregående klipps slut); mitten har flyttats halva ändringen åt vänster.
        #expect(abs(after.joins[0].x + after.joins[0].width - before.blocks[0].end) < 1e-9)
        #expect(abs(after.joins[0].centerX - (before.joins[0].centerX - 10)) < 1e-9)
        #expect(ReelTimelineLayout.hit(after, x: after.joins[0].centerX, overChip: true) == .transition(1))
    }
}
