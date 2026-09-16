import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `AITagsStore` (Fas 3d): versionerad `ai_tags.json`-persistens
/// som fortfarande läser in filer skrivna av den gamla, oversionerade Fas
/// 3b-koden (ren `JSONSerialization`, platt `[filnamn: {tags, description,
/// category}]`-dict) — se `AITagsStore.load`.
struct AITagsStoreTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AITagsStoreTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Sparar och laddar en versionerad ai_tags.json med ML-fält")
    func saveAndLoad_roundTripsMLFields() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries: [String: AITagsStore.Entry] = [
            "IMG_0001": AITagsStore.Entry(
                tags: ["Kök", "Interiör"], description: "Kök", category: "Interiör",
                mlRoom: "Kök", mlCategory: "Interiör", mlFeatures: ["öppen spis", "parkettgolv"],
                mlCaption: "Ljust kök med öppen planlösning."
            )
        ]
        AITagsStore.save(entries, to: dir)

        let loaded = try #require(AITagsStore.load(from: dir))
        #expect(loaded["IMG_0001"] == entries["IMG_0001"])
    }

    @Test("Läser en gammal (Fas 3b, oversionerad) ai_tags.json utan ML-fält")
    func load_legacyUnversionedFile_parsesWithoutMLFields() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacyJSON: [String: Any] = [
            "IMG_0002": [
                "tags": ["Badrum", "Interiör"],
                "description": "Badrum",
                "category": "Interiör"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON, options: .prettyPrinted)
        try data.write(to: dir.appendingPathComponent("ai_tags.json"))

        let loaded = try #require(AITagsStore.load(from: dir))
        let entry = try #require(loaded["IMG_0002"])
        #expect(entry.tags == ["Badrum", "Interiör"])
        #expect(entry.description == "Badrum")
        #expect(entry.category == "Interiör")
        #expect(entry.mlCaption == nil)
        #expect(entry.mlFeatures == nil)
    }

    @Test("Saknad fil ger nil, inte en krasch")
    func load_missingFile_returnsNil() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AITagsStore.load(from: dir) == nil)
    }
}
