import Foundation
import Testing
@testable import PhotoFlow

/// Pipelinesteget "Filmförslag": val av källa, skydd av användarens arbete, fingerprint som
/// överlever metadatasteget, analys ur pipelinens data och ett litet bygge från början till slut.
struct ReelProposalTests {

    // MARK: Hjälp

    private func session() throws -> URL { try ObjektfilmTestKit.tempDir("Filmforslag") }

    @discardableResult
    private func makeImages(_ names: [String], in dir: URL, seedBase: Int = 0) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.enumerated().map { i, name in
            ObjektfilmTestKit.writeJPEG(to: dir.appendingPathComponent(name), seed: seedBase + i + 1)
        }
    }

    private let address = "Testvägen 1"

    private func dir(_ kind: ReelProposal.SourceKind, in root: URL) -> URL {
        kind.directory(in: root, folderName: address)
    }

    /// En komponerad spec (utan rendering) för skyddstesterna, med bilder i en syskonmapp.
    private func composedSpec(in root: URL, sourceKind: ReelProposal.SourceKind, filmDir: URL) throws -> ReelSpec {
        let sourceDir = dir(sourceKind, in: root)
        let items = try ObjektfilmTestKit.realItems(count: 4, in: sourceDir)
        var spec = ReelComposer.compose(items: items, specDirectory: filmDir).spec
        spec.provenance.generator = ReelProposal.generator
        return spec
    }

    private func write(_ spec: ReelSpec, to filmDir: URL) throws {
        try FileManager.default.createDirectory(at: filmDir, withIntermediateDirectories: true)
        try spec.jsonData().write(to: filmDir.appendingPathComponent("reel.json"))
    }

    // MARK: Källa

    @Test("Källa: FÄRDIGA går före FÖRBÄTTRADE före TITTBILDER")
    func sourcePriority() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeImages(["a.jpg", "b.jpg", "c.jpg"], in: dir(.preview, in: root))
        #expect(ReelProposal.selectSource(outputDir: root, folderName: address).source?.kind == .preview)

        try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"], in: dir(.enhanced, in: root))
        #expect(ReelProposal.selectSource(outputDir: root, folderName: address).source?.kind == .enhanced)

        try makeImages(["x.jpg", "y.jpg", "z.jpg"], in: dir(.finished, in: root))
        let chosen = try #require(ReelProposal.selectSource(outputDir: root, folderName: address).source)
        #expect(chosen.kind == .finished && chosen.files.count == 3)
    }

    @Test("Källa: minst 3 bilder, annars nästa källa; ingen räcker ger ingen källa")
    func sourceNeedsThreeImages() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeImages(["x.jpg", "y.jpg"], in: dir(.finished, in: root))
        try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg"], in: dir(.enhanced, in: root))
        let none = ReelProposal.selectSource(outputDir: root, folderName: address)
        #expect(none.source == nil)
        #expect(none.counts[.finished] == 2 && none.counts[.enhanced] == 2)

        try makeImages(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], in: dir(.preview, in: root))
        #expect(ReelProposal.selectSource(outputDir: root, folderName: address).source?.kind == .preview)
    }

    @Test("Källa: FÖRBÄTTRADE tar bara _enh.jpg, TITTBILDER tar inte bracketgruppens exponeringar när HDR-JPEG finns")
    func sourceFiltering() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let enhanced = dir(.enhanced, in: root)
        try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"], in: enhanced)
        try Data("tiff".utf8).write(to: enhanced.appendingPathComponent("DSC_0001_enh.tiff"))
        let chosen = try #require(ReelProposal.selectSource(outputDir: root, folderName: address).source)
        #expect(chosen.files.map(\.lastPathComponent) == ["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"])

        // Grupp 7 (DSC_0010-0012) har en HDR-JPEG: exponeringarna ska bort. DSC_0020 är en singel.
        let preview = dir(.preview, in: root)
        try makeImages(["DSC_0010.jpg", "DSC_0011.jpg", "DSC_0012.jpg", "hdr_group_7.jpg", "DSC_0020.jpg"], in: preview)
        let existing = ReelProposal.ExistingData(
            tags: [:], quality: [:],
            groupMembers: [7: ["DSC_0010", "DSC_0011", "DSC_0012"], 8: ["DSC_0020"]], bracketGroupIDs: [7])
        let files = ReelProposal.images(of: .preview, in: preview, existing: existing).map(\.lastPathComponent)
        #expect(files == ["DSC_0020.jpg", "hdr_group_7.jpg"])
    }

    // MARK: Skydd mot överskrivning

    @Test("Skydd: skickad, redigerad, ändrad status eller egen film rörs inte")
    func protection() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let filmDir = AddressFolderLayout.reelDir(in: root, folderName: address)
        #expect(ReelProposal.inspectExisting(filmDir: filmDir) == .none)

        let spec = try composedSpec(in: root, sourceKind: .enhanced, filmDir: filmDir)
        try write(spec, to: filmDir)
        guard case .replaceable(let builtOn, _, let hasVideo) = ReelProposal.inspectExisting(filmDir: filmDir) else {
            Issue.record("Ett oredigerat pipelineförslag ska gå att ersätta"); return
        }
        #expect(builtOn == .enhanced && !hasVideo)

        func isProtected(_ edit: (inout ReelSpec) -> Void) throws -> Bool {
            var changed = spec
            edit(&changed)
            try write(changed, to: filmDir)
            if case .protected = ReelProposal.inspectExisting(filmDir: filmDir) { return true }
            return false
        }
        #expect(try isProtected { $0.revision = 2 })
        #expect(try isProtected { $0.status = "approved" })
        #expect(try isProtected { $0.provenance.edits = [.init(at: Date(), by: "photographer", op: "reorder")] })
        #expect(try isProtected { $0.provenance.generator = ReelComposer.generator })   // användarens egen film
        #expect(try !isProtected { _ in })

        // Skickad till mäklare: reel-remote.json räcker, även om reel.json är orörd.
        try write(spec, to: filmDir)
        let remote = ReelRemoteState(server: "https://film.test", objectId: "o", reelId: "r")
        try JSONEncoder().encode(remote).write(to: filmDir.appendingPathComponent(ReelRemoteState.fileName))
        #expect(ReelProposal.inspectExisting(filmDir: filmDir) == .protected(reason: "skickad till mäklare (reel-remote.json finns)"))
        try FileManager.default.removeItem(at: filmDir.appendingPathComponent(ReelRemoteState.fileName))

        // Oläsbar reel.json och en MP4 utan reel.json räknas också som användarens.
        try Data("inte json".utf8).write(to: filmDir.appendingPathComponent("reel.json"))
        if case .protected = ReelProposal.inspectExisting(filmDir: filmDir) {} else { Issue.record("Oläsbar spec ska skyddas") }
        try FileManager.default.removeItem(at: filmDir.appendingPathComponent("reel.json"))
        try Data("mp4".utf8).write(to: filmDir.appendingPathComponent("reel_9x16.mp4"))
        if case .protected = ReelProposal.inspectExisting(filmDir: filmDir) {} else { Issue.record("Okänd MP4 ska skyddas") }
    }

    @Test("Beslut: FÄRDIGA ersätter förslag på sämre källa, aldrig tvärtom; skyddad film byggs aldrig")
    func decisions() {
        func replaceable(_ built: ReelProposal.SourceKind?, fp: String? = "f1", video: Bool = true) -> ReelProposal.ExistingFilm {
            .replaceable(builtOn: built, fingerprint: fp, hasVideo: video)
        }
        // Bättre källa → bygg om, även om fingerprintet råkar vara detsamma.
        if case .build = ReelProposal.decide(existing: replaceable(.enhanced), source: .finished, fingerprint: "f1") {} else {
            Issue.record("FÄRDIGA ska ersätta ett förslag på FÖRBÄTTRADE")
        }
        if case .build = ReelProposal.decide(existing: replaceable(.preview), source: .finished, fingerprint: "f1") {} else {
            Issue.record("FÄRDIGA ska ersätta ett förslag på TITTBILDER")
        }
        // Sämre källa än filmen bygger på → rör inte.
        if case .skip(_, let isProtected) = ReelProposal.decide(existing: replaceable(.finished), source: .enhanced, fingerprint: "f2") {
            #expect(!isProtected)
        } else { Issue.record("Ett förslag på FÄRDIGA ska inte ersättas av FÖRBÄTTRADE") }
        // Samma källa: oförändrat hoppar över, ändrat bygger, force bygger.
        #expect(ReelProposal.decide(existing: replaceable(.enhanced), source: .enhanced, fingerprint: "f1")
                == .skip(reason: "oförändrat (samma bilder, format och motor)", protected: false))
        if case .build = ReelProposal.decide(existing: replaceable(.enhanced), source: .enhanced, fingerprint: "f2") {} else { Issue.record("Ändrade bilder ska ge nytt förslag") }
        if case .build = ReelProposal.decide(existing: replaceable(.enhanced), source: .enhanced, fingerprint: "f1", force: true) {} else { Issue.record("force ska bygga om") }
        if case .build = ReelProposal.decide(existing: replaceable(.enhanced, video: false), source: .enhanced, fingerprint: "f1") {} else { Issue.record("Saknad MP4 ska byggas") }
        // Skyddad: aldrig, inte ens med force.
        let protected = ReelProposal.decide(existing: .protected(reason: "redigerad"), source: .finished, fingerprint: "f1", force: true)
        if case .skip(let reason, let isProtected) = protected {
            #expect(isProtected && reason.contains("Filmen har redigerats/skickats — rör den inte"))
        } else { Issue.record("Skyddad film får aldrig byggas om") }
        #expect(ReelProposal.decide(existing: .none, source: .preview, fingerprint: "f1")
                == .build(reason: "nytt förslag"))
    }

    // MARK: Fingerprint

    @Test("Fingerprint: oförändrat när metadatasteget skriver om FÖRBÄTTRADE-/TITTBILDER-filer (ny storlek och ändringstid)")
    func fingerprintSurvivesMetadataRewrite() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = ReelProposal.ExistingData(
            tags: [:], quality: [:], groupMembers: [1: ["DSC_0001", "DSC_0002"], 2: ["DSC_0003"]], bracketGroupIDs: [1])
        let nef = ["dsc_0001": Int64(100), "dsc_0002": 200, "dsc_0003": 300]

        for kind in [ReelProposal.SourceKind.enhanced, .preview] {
            let directory = dir(kind, in: root)
            let suffix = kind == .enhanced ? "_enh" : ""
            let names = ["hdr_group_1\(suffix).jpg", "DSC_0003\(suffix).jpg", "DSC_0004\(suffix).jpg"]
            let files = try makeImages(names, in: directory)
            let source = ReelProposal.Source(kind: kind, directory: directory, files: files)
            let before = ReelProposal.fingerprint(source: source, existing: existing, nefSizes: nef, count: 5, format: .vertical)

            // "Metadatasteget": skriver EXIF i filerna på plats, så storlek och ändringstid ändras.
            for file in files {
                var data = try Data(contentsOf: file)
                data.append(Data(repeating: 0xAB, count: 4096))
                try data.write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: file.path)
            }
            let after = ReelProposal.fingerprint(source: source, existing: existing, nefSizes: nef, count: 5, format: .vertical)
            #expect(before == after, "\(kind): fingerprintet får inte bero på filernas storlek/mtime")

            // Men en ändrad källa (annan NEF-storlek, format, antal) ändrar det.
            #expect(before != ReelProposal.fingerprint(source: source, existing: existing, nefSizes: ["dsc_0001": 101], count: 5, format: .vertical))
            #expect(before != ReelProposal.fingerprint(source: source, existing: existing, nefSizes: nef, count: 6, format: .vertical))
            #expect(before != ReelProposal.fingerprint(source: source, existing: existing, nefSizes: nef, count: 5, format: .square))
            #expect(before != ReelProposal.fingerprint(source: ReelProposal.Source(kind: kind, directory: directory, files: Array(files.dropLast())),
                                                       existing: existing, nefSizes: nef, count: 5, format: .vertical))
        }
    }

    @Test("Fingerprint: samma indata ger samma fingerprint även utan förbättringslogg")
    func fingerprintDeterministicWithoutLog() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = dir(.enhanced, in: root)
        let files = try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"], in: directory)
        let source = ReelProposal.Source(kind: .enhanced, directory: directory, files: files)
        let a = ReelProposal.fingerprint(source: source, existing: ReelProposal.ExistingData(), count: 5, format: .vertical)
        // Utan logg: namnen räcker (samma resultat varje gång).
        #expect(a == ReelProposal.fingerprint(source: source, existing: ReelProposal.ExistingData(), count: 5, format: .vertical))
    }

    @Test("Fingerprint: FÄRDIGA identifieras av innehållet, inte av ändringstid")
    func fingerprintFinishedUsesContent() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = dir(.finished, in: root)
        let files = try makeImages(["a.jpg", "b.jpg", "c.jpg"], in: directory)
        let source = ReelProposal.Source(kind: .finished, directory: directory, files: files)
        let before = ReelProposal.fingerprint(source: source, existing: ReelProposal.ExistingData(), count: 5, format: .vertical)

        // Samma innehåll, ny ändringstid: samma fingerprint.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(7200)], ofItemAtPath: files[0].path)
        #expect(before == ReelProposal.fingerprint(source: source, existing: ReelProposal.ExistingData(), count: 5, format: .vertical))

        // Ny export med andra pixlar under samma namn: nytt fingerprint.
        ObjektfilmTestKit.writeJPEG(to: files[1], seed: 99)
        #expect(before != ReelProposal.fingerprint(source: source, existing: ReelProposal.ExistingData(), count: 5, format: .vertical))
    }

    // MARK: Analys ur befintlig data

    private func entry(room: String?, category: String = "Interiör", description: String = "", tags: [String] = []) -> AITagsStore.Entry {
        AITagsStore.Entry(tags: tags, description: description, category: category, mlRoom: room, mlCategory: nil, mlFeatures: nil, mlCaption: nil)
    }

    @Test("Befintlig data: rum, kategori och kvalitet för DSC_xxxx; rum ur pipelinens egen beskrivning utan Foundation Models")
    func existingDataSingle() {
        let data = ReelProposal.ExistingData(
            tags: [
                "DSC_0001": entry(room: "Kök", description: "Kök med öppen spis", tags: ["Interiör", "Kök", "Öppen spis"]),
                "DSC_0002": entry(room: nil, category: "Exteriör", description: "Fasadbild", tags: ["Exteriör", "Fasad", "Villa"]),
                "DSC_0003": entry(room: nil, description: "Interiör", tags: ["Interiör", "Sovrum"]),
            ],
            quality: ["DSC_0001": .init(qualityScore: 0.8, isUtility: false, horizonAngleDegrees: 1.5, sharpness: 400, duplicateGroupID: 9)],
            groupMembers: [:], bracketGroupIDs: [])

        let kitchen = data.precomputed(forKey: "DSC_0001")
        #expect(kitchen?.room == "Kök" && kitchen?.category == "Interiör")
        #expect(kitchen?.qualityScore == 0.8 && kitchen?.sharpness == 400 && kitchen?.horizonAngleDegrees == 1.5)
        #expect(kitchen?.duplicateGroupID == 9 && kitchen?.features == ["Öppen spis"])
        #expect(kitchen?.caption == "Kök med öppen spis")

        let facade = data.precomputed(forKey: "DSC_0002")
        #expect(facade?.room == "Fasadbild" && facade?.category == "Exteriör" && facade?.qualityScore == nil)
        // Beskrivningen är bara "Interiör": då används första kända rumstaggen.
        #expect(data.precomputed(forKey: "DSC_0003")?.room == "Sovrum")
        #expect(data.precomputed(forKey: "DSC_9999") == nil)
    }

    @Test("Befintlig data: hdr_group_<id> tar bästa/representativa värden över gruppens bilder")
    func existingDataHDRGroup() {
        let data = ReelProposal.ExistingData(
            tags: [
                "DSC_0010": entry(room: "Vardagsrum"), "DSC_0011": entry(room: "Vardagsrum"), "DSC_0012": entry(room: "Kök"),
            ],
            quality: [
                "DSC_0010": .init(qualityScore: 0.3, isUtility: true, horizonAngleDegrees: 2, sharpness: 100, duplicateGroupID: 4),
                "DSC_0011": .init(qualityScore: 0.9, isUtility: false, horizonAngleDegrees: 0.5, sharpness: 300, duplicateGroupID: 5),
                "DSC_0012": .init(qualityScore: 0.6, isUtility: true, horizonAngleDegrees: nil, sharpness: 250, duplicateGroupID: 6),
            ],
            groupMembers: [7: ["DSC_0010", "DSC_0011", "DSC_0012"]], bracketGroupIDs: [7])
        let pre = data.precomputed(forKey: "hdr_group_7")
        #expect(pre?.room == "Vardagsrum")                 // två av tre
        #expect(pre?.qualityScore == 0.9 && pre?.sharpness == 300)
        #expect(pre?.horizonAngleDegrees == 0.5)           // den bästa bildens
        #expect(pre?.isUtility == false)                   // bara om alla är nyttobilder
        #expect(pre?.duplicateGroupID == 5)
        #expect(data.precomputed(forKey: "hdr_group_99") == nil)
    }

    @Test("Befintlig data läses ur ai_tags.json, photo_quality.json och bracket_groups.json")
    func existingDataLoad() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        AITagsStore.save(["DSC_0001": entry(room: "Badrum")], to: root)
        PhotoQualityService.save(["DSC_0001": .init(qualityScore: 0.7, isUtility: false, horizonAngleDegrees: nil, sharpness: 12, duplicateGroupID: nil)], to: root)
        let groups: [String: Any] = ["groups": [
            ["group_id": 3, "files": ["DSC_0001.NEF", "DSC_0002.NEF"], "is_bracket": true],
            ["group_id": 4, "files": ["DSC_0005.NEF"], "is_bracket": false],
        ]]
        try JSONSerialization.data(withJSONObject: groups).write(to: root.appendingPathComponent("bracket_groups.json"))

        let data = ReelProposal.ExistingData.load(from: root)
        #expect(data.tags["DSC_0001"]?.mlRoom == "Badrum" && data.quality["DSC_0001"]?.qualityScore == 0.7)
        #expect(data.groupMembers[3] == ["DSC_0001", "DSC_0002"] && data.bracketGroupIDs == [3])
        #expect(data.precomputed(forKey: "hdr_group_3")?.room == "Badrum")
    }

    @Test("Analysen använder pipelinens värden: ingen feature print, rum och kvalitet oförändrade, storlek och saliency uppmätta")
    func analyzerUsesPrecomputed() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ObjektfilmTestKit.writeJPEG(to: root.appendingPathComponent("DSC_0001_enh.jpg"), width: 320, height: 240, seed: 3)
        var pre = ReelImageAnalyzer.Precomputed()
        pre.room = "Kök"; pre.category = "Interiör"; pre.qualityScore = 0.77; pre.sharpness = 321
        let items = try await ReelImageAnalyzer.analyze(urls: [file], cacheDirectory: root, describe: true, precomputed: [file: pre])
        let a = try #require(items.first?.analysis)
        #expect(a.room == "Kök" && a.category == "Interiör" && a.qualityScore == 0.77 && a.sharpness == 321)
        #expect(a.describedBy == "pipeline")                // Foundation Models tillfrågades inte
        #expect(a.featurePrint == nil)                      // lätt analys: ingen feature print
        #expect(a.width == 320 && a.height == 240 && a.meanLuminance != nil)
        // Cachen återanvänds, med pipelinens värden ovanpå.
        var changed = pre; changed.room = "Hall"
        let again = try await ReelImageAnalyzer.analyze(urls: [file], cacheDirectory: root, describe: true, precomputed: [file: changed])
        #expect(again.first?.analysis.room == "Hall" && again.first?.analysis.width == 320)
    }

    @Test("Dubbletter: pipelinens kluster slås ihop till bästa bilden")
    func mergeDuplicates() throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        var items = try ObjektfilmTestKit.realItems(count: 4, in: root)
        for i in items.indices { items[i].analysis.qualityScore = [0.4, 0.9, 0.5, 0.6][i] }
        let groups = [items[0].url: 1, items[1].url: 1, items[2].url: 2]
        let (kept, merged) = ReelProposal.mergeDuplicates(items, groups: groups)
        #expect(merged == 1)
        #expect(kept.map(\.url) == [items[1].url, items[2].url, items[3].url])
    }

    // MARK: Bygge från början till slut

    @Test("Bygge: tre genererade bilder ger reel.json (pipelinens generator) + MP4 + markör, och nästa körning hoppar över")
    func buildEndToEnd() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let enhanced = dir(.enhanced, in: root)
        let files = try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"], in: enhanced)
        AITagsStore.save([
            "DSC_0001": entry(room: "Fasad", category: "Exteriör", description: "Fasadbild"),
            "DSC_0002": entry(room: "Vardagsrum"),
            "DSC_0003": entry(room: "Kök"),
        ], to: root)
        PhotoQualityService.save([
            "DSC_0001": .init(qualityScore: 0.9, isUtility: false, horizonAngleDegrees: nil, sharpness: 500, duplicateGroupID: nil),
            "DSC_0002": .init(qualityScore: 0.8, isUtility: false, horizonAngleDegrees: nil, sharpness: 400, duplicateGroupID: nil),
            "DSC_0003": .init(qualityScore: 0.7, isUtility: false, horizonAngleDegrees: nil, sharpness: 300, duplicateGroupID: nil),
        ], to: root)

        let existing = await ReelProposal.loadExistingData(outputDir: root)
        let plan = await ReelProposal.plan(outputDir: root, folderName: address, existing: existing)
        #expect(plan.action == .build(reason: "nytt förslag"))
        let source = try #require(plan.source)
        #expect(source.kind == .enhanced && source.files.count == files.count)

        // Låg upplösning (108×192, 10 fps) så att testet går fort.
        let small = ReelSpec.Output(id: "vertical", aspect: "9:16", width: 108, height: 192, fps: 10, encoding: nil)
        let result = try await ReelProposal.build(
            source: source, outputDir: root, filmDir: plan.filmDir, folderName: address, existing: existing,
            fingerprint: plan.fingerprint, outputOverride: small)
        #expect(result.fromPipelineData == 3 && result.measured == 0)
        #expect(result.picks.count == result.spec.timeline.count && !result.picks.isEmpty)

        let specURL = plan.filmDir.appendingPathComponent("reel.json")
        let spec = try ReelSpec.decode(from: Data(contentsOf: specURL))
        #expect(spec.provenance.generator.hasPrefix(ReelProposal.generatorPrefix))
        #expect(spec.status == "draft" && spec.revision == 1 && spec.property.address == address)
        #expect(spec.assets.allSatisfy { $0.sources.first?.path?.contains("FÖRBÄTTRADE/") == true })
        // Rum och kvalitet kom ur pipelinens filer.
        let rooms = Set(spec.assets.compactMap { asset in asset.analysis?.room })
        #expect(!rooms.isEmpty && rooms.isSubset(of: ["Fasad", "Vardagsrum", "Kök"]))

        let video = plan.filmDir.appendingPathComponent("reel_9x16.mp4")
        let size = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        #expect(size > 0)
        #expect(ReelProposal.loadMarker(from: plan.filmDir)?.fingerprint == plan.fingerprint)
        #expect(ReelLibrary.filmFolderURLs(in: root).contains { $0.lastPathComponent == "\(address) FILM" })

        // Nästa körning: oförändrat. Efter en redigering: skyddat.
        let second = await ReelProposal.plan(outputDir: root, folderName: address, existing: existing)
        #expect(second.action == .skip(reason: "oförändrat (samma bilder, format och motor)", protected: false))
        var edited = spec
        edited.revision = 2
        try edited.jsonData().write(to: specURL)
        let third = await ReelProposal.plan(outputDir: root, folderName: address, existing: existing, force: true)
        if case .skip(_, let isProtected) = third.action { #expect(isProtected) } else { Issue.record("Redigerad film ska skyddas") }
    }

    // MARK: Steget i pipelinen

    @MainActor
    @Test("Steget: redigerad film rörs inte, Osorterade och adresser utan bilder ger inga filmer")
    func runnerLeavesEditedFilmAlone() async throws {
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = PipelineState()
        state.outputDirectory = root
        let runner = PipelineRunner(state: state)
        let now = Date()
        runner.calendarMappings = [
            (address: address, eventTitle: "a", photoDateRange: now...now.addingTimeInterval(600)),
            (address: "Tom adress 2", eventTitle: "b", photoDateRange: now...now.addingTimeInterval(600)),
        ]
        #expect(runner.reelProposalFolders() == [address, "Tom adress 2"])

        try makeImages(["DSC_0001_enh.jpg", "DSC_0002_enh.jpg", "DSC_0003_enh.jpg"], in: dir(.enhanced, in: root))
        let filmDir = AddressFolderLayout.reelDir(in: root, folderName: address)
        var spec = try composedSpec(in: root, sourceKind: .enhanced, filmDir: filmDir)
        spec.revision = 3
        try write(spec, to: filmDir)
        let before = try Data(contentsOf: filmDir.appendingPathComponent("reel.json"))

        let count = try await runner.runReelProposals()
        #expect(count == 0)
        #expect(try Data(contentsOf: filmDir.appendingPathComponent("reel.json")) == before)
        #expect(!FileManager.default.fileExists(atPath: filmDir.appendingPathComponent("reel_9x16.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: AddressFolderLayout.reelDir(in: root, folderName: "Tom adress 2").path))
        let log = state.stepStatuses[.reelProposal]?.logEntries.map(\.text).joined(separator: "\n") ?? ""
        #expect(log.contains("Filmen har redigerats/skickats — rör den inte"))
        #expect(log.contains("Tom adress 2: hoppar över — inga bilder"))
    }

    @Test("Steget finns i dashboarden, automatiska stegen och har infotext")
    func stepRegistered() {
        #expect(DashboardStep.allCases.contains(.reelProposal))
        #expect(PipelineState.automaticSteps.contains(.reelProposal))
        #expect(DashboardStep.reelProposal.title == "Filmförslag")
        #expect(DashboardStep.reelProposal.manifestKey == "reelProposal")
        #expect(!DashboardStep.reelProposal.info.details.isEmpty)
        let order = PipelineState.automaticSteps
        #expect(order.firstIndex(of: .reelProposal)! > order.firstIndex(of: .writeIPTCTags)!)
    }
}
