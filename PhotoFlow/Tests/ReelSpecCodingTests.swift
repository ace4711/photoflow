import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `ReelSpec`: golden JSON (planens exempel) fram och tillbaka,
/// tolerans för okända fält och versionskontroll.
struct ReelSpecCodingTests {

    static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Reel")
    }()

    static func exampleData() throws -> Data {
        try Data(contentsOf: fixturesDir.appendingPathComponent("example-v1.json"))
    }

    @Test("Planens exempel avkodas till rätt innehåll")
    func decodesExample() throws {
        let spec = try ReelSpec.decode(from: try Self.exampleData())
        #expect(spec.schema == "photoflow.reel")
        #expect(spec.version == 1)
        #expect(spec.assets.count == 5)
        #expect(spec.timeline.count == 5)
        #expect(spec.timeline[4].fit == .containBlur)
        #expect(spec.timeline[1].transitionIn?.type == .push)
        #expect(spec.timeline[1].transitionIn?.direction == .left)
        #expect(spec.timeline[0].transitionIn == nil)
        #expect(spec.assets[0].analysis?.salientWidth == 0.71)
        #expect(spec.assets[0].sources.first?.kind == .local)
        #expect(spec.style.easing == .easeInOut)
        #expect(spec.audio == nil)
        #expect(spec.brand == nil)
        #expect(spec.overlays.isEmpty)
        #expect(spec.outputs.first?.encoding?.bitrateMbps == 14)
        #expect(spec.provenance.autoSelection?.count == 2)
        #expect(spec.isReadable)
    }

    @Test("Golden JSON: avkoda, koda, avkoda ger samma spec")
    func roundTrip() throws {
        let spec = try ReelSpec.decode(from: try Self.exampleData())
        let encoded = try spec.jsonData()
        let again = try ReelSpec.decode(from: encoded)
        #expect(again == spec)
        // Kodningen är stabil: samma spec ger samma byte.
        #expect(try again.jsonData() == encoded)
    }

    @Test("Kodningen är läsbar: sorterade nycklar, ISO 8601-datum, oescapade snedstreck")
    func encodingIsReadable() throws {
        let spec = try ReelSpec.decode(from: try Self.exampleData())
        let text = String(decoding: try spec.jsonData(), as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"createdAt\" : \"2026-10-03T09:12:00Z\""))
        #expect(text.contains("../Lindvägen 12, Tyresö FÄRDIGA/DSC_1201.jpg"))
        // Nycklarna kommer i alfabetisk ordning.
        let positions = ["\"assets\"", "\"createdAt\"", "\"id\"", "\"minReaderVersion\"", "\"schema\""]
            .compactMap { text.range(of: "\n  " + $0)?.lowerBound }   // toppnivånycklar (2 blanksteg indrag)
        #expect(positions == positions.sorted())
    }

    @Test("Okända fält på alla nivåer ignoreras")
    func ignoresUnknownFields() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try Self.exampleData()) as? [String: Any])
        object["futureTopLevel"] = ["x": 1]
        var timeline = try #require(object["timeline"] as? [[String: Any]])
        timeline[0]["futureClipField"] = "hej"
        var motion = try #require(timeline[0]["motion"] as? [String: Any])
        motion["curve"] = "bezier"
        timeline[0]["motion"] = motion
        object["timeline"] = timeline
        object["overlays"] = [["type": "title", "text": "Lindvägen 12", "from": 0.3, "to": 2.8,
                               "position": "lowerThird", "style": "brand", "somethingNew": true]]
        object["brand"] = ["id": "x", "primaryColor": "#0B3D2E", "extra": 1]
        let data = try JSONSerialization.data(withJSONObject: object)

        let spec = try ReelSpec.decode(from: data)
        let original = try ReelSpec.decode(from: try Self.exampleData())
        #expect(spec.timeline == original.timeline)
        #expect(spec.overlays.first?.type == "title")
        #expect(spec.overlays.first?.position == "lowerThird")
        #expect(spec.brand?.primaryColor == "#0B3D2E")
    }

    @Test("Version och minReaderVersion styr om specen går att läsa")
    func versionGate() throws {
        #expect(ReelSpec.currentVersion == 1)
        var spec = try ReelSpec.decode(from: try Self.exampleData())
        #expect(spec.isReadable)

        spec.version = 2            // nyare skrivare, men bakåtkompatibel
        #expect(spec.isReadable)
        spec.minReaderVersion = 2   // brytande ändring
        #expect(!spec.isReadable)

        spec.minReaderVersion = 1
        spec.schema = "annat.format"
        #expect(!spec.isReadable)

        // Versionsfälten överlever en omkodning.
        spec.schema = ReelSpec.schemaName
        spec.version = 3
        spec.minReaderVersion = 2
        let again = try ReelSpec.decode(from: try spec.jsonData())
        #expect(again.version == 3 && again.minReaderVersion == 2)
    }

    @Test("Obligatoriska fält som saknas ger ett avkodningsfel")
    func missingRequiredField() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try Self.exampleData()) as? [String: Any])
        object.removeValue(forKey: "timeline")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try ReelSpec.decode(from: data) }
    }
}
