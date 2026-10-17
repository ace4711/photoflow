import Foundation
import Testing
@testable import PhotoFlow

/// Rundtur Swift ↔ webb för fotografens lås: samma fixtur som webbens tester
/// (`web/reel/test/fixtures/reel-locks-v1.json`) ska läsas, tolkas och skrivas
/// likadant här, så att en film som mäklaren redigerat kommer tillbaka med låsen intakta.
struct ReelWebParityTests {

    static let fixtureURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // PhotoFlow
            .deletingLastPathComponent()      // repo
            .appendingPathComponent("web/reel/test/fixtures/reel-locks-v1.json")
    }()

    static func fixture() throws -> (data: Data, spec: ReelSpec) {
        let data = try Data(contentsOf: fixtureURL)
        return (data, try ReelSpec.decode(from: data))
    }

    @Test("Webbens låsfixtur avkodas med alla lås")
    func decodesLocks() throws {
        let spec = try Self.fixture().spec
        #expect(spec.isReadable)
        #expect(spec.editor?.pinnedAssets == [String(repeating: "c", count: 64)])
        #expect(spec.editor?.excludedAssets == [String(repeating: "f", count: 64)])
        #expect(spec.editor?.orderLocked == true)
        #expect(spec.editor?.tempo == "calm")
        let clip = Dictionary(uniqueKeysWithValues: spec.timeline.map { ($0.asset, $0) })
        #expect(clip["a2"]?.motionPreset == "custom")
        #expect(clip["a2"]?.transitionLocked == true)
        #expect(clip["a2"]?.transitionIn?.type == .cut)
        #expect(clip["a3"]?.transitionLocked == true)
        #expect(clip["a3"]?.transitionIn == nil)
        #expect(clip["a3"]?.durationLocked == true)
    }

    @Test("Låsen tolkas som fotografens val")
    func overridesFromFixture() throws {
        let spec = try Self.fixture().spec
        let o = ReelComposer.overrides(in: spec)
        #expect(o["a2"]?.preset == .custom)
        #expect(o["a2"]?.custom != nil)
        #expect(o["a2"]?.transitionLocked == true)
        #expect(o["a2"]?.transition?.type == .cut)
        #expect(o["a3"]?.duration == 4)
        #expect(o["a3"]?.transitionLocked == true)
        #expect(o["a3"]?.transition == nil)
        #expect(o["a4"]?.preset == .zoomIn)
        #expect(o["a1"] == nil)
    }

    @Test("Swift skriver tidslinje, stil och editor exakt som webbens fixtur")
    func encodesLikeWeb() throws {
        let (data, spec) = try Self.fixture()
        let written = try spec.jsonData()
        func parts(_ d: Data) throws -> [String: NSObject] {
            let obj = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
            var out: [String: NSObject] = [:]
            for key in ["timeline", "style", "editor", "outputs"] { out[key] = obj[key] as? NSObject }
            return out
        }
        #expect(try parts(written) == parts(data))
        #expect(try ReelSpec.decode(from: written) == spec)
    }

    @Test("Ombyggnad (omordning) behåller låsen från webben")
    func rebuildKeepsWebLocks() throws {
        let spec = try Self.fixture().spec
        let before = Dictionary(uniqueKeysWithValues: spec.timeline.map { ($0.asset, $0) })
        let rebuilt = ReelComposer.rebuild(spec, order: spec.timeline.map(\.asset).reversed(), op: "reorder")
        let after = Dictionary(uniqueKeysWithValues: rebuilt.timeline.map { ($0.asset, $0) })
        #expect(rebuilt.timeline.map(\.asset) == ["a5", "a4", "a3", "a2", "a1"])
        // Fixturens cy (0,55 vid zoom 1,05) ligger utanför bilden och klampas enligt spec 5.1;
        // cx och zoom ryms och ska vara orörda, och en andra ombyggnad ska inte ändra något.
        let m = try #require(after["a2"]?.motion), b = try #require(before["a2"]?.motion)
        #expect(m.from.cx == b.from.cx && m.to.cx == b.to.cx)
        #expect(m.from.zoom == b.from.zoom && m.to.zoom == b.to.zoom)
        #expect(abs(m.from.cy - (1 - 0.5 / 1.05)) < 1e-9)
        let again = ReelComposer.rebuild(rebuilt, order: rebuilt.timeline.map(\.asset), op: "reorder")
        #expect(again.timeline.first { $0.asset == "a2" }?.motion == m)
        #expect(after["a2"]?.motionPreset == "custom")
        #expect(after["a2"]?.transitionIn?.type == .cut)
        #expect(after["a2"]?.transitionLocked == true)
        #expect(after["a3"]?.duration == 4)
        #expect(after["a3"]?.transitionLocked == true)
        #expect(after["a3"]?.transitionIn == nil)
        #expect(after["a4"]?.motionPreset == "zoomIn")
        #expect(rebuilt.editor == spec.editor)
    }
}
