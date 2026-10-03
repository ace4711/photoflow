import Foundation
import CryptoKit

/// Pipelinesteget "Filmförslag": ett automatiskt filmförslag (Objektfilm) per adress.
///
/// Det här är ren logik och själva bygget, utan `PipelineRunner`/UI (steget i
/// `PipelineRunner+ReelProposal.swift` anropar det): vilken mapp bilderna hämtas från,
/// om en befintlig film får röras, ett fingerprint som inte påverkas av metadatasteget,
/// analys ur pipelinens egna filer och själva sammansättningen + renderingen.
nonisolated enum ReelProposal {

    /// Höj när något i förslagets logik ändras så att redan byggda förslag görs om.
    static let engineVersion = 1
    static let generatorPrefix = "PhotoFlow Filmförslag (pipeline) v\(engineVersion)"
    /// Står i `provenance.generator`: visar att `reel.json` är ett automatiskt förslag från pipelinen.
    static var generator: String { "\(generatorPrefix) / \(ReelComposer.generator)" }
    /// Fingerprint + källa för det senast byggda förslaget (skrivs först när renderingen lyckats).
    static let markerFileName = "reel_proposal.json"
    static let minimumImages = 3
    static let defaultCount = 5
    static let defaultFormat = ReelFormat.vertical

    static func videoFileName(for format: ReelFormat) -> String {
        "reel_\(format.output.aspect.replacingOccurrences(of: ":", with: "x")).mp4"
    }

    // MARK: - Källa

    /// Var bilderna hämtas. `rank`: högre är bättre källa.
    nonisolated enum SourceKind: String, Codable, Sendable, CaseIterable {
        case preview, enhanced, finished

        var rank: Int {
            switch self {
            case .preview: return 0
            case .enhanced: return 1
            case .finished: return 2
            }
        }

        /// Mappnamnets del efter adressen.
        var label: String {
            switch self {
            case .finished: return "FÄRDIGA"
            case .enhanced: return "FÖRBÄTTRADE"
            case .preview: return "TITTBILDER"
            }
        }

        func directory(in outputDir: URL, folderName: String) -> URL {
            switch self {
            case .finished: return AddressFolderLayout.finishedDir(in: outputDir, folderName: folderName)
            case .enhanced: return AddressFolderLayout.enhancedDir(in: outputDir, folderName: folderName)
            case .preview: return AddressFolderLayout.previewDir(in: outputDir, folderName: folderName)
            }
        }
    }

    nonisolated struct Source: Sendable, Equatable {
        var kind: SourceKind
        var directory: URL
        var files: [URL]
    }

    private static let finishedExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]

    /// Bildfilerna i en källmapp (sorterade). FÖRBÄTTRADE: bara `_enh.jpg` (TIFF:en är för stor
    /// för filmen). TITTBILDER: JPEG, utan exponeringarna i de bracketgrupper som har en HDR-JPEG
    /// i samma mapp (annars kommer samma motiv med både mörk, ljus och HDR-version).
    static func images(of kind: SourceKind, in directory: URL, existing: ExistingData = ExistingData()) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var files: [URL]
        switch kind {
        case .finished:
            files = entries.filter { finishedExtensions.contains($0.pathExtension.lowercased()) }
        case .enhanced:
            files = entries.filter {
                ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
                    && $0.deletingPathExtension().lastPathComponent.hasSuffix(AddressFolderLayout.enhancedFileSuffix)
            }
        case .preview:
            files = entries.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            var covered = Set<String>()
            for url in files {
                let stem = url.deletingPathExtension().lastPathComponent
                guard stem.hasPrefix("hdr_group_"), let id = Int(stem.dropFirst("hdr_group_".count)),
                      existing.bracketGroupIDs.contains(id) else { continue }
                covered.formUnion(existing.groupMembers[id] ?? [])
            }
            files.removeAll { covered.contains($0.deletingPathExtension().lastPathComponent) }
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Källa i prioritetsordning FÄRDIGA > FÖRBÄTTRADE > TITTBILDER: den första mapp som har minst
    /// `minimumImages` bilder. Nil om ingen räcker (`found` säger då hur många bilder bästa mappen hade).
    static func selectSource(outputDir: URL, folderName: String, existing: ExistingData = ExistingData())
        -> (source: Source?, counts: [SourceKind: Int]) {
        var counts: [SourceKind: Int] = [:]
        for kind in [SourceKind.finished, .enhanced, .preview] {
            let dir = kind.directory(in: outputDir, folderName: folderName)
            let files = images(of: kind, in: dir, existing: existing)
            counts[kind] = files.count
            if files.count >= minimumImages { return (Source(kind: kind, directory: dir, files: files), counts) }
        }
        return (nil, counts)
    }

    /// Bildens nyckel i pipelinens filer: filnamnet utan ändelse och utan `_enh`
    /// (`DSC_1758_enh.jpg` → `DSC_1758`, `hdr_group_134.jpg` → `hdr_group_134`).
    static func key(forFile url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(AddressFolderLayout.enhancedFileSuffix) { stem = String(stem.dropLast(AddressFolderLayout.enhancedFileSuffix.count)) }
        return stem
    }

    // MARK: - Pipelinens befintliga data

    /// Det pipelinen redan vet om bilderna: Vision-taggar/rum (`ai_tags.json`), kvalitet
    /// (`photo_quality.json`), bracketgrupper (`bracket_groups.json`) och förbättringsloggen
    /// (`enhancement.json`, för fingerprintet). Allt nycklat på bildens basnamn (`DSC_xxxx`).
    nonisolated struct ExistingData: Sendable {
        var tags: [String: AITagsStore.Entry] = [:]
        var quality: [String: PhotoQualityService.Result] = [:]
        /// Grupp-id → bildnycklar (NEF-basnamn) i gruppen.
        var groupMembers: [Int: [String]] = [:]
        /// Grupper med flera exponeringar (de som får en `hdr_group_<id>`).
        var bracketGroupIDs: Set<Int> = []
        var enhancement: EnhancementLog?

        init() {}

        init(tags: [String: AITagsStore.Entry], quality: [String: PhotoQualityService.Result],
             groupMembers: [Int: [String]], bracketGroupIDs: Set<Int>, enhancement: EnhancementLog? = nil) {
            self.tags = tags
            self.quality = quality
            self.groupMembers = groupMembers
            self.bracketGroupIDs = bracketGroupIDs
            self.enhancement = enhancement
        }

        static func load(from outputDir: URL) -> ExistingData {
            var data = ExistingData()
            data.tags = AITagsStore.load(from: outputDir) ?? [:]
            data.quality = PhotoQualityService.load(from: outputDir) ?? [:]
            data.enhancement = EnhancementLog.load(from: outputDir)
            let file = outputDir.appendingPathComponent("bracket_groups.json")
            if let raw = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let groups = json["groups"] as? [[String: Any]] {
                for group in groups {
                    guard let id = group["group_id"] as? Int, let files = group["files"] as? [String] else { continue }
                    data.groupMembers[id] = files.map { ($0 as NSString).deletingPathExtension }
                    if group["is_bracket"] as? Bool == true { data.bracketGroupIDs.insert(id) }
                }
            }
            return data
        }

        /// Bildnycklarna som ligger bakom en nyckel: `hdr_group_<id>` är gruppens alla bilder.
        func members(ofKey key: String) -> [String] {
            if key.hasPrefix("hdr_group_"), let id = Int(key.dropFirst("hdr_group_".count)) {
                return groupMembers[id] ?? []
            }
            return [key]
        }

        /// Pipelinens värden för en bild. För en HDR-grupp: bästa/representativa värdet över
        /// gruppens bilder (högsta kvalitet och skärpa; rum och kategori som flest bilder är
        /// överens om; horisont från den bästa bilden). Nil när varken taggar eller kvalitet finns.
        func precomputed(forKey key: String) -> ReelImageAnalyzer.Precomputed? {
            typealias Member = (tags: AITagsStore.Entry?, quality: PhotoQualityService.Result?)
            var members: [Member] = self.members(ofKey: key)
                .map { (tags[$0], quality[$0]) }
                .filter { $0.tags != nil || $0.quality != nil }
            guard !members.isEmpty else { return nil }
            // Bästa bilden först, så att oavgjorda val följer den.
            members.sort { ($0.quality?.qualityScore ?? -1) > ($1.quality?.qualityScore ?? -1) }
            let qualities = members.compactMap(\.quality)

            var pre = ReelImageAnalyzer.Precomputed()
            pre.qualityScore = qualities.compactMap(\.qualityScore).max()
            pre.sharpness = qualities.compactMap(\.sharpness).max()
            pre.isUtility = !qualities.isEmpty && qualities.allSatisfy(\.isUtility)
            pre.horizonAngleDegrees = qualities.first(where: { $0.horizonAngleDegrees != nil })?.horizonAngleDegrees
            pre.duplicateGroupID = members.first?.quality?.duplicateGroupID
            pre.room = Self.mostCommon(members.compactMap { $0.tags.flatMap(Self.roomName(of:)) })
            pre.category = Self.mostCommon(members.compactMap { $0.tags.flatMap(Self.categoryName(of:)) })
            var features: [String] = []
            for entry in members.compactMap(\.tags) {
                for f in Self.features(of: entry) where !features.contains(f) { features.append(f) }
            }
            pre.features = features.isEmpty ? nil : features
            pre.caption = members.compactMap { $0.tags.flatMap(Self.caption(of:)) }.first
            return pre
        }

        private static func mostCommon(_ values: [String]) -> String? {
            var counts: [String: Int] = [:]
            for v in values { counts[v, default: 0] += 1 }
            guard let top = counts.values.max() else { return nil }
            // Första i listan (bästa bilden) bland de som är lika vanliga.
            return values.first { counts[$0] == top }
        }

        private static let knownRooms = ["Kök", "Badrum", "Sovrum", "Vardagsrum", "Matplats", "Tvättstuga", "Kontor",
                                         "Barnrum", "Hall", "Entré", "Trappa", "Fasad", "Trädgård", "Tomt", "Balkong",
                                         "Uteplats", "Terrass", "Altan", "Veranda", "Pool", "Garage", "Utsikt"]
        private static let knownFeatures = ["Öppen spis", "Bastu", "Balkong", "Uteplats", "Terrass", "Altan", "Pool", "Trädgård"]

        /// Rummet/motivet: Foundation Models-rummet om det finns, annars pipelinens egen slutsats
        /// (början av `description`: "Kök med öppen spis" → "Kök"), annars första kända rumstaggen.
        static func roomName(of entry: AITagsStore.Entry) -> String? {
            if let room = entry.mlRoom?.trimmingCharacters(in: .whitespaces), !room.isEmpty { return room }
            let head = entry.description.components(separatedBy: " med ").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !head.isEmpty, !["Interiör", "Exteriör"].contains(head) { return head }
            return entry.tags.first { knownRooms.contains($0) }
        }

        static func categoryName(of entry: AITagsStore.Entry) -> String? {
            let value = (entry.mlCategory ?? entry.category).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        static func features(of entry: AITagsStore.Entry) -> [String] {
            entry.mlFeatures ?? entry.tags.filter { knownFeatures.contains($0) }
        }

        static func caption(of entry: AITagsStore.Entry) -> String? {
            if let c = entry.mlCaption, !c.isEmpty { return c }
            return entry.description.isEmpty ? nil : entry.description
        }
    }

    // MARK: - Fingerprint

    /// Fingerprint för ett förslag: källans bilder, format, antal bilder och motorversioner.
    ///
    /// Får inte bero på något som metadatasteget skriver om (storlek/ändringstid på
    /// FÖRBÄTTRADE/TITTBILDER): de bilderna identifieras av original-NEF:erna (namn + storlek, skrivs
    /// aldrig till) och, för FÖRBÄTTRADE, förbättringsloggens fingerprint per bild (profil + motor).
    /// FÄRDIGA skrivs inte om av pipelinen (Lightroom-exporter), så de identifieras av namn och
    /// SHA-256 av innehållet.
    static func fingerprint(source: Source, existing: ExistingData, nefSizes: [String: Int64] = [:],
                            count: Int, format: ReelFormat) -> String {
        var lines = [
            "engine=\(engineVersion)", "generator=\(ReelComposer.generator)",
            "format=\(format.rawValue)", "count=\(count)", "source=\(source.kind.rawValue)",
        ]
        for file in source.files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            switch source.kind {
            case .finished:
                lines.append("\(name):\(ReelImageAnalyzer.sha256Hex(of: file) ?? "okänd")")
            case .enhanced, .preview:
                let key = key(forFile: file)
                let members = existing.members(ofKey: key).sorted().map { member -> String in
                    let size = nefSizes[member.lowercased()].map { "\($0)" } ?? "-"
                    return "\(member)=\(size)"
                }
                var line = "\(name):\(members.isEmpty ? key : members.joined(separator: ","))"
                if source.kind == .enhanced, let entry = existing.enhancement?.entries[key] {
                    line += ":enh=\(entry.fingerprint)"
                }
                lines.append(line)
            }
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Storlekarna på original-NEF:erna (nyckel = basnamn i gemener) via symlänkarna i
    /// `<adress> ÖVRIGA/`. Original som saknas (kort/inputmapp borta) räknas inte med.
    static func nefSizes(outputDir: URL, folderName: String) -> [String: Int64] {
        let dir = AddressFolderLayout.extrasDir(in: outputDir, folderName: folderName)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var sizes: [String: Int64] = [:]
        for url in entries where url.pathExtension.lowercased() == "nef" {
            let resolved = url.resolvingSymlinksInPath()
            if let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.size] as? NSNumber)?.int64Value {
                sizes[url.deletingPathExtension().lastPathComponent.lowercased()] = size
            }
        }
        return sizes
    }

    // MARK: - Skydd av användarens arbete

    nonisolated struct Marker: Codable, Sendable, Equatable {
        var version: Int
        var fingerprint: String
        var source: SourceKind
        var specID: String
        var generatedAt: Date
    }

    static func loadMarker(from filmDir: URL) -> Marker? {
        guard let data = try? Data(contentsOf: filmDir.appendingPathComponent(markerFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    static func saveMarker(_ marker: Marker, to filmDir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(marker) else { return }
        try? data.write(to: filmDir.appendingPathComponent(markerFileName), options: .atomic)
    }

    /// Läget för filmen som redan ligger i FILM-mappen.
    nonisolated enum ExistingFilm: Sendable, Equatable {
        case none
        /// Ett oredigerat automatiskt förslag från pipelinen: får ersättas.
        case replaceable(builtOn: SourceKind?, fingerprint: String?, hasVideo: Bool)
        /// Användarens arbete (redigerad, skickad eller skapad utanför pipelinen): rörs aldrig.
        case protected(reason: String)
    }

    static let protectedMessage = "Filmen har redigerats/skickats — rör den inte"

    /// Avgör om en befintlig film får ersättas. Skyddad om: `reel-remote.json` finns (skickad till
    /// mäklare), `reel.json` inte går att läsa, `revision > 1`, status annan än draft, redigeringar i
    /// `provenance.edits`, eller filmen inte är byggd av pipelinen (användaren skapade den själv).
    static func inspectExisting(filmDir: URL, format: ReelFormat = defaultFormat) -> ExistingFilm {
        let fm = FileManager.default
        let specURL = filmDir.appendingPathComponent(ReelLibrary.specFileName)
        let videoURL = filmDir.appendingPathComponent(videoFileName(for: format))

        if fm.fileExists(atPath: filmDir.appendingPathComponent(ReelRemoteState.fileName).path) {
            return .protected(reason: "skickad till mäklare (reel-remote.json finns)")
        }
        guard fm.fileExists(atPath: specURL.path) else {
            // En MP4 utan reel.json är inte vår: skriv inte över den.
            if fm.fileExists(atPath: videoURL.path) { return .protected(reason: "\(videoURL.lastPathComponent) finns utan reel.json") }
            return .none
        }
        guard let data = try? Data(contentsOf: specURL), let spec = try? ReelSpec.decode(from: data), spec.isReadable else {
            return .protected(reason: "reel.json går inte att läsa")
        }
        if spec.revision > 1 { return .protected(reason: "redigerad (revision \(spec.revision))") }
        if spec.status != "draft" { return .protected(reason: "status \"\(spec.status)\"") }
        if let edits = spec.provenance.edits, !edits.isEmpty { return .protected(reason: "redigerad (\(edits.count) ändringar)") }
        if !spec.provenance.generator.hasPrefix(generatorPrefix) {
            return .protected(reason: "skapad utanför pipelinen (\(spec.provenance.generator))")
        }

        let paths = spec.assets.flatMap { $0.sources.compactMap(\.path) }
        let builtOn: SourceKind? = SourceKind.allCases.first { kind in
            paths.contains { $0.contains("\(kind.label)/") }
        }
        let marker = loadMarker(from: filmDir)
        let fingerprint = marker?.specID == spec.id ? marker?.fingerprint : nil
        return .replaceable(builtOn: builtOn, fingerprint: fingerprint, hasVideo: fm.fileExists(atPath: videoURL.path))
    }

    nonisolated enum Action: Sendable, Equatable {
        case build(reason: String)
        case skip(reason: String, protected: Bool)
    }

    /// Bygga eller hoppa över. `force` (steget körs om manuellt) hoppar över fingerprintkontrollen
    /// men aldrig skyddet.
    static func decide(existing: ExistingFilm, source: SourceKind, fingerprint: String, force: Bool = false) -> Action {
        switch existing {
        case .none:
            return .build(reason: "nytt förslag")
        case .protected(let reason):
            return .skip(reason: "\(protectedMessage) (\(reason))", protected: true)
        case .replaceable(let builtOn, let known, let hasVideo):
            if let builtOn, builtOn.rank > source.rank {
                return .skip(reason: "förslaget bygger på bättre källa (\(builtOn.label)) än \(source.label)", protected: false)
            }
            if let builtOn, builtOn.rank < source.rank {
                return .build(reason: "bättre källa (\(source.label) ersätter förslag på \(builtOn.label))")
            }
            if !force, hasVideo, known == fingerprint {
                return .skip(reason: "oförändrat (samma bilder, format och motor)", protected: false)
            }
            return .build(reason: known == nil ? "förslaget saknar fingerprint" : (known == fingerprint ? "körs om" : "bilderna har ändrats"))
        }
    }

    // MARK: - Planering

    nonisolated struct Plan: Sendable {
        var folderName: String
        var filmDir: URL
        /// Nil när ingen källmapp har minst `minimumImages` bilder.
        var source: Source?
        var fingerprint: String
        var action: Action
    }

    /// Läser pipelinens data en gång för hela steget (utanför huvudtråden).
    @concurrent
    static func loadExistingData(outputDir: URL) async -> ExistingData {
        ExistingData.load(from: outputDir)
    }

    /// Väljer källa, räknar fingerprint och avgör om förslaget ska byggas för en adress. Hashar
    /// FÄRDIGA-bilderna, så det körs utanför huvudtråden.
    @concurrent
    static func plan(outputDir: URL, folderName: String, existing: ExistingData, count: Int = defaultCount,
                     format: ReelFormat = defaultFormat, force: Bool = false) async -> Plan {
        let filmDir = AddressFolderLayout.reelDir(in: outputDir, folderName: folderName)
        let (source, counts) = selectSource(outputDir: outputDir, folderName: folderName, existing: existing)
        guard let source else {
            let found = SourceKind.allCases.sorted { $0.rank > $1.rank }
                .map { "\($0.label) \(counts[$0] ?? 0)" }.joined(separator: ", ")
            let reason = counts.values.allSatisfy { $0 == 0 }
                ? "inga bilder (ingen FÄRDIGA-, FÖRBÄTTRADE- eller TITTBILDER-mapp med bilder)"
                : "färre än \(minimumImages) bilder (\(found))"
            return Plan(folderName: folderName, filmDir: filmDir, source: nil, fingerprint: "",
                        action: .skip(reason: reason, protected: false))
        }
        let fingerprint = fingerprint(source: source, existing: existing,
                                      nefSizes: nefSizes(outputDir: outputDir, folderName: folderName),
                                      count: count, format: format)
        let action = decide(existing: inspectExisting(filmDir: filmDir, format: format), source: source.kind,
                            fingerprint: fingerprint, force: force)
        return Plan(folderName: folderName, filmDir: filmDir, source: source, fingerprint: fingerprint, action: action)
    }

    // MARK: - Bygge

    nonisolated enum Stage: Sendable {
        case analyzing(done: Int, total: Int)
        case rendering(fraction: Double)
    }

    nonisolated struct Pick: Sendable, Equatable {
        var slot: String
        var file: String
        var reason: String
    }

    nonisolated struct BuildResult: Sendable {
        var spec: ReelSpec
        var picks: [Pick]
        var excluded: [String]
        var videoURL: URL
        var duration: Double
        var fileBytes: Int
        var analysisSeconds: Double
        var renderSeconds: Double
        /// Bilder som analyserades ur pipelinens data (lätt analys) respektive mättes fullt.
        var fromPipelineData: Int
        var measured: Int
        var mergedDuplicates: Int
    }

    nonisolated enum BuildError: LocalizedError {
        case tooFewImages(Int)
        var errorDescription: String? {
            switch self {
            case .tooFewImages(let n): return "Bara \(n) användbara bilder (minst \(ReelProposal.minimumImages) krävs)"
            }
        }
    }

    /// Slår ihop nästan-lika bilder enligt pipelinens dubblettkluster (`duplicateGroupID`): bästa
    /// bilden i varje kluster behålls. Ersätter feature print-jämförelsen som den lätta analysen hoppar över.
    static func mergeDuplicates(_ items: [ReelImageAnalyzer.Item], groups: [URL: Int]) -> (kept: [ReelImageAnalyzer.Item], merged: Int) {
        var best: [Int: ReelImageAnalyzer.Item] = [:]
        for item in items {
            guard let g = groups[item.url] else { continue }
            if let current = best[g] {
                if (item.analysis.qualityScore ?? -1) > (current.analysis.qualityScore ?? -1) { best[g] = item }
            } else {
                best[g] = item
            }
        }
        let kept = items.filter { item in
            guard let g = groups[item.url] else { return true }
            return best[g]?.url == item.url
        }
        return (kept, items.count - kept.count)
    }

    /// Analyserar, väljer, skriver `reel.json` och renderar MP4:n i `filmDir`. Tungt arbete körs
    /// utanför huvudtråden. Markören (`reel_proposal.json`) skrivs först när renderingen lyckats, så
    /// ett avbrutet bygge görs om vid nästa körning. `outputOverride` byter utdataformat (tester:
    /// liten upplösning).
    @concurrent
    static func build(
        source: Source,
        outputDir: URL,
        filmDir: URL,
        folderName: String,
        existing: ExistingData,
        fingerprint: String,
        count: Int = defaultCount,
        format: ReelFormat = defaultFormat,
        outputOverride: ReelSpec.Output? = nil,
        describe: Bool = false,
        progress: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> BuildResult {
        try FileManager.default.createDirectory(at: filmDir, withIntermediateDirectories: true)
        // Mappen måste vara en katalog-URL: `appendingPathComponent` på en mapp som inte fanns än ger
        // en URL utan avslutande snedstreck, och renderaren löser då "../<källa>/bild.jpg" en nivå för högt.
        let filmDir = URL(fileURLWithPath: filmDir.path, isDirectory: true)

        // Analys: pipelinens data där nyckeln går att härleda, annars full analys som vanligt.
        var precomputed: [URL: ReelImageAnalyzer.Precomputed] = [:]
        for file in source.files {
            if let pre = existing.precomputed(forKey: key(forFile: file)), pre.hasData { precomputed[file] = pre }
        }
        let analysisStart = Date()
        let analyzed = try await ReelImageAnalyzer.analyze(
            urls: source.files, cacheDirectory: filmDir, aiTagsDirectory: outputDir, describe: describe,
            precomputed: precomputed, progress: { done, total in progress(.analyzing(done: done, total: total)) })
        let analysisSeconds = Date().timeIntervalSince(analysisStart)
        try Task.checkCancellation()

        let groups = precomputed.compactMapValues(\.duplicateGroupID)
        let (items, merged) = mergeDuplicates(analyzed, groups: groups)
        guard items.count >= minimumImages else { throw BuildError.tooFewImages(items.count) }

        var options = ReelComposer.Options()
        options.count = count
        options.format = format
        options.address = folderName
        let composed = ReelComposer.compose(items: items, specDirectory: filmDir, options: options)
        var spec = composed.spec
        spec.provenance.generator = generator
        if let outputOverride { spec.outputs = [outputOverride] }
        let output = spec.outputs.first ?? format.output
        let total = ReelTimeline.totalDuration(spec)

        let specURL = filmDir.appendingPathComponent(ReelLibrary.specFileName)
        try spec.jsonData().write(to: specURL, options: .atomic)

        let videoURL = filmDir.appendingPathComponent(videoFileName(for: format))
        let renderStart = Date()
        try await ReelRenderer.export(spec: spec, specDirectory: filmDir, output: output, to: videoURL) { fraction in
            progress(.rendering(fraction: fraction))
        }
        let renderSeconds = Date().timeIntervalSince(renderStart)
        try Task.checkCancellation()

        saveMarker(Marker(version: engineVersion, fingerprint: fingerprint, source: source.kind, specID: spec.id,
                          generatedAt: Date()), to: filmDir)

        let names = Dictionary(uniqueKeysWithValues: spec.assets.map {
            ($0.id, $0.sources.first?.path.map { ($0 as NSString).lastPathComponent } ?? $0.id)
        })
        let picks = (spec.provenance.autoSelection ?? []).map {
            Pick(slot: ReelSelector.Slot(rawValue: $0.slot)?.label ?? $0.slot, file: names[$0.asset] ?? $0.asset, reason: $0.reason)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        return BuildResult(
            spec: spec, picks: picks, excluded: composed.selection.excluded.map(\.reason), videoURL: videoURL,
            duration: total, fileBytes: size, analysisSeconds: analysisSeconds, renderSeconds: renderSeconds,
            fromPipelineData: precomputed.count, measured: source.files.count - precomputed.count, mergedDuplicates: merged)
    }
}
