import Foundation
import Dispatch

/// Headless CLI-omslag runt den RIKTIGA `PipelineRunner`-koden (samma
/// `Sources/Services`/`Sources/Models`/`Sources/Shared` som macOS-appen,
/// se kommentaren i `project.yml` vid `photoflow-cli`-målet för varför de
/// delas via `sources` i stället för ett separat ramverksmål).
///
/// Tillkom under Slutgranskningen (se FORBATTRINGAR.md, "Rök-test via CLI")
/// eftersom `PipelineSmokeTest` (körd via `xcodebuild test`) observerades
/// HÄNGA i DNG-konverteringssteget — `Process.waitUntilExit()` returnerade
/// aldrig när Adobe DNG Converter startades som barnprocess till
/// testvärden, trots att alla DNG-filer skrevs klart på disk. Ett fristående
/// körbart mål utan testvärd/debugger-instrumentering kringgår det problemet
/// helt, och ger dessutom en verifieringsväg som fungerar mot RIKTIGA
/// NEF-mappar utan att behöva Xcodes testrunner alls. `PipelineSmokeTest.swift`
/// togs bort (`Tests/`) när det här CLI-verktyget + `scripts/smoke-run.sh`
/// visade sig vara en fullgod ersättning — se FORBATTRINGAR.md.
///
/// Användning:
/// ```
/// photoflow-cli run --input <mapp> --output <mapp> [--no-hdr] [--no-calendar] [--no-ai] [--json]
/// ```
/// Kalendermatchning kräver en interaktiv EventKit-behörighetssession (ingen
/// sådan finns headless) — kör därför alltid med `--no-calendar` i en
/// automatiserad kontext (se `scripts/smoke-run.sh`).
@main
struct PhotoFlowCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = arguments.first else {
            printUsage()
            exit(2)
        }
        switch subcommand {
        case "run":
            await runCommand(Array(arguments.dropFirst()))
        case "verify":
            await verifyCommand(Array(arguments.dropFirst()))
        case "reel":
            await reelCommand(Array(arguments.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            standardError("Okänt kommando: \(subcommand)\n")
            printUsage()
            exit(2)
        }
    }

    private static func printUsage() {
        print("""
        Användning: photoflow-cli run --input <mapp> --output <mapp> [flaggor]
                    photoflow-cli verify --output <mapp> [--json]
                    photoflow-cli reel --input <mapp> --output <mapp> [flaggor]

        "run" kör hela PhotoFlow-pipelinen (NEF -> DNG -> previews ->
        bracket-analys -> [HDR] -> [kalendermatchning] -> [AI-taggning] ->
        adressmappar -> metadata) headless, utan GUI/testvärd. Se
        FORBATTRINGAR.md, "Rök-test via CLI", för bakgrund och verifierade
        körningar.

        Flaggor (run):
          --input <mapp>    Mapp med NEF-filer (rekursivt). Krävs.
          --output <mapp>   Mapp att skriva resultatet till. Krävs.
          --no-hdr          Stäng av HDR-sammanslagning (på som standard).
          --no-calendar     Stäng av kalendermatchning (på som standard i
                             appen, men headless saknar EventKit-behörighet
                             — använd ALLTID den här flaggan utanför en
                             interaktiv GUI-session).
          --no-ai           Stäng av AI-taggning/Vision-analys (på som standard).
          --json            Skriv en maskinläsbar JSON-sammanfattning på
                             slutet (mellan PHOTOFLOW_CLI_JSON_SUMMARY_BEGIN/
                             _END-markörraderna på stdout).

        "verify" kör `SessionVerifier` (se FORBATTRINGAR.md, "Verifiera
        session") mot en redan bearbetad outputmapp och skriver rapporten
        till stdout. Med --repair-links skrivs trasiga symlänkar om relativt
        FÖRE verifieringen körs (se FORBATTRINGAR.md, "Relativa symlänkar
        och länkreparation") — kombinera med --dry-run för att bara se vad
        som SKULLE göras, utan att skriva något till disk.

        Flaggor (verify):
          --output <mapp>   Outputmapp att verifiera. Krävs.
          --json            Skriv rapporten (och ev. reparationsresultatet)
                             som JSON i stället för text.
          --repair-links    Reparera trasiga symlänkar (dng/preview) mot
                             sessionens egna dng/, previews/, hdr/ innan
                             verifieringen körs. Rör aldrig original-NEF.
          --dry-run         Tillsammans med --repair-links: visa bara vad
                             som skulle repareras, skriv inget till disk.

        "reel" gör en Objektfilm (bildspel) av färdiga bilder: analyserar
        bilderna (cache i reel_analysis.json i outputmappen), väljer och
        ordnar dem, skriver specen reel.json och renderar reel_<format>.mp4
        (H.264 High, 30 fps, tyst AAC-spår) i outputmappen.

        Flaggor (reel):
          --input <mapp>    Mapp med färdiga bilder (JPEG/PNG/TIFF/HEIC,
                             inte rekursivt). Krävs.
          --output <mapp>   Mapp för reel.json, reel_analysis.json och
                             videon. Krävs.
          --count <n>       Antal bilder i filmen (standard 5).
          --aspect <a>      9:16 (standard, 1080x1920), 1:1 (1080x1080)
                             eller 16:9 (1920x1080).
          --no-ai           Hoppa över Foundation Models-beskrivningen
                             (rum/kategori) i analysen.
          --json            Skriv en maskinläsbar JSON-sammanfattning
                             (mellan PHOTOFLOW_CLI_JSON_SUMMARY_BEGIN/_END).

        Avslutar med exit-kod 0 om alla steg/kontroller lyckades, annars 1.
        Exit-kod 2 vid felaktiga argument.
        """)
    }

    private static func standardError(_ text: String) {
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }

    private static func fail(_ message: String) -> Never {
        standardError("photoflow-cli: \(message)\n")
        exit(2)
    }

    // MARK: - run

    private static func runCommand(_ args: [String]) async {
        var inputPath: String?
        var outputPath: String?
        var noHDR = false
        var noCalendar = false
        var noAI = false
        var jsonOutput = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--input":
                idx += 1
                guard idx < args.count else { fail("--input kräver ett värde") }
                inputPath = args[idx]
            case "--output":
                idx += 1
                guard idx < args.count else { fail("--output kräver ett värde") }
                outputPath = args[idx]
            case "--no-hdr":
                noHDR = true
            case "--no-calendar":
                noCalendar = true
            case "--no-ai":
                noAI = true
            case "--json":
                jsonOutput = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Okänd flagga: \(arg)")
            }
            idx += 1
        }

        guard let inputPath, let outputPath else {
            fail("--input och --output krävs")
        }

        let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir), isDir.boolValue else {
            standardError("Indatamappen finns inte: \(inputURL.path)\n")
            exit(1)
        }

        // Samma UI-oberoende inställningsobjekt som appen (@AppStorage /
        // UserDefaults.standard), men eftersom photoflow-cli är en fristående
        // binär utan bundle-id delar den INTE domän med den riktiga appen
        // (com.photoflow.app) — UserDefaults.standard för en obundlad process
        // faller tillbaka på en egen domän keyad på processnamnet, så en
        // CLI-körning kan aldrig råka ändra användarens riktiga
        // app-inställningar.
        let settings = AppSettings.shared
        settings.hdrMergeEnabled = !noHDR
        settings.calendarMatchEnabled = !noCalendar
        settings.aiTaggingEnabled = !noAI
        // Ljud/tal/systemnotiser stängs alltid av headless: dels är de
        // meningslösa utan en interaktiv session, dels kraschar
        // `NotificationService` numera bara inte längre (se dess
        // `isRunningInAppBundle`-koll) men skulle ändå bara logga brus.
        settings.notificationsEnabled = false
        settings.soundEnabled = false
        settings.speechEnabled = false
        settings.watchEnabled = false

        print("PhotoFlow CLI — startar pipeline")
        print("  input:  \(inputURL.path)")
        print("  output: \(outputURL.path)")
        print("  HDR: \(settings.hdrMergeEnabled ? "på" : "av"), kalender: \(settings.calendarMatchEnabled ? "på" : "av"), AI-taggning: \(settings.aiTaggingEnabled ? "på" : "av")")

        let state = PipelineState()
        let runner = PipelineRunner(state: state)
        let cliStart = Date()

        // Ctrl-C avbryter pipelinen snyggt (samma väg som "Avbryt"-knappen i
        // appen) i stället för att bara döda processen och lämna en
        // halvfärdig DNG-konvertering.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler {
            Task { @MainActor in
                standardError("\nAvbryter (SIGINT)...\n")
                runner.cancel()
            }
        }
        sigintSource.resume()

        // Skriver ut varje stegs statusövergångar till stdout medan pipelinen
        // kör, parallellt med `runner.startPipeline` nedan — båda körs på
        // MainActor men kopplas loss vid varje `await` (Task.sleep här,
        // process-anropen där), så pollningen hinner interfoliera.
        let pollTask = Task { @MainActor in
            var lastKeys: [DashboardStep: String] = [:]
            while !Task.isCancelled {
                Self.printStepTransitions(state: state, since: cliStart, lastKeys: &lastKeys)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        await runner.startPipeline(inputDir: inputURL, outputDir: outputURL)
        pollTask.cancel()

        // Kalendermatchning AV betyder att `writeIPTCTags`-steget inte körs
        // automatiskt inne i `startPipeline` (se PipelineRunner.swift) — kör
        // det manuellt här, precis som ett "Kör om"-klick på det steget i
        // appen skulle göra (se `PipelineRunner.rerunStep`'s `.writeIPTCTags`-
        // gren, som gör exakt samma sak), så AI-taggar/beskrivningar ändå
        // skrivs till Osorterade-filerna och steget rapporteras som klart i
        // stället för att stå kvar på "active" i sammanfattningen. Samma
        // mönster som `PipelineSmokeTest`.
        if !settings.calendarMatchEnabled {
            print("Kalendermatchning av — kör metadatasteget manuellt (som appens \"Kör om\"-knapp skulle göra).")
            await runner.writeIPTCMetadata()
            state.completeStep(.writeIPTCTags)
        }

        var finalKeys: [DashboardStep: String] = [:]
        printStepTransitions(state: state, since: cliStart, lastKeys: &finalKeys, force: true)

        let totalSeconds = Date().timeIntervalSince(cliStart)
        let success = state.errorMessage == nil && !state.stepStatuses.values.contains { $0.isError }

        let stepSummaries = DashboardStep.allCases.compactMap { step -> StepSummary? in
            guard let status = state.stepStatuses[step] else { return nil }
            guard status.phase != .idle else { return nil }
            return StepSummary(
                step: step.title,
                phase: "\(status.phase)",
                processed: status.processedCount,
                total: status.totalCount,
                durationSeconds: status.lastDuration
            )
        }

        let filesCreated = FilesCreated(
            dngFiles: countFiles(in: outputURL.appendingPathComponent("dng"), ext: "dng"),
            previewFiles: countFiles(in: outputURL.appendingPathComponent("previews"), ext: "jpg"),
            hdrTiffFiles: countFilesRecursive(in: outputURL, namePrefix: "hdr_group_", ext: "tiff"),
            symlinks: countSymlinksRecursive(in: outputURL),
            xmpSidecars: countFilesRecursive(in: outputURL, ext: "xmp")
        )

        print("")
        print(success ? "KLART: pipelinen lyckades." : "FEL: pipelinen misslyckades.")
        if let errorMessage = state.errorMessage {
            print("  Fel: \(errorMessage)")
        }
        print(String(format: "  Total tid: %.1fs", totalSeconds))
        for s in stepSummaries {
            let dur = s.durationSeconds.map { String(format: "%.1fs", $0) } ?? "-"
            print("  - \(s.step): \(s.phase) (\(s.processed)/\(s.total), \(dur))")
        }
        print("  Skapade filer: \(filesCreated.dngFiles) DNG, \(filesCreated.previewFiles) previews, \(filesCreated.hdrTiffFiles) HDR-TIFF, \(filesCreated.symlinks) symlänkar, \(filesCreated.xmpSidecars) XMP-sidecars")

        if jsonOutput {
            let summary = RunSummary(
                inputDirectory: inputURL.path,
                outputDirectory: outputURL.path,
                totalSeconds: totalSeconds,
                hdrEnabled: settings.hdrMergeEnabled,
                calendarEnabled: settings.calendarMatchEnabled,
                aiTaggingEnabled: settings.aiTaggingEnabled,
                success: success,
                errorMessage: state.errorMessage,
                steps: stepSummaries,
                filesCreated: filesCreated
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(summary), let json = String(data: data, encoding: .utf8) {
                print("PHOTOFLOW_CLI_JSON_SUMMARY_BEGIN")
                print(json)
                print("PHOTOFLOW_CLI_JSON_SUMMARY_END")
            }
        }

        exit(success ? 0 : 1)
    }

    // MARK: - verify

    /// Kör `SessionVerifier` mot en redan bearbetad outputmapp — se
    /// FORBATTRINGAR.md, "Verifiera session". Gör det möjligt att köra
    /// verifieringen från `scripts/smoke-run.sh` så rök-testet kontrollerar
    /// sitt eget resultat, och för att verifiera en riktig session utan att
    /// öppna appen.
    private static func verifyCommand(_ args: [String]) async {
        var outputPath: String?
        var jsonOutput = false
        var repairLinks = false
        var dryRun = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--output":
                idx += 1
                guard idx < args.count else { fail("--output kräver ett värde") }
                outputPath = args[idx]
            case "--json":
                jsonOutput = true
            case "--repair-links":
                repairLinks = true
            case "--dry-run":
                dryRun = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Okänd flagga: \(arg)")
            }
            idx += 1
        }

        guard let outputPath else { fail("--output krävs") }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL

        var repairReport: SessionVerifier.RepairReport?
        if repairLinks {
            let result = SessionVerifier.repairBrokenLinks(outputDir: outputURL, dryRun: dryRun)
            repairReport = result
            if !jsonOutput {
                print(dryRun ? "Torrkörning — inget skrivet till disk." : "Reparation genomförd.")
                print(result.summaryText)
                for link in result.repaired {
                    print("  \(link.path)")
                    print("    gammal destination: \(link.oldDestination)")
                    print("    ny destination:     \(link.newDestination)")
                }
                for link in result.unresolved {
                    print("  KUNDE INTE REPARERAS: \(link.path) — \(link.reason)")
                }
                print("")
            }
        }

        let report: SessionVerifier.Report
        do {
            report = try await SessionVerifier.verify(outputDir: outputURL)
        } catch {
            standardError("photoflow-cli verify: \(error.localizedDescription)\n")
            exit(1)
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let repairReport, let data = try? encoder.encode(repairReport), let json = String(data: data, encoding: .utf8) {
                print("PHOTOFLOW_CLI_REPAIR_JSON_BEGIN")
                print(json)
                print("PHOTOFLOW_CLI_REPAIR_JSON_END")
            }
            if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print(report.asPlainText())
        }

        exit(report.errorCount == 0 ? 0 : 1)
    }

    // MARK: - reel

    private static func reelCommand(_ args: [String]) async {
        var inputPath: String?
        var outputPath: String?
        var count = 5
        var format = ReelFormat.vertical
        var describe = true
        var jsonOutput = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--input":
                idx += 1
                guard idx < args.count else { fail("--input kräver ett värde") }
                inputPath = args[idx]
            case "--output":
                idx += 1
                guard idx < args.count else { fail("--output kräver ett värde") }
                outputPath = args[idx]
            case "--count":
                idx += 1
                guard idx < args.count, let n = Int(args[idx]), n > 0 else { fail("--count kräver ett heltal > 0") }
                count = n
            case "--aspect":
                idx += 1
                guard idx < args.count else { fail("--aspect kräver ett värde") }
                switch args[idx] {
                case "9:16": format = .vertical
                case "1:1": format = .square
                case "16:9": format = .landscape
                default: fail("--aspect måste vara 9:16, 1:1 eller 16:9")
                }
            case "--no-ai":
                describe = false
            case "--json":
                jsonOutput = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Okänd flagga: \(arg)")
            }
            idx += 1
        }
        guard let inputPath, let outputPath else { fail("--input och --output krävs") }
        // Symlänkar löses upp (efter att outputmappen skapats) så att specens
        // relativa sökvägar blir rätt även när /tmp och /private/tmp blandas.
        try? FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        let inputURL = URL(fileURLWithPath: inputPath).resolvingSymlinksInPath()
        let outputURL = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir), isDir.boolValue else {
            standardError("Indatamappen finns inte: \(inputURL.path)\n")
            exit(1)
        }
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: inputURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else {
            standardError("Inga bilder i \(inputURL.path)\n")
            exit(1)
        }
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        func log(_ text: String) { if !jsonOutput { print(text) } }
        log("PhotoFlow CLI — Objektfilm")
        log("  input:  \(inputURL.path) (\(files.count) bilder)")
        log("  output: \(outputURL.path)")

        do {
            // Analys
            let analysisStart = Date()
            let items = try await ReelImageAnalyzer.analyze(
                urls: files, cacheDirectory: outputURL, aiTagsDirectory: inputURL, describe: describe)
            let analysisSeconds = Date().timeIntervalSince(analysisStart)
            log(String(format: "Analys: %d av %d bilder på %.1fs", items.count, files.count, analysisSeconds))
            guard !items.isEmpty else { fail("Ingen bild gick att analysera") }

            // Komponera
            var options = ReelComposer.Options()
            options.count = count
            options.format = format
            options.address = inputURL.lastPathComponent
            let result = ReelComposer.compose(items: items, specDirectory: outputURL, options: options)
            let spec = result.spec
            let specURL = outputURL.appendingPathComponent("reel.json")
            try spec.jsonData().write(to: specURL, options: .atomic)
            let total = ReelTimeline.totalDuration(spec)

            let names: [String: String] = Dictionary(uniqueKeysWithValues: spec.assets.map { asset in
                (asset.id, asset.sources.first?.path.map { ($0 as NSString).lastPathComponent } ?? asset.id)
            })
            let picks: [PickSummary] = (spec.provenance.autoSelection ?? []).map {
                PickSummary(asset: $0.asset, file: names[$0.asset] ?? "", slot: $0.slot, reason: $0.reason)
            }
            log("Urval (\(spec.timeline.count) klipp, \(String(format: "%.1f", total)) s):")
            for p in picks { log("  \(p.asset) \(p.file) [\(p.slot)] \(p.reason)") }
            for e in result.selection.excluded.prefix(10) { log("  utesluten: \(e.reason)") }

            // Rendera
            let output = format.output
            let videoURL = outputURL.appendingPathComponent("reel_\(output.aspect.replacingOccurrences(of: ":", with: "x")).mp4")
            let renderStart = Date()
            let lastPercent = ProgressBox()
            let quiet = jsonOutput
            try await ReelRenderer.export(spec: spec, specDirectory: outputURL, output: output, to: videoURL) { p in
                let pct = Int(p * 10) * 10
                if !quiet, lastPercent.advance(to: pct) { print("  rendering \(pct)%") }
            }
            let renderSeconds = Date().timeIntervalSince(renderStart)
            let size = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
            log(String(format: "Klar: %@ (%.1f s film, %.1f MB, rendering %.1fs)",
                       videoURL.path, total, Double(size) / 1_000_000, renderSeconds))

            if jsonOutput {
                let summary = ReelSummary(
                    inputDirectory: inputURL.path, specFile: specURL.path, videoFile: videoURL.path,
                    aspect: output.aspect, width: output.width, height: output.height, fps: output.fps,
                    durationSeconds: total, fileBytes: size, analysisSeconds: analysisSeconds,
                    renderSeconds: renderSeconds, picks: picks)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if let data = try? encoder.encode(summary), let json = String(data: data, encoding: .utf8) {
                    print("PHOTOFLOW_CLI_JSON_SUMMARY_BEGIN")
                    print(json)
                    print("PHOTOFLOW_CLI_JSON_SUMMARY_END")
                }
            }
            exit(0)
        } catch {
            standardError("photoflow-cli reel: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    // MARK: - Progress printing

    @MainActor
    private static func printStepTransitions(
        state: PipelineState, since start: Date, lastKeys: inout [DashboardStep: String], force: Bool = false
    ) {
        for step in DashboardStep.allCases {
            guard let status = state.stepStatuses[step] else { continue }
            let key = "\(status.phase)|\(status.processedCount)/\(status.totalCount)"
            guard status.phase != .idle, force || lastKeys[step] != key else { continue }
            lastKeys[step] = key
            let elapsed = Date().timeIntervalSince(start)
            let text = status.statusText.isEmpty ? "\(status.phase)" : status.statusText
            print(String(format: "[%6.1fs] %@: %@", elapsed, step.title, text))
        }
    }

    // MARK: - File counting helpers

    private static func countFiles(in dir: URL, ext: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == ext.lowercased() }
            .count
    }

    private static func countFilesRecursive(in dir: URL, namePrefix: String? = nil, ext: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == ext.lowercased() else { continue }
            if let namePrefix, !url.lastPathComponent.hasPrefix(namePrefix) { continue }
            count += 1
        }
        return count
    }

    private static func countSymlinksRecursive(in dir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                count += 1
            }
        }
        return count
    }
}

// MARK: - JSON summary types

private struct StepSummary: Codable {
    let step: String
    let phase: String
    let processed: Int
    let total: Int
    let durationSeconds: Double?
}

private struct FilesCreated: Codable {
    let dngFiles: Int
    let previewFiles: Int
    let hdrTiffFiles: Int
    let symlinks: Int
    let xmpSidecars: Int
}

private struct RunSummary: Codable {
    let inputDirectory: String
    let outputDirectory: String
    let totalSeconds: Double
    let hdrEnabled: Bool
    let calendarEnabled: Bool
    let aiTaggingEnabled: Bool
    let success: Bool
    let errorMessage: String?
    let steps: [StepSummary]
    let filesCreated: FilesCreated
}

private struct PickSummary: Codable {
    let asset: String
    let file: String
    let slot: String
    let reason: String
}

private struct ReelSummary: Codable {
    let inputDirectory: String
    let specFile: String
    let videoFile: String
    let aspect: String
    let width: Int
    let height: Int
    let fps: Int
    let durationSeconds: Double
    let fileBytes: Int
    let analysisSeconds: Double
    let renderSeconds: Double
    let picks: [PickSummary]
}

/// Låter en `@Sendable`-progresscallback skriva ut varje tiondel bara en gång.
private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func advance(to value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value > last else { return false }
        last = value
        return true
    }
}
