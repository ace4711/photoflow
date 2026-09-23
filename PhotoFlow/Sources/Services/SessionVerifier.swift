import Foundation

/// "Verifiera session" (se `FORBATTRINGAR.md`): en ren, testbar kontroll av
/// EN sessions outputmapp, byggd för att systematiskt fånga precis den typ av
/// fel som hittades manuellt en natt när HDR-resultat blev kvar i `hdr/` utan
/// att flyttas till en adressmapp (se `PipelineRunnerHDROrphanTests` — den
/// specifika buggen är sedan fixad, men ingenting körde motsvarande kontroll
/// automatiskt EFTER en lyckad körning för att upptäcka om samma sak hände av
/// någon annan anledning, t.ex. en trasig symlänk efter manuell städning).
///
/// Härleder alla förväntningar direkt ur samma format-kontrakt som
/// `Services/Pipeline/*`/`AddressFolderLayout`/`BracketAnalyzer` redan
/// använder — se dessa filers kommentarer för själva formatet. Läser ALDRIG
/// via `SessionManifestStore.loadOrMigrate` (som skriver ett nytt manifest
/// till disk om inget finns) — en verifiering får aldrig ha sidoeffekter,
/// bara `SessionManifestStore.load`.
///
/// `verify`/`loadContext` körs på `MainActor` (projektets default —
/// `SessionManifestStore.load`/`DashboardStep.title`/`.manifestKey` är alla
/// själva `MainActor`-isolerade av samma skäl, se deras egna kommentarer),
/// men läser ALLT en kontroll behöver in i en ren `Sendable`-`Context`
/// FÖRE `TaskGroup`:en startas. De sex `check*`-funktionerna nedan är
/// explicit `nonisolated` (samma mönster som `PhotoQualityService`/
/// `HDREngine`) och anropas via `await safely(...)` — det `await`:et hoppar
/// faktiskt av `MainActor` för kontrollens hela körtid (inklusive dess
/// `exiftool`-anrop), så de körs parallellt på det globala
/// concurrency-trådpoolen i stället för att seriealiseras på UI-tråden. Ett
/// enskilt fel i EN kontroll fångas i `safely(_:_:)` och blir bara ett
/// `.error`-fynd istället för att stoppa hela verifieringen (uppdragets krav).
enum SessionVerifier {

    // MARK: - Resultat

    enum Severity: String, Codable, Sendable, Comparable {
        case error, warning, ok

        /// Visningsordning: fel → varningar → OK.
        private var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .ok: return 2
            }
        }
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    struct Finding: Codable, Sendable, Identifiable, Hashable {
        /// Stabil nyckel (t.ex. `"symlinks.broken"`), inte visad i UI — gör
        /// fynden testbara utan att bero på den svenska texten, och ger en
        /// deterministisk sorteringsordning inom samma allvarlighetsgrad.
        var id: String
        var severity: Severity
        var title: String
        var detail: String
        /// Vad man gör åt det. `nil` för OK-fynd (kräver ingen åtgärd).
        var recommendation: String?
        /// Absoluta sökvägar till berörda filer, om relevant. Kan vara tom
        /// även för ett fel (t.ex. "manifestet saknas helt").
        var affectedFiles: [String] = []
    }

    struct Report: Codable, Sendable {
        var outputDirectory: String
        var generatedAt: Date
        var findings: [Finding]

        var errorCount: Int { findings.filter { $0.severity == .error }.count }
        var warningCount: Int { findings.filter { $0.severity == .warning }.count }
        var okCount: Int { findings.filter { $0.severity == .ok }.count }

        /// "3 fel, 5 varningar, 14 kontroller OK" — se `SessionVerifyView`.
        var summaryText: String {
            "\(errorCount) fel, \(warningCount) varningar, \(okCount) kontroller OK"
        }

        /// Findings grupperade och sorterade för visning: fel → varningar →
        /// OK, och inom samma allvarlighetsgrad efter stabil `id` (annars
        /// skulle ordningen variera mellan körningar beroende på vilken
        /// `TaskGroup`-tasks som råkade bli klar först).
        var sortedFindings: [Finding] {
            findings.sorted {
                $0.severity == $1.severity ? $0.id < $1.id : $0.severity < $1.severity
            }
        }

        /// Ren textrapport för urklipp (`SessionVerifyView`s "Kopiera"-knapp)
        /// och `photoflow-cli verify` (icke-JSON-läget).
        func asPlainText() -> String {
            var lines = [
                "PhotoFlow — sessionsverifiering",
                outputDirectory,
                summaryText,
                ""
            ]
            for finding in sortedFindings {
                let marker: String
                switch finding.severity {
                case .error: marker = "FEL"
                case .warning: marker = "VARNING"
                case .ok: marker = "OK"
                }
                lines.append("[\(marker)] \(finding.title)")
                lines.append("  \(finding.detail)")
                if let recommendation = finding.recommendation {
                    lines.append("  Åtgärd: \(recommendation)")
                }
                if !finding.affectedFiles.isEmpty {
                    for file in finding.affectedFiles.prefix(20) {
                        lines.append("    - \(file)")
                    }
                    if finding.affectedFiles.count > 20 {
                        lines.append("    ... och \(finding.affectedFiles.count - 20) till")
                    }
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Verify

    /// Kör alla kontroller mot `outputDir` och returnerar en samlad rapport.
    /// `exiftoolPath` går att peka om i tester (se `SessionVerifierTests`) —
    /// standard är `ToolLocator.exiftool` (samma sökväg pipelinen använder).
    static func verify(outputDir: URL, exiftoolPath: String? = ToolLocator.exiftool) async throws -> Report {
        try Task.checkCancellation()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue else {
            return Report(outputDirectory: outputDir.path, generatedAt: Date(), findings: [
                Finding(
                    id: "output.missing", severity: .error,
                    title: "Outputmappen finns inte",
                    detail: "\"\(outputDir.path)\" hittades inte på disk.",
                    recommendation: "Kontrollera sökvägen, eller ta bort sessionen ur historiken om mappen är borttagen/flyttad."
                )
            ])
        }

        let context = loadContext(outputDir: outputDir)
        try Task.checkCancellation()

        var findings: [Finding] = []
        try await withThrowingTaskGroup(of: [Finding].self) { group in
            group.addTask { await safely("symlinks") { checkSymlinks(context: context) } }
            group.addTask { await safely("coverage") { checkCoverage(context: context) } }
            group.addTask { await safely("orphans") { checkOrphans(context: context) } }
            group.addTask { await safely("metadata") { checkMetadataSample(context: context, exiftoolPath: exiftoolPath) } }
            group.addTask { await safely("culling") { checkCulling(context: context, exiftoolPath: exiftoolPath) } }
            group.addTask { await safely("manifest") { checkManifest(context: context) } }

            for try await result in group {
                try Task.checkCancellation()
                findings.append(contentsOf: result)
            }
        }

        return Report(outputDirectory: outputDir.path, generatedAt: Date(), findings: findings)
    }

    /// Kör en kontroll och konverterar ett oväntat `throw` till ett `.error`-
    /// fynd istället för att låta det stoppa hela verifieringen (uppdragets
    /// krav: "låt aldrig ett enskilt fel stoppa hela verifieringen"). Alla
    /// kontroller nedan är i praktiken redan skrivna med `try?`/valfria
    /// bindningar och kastar inte — det här är ett skyddsnät för framtida
    /// kod, inte den normala vägen.
    /// `nonisolated` + `async`: the `await` at each call site hops off
    /// `MainActor` for `body()`'s entire (synchronous) duration, which is
    /// what actually makes the six checks in `verify()`'s `TaskGroup` run in
    /// parallel off the main thread — see this file's top comment.
    private static nonisolated func safely(_ name: String, _ body: @Sendable () throws -> [Finding]) async -> [Finding] {
        do {
            return try body()
        } catch {
            return [Finding(
                id: "\(name).internalError", severity: .error,
                title: "Internt fel vid kontroll (\(name))",
                detail: "\(error.localizedDescription)",
                recommendation: "Rapportera detta som en bugg — verifieringen kunde inte slutföra kontrollen."
            )]
        }
    }

    // MARK: - Context: allt kontrollerna behöver, inläst en gång

    /// Vilken typ av adressundermapp en symlänk ligger i, se
    /// `AddressFolderLayout`. `.dng` täcker BÅDE den suffixlösa
    /// adressmappen (DNG-symlänkar) och toppnivåfall som inte matchar något
    /// av de andra två — dvs den "vanliga" adressmappen.
    // `nonisolated`: this enum's compiler-synthesized `Equatable` conformance
    // would otherwise default to `MainActor` (like everything else in this
    // file) and couldn't be used from the `nonisolated` `check*` functions
    // below that compare `.role == .extras` etc.
    private nonisolated enum FolderRole { case preview, extras, dng }

    /// En fil i en adressmapp — vanligtvis en symlänk som
    /// `exportToAddressFolders` skapat, men INTE alltid: en session som
    /// kopierats/arkiverats (Finder-kopiering, zip, molnsynk, ...) får ofta
    /// sina symlänkar upplösta till vanliga filkopior av verktyget som
    /// kopierade den — verifierat mot en riktig session i `/Users/fredrik/
    /// Desktop/lint/OUTPUT` där hela adressträdet bestod av vanliga filer,
    /// inte symlänkar (se FORBATTRINGAR.md, "Verifiera session"). Täcknings-
    /// kontrollerna (`checkCoverage`) räknar BÅDA som giltig täckning — det
    /// som spelar roll för mäklaren är att bildfilen finns där, inte
    /// mekanismen. Bara `checkSymlinks` (brutna länkar) bryr sig om
    /// `isSymlink`, eftersom bara en symlänk kan vara "bruten".
    private struct AddressFileEntry: Sendable {
        let url: URL
        /// `deletingPathExtension().lastPathComponent` — exakt skiftläge,
        /// samma jämförelse som `PipelineRunner.cullCandidates` använder.
        let basename: String
        /// Lowercased, utan punkt.
        let ext: String
        let role: FolderRole
        /// `true` om filen ligger under en "Gallrade"-undermapp (se
        /// `PipelineRunner+Culling.moveRejectedToFolder`).
        let isInGallrade: Bool
        let isSymlink: Bool
        /// `true` om en SYMLÄNKS mål inte längre finns på disk. Alltid
        /// `false` för en vanlig fil (den kan per definition inte vara
        /// "bruten" på samma sätt).
        let isBroken: Bool
    }

    private struct CalendarMatch: Sendable {
        let address: String
        let eventTitle: String
        let start: Date
        let end: Date
    }

    /// Bara de fält en verifiering faktiskt behöver ur en `bracket_groups.
    /// json`-grupp. Läst via `JSONSerialization` + tillåtande optional-
    /// bindningar (samma mönster som `AddressSessionLoader`/`PipelineRunner+
    /// LoadSession`) i stället för `BracketGroupResult`s strikta `Decodable`
    /// — en riktig session verifierades mot under utveckling av den här
    /// funktionen och hade en `bracket_groups.json` UTAN ett `"params"`-fält
    /// (skriven av en äldre appversion, innan det fältet fanns), vilket fick
    /// en strikt `Codable`-avkodning av HELA filen att misslyckas och
    /// felaktigt rapportera "bracket_groups.json saknas" för en fil som
    /// faktiskt fanns och gick att läsa ut bilderna ur. Se
    /// `FORBATTRINGAR.md`, "Verifiera session", för den skarpa körningen som
    /// hittade detta.
    private struct GroupInfo: Sendable {
        let files: [String]
        let datetimes: [String]
        let dateStart: String
    }

    private struct Context: Sendable {
        let outputDir: URL
        let dngDir: URL
        let previewDir: URL
        let hdrDir: URL

        let bracketGroupsExists: Bool
        let groups: [GroupInfo]

        let cullDecisionsExists: Bool
        /// photoId ("groupId_filename.NEF") -> "accepted"/"rejected".
        let cullDecisions: [String: String]

        let calendarMatches: [CalendarMatch]

        let manifest: SessionManifest?

        let addressFiles: [AddressFileEntry]

        /// Alla NEF-basnamn (utan ".NEF") över samtliga grupper, i den ordning
        /// `bracket_groups.json` listar dem. Tom om filen saknas/inte gick att
        /// tolka. Beräknad EN gång i `loadContext` (i stället för en
        /// computed property) — bara för att `Context` ska förbli en ren
        /// datastruktur utan några medlemmar som skulle behöva egen
        /// `nonisolated`-markering.
        let nefBaseNames: [String]
    }

    private static func loadContext(outputDir rawOutputDir: URL) -> Context {
        // Resolved once here (see `FileSafety.resolvedPath`'s doc comment) so
        // `dngDir`/`previewDir`/`hdrDir` below share the same symlink-
        // resolution basis as the `AddressFileEntry.url`s `collectAddressFiles`
        // gets back from `FileManager` enumeration — needed for
        // `repairBrokenLinks`'s relative-path arithmetic to come out clean
        // (reproducible under `/tmp`/`/var`, both symlinks on macOS).
        let outputDir = FileSafety.resolvedPath(rawOutputDir)
        let fm = FileManager.default
        let dngDir = outputDir.appendingPathComponent("dng")
        let previewDir = outputDir.appendingPathComponent("previews")
        let hdrDir = outputDir.appendingPathComponent("hdr")

        // bracket_groups.json — se `GroupInfo`s kommentar för varför det här
        // läses tillåtande via `JSONSerialization` i stället för
        // `BracketAnalysisOutput`s strikta `Decodable`-kontrakt.
        var groups: [GroupInfo] = []
        var bracketGroupsExists = false
        let groupsURL = outputDir.appendingPathComponent("bracket_groups.json")
        if let data = try? Data(contentsOf: groupsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawGroups = json["groups"] as? [[String: Any]] {
            bracketGroupsExists = true
            groups = rawGroups.map { raw in
                GroupInfo(
                    files: (raw["files"] as? [String]) ?? [],
                    datetimes: (raw["datetimes"] as? [String]) ?? [],
                    dateStart: (raw["date_start"] as? String) ?? ""
                )
            }
        }

        // cull_decisions.json — se `PipelineState.saveCullDecisions`.
        var cullDecisions: [String: String] = [:]
        var cullDecisionsExists = false
        let cullURL = outputDir.appendingPathComponent("cull_decisions.json")
        if let data = try? Data(contentsOf: cullURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            cullDecisions = dict
            cullDecisionsExists = true
        }

        // calendar_matches.json — se `PipelineRunner+Calendar.matchCalendarBookings`.
        var calendarMatches: [CalendarMatch] = []
        let calURL = outputDir.appendingPathComponent("calendar_matches.json")
        if let data = try? Data(contentsOf: calURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let formatter = ISO8601DateFormatter()
            for entry in json {
                guard let address = entry["address"] as? String,
                      let eventTitle = entry["event_title"] as? String,
                      let startStr = entry["range_start"] as? String,
                      let endStr = entry["range_end"] as? String,
                      let start = formatter.date(from: startStr),
                      let end = formatter.date(from: endStr) else { continue }
                calendarMatches.append(CalendarMatch(address: address, eventTitle: eventTitle, start: start, end: end))
            }
        }

        // photoflow_session.json — ALDRIG loadOrMigrate (skulle skriva till disk).
        let manifest = SessionManifestStore.load(from: outputDir)

        let addressFiles = collectAddressFiles(outputDir: outputDir, fm: fm)
        let nefBaseNames = groups.flatMap(\.files).map { ($0 as NSString).deletingPathExtension }

        return Context(
            outputDir: outputDir, dngDir: dngDir, previewDir: previewDir, hdrDir: hdrDir,
            bracketGroupsExists: bracketGroupsExists, groups: groups,
            cullDecisionsExists: cullDecisionsExists, cullDecisions: cullDecisions,
            calendarMatches: calendarMatches, manifest: manifest, addressFiles: addressFiles,
            nefBaseNames: nefBaseNames
        )
    }

    /// Går igenom alla toppnivåmappar utom stagingmapparna (`dng/`,
    /// `previews/`, `hdr/`, `bracket_groups/` — se `AddressFolderLayout`s
    /// kommentar: DNG-länkar/filer ligger direkt i adressmappen, previews/
    /// original i suffixerade syskonmappar) och samlar in VARJE fil som
    /// hittas (symlänk ELLER vanlig fil, se `AddressFileEntry`s kommentar),
    /// med roll (`.dng`/`.preview`/`.extras`) härledd från föräldramappens
    /// namnsuffix.
    private static func collectAddressFiles(outputDir: URL, fm: FileManager) -> [AddressFileEntry] {
        let excludedTopNames: Set<String> = ["dng", "previews", "hdr", "bracket_groups"]
        guard let topLevel = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var result: [AddressFileEntry] = []
        for entry in topLevel {
            guard !excludedTopNames.contains(entry.lastPathComponent),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let enumerator = fm.enumerator(
                at: entry, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let resourceValues = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                let isSymlink = resourceValues?.isSymbolicLink == true
                // En katalog dyker också upp i enumeratorn (t.ex. en
                // "Gallrade"-undermapp) — bara filer (symlänk eller vanlig)
                // är kandidater för täckningskontrollen.
                guard isSymlink || resourceValues?.isRegularFile == true else { continue }

                var parentURL = fileURL.deletingLastPathComponent()
                var parentName = parentURL.lastPathComponent
                let isInGallrade = parentName == "Gallrade"
                if isInGallrade {
                    parentURL = parentURL.deletingLastPathComponent()
                    parentName = parentURL.lastPathComponent
                }

                let role: FolderRole
                if parentName.hasSuffix(" TITTBILDER") {
                    role = .preview
                } else if parentName.hasSuffix(" ÖVRIGA") {
                    role = .extras
                } else {
                    role = .dng
                }

                // `fileExists` följer symlänken — `false` betyder att målet
                // saknas (brutet länk), utan att behöva lösa upp sökvägen
                // själva (se `readlink`-baserade alternativ nedan för varför
                // det INTE görs här: en symlänk kan legitimt peka utanför
                // outputDir, t.ex. en NEF-symlänk mot originalkortet). En
                // vanlig fil kan per definition inte vara "bruten" så här.
                let isBroken = isSymlink && !fm.fileExists(atPath: fileURL.path)

                result.append(AddressFileEntry(
                    url: fileURL,
                    basename: fileURL.deletingPathExtension().lastPathComponent,
                    ext: fileURL.pathExtension.lowercased(),
                    role: role,
                    isInGallrade: isInGallrade,
                    isSymlink: isSymlink,
                    isBroken: isBroken
                ))
            }
        }
        return result
    }

    // MARK: - Kontroll 1: Symlänkar

    private static nonisolated func checkSymlinks(context: Context) -> [Finding] {
        let symlinks = context.addressFiles.filter(\.isSymlink)
        let broken = symlinks.filter(\.isBroken)
        guard !broken.isEmpty else {
            return [Finding(
                id: "symlinks.broken", severity: .ok,
                title: "Alla symlänkar pekar på befintliga filer",
                detail: "\(symlinks.count) symlänkar kontrollerade i adressmapparna, inga brutna."
            )]
        }
        return [Finding(
            id: "symlinks.broken", severity: .error,
            title: "\(broken.count) brutna symlänkar",
            detail: "Dessa symlänkar pekar på filer som inte längre finns (t.ex. efter att en stagingmapp eller ett SD-kort städats bort).",
            recommendation: "Kör om det steg som skapade filen (Konvertera DNG/Skapa previews/Skapa HDR) om originalet fortfarande finns, annars ta bort länken manuellt.",
            affectedFiles: broken.map(\.url.path).sorted()
        )]
    }

    // MARK: - Kontroll 2: Täckning per bild

    private static nonisolated func checkCoverage(context: Context) -> [Finding] {
        guard context.bracketGroupsExists else {
            return [Finding(
                id: "coverage.noBracketGroups", severity: .warning,
                title: "bracket_groups.json saknas",
                detail: "Kan inte kontrollera att varje bild har preview/DNG/symlänkar utan bracket-analysens resultat.",
                recommendation: "Kör om steget Skapa HDR (bracket-analysen körs som en del av det steget)."
            )]
        }

        let fm = FileManager.default
        let bases = context.nefBaseNames
        guard !bases.isEmpty else {
            return [Finding(
                id: "coverage.empty", severity: .warning,
                title: "bracket_groups.json innehåller inga bilder",
                detail: "Filen finns men listar noll grupper/bilder.",
                recommendation: "Kör om steget Skapa HDR om det finns NEF-filer i indatamappen."
            )]
        }

        let extrasBases = Set(context.addressFiles.filter { $0.role == .extras && $0.ext == "nef" }.map(\.basename))
        let dngLinkBases = Set(context.addressFiles.filter { $0.role == .dng && $0.ext == "dng" }.map(\.basename))
        let previewLinkBases = Set(context.addressFiles.filter { $0.role == .preview && $0.ext == "jpg" }.map(\.basename))

        var findings: [Finding] = []

        func missingFiles(where predicate: (String) -> Bool) -> [String] {
            bases.filter(predicate).sorted()
        }

        let missingPreviewFiles = missingFiles { !fm.fileExists(atPath: context.previewDir.appendingPathComponent("\($0).jpg").path) }
        findings.append(coverageFinding(
            id: "coverage.previewFiles", missing: missingPreviewFiles, total: bases.count,
            okTitle: "Alla bilder har en preview", okDetail: "\(bases.count) NEF-filer har en preview-JPEG i previews/.",
            errorTitlePrefix: "saknar preview i previews/",
            recommendation: "Kör om steget Skapa previews."
        ))

        let missingDNGFiles = missingFiles { !fm.fileExists(atPath: context.dngDir.appendingPathComponent("\($0).dng").path) }
        findings.append(coverageFinding(
            id: "coverage.dngFiles", missing: missingDNGFiles, total: bases.count,
            okTitle: "Alla bilder har en DNG", okDetail: "\(bases.count) NEF-filer har en konverterad DNG i dng/.",
            errorTitlePrefix: "saknar DNG i dng/",
            recommendation: "Kör om steget Konvertera DNG."
        ))

        let missingExtras = missingFiles { !extrasBases.contains($0) }
        findings.append(coverageFinding(
            id: "coverage.extrasLinks", missing: missingExtras, total: bases.count,
            okTitle: "Alla original-NEF finns i en ÖVRIGA-mapp", okDetail: "\(bases.count) bilder har en NEF-fil (symlänk eller kopia) i en \"<adress> ÖVRIGA\"-mapp.",
            errorTitlePrefix: "saknar NEF i en ÖVRIGA-mapp",
            recommendation: "Kör om steget Sortera filer."
        ))

        let missingDNGLinks = missingFiles { !dngLinkBases.contains($0) }
        findings.append(coverageFinding(
            id: "coverage.dngLinks", missing: missingDNGLinks, total: bases.count,
            okTitle: "Alla DNG finns i sin adressmapp", okDetail: "\(bases.count) bilder har en DNG-fil (symlänk eller kopia) i en adressmapp.",
            errorTitlePrefix: "saknar DNG i en adressmapp",
            recommendation: "Kör om steget Sortera filer."
        ))

        let missingPreviewLinks = missingFiles { !previewLinkBases.contains($0) }
        findings.append(coverageFinding(
            id: "coverage.previewLinks", missing: missingPreviewLinks, total: bases.count,
            okTitle: "Alla previews finns i en TITTBILDER-mapp", okDetail: "\(bases.count) bilder har en preview-fil (symlänk eller kopia) i en \"<adress> TITTBILDER\"-mapp.",
            errorTitlePrefix: "saknar preview i en TITTBILDER-mapp",
            recommendation: "Kör om steget Sortera filer."
        ))

        return findings
    }

    private static nonisolated func coverageFinding(
        id: String, missing: [String], total: Int, okTitle: String, okDetail: String,
        errorTitlePrefix: String, recommendation: String
    ) -> Finding {
        guard !missing.isEmpty else {
            return Finding(id: id, severity: .ok, title: okTitle, detail: okDetail)
        }
        return Finding(
            id: id, severity: .error,
            title: "\(missing.count) av \(total) bilder \(errorTitlePrefix)",
            detail: "Dessa NEF-basnamn saknar förväntad fil/länk.",
            recommendation: recommendation,
            affectedFiles: missing
        )
    }

    // MARK: - Kontroll 3: Föräldralösa filer

    private static nonisolated func checkOrphans(context: Context) -> [Finding] {
        let fm = FileManager.default
        var findings: [Finding] = []

        // hdr/-stagingmappen ska vara tom efter en lyckad sortering — precis
        // den bug (HDR-resultat aldrig flyttat till en adressmapp) det här
        // verktyget finns till för att fånga.
        let hdrLeftovers = (try? fm.contentsOfDirectory(at: context.hdrDir, includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        if hdrLeftovers.isEmpty {
            findings.append(Finding(
                id: "orphans.hdrLeftovers", severity: .ok,
                title: "hdr/-mappen är tom",
                detail: "Inga bortglömda HDR-resultat i stagingmappen."
            ))
        } else {
            findings.append(Finding(
                id: "orphans.hdrLeftovers", severity: .error,
                title: "\(hdrLeftovers.count) HDR-resultat aldrig flyttade till en adressmapp",
                detail: "Dessa filer ligger kvar i hdr/ — de har inte flyttats till någon \"<adress> ÖVRIGA\"/\"TITTBILDER\"-mapp och syns därför aldrig i Lightroom/Finder.",
                recommendation: "Kör om steget Sortera filer.",
                affectedFiles: hdrLeftovers.map(\.path).sorted()
            ))
        }

        guard context.bracketGroupsExists else { return findings }
        let knownBases = Set(context.nefBaseNames)

        // Föräldralösa filer i dng/ och previews/ — basnamn som inte hör till
        // någon känd bild i bracket_groups.json (t.ex. kvarlämnade filer från
        // en tidigare körning med annan indatamapp).
        let dngOrphans = ((try? fm.contentsOfDirectory(at: context.dngDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "dng" && !knownBases.contains($0.deletingPathExtension().lastPathComponent) }
        let previewOrphans = ((try? fm.contentsOfDirectory(at: context.previewDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" && !knownBases.contains($0.deletingPathExtension().lastPathComponent) }
        let stagingOrphans = (dngOrphans + previewOrphans).map(\.path).sorted()
        if stagingOrphans.isEmpty {
            findings.append(Finding(
                id: "orphans.stagingFiles", severity: .ok,
                title: "Inga föräldralösa filer i dng/ eller previews/",
                detail: "Alla filer i stagingmapparna hör till en känd bild."
            ))
        } else {
            findings.append(Finding(
                id: "orphans.stagingFiles", severity: .warning,
                title: "\(stagingOrphans.count) föräldralösa filer i dng/previews",
                detail: "Dessa filer hör inte till någon bild i bracket_groups.json — kan vara kvarlämnat från en tidigare körning med annan indatamapp.",
                recommendation: "Kontrollera manuellt om filerna behövs innan de tas bort.",
                affectedFiles: stagingOrphans
            ))
        }

        // Föräldralösa filer i adressmapparna (symlänk eller kopia) — basnamn som inte finns i
        // bracket_groups.json alls.
        let addressOrphans = context.addressFiles
            .filter { !knownBases.contains($0.basename) }
            .map(\.url.path)
            .sorted()
        if addressOrphans.isEmpty {
            findings.append(Finding(
                id: "orphans.addressLinks", severity: .ok,
                title: "Inga föräldralösa filer i adressmapparna",
                detail: "Alla filer i adressmapparna hör till en känd bild."
            ))
        } else {
            findings.append(Finding(
                id: "orphans.addressLinks", severity: .warning,
                title: "\(addressOrphans.count) föräldralösa filer i adressmapparna",
                detail: "Dessa filer har basnamn som inte finns i bracket_groups.json — kan bero på en omkörning med ändrade inställningar.",
                recommendation: "Kontrollera manuellt om länkarna fortfarande behövs.",
                affectedFiles: addressOrphans
            ))
        }

        return findings
    }

    // MARK: - Kontroll 4: Metadata (stickprov)

    private static nonisolated func checkMetadataSample(context: Context, exiftoolPath: String?) -> [Finding] {
        guard context.bracketGroupsExists, !context.groups.isEmpty else { return [] }

        let sampleSize = 10
        let sample = context.nefBaseNames.sorted().prefix(sampleSize)
        guard !sample.isEmpty else { return [] }

        // XMP-sidecar: ren filsystemskontroll, kräver inte exiftool — körs
        // därför alltid, oavsett om adress/GPS-stickprovet nedan kan köras.
        // Bara basnamn som faktiskt HAR en NEF-fil i en ÖVRIGA-mapp
        // kontrolleras (annars är det redan flaggat av `coverage.extrasLinks`,
        // ingen mening att dubbelrapportera).
        var findings = checkXMPSidecarSample(context: context, sample: sample)

        guard let exiftoolPath else {
            findings.append(Finding(
                id: "metadata.exiftoolMissing", severity: .warning,
                title: "exiftool saknas",
                detail: "Kan inte stickprovskontrollera adress/GPS-metadata utan exiftool.",
                recommendation: "Installera med: brew install exiftool"
            ))
            return findings
        }

        // Bygg per-fil förväntad-kalendermatchning (samma logik som
        // `AddressSessionLoader.loadPhotoDates`/`loadCalendarMatches`) — bara
        // för att avgöra OM en adress/GPS förväntas, inte det exakta
        // textinnehållet (det beror på geokodning/bokningstitel-parsning som
        // inte är värt att återskapa här bara för ett stickprov).
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var expectedMatch: [String: Bool] = [:] // basename -> förväntar adress/GPS
        for group in context.groups {
            for (i, filename) in group.files.enumerated() {
                let base = (filename as NSString).deletingPathExtension
                let dateStr = i < group.datetimes.count ? group.datetimes[i] : group.dateStart
                guard let date = dateFormatter.date(from: dateStr) else { continue }
                let matches = context.calendarMatches.contains { date >= $0.start && date <= $0.end }
                expectedMatch[base] = matches
            }
        }

        let dngLookup: [String: URL] = Dictionary(uniqueKeysWithValues:
            sample.compactMap { base -> (String, URL)? in
                let url = context.dngDir.appendingPathComponent("\(base).dng")
                return FileManager.default.fileExists(atPath: url.path) ? (base, url) : nil
            }
        )
        guard !dngLookup.isEmpty else {
            findings.append(Finding(
                id: "metadata.noDNGSample", severity: .warning,
                title: "Inget stickprov kunde köras",
                detail: "Ingen av de \(sample.count) utvalda bilderna har en DNG i dng/ att läsa metadata från."
            ))
            return findings
        }

        let tagsByFile = readExifTags(
            exiftoolPath: exiftoolPath,
            files: Array(dngLookup.values),
            tags: ["-IPTC:ObjectName", "-XMP:Title", "-GPSLatitude", "-GPSLongitude"]
        )

        var missingAddress: [String] = []
        var missingGPS: [String] = []
        var anyExpected = false
        for (base, url) in dngLookup {
            guard expectedMatch[base] == true else { continue }
            anyExpected = true
            let tags = tagsByFile[url.path] ?? [:]
            let hasAddress = !(tags["ObjectName"] ?? "").isEmpty || !(tags["Title"] ?? "").isEmpty
            let hasGPS = !(tags["GPSLatitude"] ?? "").isEmpty && !(tags["GPSLongitude"] ?? "").isEmpty
            if !hasAddress { missingAddress.append(url.path) }
            if !hasGPS { missingGPS.append(url.path) }
        }

        if !anyExpected {
            findings.append(Finding(
                id: "metadata.addressSample", severity: .ok,
                title: "Ingen kalendermatchning i stickprovet",
                detail: "Ingen av de kontrollerade bilderna låg inom ett kalenderintervall — adress/GPS förväntas inte, hoppar över den kontrollen."
            ))
        } else {
            findings.append(contentsOf: [
                metadataFinding(
                    id: "metadata.addressSample", missing: missingAddress,
                    okTitle: "Adress skriven i stickprovet", okDetail: "Adress hittad i IPTC/XMP på de kontrollerade DNG-filerna med kalendermatchning.",
                    errorTitle: "Adress saknas i stickprovet", recommendation: "Kör om steget Skriv metadata."
                ),
                metadataFinding(
                    id: "metadata.gpsSample", missing: missingGPS,
                    okTitle: "GPS skrivet i stickprovet", okDetail: "GPS-koordinater hittade på de kontrollerade DNG-filerna med kalendermatchning.",
                    errorTitle: "GPS saknas i stickprovet", recommendation: "Kör om steget Skriv metadata."
                )
            ])
        }

        return findings
    }

    /// NEF-sidecar-delen av metadata-stickprovet — bruten ut ur
    /// `checkMetadataSample` så den körs OAVSETT om `exiftool` finns (ren
    /// filsystemskontroll, ingen process att starta).
    private static nonisolated func checkXMPSidecarSample(context: Context, sample: ArraySlice<String>) -> [Finding] {
        var missingSidecars: [String] = []
        var checkedSidecars = 0
        for base in sample {
            guard let nefLink = context.addressFiles.first(where: { $0.role == .extras && $0.ext == "nef" && $0.basename == base }) else { continue }
            checkedSidecars += 1
            let sidecar = nefLink.url.deletingPathExtension().appendingPathExtension("xmp")
            if !FileManager.default.fileExists(atPath: sidecar.path) {
                missingSidecars.append(nefLink.url.path)
            }
        }
        guard checkedSidecars > 0 else { return [] }
        return [metadataFinding(
            id: "metadata.xmpSidecarSample", missing: missingSidecars,
            okTitle: "NEF har XMP-sidecar i stickprovet", okDetail: "\(checkedSidecars) NEF-symlänkar kontrollerade, alla hade en .xmp-sidecar.",
            errorTitle: "NEF saknar XMP-sidecar i stickprovet", recommendation: "Kör om steget Skriv metadata."
        )]
    }

    private static nonisolated func metadataFinding(id: String, missing: [String], okTitle: String, okDetail: String, errorTitle: String, recommendation: String) -> Finding {
        guard !missing.isEmpty else {
            return Finding(id: id, severity: .ok, title: okTitle, detail: okDetail)
        }
        return Finding(
            id: id, severity: .warning,
            title: "\(errorTitle) (\(missing.count) filer)",
            detail: "Stickprov, inte en fullständig genomgång — fler filer kan vara berörda.",
            recommendation: recommendation,
            affectedFiles: missing.sorted()
        )
    }

    /// Kör ETT `exiftool -j` (JSON-utdata) anrop för hela listan filer, så en
    /// verifiering aldrig startar en process per fil. Returnerar
    /// `[filPath: [taggnamn utan prefix: värde som sträng]]`.
    private static nonisolated func readExifTags(exiftoolPath: String, files: [URL], tags: [String]) -> [String: [String: String]] {
        guard !files.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-j", "-charset", "iptc=UTF8"] + tags + files.map(\.path)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [String: [String: String]] = [:]
        for entry in json {
            guard let sourceFile = entry["SourceFile"] as? String else { continue }
            var fileTags: [String: String] = [:]
            for (key, value) in entry where key != "SourceFile" {
                if let str = value as? String {
                    fileTags[key] = str
                } else if let num = value as? NSNumber {
                    fileTags[key] = num.stringValue
                }
            }
            result[sourceFile] = fileTags
        }
        return result
    }

    // MARK: - Kontroll 5: Gallring

    private static nonisolated func checkCulling(context: Context, exiftoolPath: String?) -> [Finding] {
        guard context.cullDecisionsExists, !context.cullDecisions.isEmpty else {
            return [Finding(
                id: "culling.none", severity: .ok,
                title: "Ingen gallring gjord ännu",
                detail: "cull_decisions.json saknas eller är tom — inget att kontrollera."
            )]
        }

        var acceptedBases: [String] = []
        var rejectedBases: [String] = []
        for (photoID, decision) in context.cullDecisions {
            // photoID = "<groupId>_<filename>.NEF" — se `PipelineRunner+LoadSession`.
            guard let underscoreIdx = photoID.firstIndex(of: "_") else { continue }
            let filename = String(photoID[photoID.index(after: underscoreIdx)...])
            let base = (filename as NSString).deletingPathExtension
            if decision == "accepted" { acceptedBases.append(base) }
            else if decision == "rejected" { rejectedBases.append(base) }
        }

        guard !rejectedBases.isEmpty else {
            return [Finding(
                id: "culling.none", severity: .ok,
                title: "Inga avvisade bilder",
                detail: "\(acceptedBases.count) accepterade, 0 avvisade — inget gallringsläge att kontrollera."
            )]
        }

        enum DiskState { case present, moved, missing, mixed }
        func state(for base: String) -> DiskState {
            let matches = context.addressFiles.filter { $0.basename == base }
            guard !matches.isEmpty else { return .missing }
            let hasNormal = matches.contains { !$0.isInGallrade }
            let hasMoved = matches.contains(where: \.isInGallrade)
            if hasNormal && hasMoved { return .mixed }
            return hasMoved ? .moved : .present
        }

        let states = Dictionary(uniqueKeysWithValues: rejectedBases.map { ($0, state(for: $0)) })
        let counts = (
            present: states.values.filter { $0 == .present }.count,
            moved: states.values.filter { $0 == .moved }.count,
            missing: states.values.filter { $0 == .missing }.count,
            mixed: states.values.filter { $0 == .mixed }.count
        )
        let dominant: DiskState = [
            (DiskState.present, counts.present), (.moved, counts.moved), (.missing, counts.missing)
        ].max(by: { $0.1 < $1.1 })!.0

        let inconsistent = states.filter { $0.value != dominant || dominant == .mixed }.map(\.key).sorted()

        guard inconsistent.isEmpty, dominant != .mixed else {
            return [Finding(
                id: "culling.consistency", severity: .error,
                title: "Gallringsbeslut stämmer inte med filerna på disk",
                detail: "\(inconsistent.count) av \(rejectedBases.count) avvisade bilder är varken kvar, borttagna eller flyttade på ett konsekvent sätt (blandat läge).",
                recommendation: "Kontrollera gallringsläget (Inställningar → Gallring) och kör om steget Granska/Slutgranskning.",
                affectedFiles: inconsistent
            )]
        }

        switch dominant {
        case .missing:
            return [Finding(
                id: "culling.consistency", severity: .ok,
                title: "Gallring: avvisade bilder raderade",
                detail: "\(rejectedBases.count) avvisade bilder är borttagna från adressmapparna, stämmer med gallringsläget \"radera\"."
            )]
        case .moved:
            return [Finding(
                id: "culling.consistency", severity: .ok,
                title: "Gallring: avvisade bilder flyttade",
                detail: "\(rejectedBases.count) avvisade bilder ligger i Gallrade-undermappar, stämmer med gallringsläget \"flytta\"."
            )]
        case .present, .mixed:
            // "markera"-läget lämnar filerna orörda och sätter XMP:Rating i
            // stället — stickprovskontrollera det om exiftool finns.
            guard let exiftoolPath else {
                return [Finding(
                    id: "culling.consistency", severity: .ok,
                    title: "Gallring: avvisade bilder kvar (läge \"markera\" antas)",
                    detail: "\(rejectedBases.count) avvisade bilder finns kvar i adressmapparna. exiftool saknas — kan inte stickprovskontrollera XMP:Rating.",
                    recommendation: "Installera exiftool för att verifiera betygssättningen: brew install exiftool"
                )]
            }
            return [checkCullRatingsSample(context: context, acceptedBases: acceptedBases, rejectedBases: rejectedBases, exiftoolPath: exiftoolPath)]
        }
    }

    private static nonisolated func checkCullRatingsSample(context: Context, acceptedBases: [String], rejectedBases: [String], exiftoolPath: String) -> Finding {
        let sample = Array((rejectedBases + acceptedBases).sorted().prefix(10))
        var expectedRating: [String: Int] = [:]
        for base in sample {
            if rejectedBases.contains(base) { expectedRating[base] = -1 }
            else if acceptedBases.contains(base) { expectedRating[base] = 3 }
        }

        let fileLookup: [String: URL] = Dictionary(uniqueKeysWithValues: sample.compactMap { base -> (String, URL)? in
            let dng = context.dngDir.appendingPathComponent("\(base).dng")
            if FileManager.default.fileExists(atPath: dng.path) { return (base, dng) }
            return nil
        })
        guard !fileLookup.isEmpty else {
            return Finding(
                id: "culling.ratingsSample", severity: .warning,
                title: "Kunde inte stickprovskontrollera betyg",
                detail: "Ingen DNG hittades för de utvalda gallringsbesluten."
            )
        }

        let tags = readExifTags(exiftoolPath: exiftoolPath, files: Array(fileLookup.values), tags: ["-XMP:Rating"])
        var mismatches: [String] = []
        for (base, url) in fileLookup {
            let expected = expectedRating[base]
            let actual = (tags[url.path]?["Rating"]).flatMap { Int($0) }
            if actual != expected {
                mismatches.append(url.path)
            }
        }

        guard mismatches.isEmpty else {
            return Finding(
                id: "culling.ratingsSample", severity: .warning,
                title: "\(mismatches.count) filer har fel XMP:Rating i stickprovet",
                detail: "Gallringsbeslutet i cull_decisions.json matchar inte XMP:Rating som faktiskt är skrivet.",
                recommendation: "Kör om steget Granska (Avsluta gallring) för att skriva om betygen.",
                affectedFiles: mismatches
            )
        }
        return Finding(
            id: "culling.ratingsSample", severity: .ok,
            title: "Gallring: betyg stämmer i stickprovet",
            detail: "\(fileLookup.count) filer kontrollerade — XMP:Rating matchar gallringsbeslutet."
        )
    }

    // MARK: - Kontroll 6: Manifest mot disk

    private static nonisolated func checkManifest(context: Context) -> [Finding] {
        guard let manifest = context.manifest else {
            return [Finding(
                id: "manifest.missing", severity: .warning,
                title: "photoflow_session.json saknas",
                detail: "Sessionen har inget manifest (körd före den funktionen fanns, eller aldrig sparad) — kan inte jämföra stegens räknade antal mot disk.",
                recommendation: "Öppna sessionen i appen en gång, eller kör om ett steg, så genereras ett manifest."
            )]
        }

        var findings: [Finding] = []

        // Literal nycklar/titlar i stället för `DashboardStep.generatePreviews.
        // manifestKey`/`.title`: `DashboardStep` är (liksom det mesta i appen)
        // `MainActor`-isolerat via projektets default, och `checkManifest`
        // körs medvetet `nonisolated` (se filens topp-kommentar) för att kunna
        // köras parallellt utanför `MainActor`. Nycklarna är ett stabilt
        // filformat-kontrakt (se `SessionManifest.manifestKey`s kommentar) —
        // om de någonsin ändras där måste de ändras här också.
        if let previewStep = manifest.steps["generatePreviews"] {
            let actual = (try? FileManager.default.contentsOfDirectory(at: context.previewDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "jpg" }.count ?? 0
            findings.append(manifestCountFinding(
                id: "manifest.previews", stepTitle: "Skapa previews",
                manifestCount: previewStep.processedCount, actualCount: actual
            ))
        }

        if let dngStep = manifest.steps["convertToDNG"] {
            let actual = (try? FileManager.default.contentsOfDirectory(at: context.dngDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "dng" }.count ?? 0
            findings.append(manifestCountFinding(
                id: "manifest.dng", stepTitle: "Konvertera DNG",
                manifestCount: dngStep.processedCount, actualCount: actual
            ))
        }

        if context.bracketGroupsExists {
            let actualPhotoCount = context.nefBaseNames.count
            if manifest.photoCount != actualPhotoCount {
                findings.append(Finding(
                    id: "manifest.photoCount", severity: .warning,
                    title: "Manifestets bildantal stämmer inte med bracket_groups.json",
                    detail: "Manifestet säger \(manifest.photoCount) bilder, bracket_groups.json listar \(actualPhotoCount).",
                    recommendation: "Kör om steget Skapa HDR för att uppdatera manifestet."
                ))
            } else {
                findings.append(Finding(
                    id: "manifest.photoCount", severity: .ok,
                    title: "Manifestets bildantal stämmer",
                    detail: "\(actualPhotoCount) bilder i både manifest och bracket_groups.json."
                ))
            }
        }

        return findings
    }

    private static nonisolated func manifestCountFinding(id: String, stepTitle: String, manifestCount: Int, actualCount: Int) -> Finding {
        guard manifestCount != actualCount else {
            return Finding(
                id: id, severity: .ok,
                title: "\(stepTitle): manifest stämmer med disk",
                detail: "\(actualCount) filer, enligt både manifest och disk."
            )
        }
        return Finding(
            id: id, severity: .warning,
            title: "\(stepTitle): manifest stämmer inte med disk",
            detail: "Manifestet säger \(manifestCount) bearbetade filer, disk har \(actualCount).",
            recommendation: "Kör om steget \"\(stepTitle)\" för att synka om."
        )
    }

    // MARK: - Reparation av trasiga länkar

    /// En enskild länk som redan skrivits om (eller, i en torrkörning, SKULLE
    /// skrivas om) av `repairBrokenLinks`.
    struct LinkRepair: Codable, Sendable, Hashable {
        var path: String
        var oldDestination: String
        var newDestination: String
    }

    /// En trasig länk `repairBrokenLinks` INTE kunde reparera — rapporteras,
    /// tystas aldrig (uppdragets krav: "målfilen finns inte längre någonstans"
    /// ska synas, inte bara tyst hoppas över).
    struct UnrepairableLink: Codable, Sendable, Hashable {
        var path: String
        var oldDestination: String
        var reason: String
    }

    struct RepairReport: Codable, Sendable {
        var dryRun: Bool
        var repaired: [LinkRepair]
        var unresolved: [UnrepairableLink]

        /// "12 trasiga länkar skrivs om relativt. 2 kan INTE repareras
        /// (målfilen hittades inte)." — se `SessionVerifyView`s
        /// bekräftelsedialog och `photoflow-cli verify --repair-links`.
        var summaryText: String {
            let verb = dryRun ? "skulle skrivas om relativt" : "skrivna om relativt"
            var text = "\(repaired.count) trasiga länkar \(verb)."
            if !unresolved.isEmpty {
                text += " \(unresolved.count) kan INTE repareras (målfilen hittades inte) och lämnas orörda."
            }
            return text
        }
    }

    /// Reparerar symlänkar som `checkSymlinks` (se `verify`, fyndet
    /// `"symlinks.broken"`) flaggar som trasiga — se FORBATTRINGAR.md,
    /// "Relativa symlänkar och länkreparation". Sessioner processade INNAN
    /// `FileSafety.createLink` fanns har ABSOLUTA DNG/preview-symlänkar som
    /// bryts så fort hela outputmappen flyttas/arkiveras, trots att
    /// målfilen (`dng/DSC_0001.dng`) ligger kvar bredvid i samma flyttade
    /// träd — exakt vad den skarpa körningen mot `/Users/fredrik/Desktop/
    /// lint/OUTPUT` hittade (1259 brutna länkar).
    ///
    /// För varje trasig länk letas det efter en fil med SAMMA FILNAMN i
    /// sessionens egna stagingmappar (`dng/`, `previews/`, `hdr/`); hittas
    /// en sådan skrivs länken om relativt via samma `FileSafety.
    /// linkDestination`-logik som `exportToAddressFolders` använder för nya
    /// länkar. Original-NEF-symlänkar (som pekar UTANFÖR sessionen, mot
    /// användarens indatamapp/SD-kort) är aldrig kandidater — deras filnamn
    /// ("DSC_0001.NEF") förekommer per definition aldrig i `dng/`
    /// (`.dng`-filer) eller `previews/`/`hdr/` (`.jpg`/`.tiff`-filer), så de
    /// hoppas naturligt över utan att någon separat specialkontroll behövs.
    /// Raderar ALDRIG något: bara den redan trasiga länken själv tas bort
    /// (aldrig en riktig fil) innan den nya länken skrivs, och en trasig länk
    /// utan någon hittad ersättning lämnas helt orörd och rapporteras i
    /// `unresolved` i stället för att tystas.
    ///
    /// `dryRun: true` gör INGA ändringar på disk — bara samma beräkning, så
    /// UI:t/CLI:t kan visa exakt vad som skulle hända innan användaren
    /// bekräftar.
    static func repairBrokenLinks(outputDir: URL, dryRun: Bool) -> RepairReport {
        let fm = FileManager.default
        let context = loadContext(outputDir: outputDir)
        let broken = context.addressFiles.filter { $0.isSymlink && $0.isBroken }
        // I DEN ordningen: en DNG-symlänks mål kan bara rimligen ligga i
        // dng/, en preview-symlänks i previews/, osv — men eftersom
        // matchningen är på FULLSTÄNDIGT filnamn (inklusive ändelse) kan
        // ingen av dem av misstag matcha fel stagingmapp ändå.
        let searchDirs = [context.dngDir, context.previewDir, context.hdrDir]

        var repaired: [LinkRepair] = []
        var unresolved: [UnrepairableLink] = []

        for entry in broken {
            let filename = entry.url.lastPathComponent
            let oldDestination = (try? fm.destinationOfSymbolicLink(atPath: entry.url.path)) ?? "?"

            guard let sourceDir = searchDirs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent(filename).path) }) else {
                unresolved.append(UnrepairableLink(
                    path: entry.url.path, oldDestination: oldDestination,
                    reason: "Ingen fil med namnet \"\(filename)\" hittades i dng/, previews/ eller hdr/ — troligen borttagen/aldrig skapad, inte bara flyttad."
                ))
                continue
            }

            let target = sourceDir.appendingPathComponent(filename)
            // `context.outputDir` (resolved, see `loadContext`), NOT the raw
            // `outputDir` parameter — `entry.url`/`target` both come from
            // `context` and share that same resolution basis; mixing in the
            // unresolved parameter here would make `FileSafety.isInside`
            // wrongly think an inside-session target is outside it whenever
            // `outputDir` sits behind a symlink (e.g. under `/tmp`/`/var`).
            let newDestination = FileSafety.linkDestination(for: target, from: entry.url, outputDir: context.outputDir)

            if !dryRun {
                // Tar bara bort den REDAN TRASIGA länken (aldrig en riktig
                // fil — `entry` kommer bara från `broken`, dvs redan
                // verifierad som en symlänk vars mål inte finns).
                try? fm.removeItem(at: entry.url)
                try? fm.createSymbolicLink(atPath: entry.url.path, withDestinationPath: newDestination)
            }
            repaired.append(LinkRepair(path: entry.url.path, oldDestination: oldDestination, newDestination: newDestination))
        }

        return RepairReport(dryRun: dryRun, repaired: repaired, unresolved: unresolved)
    }
}
