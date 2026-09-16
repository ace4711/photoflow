import Foundation
import CryptoKit
import Testing
@testable import PhotoFlow

/// OPT-IN rök-test av HELA pipelinen mot en riktig bracket-serie
/// (Slutgranskning, Del 2 — se FORBATTRINGAR.md). Av som standard: testet
/// returnerar direkt och räknas som godkänt (samma "hoppa över tyst"-mönster
/// som de miljöberoende geocode-testerna i `CalendarServiceTests`) om varken
/// miljövariabeln `PHOTOFLOW_SMOKE=1` ÄR satt ELLER en styrfil finns på
/// `~/Library/Application Support/PhotoFlow/smoke_test.json`.
///
/// Miljövariabler når INTE alltid testprocessen när man kör
/// `xcodebuild ... test` från kommandoraden (verifierat: `xcodebuild test`
/// startar testvärden med en egen, tom miljö oavsett den anropande skalets
/// `export`) — styrfilen är därför det tillförlitliga sättet att slå på
/// testet, och fungerar identiskt oavsett om man kör via Xcode (Cmd+U) eller
/// `xcodebuild test`. Skapa den t.ex. så här:
/// ```
/// mkdir -p ~/Library/Application\ Support/PhotoFlow
/// cat > ~/Library/Application\ Support/PhotoFlow/smoke_test.json <<'JSON'
/// {"enabled": true, "inputPath": "/sokvag/till/en/mapp/med/NEF-filer", "keepOutput": true}
/// JSON
/// ```
/// `inputPath`/`keepOutput` är valfria (se defaultvärden nedan). Radera
/// filen (eller sätt `"enabled": false`) för att stänga av igen.
///
/// Kör den RIKTIGA `PipelineRunner`-koden headless, inte en mock:
/// kalendermatchning AV (ingen EventKit-åtkomst behövs i en testmiljö),
/// AI-taggning och HDR (Core Image-motorn, `AppSettings.hdrEngine ==
/// "coreImage"`) PÅ — appens verkliga standardinställningar i övrigt.
///
/// `AppSettings.shared` är `@AppStorage`-baserad (`UserDefaults.standard`).
/// Testmålet körs värdad inuti PhotoFlow.app-processen (`TEST_HOST`), så det
/// DELAR riktig UserDefaults med appen — varje inställning testet ändrar
/// snapshottas och återställs i en `defer`, så en körning aldrig permanent
/// ändrar användarens riktiga appkonfiguration.
///
/// Indata: sätt `PHOTOFLOW_SMOKE_INPUT` till en egen mapp med NEF-filer
/// (gärna med en riktig exponeringsbracket), annars faller testet tillbaka på
/// samma riktiga testmapp tidigare faser redan använt för verifiering (se
/// Fas 2a i FORBATTRINGAR.md: `~/Desktop/ptohotagraphy-test/Exempelgatan 7`).
/// Om den mappen inte finns på den aktuella maskinen hoppar testet över sig
/// själv i stället för att faila. Utdata skrivs till en tillfällig mapp under
/// `NSTemporaryDirectory()` och städas bort efteråt — sätt
/// `PHOTOFLOW_SMOKE_KEEP_OUTPUT=1` för att behålla den för manuell
/// inspektion (sökvägen skrivs ut i testloggen).
///
/// Körs ALDRIG mot användarens riktiga input-/kortmappar — bara mot en kopia
/// (eller en mapp användaren själv pekar ut), och skriver bara till en
/// engångs-temp-mapp. Se `FileSafetyTests`/`PipelineRunnerCullSafetyTests`
/// för de riktade enhetstesterna av själva säkerhetsspärrarna.
///
/// KÄND BEGRÄNSNING (se FORBATTRINGAR.md "Slutgranskning" för detaljer och
/// repro): när det här testet körs via `xcodebuild test` har
/// DNG-konverteringssteget observerats HÄNGA i `Process.waitUntilExit()` —
/// Adobe DNG Converter skriver faktiskt klart alla DNG-filer (verifierat på
/// disk), men `waitUntilExit()` returnerar aldrig i just den processkontext
/// `xcodebuild test` skapar. Samma anrop (`Process` + samma binär, samma
/// argument) i ett fristående Swift-skript (inte testvärdat) returnerar
/// normalt på ~5s. Misstänkt orsak: hur Xcodes testrunner/debugger
/// övervakar/reapar barnprocesser till den testvärdade appen — INTE en bugg
/// i `ProcessRunner`/`PipelineRunner`. Om detta inträffar: avbryt testet
/// (Xcode: stoppa körningen; kommandorad: `kill` på `xcodebuild`-processen),
/// och kör hellre via Xcodes Test Navigator (Cmd+U) i stället för
/// `xcodebuild test` från kommandoraden — inte verifierat om det undviker
/// problemet, men är värt att prova.
@MainActor
struct PipelineSmokeTest {

    /// Styrfil-schema, se dok-kommentaren ovan för hur man skapar den. Alla
    /// fält är valfria så en tom/ofullständig fil bara betyder "av".
    private struct SmokeTestConfig: Decodable {
        var enabled: Bool?
        var inputPath: String?
        var keepOutput: Bool?
    }

    private static var controlFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PhotoFlow/smoke_test.json")
    }

    private static func loadConfig() -> SmokeTestConfig? {
        guard let data = try? Data(contentsOf: controlFileURL) else { return nil }
        return try? JSONDecoder().decode(SmokeTestConfig.self, from: data)
    }

    @Test("Hela pipelinen mot en riktig bracket-serie — verifierar att originalen förblir bit-identiska")
    func fullPipeline_realNEFBracketSeries_leavesOriginalsUntouched() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = Self.loadConfig()
        guard env["PHOTOFLOW_SMOKE"] == "1" || config?.enabled == true else {
            return // Av som standard, se dok-kommentaren ovan för hur man kör det.
        }

        let inputDir: URL
        if let override = env["PHOTOFLOW_SMOKE_INPUT"] ?? config?.inputPath {
            inputDir = URL(fileURLWithPath: override)
        } else {
            inputDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/ptohotagraphy-test/Exempelgatan 7")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputDir.path, isDirectory: &isDir), isDir.boolValue else {
            print("Röktest påslaget men indatamappen \(inputDir.path) finns inte på den här maskinen — hoppar över. Ange \"inputPath\" i \(Self.controlFileURL.path) för att peka på en egen mapp med NEF-filer.")
            return
        }
        let nefFiles = ((try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.uppercased() == "NEF" }
        guard !nefFiles.isEmpty else {
            print("Röktest påslaget men \(inputDir.path) innehåller inga NEF-filer — hoppar över.")
            return
        }

        // 1. Hasha alla källfiler INNAN pipelinen körs — det slutgiltiga
        //    beviset på att originalen aldrig rörs, oavsett vad som händer
        //    längre ner i pipelinen.
        var hashesBefore: [String: String] = [:]
        for url in nefFiles {
            hashesBefore[url.lastPathComponent] = try Self.sha256(of: url)
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoFlowSmokeTest-\(UUID().uuidString)")
        let keepOutput = (env["PHOTOFLOW_SMOKE_KEEP_OUTPUT"] == "1") || (config?.keepOutput == true)
        defer {
            if keepOutput {
                print("PHOTOFLOW_SMOKE_KEEP_OUTPUT=1 — utdata sparad i \(outputDir.path)")
            } else {
                try? FileManager.default.removeItem(at: outputDir)
            }
        }

        // 2. Snapshotta + sätt de inställningar röktestet behöver, återställ
        //    alltid efteråt (se dok-kommentaren ovan om delad UserDefaults).
        let settings = AppSettings.shared
        let savedCalendar = settings.calendarMatchEnabled
        let savedHDR = settings.hdrMergeEnabled
        let savedHDREngine = settings.hdrEngine
        let savedAITagging = settings.aiTaggingEnabled
        defer {
            settings.calendarMatchEnabled = savedCalendar
            settings.hdrMergeEnabled = savedHDR
            settings.hdrEngine = savedHDREngine
            settings.aiTaggingEnabled = savedAITagging
        }
        settings.calendarMatchEnabled = false // ingen EventKit-åtkomst i testmiljön
        settings.hdrMergeEnabled = true
        settings.hdrEngine = "coreImage"
        settings.aiTaggingEnabled = true

        let state = PipelineState()
        let runner = PipelineRunner(state: state)

        let start = ContinuousClock.now
        await runner.startPipeline(inputDir: inputDir, outputDir: outputDir)
        let elapsed = ContinuousClock.now - start
        print("RÖKTEST: hela pipelinen tog \(elapsed) för \(nefFiles.count) NEF-filer.")

        if let error = state.errorMessage {
            Issue.record("Pipelinen avslutades med fel: \(error)")
        }

        // 3. Källfilerna ska vara bit-identiska efteråt — den viktigaste
        //    kontrollen i hela testet.
        for file in nefFiles {
            let after = try Self.sha256(of: file)
            #expect(hashesBefore[file.lastPathComponent] == after, "\(file.lastPathComponent) ändrades av pipelinen!")
        }
        print("RÖKTEST: alla \(nefFiles.count) NEF-original bit-identiska före/efter.")

        // 4. Previews skapade för alla NEF.
        let previewStagingDir = outputDir.appendingPathComponent("previews")
        let previews = ((try? FileManager.default.contentsOfDirectory(at: previewStagingDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
        #expect(previews.count == nefFiles.count, "Förväntade \(nefFiles.count) previews, fick \(previews.count)")

        // 5. bracket_groups.json rimlig.
        let groupsFile = outputDir.appendingPathComponent("bracket_groups.json")
        #expect(FileManager.default.fileExists(atPath: groupsFile.path))
        if let data = try? Data(contentsOf: groupsFile),
           let output = try? JSONDecoder().decode(BracketAnalysisOutput.self, from: data) {
            #expect(output.totalImages == nefFiles.count)
            #expect(!output.groups.isEmpty)
            print("RÖKTEST: \(output.groups.count) grupper (\(output.groups.filter(\.isBracket).count) brackets, \(output.groups.filter { !$0.isBracket }.count) singlar).")
        } else {
            Issue.record("Kunde inte tolka bracket_groups.json")
        }

        // 6. Osorterade-mappar med symlänkar (kalendermatchning AV -> allt dit).
        let symlinkCount = Self.countSymlinks(in: outputDir)
        #expect(symlinkCount > 0, "Förväntade symlänkar under outputDir (adressmappar/bracket_groups)")
        print("RÖKTEST: \(symlinkCount) symlänkar totalt under outputDir.")

        // 7. HDR: minst en 16-bitars TIFF skapad (Core Image-motorn), och den
        //    ska ligga i "Osorterade ÖVRIGA" (Slutgransknings-fixen i
        //    PipelineRunner+SortFolders.swift — tidigare tappades HDR-filer
        //    permanent i outputDir/hdr/ när det inte fanns en kalendermatchning).
        let osorteradeExtras = AddressFolderLayout.extrasDir(in: outputDir, folderName: "Osorterade")
        let hdrTiffs = ((try? FileManager.default.contentsOfDirectory(at: osorteradeExtras, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("hdr_group_") && $0.pathExtension.lowercased() == "tiff" }
        let orphanedHDR = ((try? FileManager.default.contentsOfDirectory(at: outputDir.appendingPathComponent("hdr"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "tiff" }
        #expect(orphanedHDR.isEmpty, "HDR-TIFF kvar i hdr/ (borde ha flyttats till Osorterade ÖVRIGA): \(orphanedHDR.map(\.lastPathComponent))")
        if let firstTiff = hdrTiffs.first {
            let bits: String? = (try? Self.exiftoolValue(for: "-BitsPerSample", file: firstTiff)) ?? nil
            #expect(bits?.contains("16") == true, "Förväntade 16 bitar/sampel på \(firstTiff.lastPathComponent), fick \(bits ?? "nil")")
            print("RÖKTEST: HDR-TIFF \(firstTiff.lastPathComponent) i Osorterade ÖVRIGA, BitsPerSample=\(bits ?? "?")")
        } else {
            print("RÖKTEST: inga HDR-brackets i indatan (eller HDR-sammanslagning gav inget resultat) — se pipeline.log i \(outputDir.path).")
        }

        // 8. Metadata + XMP-sidecar: kalendermatchning AV betyder att
        //    writeIPTCTags-steget inte körs automatiskt i startPipeline (se
        //    PipelineRunner.swift), men AI-tagg-branschen för "Osorterade"
        //    (Fas 1a) ska fungera oberoende av kalendermatchning — kör den
        //    manuellt, precis som ett "Kör om"-klick i appen skulle göra.
        await runner.writeIPTCMetadata()
        if let dngFile = ((try? FileManager.default.contentsOfDirectory(at: AddressFolderLayout.dngDir(in: outputDir, folderName: "Osorterade"), includingPropertiesForKeys: nil)) ?? [])
            .first(where: { $0.pathExtension.lowercased() == "dng" }) {
            let keywords: String? = (try? Self.exiftoolValue(for: "-IPTC:Keywords", file: dngFile)) ?? nil
            print("RÖKTEST: DNG \(dngFile.lastPathComponent) — IPTC:Keywords=\(keywords ?? "(inga)")")
        }
        let xmpCount = ((try? FileManager.default.contentsOfDirectory(at: osorteradeExtras, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xmp" }.count
        print("RÖKTEST: \(xmpCount) XMP-sidecars i Osorterade ÖVRIGA.")

        print("RÖKTEST KLART på \(nefFiles.count) NEF-filer, \(elapsed). Se FORBATTRINGAR.md \"Slutgranskning\" för sammanställning.")
    }

    // MARK: - Helpers

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func countSymlinks(in dir: URL) -> Int {
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

    private static func exiftoolValue(for tag: String, file: URL) throws -> String? {
        guard let exiftool = ToolLocator.exiftool else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftool)
        process.arguments = ["-s3", tag, file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
