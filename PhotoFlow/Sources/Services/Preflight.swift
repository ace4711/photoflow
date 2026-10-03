import Foundation
import IOKit

/// Startkontrollen: visar om allt appen behöver är på plats — mappar, kalender,
/// verktyg, Lightroom-pluginet och AI-modellen — och vad man gör åt det som
/// saknas. Körs vid appstart, när inställningarna ändras, när en disk ansluts
/// eller matas ut, och innan Kör/bevakning startar. En blockerande brist (t.ex.
/// att inputmappens externa disk inte är ansluten) öppnar kontrollen i stället
/// för att låta pipelinen misslyckas halvvägs.
///
/// `evaluate` är ren: allt den behöver läsa kommer via `Input` och `FolderProbe`,
/// så den testas utan riktiga diskar eller kalendrar (`PreflightTests`).
/// Kontrollen läser bara — de enda skrivningarna sker i `PreflightModel` när
/// användaren uttryckligen trycker på en åtgärdsknapp. Kalenderåtkomst begärs
/// aldrig av kontrollen själv (se `PhotoFlowApp.startupChecks`), bara visas.
nonisolated enum Preflight {

    // MARK: - Resultat

    nonisolated enum Status: Int, Comparable, Sendable {
        case ok, info, warning, blocker
        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    nonisolated enum Section: Int, CaseIterable, Sendable {
        case folders, calendar, tools, lightroom, ai

        var title: String {
            switch self {
            case .folders: return "Mappar"
            case .calendar: return "Kalender"
            case .tools: return "Verktyg"
            case .lightroom: return "Lightroom"
            case .ai: return "AI på enheten"
            }
        }

        var systemImage: String {
            switch self {
            case .folders: return "folder"
            case .calendar: return "calendar"
            case .tools: return "wrench.and.screwdriver"
            case .lightroom: return "camera.aperture"
            case .ai: return "sparkles"
            }
        }
    }

    nonisolated enum Fix: Equatable, Sendable {
        case chooseInput
        case chooseOutput
        case createFolder(URL)
        case revealInFinder(URL)
        case relinkLightroomPlugin
        case requestCalendarAccess
        case openCalendarPrivacy
        /// Öppnar Inställningar på en viss flik (samma numrering som `SettingsView`).
        case openSettings(tab: Int, label: String)

        var label: String {
            switch self {
            case .chooseInput: return "Välj inputmapp…"
            case .chooseOutput: return "Välj outputmapp…"
            case .createFolder: return "Skapa mappen"
            case .revealInFinder: return "Visa i Finder"
            case .relinkLightroomPlugin: return "Välj pluginet…"
            case .requestCalendarAccess: return "Ge kalenderåtkomst"
            case .openCalendarPrivacy: return "Öppna Systeminställningar"
            case .openSettings(_, let label): return label
            }
        }
    }

    nonisolated struct Check: Identifiable, Equatable, Sendable {
        /// Stabil nyckel (t.ex. `"input.volume"`) — testerna bygger på den, inte på texten.
        var id: String
        var section: Section
        var status: Status
        var title: String
        var detail: String
        var path: String?
        var fix: Fix?
    }

    /// En rad i mappträdet: en mapp appen använder och om den finns än.
    nonisolated struct StructureEntry: Identifiable, Equatable, Sendable {
        var id: String { path }
        var name: String
        var path: String
        var purpose: String
        var exists: Bool
        /// Indrag i trädet (0 = input/output, 1 = undermapp).
        var depth: Int
        /// Mappar som pipelinen skapar själv räknas inte som brist.
        var createdByPipeline: Bool
    }

    nonisolated struct Report: Equatable, Sendable {
        var checks: [Check]
        var structure: [StructureEntry]

        var worst: Status { checks.map(\.status).max() ?? .ok }
        var blockers: [Check] { checks.filter { $0.status == .blocker } }
        var warnings: [Check] { checks.filter { $0.status == .warning } }
        func check(_ id: String) -> Check? { checks.first { $0.id == id } }
        func checks(in section: Section) -> [Check] { checks.filter { $0.section == section } }
        func worst(in section: Section) -> Status { checks(in: section).map(\.status).max() ?? .ok }

        var summary: String {
            switch worst {
            case .blocker:
                return blockers.count == 1 ? "1 sak måste åtgärdas" : "\(blockers.count) saker måste åtgärdas"
            case .warning:
                return warnings.count == 1 ? "1 varning" : "\(warnings.count) varningar"
            case .ok, .info:
                return "Allt klart"
            }
        }

        static let empty = Report(checks: [], structure: [])
    }

    // MARK: - Indata

    nonisolated struct ItemState: Equatable, Sendable {
        var exists = false
        var isDirectory = false
        var readable = false
        var writable = false
        /// Symlänkens mål om posten är en symlänk (oavsett om målet finns).
        var symlinkDestination: String?
    }

    /// Hur en extern disk är ansluten, läst ur IOKit (`IOUSBHostDevice`).
    nonisolated struct USBLink: Equatable, Sendable {
        var product: String
        /// `USBSpeed`: 1 low, 2 full, 3 high (480 Mb/s), 4 super (5 Gb/s),
        /// 5 super+ (10 Gb/s), 6 super+ 2×2 (20 Gb/s).
        var speed: Int

        /// USB 2.0 eller långsammare — för en SSD eller kortläsare betyder det
        /// nästan alltid fel kabel eller en kontakt som inte sitter i ordentligt.
        var isSlow: Bool { speed <= 3 }

        var label: String {
            switch speed {
            case 1: return "1,5 Mb/s"
            case 2: return "12 Mb/s"
            case 3: return "480 Mb/s (USB 2.0)"
            case 4: return "5 Gb/s"
            case 5: return "10 Gb/s"
            case 6: return "20 Gb/s"
            default: return "okänd hastighet"
            }
        }
    }

    /// Filsystemsläsningarna, utbytbara i tester.
    nonisolated struct FolderProbe: Sendable {
        var item: @Sendable (URL) -> ItemState
        /// Är `/Volumes/<namn>` en monterad volym (inte en kvarlämnad tom mapp)?
        var isVolumeMounted: @Sendable (URL) -> Bool
        var freeBytes: @Sendable (URL) -> Int64?
        /// NEF-filer i mappen (rekursivt), utan att gå in i `excluding`.
        var nefBytes: @Sendable (_ dir: URL, _ excluding: URL?) -> (count: Int, bytes: Int64)
        /// USB-anslutningen för disken som `url` ligger på, eller nil om den inte sitter på USB.
        var usbLink: @Sendable (URL) -> USBLink? = { _ in nil }

        static let live = FolderProbe(
            item: { url in
                let fm = FileManager.default
                var isDir: ObjCBool = false
                var state = ItemState()
                state.symlinkDestination = try? fm.destinationOfSymbolicLink(atPath: url.path)
                state.exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
                state.isDirectory = isDir.boolValue
                state.readable = state.exists && fm.isReadableFile(atPath: url.path)
                state.writable = state.exists && fm.isWritableFile(atPath: url.path)
                return state
            },
            isVolumeMounted: { root in
                let values = try? root.resourceValues(forKeys: [.volumeURLKey])
                return values?.volume?.standardizedFileURL.path == root.standardizedFileURL.path
            },
            freeBytes: { url in
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            },
            nefBytes: { dir, excluding in
                guard let walker = FileManager.default.enumerator(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
                ) else { return (0, 0) }
                let excludedPath = excluding?.standardizedFileURL.path
                var count = 0
                var bytes: Int64 = 0
                while let url = walker.nextObject() as? URL {
                    if let excludedPath, url.standardizedFileURL.path == excludedPath {
                        walker.skipDescendants()
                        continue
                    }
                    guard url.pathExtension.uppercased() == "NEF" else { continue }
                    count += 1
                    bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
                return (count, bytes)
            },
            usbLink: { url in liveUSBLink(for: url) }
        )

        /// Volym → BSD-namn (statfs) → IOMedia → uppåt i IOService-trädet till
        /// USB-enheten. Fungerar även för APFS-volymer, vars förälder är
        /// containern och därefter den fysiska disken.
        private static func liveUSBLink(for url: URL) -> USBLink? {
            var fs = statfs()
            guard statfs(url.path, &fs) == 0 else { return nil }
            let device = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard device.hasPrefix("/dev/"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, String(device.dropFirst(5))) else { return nil }
            let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard media != 0 else { return nil }
            defer { IOObjectRelease(media) }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            func search(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
            }
            guard let speed = (search("USBSpeed") as? NSNumber)?.intValue else { return nil }
            let product = (search("USB Product Name") as? String)?.trimmingCharacters(in: .whitespaces) ?? "USB-disk"
            return USBLink(product: product, speed: speed)
        }
    }

    nonisolated enum CalendarAccess: Sendable {
        case notDetermined, denied, writeOnly, full
    }

    nonisolated struct CalendarInput: Sendable {
        var enabled: Bool
        var access: CalendarAccess
        var selected: [String]
        var available: [String]
        /// Händelser de senaste `recentDays` dagarna i de valda kalendrarna.
        var recentEventCount: Int
        /// Titlar bland dem där ingen adress gick att utläsa.
        var recentWithoutAddress: [String]
        var recentDays: Int = 14
    }

    nonisolated struct ToolInput: Sendable {
        var name: String
        var required: Bool
        var ok: Bool
        var detail: String?
    }

    nonisolated struct Input: Sendable {
        var inputDir: URL?
        var outputDir: URL?
        /// `~/Library/Application Support/PhotoFlow` — bryggmapp mot Lightroom och appens register.
        var supportDir: URL
        /// `~/Library/Application Support/Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin`.
        var lightroomPluginLink: URL
        var lightroomInstalled: Bool
        /// Namn på anslutna volymer som ser ut som minneskort.
        var sdCards: [String]
        var calendar: CalendarInput
        /// Tom innan verktygskontrollen hunnit köras — då visas ingen verktygssektion.
        var tools: [ToolInput]
        var modelAvailable: Bool
        var aiDescriptionsEnabled: Bool
    }

    /// Hur mycket plats en körning ungefär tar per byte NEF: DNG (~1×),
    /// förhandsbilder och HDR-TIFF (16 bit) tillsammans.
    static let spaceFactor: Double = 3.5
    static let minimumFreeBytes: Int64 = 2_000_000_000

    /// Undermappar pipelinen skapar i outputmappen.
    static let pipelineSubfolders: [(name: String, purpose: String)] = [
        ("dng", "DNG-konverterade råfiler"),
        ("previews", "JPEG-förhandsbilder"),
        ("hdr", "HDR-sammanslagningar innan sortering"),
        ("bracket_groups", "Exponeringsserier"),
    ]

    // MARK: - Utvärdering

    static func evaluate(_ input: Input, probe: FolderProbe) -> Report {
        var checks: [Check] = []
        let folders = folderSection(input, probe: probe)
        checks += folders.checks
        checks += calendarSection(input.calendar, modelAvailable: input.modelAvailable)
        checks += toolSection(input.tools)
        checks.append(lightroomCheck(input, probe: probe))
        checks += aiSection(input)

        // Allvarligast först, annars i den ordning de lades till.
        let ordered = checks.enumerated().sorted { a, b in
            a.element.status != b.element.status ? a.element.status > b.element.status : a.offset < b.offset
        }.map(\.element)
        return Report(checks: ordered, structure: folders.structure)
    }

    // MARK: Mappar

    private static func folderSection(_ input: Input, probe: FolderProbe) -> (checks: [Check], structure: [StructureEntry]) {
        var checks: [Check] = []
        // Utan vald outputmapp hamnar resultatet i input/processed — samma regel som PipelineRunner.
        let effectiveOutput = input.outputDir ?? input.inputDir?.appendingPathComponent("processed")

        let inputUsable: Bool
        if let dir = input.inputDir {
            let result = folderChecks(
                key: "input", label: "Inputmappen", dir: dir,
                purpose: "NEF-filer från minneskortet", chooseFix: .chooseInput,
                writeReason: "appen kopierar hit från minneskortet och lägger XMP-filer bredvid NEF-filerna",
                probe: probe
            )
            checks += result.checks
            inputUsable = result.usable
        } else {
            checks.append(Check(
                id: "input.missing", section: .folders, status: .blocker, title: "Ingen inputmapp vald",
                detail: "Välj mappen där NEF-filerna ska ligga. Minneskort kopieras dit automatiskt.",
                fix: .chooseInput
            ))
            inputUsable = false
        }

        var outputUsable = false
        if input.outputDir == nil, input.inputDir != nil {
            checks.append(Check(
                id: "output.default", section: .folders, status: .warning, title: "Ingen outputmapp vald",
                detail: "Resultatet hamnar i \"processed\" inuti inputmappen. En egen outputmapp bredvid inputmappen är tydligare.",
                path: effectiveOutput?.path, fix: .chooseOutput
            ))
        }
        if let out = effectiveOutput {
            if let inDir = input.inputDir, samePath(out, inDir) {
                checks.append(Check(
                    id: "output.sameAsInput", section: .folders, status: .blocker, title: "Input och output är samma mapp",
                    detail: "Appen skulle blanda sina egna filer med NEF-filerna. Välj en separat outputmapp.",
                    path: out.path, fix: .chooseOutput
                ))
            } else if input.outputDir == nil, !inputUsable {
                // Standardmappen inuti en input som saknas — bara inputbristen är relevant.
            } else {
                let result = folderChecks(
                    key: "output", label: "Outputmappen", dir: out,
                    purpose: "allt appen skapar", chooseFix: .chooseOutput,
                    writeReason: "appen skriver DNG, förhandsbilder och adressmappar hit",
                    probe: probe, missingIsFine: input.outputDir == nil
                )
                checks += result.checks
                outputUsable = result.usable
                if let inDir = input.inputDir, input.outputDir != nil, isInside(out, inDir) {
                    checks.append(Check(
                        id: "output.insideInput", section: .folders, status: .warning,
                        title: "Outputmappen ligger inuti inputmappen",
                        detail: "Det fungerar, men det är lätt att råka radera resultatet tillsammans med råfilerna. Lägg den bredvid i stället.",
                        path: out.path, fix: .chooseOutput
                    ))
                }
            }
        }

        checks += usbChecks(
            input: inputUsable ? input.inputDir : nil,
            output: outputUsable ? effectiveOutput : nil,
            cards: input.sdCards, probe: probe
        )

        // Ledigt utrymme
        if outputUsable, let out = effectiveOutput {
            let measureAt = probe.item(out).exists ? out : out.deletingLastPathComponent()
            if let free = probe.freeBytes(measureAt) {
                let nef = inputUsable ? probe.nefBytes(input.inputDir!, effectiveOutput) : (count: 0, bytes: 0)
                let needed = Int64(Double(nef.bytes) * spaceFactor)
                let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                if free < minimumFreeBytes {
                    checks.append(Check(
                        id: "output.space", section: .folders, status: .blocker, title: "Nästan fullt på outputdisken",
                        detail: "Bara \(freeText) ledigt. Frigör plats eller välj en annan disk.",
                        path: out.path, fix: .chooseOutput
                    ))
                } else if needed > free {
                    let neededText = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                    checks.append(Check(
                        id: "output.space", section: .folders, status: .warning, title: "Platsen kan ta slut",
                        detail: "\(nef.count) NEF-filer behöver ungefär \(neededText), men bara \(freeText) är ledigt.",
                        path: out.path, fix: .chooseOutput
                    ))
                } else {
                    let detail = nef.count > 0
                        ? "\(freeText) ledigt — räcker för de \(nef.count) NEF-filerna i inputmappen."
                        : "\(freeText) ledigt."
                    checks.append(Check(id: "output.space", section: .folders, status: .ok, title: "Ledigt utrymme", detail: detail, path: out.path))
                }
            }
        }

        // Minneskort
        checks.append(Check(
            id: "sdcard", section: .folders, status: .info,
            title: input.sdCards.isEmpty ? "Inget minneskort anslutet" : "Minneskort anslutet",
            detail: input.sdCards.isEmpty
                ? "Sätt i kortet när du vill hämta bilder — med bevakning på kopieras NEF-filerna till inputmappen."
                : "\(input.sdCards.joined(separator: ", ")) — NEF-filerna kopieras till inputmappen när bevakningen är på."
        ))

        // Appens egen mapp (bryggan mot Lightroom, historik)
        let support = probe.item(input.supportDir)
        if support.exists && !support.writable {
            checks.append(Check(
                id: "support", section: .folders, status: .blocker, title: "Appens arbetsmapp är skrivskyddad",
                detail: "Historik och Lightroom-bryggan sparas här. Kontrollera behörigheterna i Finder.",
                path: input.supportDir.path, fix: .revealInFinder(input.supportDir)
            ))
        } else {
            checks.append(Check(
                id: "support", section: .folders, status: .ok, title: "Appens arbetsmapp",
                detail: support.exists ? "Historik och Lightroom-bryggan." : "Skapas automatiskt första gången den behövs.",
                path: input.supportDir.path
            ))
        }

        // Mappträdet
        var structure: [StructureEntry] = []
        if let dir = input.inputDir {
            structure.append(StructureEntry(
                name: dir.lastPathComponent, path: dir.path, purpose: "Input — NEF-filer",
                exists: probe.item(dir).isDirectory, depth: 0, createdByPipeline: false
            ))
        }
        if let out = effectiveOutput {
            structure.append(StructureEntry(
                name: out.lastPathComponent, path: out.path, purpose: "Output — allt appen skapar",
                exists: probe.item(out).isDirectory, depth: 0, createdByPipeline: input.outputDir == nil
            ))
            for sub in pipelineSubfolders {
                let url = out.appendingPathComponent(sub.name)
                structure.append(StructureEntry(
                    name: sub.name, path: url.path, purpose: sub.purpose,
                    exists: probe.item(url).isDirectory, depth: 1, createdByPipeline: true
                ))
            }
        }
        return (checks, structure)
    }

    /// USB-hastigheten för de externa diskar som input, output och anslutna
    /// minneskort ligger på — en per disk, med alla roller den har.
    private static func usbChecks(input: URL?, output: URL?, cards: [String], probe: FolderProbe) -> [Check] {
        var roles: [(root: URL, url: URL, role: String)] = []
        func add(_ url: URL?, _ role: String) {
            guard let url, let root = volumeRoot(of: url) else { return }
            if let i = roles.firstIndex(where: { samePath($0.root, root) }) {
                roles[i].role += " och \(role)"
            } else {
                roles.append((root, url, role))
            }
        }
        add(input, "inputmappen")
        add(output, "outputmappen")
        for card in cards { add(URL(fileURLWithPath: "/Volumes").appendingPathComponent(card), "minneskortet") }

        return roles.compactMap { entry in
            guard let link = probe.usbLink(entry.url) else { return nil }
            let name = entry.root.lastPathComponent.trimmingCharacters(in: .whitespaces)
            let id = "usb.\(name)"
            if link.isSlow {
                return Check(
                    id: id, section: .folders, status: .warning,
                    title: "\"\(name)\" är ansluten i USB 2.0-hastighet",
                    detail: "\(link.product) (\(entry.role)) går i \(link.label) i stället för 5–10 Gb/s, så kopiering och DNG-konvertering tar många gånger längre tid. "
                        + "Vanligast är kabeln — många USB-C-kablar klarar bara USB 2.0. Använd kabeln som följde med, tryck i kontakten ordentligt i båda ändar eller prova en annan port. Mata ut disken först.",
                    path: entry.root.path
                )
            }
            return Check(
                id: id, section: .folders, status: .ok, title: "Anslutning för \"\(name)\"",
                detail: "\(link.product) (\(entry.role)): \(link.label).", path: entry.root.path
            )
        }
    }

    /// Kontrollerna för en vald mapp: disken ansluten → mappen finns → är en mapp → läs/skriv.
    /// Returnerar bara den första bristen i den kedjan; den är det man ska åtgärda först.
    private static func folderChecks(
        key: String, label: String, dir: URL, purpose: String, chooseFix: Fix,
        writeReason: String, probe: FolderProbe, missingIsFine: Bool = false
    ) -> (checks: [Check], usable: Bool) {
        func check(_ suffix: String, _ status: Status, _ title: String, _ detail: String, _ fix: Fix?) -> Check {
            Check(id: "\(key).\(suffix)", section: .folders, status: status, title: title, detail: detail, path: dir.path, fix: fix)
        }
        if let volume = volumeRoot(of: dir), !probe.isVolumeMounted(volume) {
            return ([check(
                "volume", .blocker, "Disken \"\(volume.lastPathComponent)\" är inte ansluten",
                "\(label) ligger på en extern disk. Anslut disken — kontrollen uppdateras av sig själv — eller välj en annan mapp.",
                chooseFix
            )], false)
        }
        let state = probe.item(dir)
        if !state.exists {
            if missingIsFine {
                return ([check("exists", .ok, label, "Skapas vid första körningen.", nil)], true)
            }
            let parent = dir.deletingLastPathComponent()
            let parentOK = probe.item(parent).isDirectory
            return ([check(
                "exists", .blocker, "\(label) finns inte",
                parentOK
                    ? "Mappen \"\(dir.lastPathComponent)\" saknas. Skapa den, eller välj en annan."
                    : "Varken mappen eller \"\(parent.path)\" finns. Välj en annan mapp.",
                parentOK ? .createFolder(dir) : chooseFix
            )], false)
        }
        if !state.isDirectory {
            return ([check("notDirectory", .blocker, "\(label) är en fil, inte en mapp", "Välj en mapp i stället.", chooseFix)], false)
        }
        if !state.readable || !state.writable {
            return ([check(
                "access", .blocker,
                state.readable ? "\(label) är skrivskyddad" : "\(label) går inte att läsa",
                "Behövs eftersom \(writeReason). Kontrollera behörigheterna i Finder (Visa info), eller välj en annan mapp.",
                .revealInFinder(dir)
            )], false)
        }
        return ([check("ok", .ok, label, "Finns och går att skriva till — \(purpose).", .revealInFinder(dir))], true)
    }

    // MARK: Kalender

    private static func calendarSection(_ cal: CalendarInput, modelAvailable: Bool) -> [Check] {
        func check(_ id: String, _ status: Status, _ title: String, _ detail: String, _ fix: Fix? = nil) -> Check {
            Check(id: id, section: .calendar, status: status, title: title, detail: detail, fix: fix)
        }
        let chooseCalendars = Fix.openSettings(tab: 1, label: "Välj kalendrar…")
        guard cal.enabled else {
            return [check(
                "calendar.disabled", .info, "Kalendermatchning är avstängd",
                "Alla bilder hamnar under \"Osorterade\" i stället för i adressmappar.",
                .openSettings(tab: 1, label: "Inställningar…")
            )]
        }
        switch cal.access {
        case .notDetermined:
            return [check(
                "calendar.access", .warning, "Appen har inte fått kalenderåtkomst än",
                "Bokningarna i kalendern avgör vilken adressmapp bilderna hamnar i. Utan åtkomst hamnar allt under \"Osorterade\".",
                .requestCalendarAccess
            )]
        case .denied, .writeOnly:
            return [check(
                "calendar.access", .warning,
                cal.access == .writeOnly ? "Appen kan bara skriva i kalendern, inte läsa" : "Kalenderåtkomst är nekad",
                "Utan läsåtkomst hamnar alla bilder under \"Osorterade\". Slå på full åtkomst för PhotoFlow under Integritet och säkerhet → Kalendrar.",
                .openCalendarPrivacy
            )]
        case .full:
            break
        }

        var checks: [Check] = []
        if cal.selected.isEmpty {
            checks.append(check(
                "calendar.selection", .ok, "Alla kalendrar används",
                cal.available.isEmpty ? "Inga kalendrar hittades." : "\(cal.available.count) kalendrar: \(cal.available.joined(separator: ", ")).",
                chooseCalendars
            ))
        } else {
            let match = CalendarService.matchCalendarNames(selected: cal.selected, available: cal.available)
            if match.matched.isEmpty {
                checks.append(check(
                    "calendar.selection", .blocker, "Ingen av de valda kalendrarna finns",
                    "Valda: \(cal.selected.joined(separator: ", ")). Ingen bokning kommer att hittas — välj kalendrar på nytt.",
                    chooseCalendars
                ))
            } else if !match.notFound.isEmpty {
                checks.append(check(
                    "calendar.selection", .warning, "Vissa valda kalendrar finns inte",
                    "Hittas inte: \(match.notFound.joined(separator: ", ")). Används: \(match.matched.joined(separator: ", ")).",
                    chooseCalendars
                ))
            } else {
                checks.append(check(
                    "calendar.selection", .ok, "Valda kalendrar finns",
                    match.matched.joined(separator: ", "), chooseCalendars
                ))
            }
        }

        let testMatch = Fix.openSettings(tab: 1, label: "Testa matchning…")
        if cal.recentEventCount == 0 {
            checks.append(check(
                "calendar.events", .info, "Inga bokningar de senaste \(cal.recentDays) dagarna",
                "Stämmer det? Annars kan fel kalender vara vald.", testMatch
            ))
        } else if !cal.recentWithoutAddress.isEmpty {
            let examples = cal.recentWithoutAddress.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
            // Kontrollen läser titlarna med de enkla reglerna. Med Apple Intelligence
            // tolkas fler vid körning, så då är det bara värt att känna till.
            checks.append(check(
                "calendar.events", modelAvailable ? .info : .warning,
                "\(cal.recentWithoutAddress.count) av \(cal.recentEventCount) bokningar saknar tydlig adress",
                "T.ex. \(examples). "
                    + (modelAvailable
                        ? "Apple Intelligence försöker tolka dem vid körning — \"Testa matchning\" visar resultatet."
                        : "Bilder från dem hamnar under \"Osorterade\"."),
                testMatch
            ))
        } else {
            checks.append(check(
                "calendar.events", .ok, "Bokningarna går att läsa",
                "\(cal.recentEventCount) bokningar de senaste \(cal.recentDays) dagarna, alla med adress.", testMatch
            ))
        }
        return checks
    }

    // MARK: Verktyg

    private static func toolSection(_ tools: [ToolInput]) -> [Check] {
        tools.compactMap { tool in
            let id = "tool.\(tool.name)"
            if tool.ok {
                return Check(id: id, section: .tools, status: .ok, title: tool.name, detail: tool.detail ?? "Installerat.")
            }
            if tool.required {
                return Check(
                    id: id, section: .tools, status: .blocker, title: "\(tool.name) saknas",
                    detail: tool.detail ?? "Behövs för pipelinen.",
                    fix: .openSettings(tab: 4, label: "Installera…")
                )
            }
            return nil  // valfria verktyg som saknas syns under Inställningar → System
        }
    }

    // MARK: Lightroom

    private static func lightroomCheck(_ input: Input, probe: FolderProbe) -> Check {
        let link = probe.item(input.lightroomPluginLink)
        let url = input.lightroomPluginLink
        if let destination = link.symlinkDestination, !link.exists {
            return Check(
                id: "lightroom.plugin", section: .lightroom, status: .warning, title: "Lightroom-pluginets länk är trasig",
                detail: "Länken pekar på \(destination), som inte finns längre (har projektet flyttats?). Välj PhotoFlowLR.lrplugin på nytt och starta om Lightroom.",
                path: url.path, fix: .relinkLightroomPlugin
            )
        }
        if link.exists {
            return Check(
                id: "lightroom.plugin", section: .lightroom, status: .ok, title: "Lightroom-pluginet",
                detail: "Installerat" + (link.symlinkDestination.map { " (länk till \($0))" } ?? "") + ".",
                path: url.path, fix: .revealInFinder(url)
            )
        }
        return Check(
            id: "lightroom.plugin", section: .lightroom,
            status: input.lightroomInstalled ? .warning : .info,
            title: "Lightroom-pluginet är inte installerat",
            detail: input.lightroomInstalled
                ? "Behövs för att skicka bilder till Lightroom. Välj PhotoFlowLR.lrplugin så länkas det in."
                : "Behövs bara om du använder Lightroom Classic.",
            path: url.path, fix: .relinkLightroomPlugin
        )
    }

    // MARK: AI

    private static func aiSection(_ input: Input) -> [Check] {
        guard input.calendar.enabled || input.aiDescriptionsEnabled else { return [] }
        if input.modelAvailable {
            return [Check(
                id: "ai.model", section: .ai, status: .ok, title: "Apple Intelligence",
                detail: "Tillgängligt — tolkar bokningstitlar och skriver bildbeskrivningar."
            )]
        }
        return [Check(
            id: "ai.model", section: .ai, status: .info, title: "Apple Intelligence är inte tillgängligt",
            detail: "Adresser tolkas med enklare regler och bildbeskrivningar hoppas över. Slå på Apple Intelligence i Systeminställningar om datorn stöder det."
        )]
    }

    // MARK: - Sökvägshjälp

    /// `/Volumes/<namn>` för en sökväg på en extern volym, annars nil.
    static func volumeRoot(of url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2])
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.pathComponents == b.standardizedFileURL.pathComponents
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.pathComponents
        let p = parent.standardizedFileURL.pathComponents
        return c.count > p.count && c.starts(with: p)
    }
}
