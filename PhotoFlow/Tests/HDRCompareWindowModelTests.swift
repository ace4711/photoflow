import Foundation
import Testing
@testable import PhotoFlow

/// `HDRCompareModel` (fönstrets logik) mot ett litet syntetiskt manifest i en tillfällig mapp.
@MainActor
struct HDRCompareWindowModelTests {
    func makeManifest(variants: [String]) throws -> (dir: URL, manifest: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdrcompare-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var groups: [HDRCompareManifest.Group] = []
        for gid in ["g1", "g2", "g3", "g4", "g5", "g6"] {
            var vs: [String: String] = [:]
            for v in variants {
                let path = "\(gid)-\(v).jpg"
                try Data([0xFF]).write(to: dir.appendingPathComponent(path))
                vs[v] = path
            }
            groups.append(.init(id: gid, category: "interior", variants: vs))
        }
        let url = dir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(HDRCompareManifest(version: 1, created: nil, groups: groups)).write(to: url)
        return (dir, url)
    }

    @Test func betygSparasEfterVarjeBedomningOchOverlever() throws {
        let (dir, url) = try makeManifest(variants: ["pf-radiance", "lr-auto"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HDRCompareModel()
        model.remembersLastManifest = false
        model.load(url)
        #expect(model.groups.count == 6)
        #expect(model.selectedGroupID == "g1")
        #expect(model.canonicalPair?.a == "pf-radiance" && model.canonicalPair?.b == "lr-auto")
        #expect(model.displayPair?.left == "pf-radiance")
        #expect(model.currentVerdict == nil)

        model.draftAspects = [.window]
        model.rate(.left)
        #expect(model.isRated(model.groups[0]))
        #expect(model.ratedCount == 1)
        let onDisk = HDRCompareVerdictStore.load(forManifest: url)
        #expect(onDisk.verdicts.count == 1 && onDisk.verdicts[0].winner == "pf-radiance")
        #expect(onDisk.verdicts[0].aspects == ["window"])

        // Aspekter ändras efter betyget: sparas direkt, utan ny knapptryckning.
        model.draftAspects = [.window, .noise]
        model.draftChanged()
        #expect(HDRCompareVerdictStore.load(forManifest: url).verdicts[0].aspects == ["window", "noise"])

        // Ny modell (omstart) ser samma betyg och samma blind-seed.
        let again = HDRCompareModel()
        again.remembersLastManifest = false
        again.load(url)
        #expect(again.ratedCount == 1)
        #expect(again.verdictFile.blindSeed == model.verdictFile.blindSeed)
        #expect(again.displayedChoice == .left)
    }

    @Test func blindlagetSlumpaOrdningenOchDoljerEtiketterTillsBedomt() throws {
        let (dir, url) = try makeManifest(variants: ["pf-radiance", "lr-auto"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HDRCompareModel()
        model.remembersLastManifest = false
        model.load(url)
        model.blind = true
        var swaps = 0
        for g in model.groups {
            model.selectedGroupID = g.id
            #expect(model.labelsHidden)
            #expect(model.label(for: "pf-radiance", position: "A") == "A")
            if model.displayPair?.left == "lr-auto" { swaps += 1 }
        }
        #expect(swaps > 0 && swaps < model.groups.count, "\(swaps) av \(model.groups.count) bytte plats")

        // Bedöm en grupp där A (vänster) är lr-auto: vinnaren ska bli lr-auto och etiketterna visas.
        model.selectedGroupID = model.groups.first { HDRCompareBlind.isSwapped(seed: model.verdictFile.blindSeed, groupId: $0.id) }?.id
        model.rate(.left)
        #expect(model.currentVerdict?.winner == "lr-auto")
        #expect(model.currentVerdict?.blind == true)
        #expect(!model.labelsHidden)
        #expect(model.label(for: "lr-auto", position: "A") == "A · lr-auto")
    }

    @Test func faller_tillbakaTillAnnatParNarLRSaknas() throws {
        let (dir, url) = try makeManifest(variants: ["pf-radiance", "pf-fusion"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HDRCompareModel()
        model.remembersLastManifest = false
        model.load(url)
        #expect(model.canonicalPair?.a == "pf-radiance" && model.canonicalPair?.b == "pf-fusion")
        #expect(model.missingText(model.groups[0]) == "saknar lr-auto")
        // Val av B som saknas i gruppen ger standardpar i stället för tom ruta.
        model.preferredB = "lr-auto"
        #expect(model.canonicalPair?.b == "pf-fusion")
    }

    @Test func navigeringStannarIListan() throws {
        let (dir, url) = try makeManifest(variants: ["pf-radiance", "lr-auto"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HDRCompareModel()
        model.remembersLastManifest = false
        model.load(url)
        model.selectRelative(-1)
        #expect(model.selectedGroupID == "g1")
        model.selectRelative(1)
        #expect(model.selectedGroupID == "g2")
        for _ in 0..<10 { model.selectRelative(1) }
        #expect(model.selectedGroupID == "g6")
    }

    @Test func felaktigtManifestGerFelmeddelandeUtanAttKrascha() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdrcompare-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("manifest.json")
        try Data("{ inte json".utf8).write(to: url)
        let model = HDRCompareModel()
        model.remembersLastManifest = false
        model.load(url)
        #expect(model.manifest == nil)
        #expect(model.loadError?.contains("manifest.json") == true)
    }
}
