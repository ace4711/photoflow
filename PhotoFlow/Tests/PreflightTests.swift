import Foundation
import Testing
@testable import PhotoFlow

/// Tester för `Preflight.evaluate` — startkontrollens rena beslutslogik — mot ett
/// påhittat filsystem (`FakeDisk`), så inga riktiga diskar eller kalendrar behövs.
struct PreflightTests {

    // MARK: - Påhittat filsystem

    nonisolated final class FakeDisk: @unchecked Sendable {
        var items: [String: Preflight.ItemState] = [:]
        var mounted: Set<String> = []
        var free: Int64? = 500_000_000_000
        var nef: (count: Int, bytes: Int64) = (0, 0)

        func dir(_ path: String, writable: Bool = true) {
            items[path] = .init(exists: true, isDirectory: true, readable: true, writable: writable)
        }

        var probe: Preflight.FolderProbe {
            Preflight.FolderProbe(
                item: { [self] in items[$0.standardizedFileURL.path] ?? .init() },
                isVolumeMounted: { [self] in mounted.contains($0.path) },
                freeBytes: { [self] _ in free },
                nefBytes: { [self] _, _ in nef }
            )
        }
    }

    static let ext = "/Volumes/photo-ingestion/PhotoFlow"

    /// En disk där allt är på plats: extern disk ansluten, input/output finns.
    func healthyDisk() -> FakeDisk {
        let disk = FakeDisk()
        disk.mounted = ["/Volumes/photo-ingestion"]
        disk.dir(Self.ext)
        disk.dir("\(Self.ext)/input")
        disk.dir("\(Self.ext)/output")
        disk.dir("/Users/x/Library/Application Support/PhotoFlow")
        disk.items["/Users/x/Library/Application Support/Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin"] =
            .init(exists: true, isDirectory: true, readable: true, writable: true)
        return disk
    }

    func input(
        inputDir: String? = "\(ext)/input",
        outputDir: String? = "\(ext)/output",
        calendar: Preflight.CalendarInput? = nil,
        tools: [Preflight.ToolInput] = [],
        lightroomInstalled: Bool = true,
        modelAvailable: Bool = false
    ) -> Preflight.Input {
        Preflight.Input(
            inputDir: inputDir.map { URL(fileURLWithPath: $0) },
            outputDir: outputDir.map { URL(fileURLWithPath: $0) },
            supportDir: URL(fileURLWithPath: "/Users/x/Library/Application Support/PhotoFlow"),
            lightroomPluginLink: URL(fileURLWithPath: "/Users/x/Library/Application Support/Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin"),
            lightroomInstalled: lightroomInstalled,
            sdCards: [],
            calendar: calendar ?? Self.calendarOK,
            tools: tools,
            modelAvailable: modelAvailable,
            aiDescriptionsEnabled: false
        )
    }

    static let calendarOK = Preflight.CalendarInput(
        enabled: true, access: .full, selected: ["Bokningar"], available: ["Bokningar", "Privat"],
        recentEventCount: 5, recentWithoutAddress: []
    )

    // MARK: - Mappar

    @Test("Allt på plats: inga blockerande eller varnande fynd")
    func healthy_noProblems() {
        let report = Preflight.evaluate(input(), probe: healthyDisk().probe)
        #expect(report.blockers.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.check("input.ok")?.status == .ok)
        #expect(report.check("output.ok")?.status == .ok)
        #expect(report.summary == "Allt klart")
    }

    @Test("Ingen inputmapp vald blockerar och erbjuder att välja")
    func noInput_blocks() {
        let report = Preflight.evaluate(input(inputDir: nil), probe: healthyDisk().probe)
        #expect(report.check("input.missing")?.status == .blocker)
        #expect(report.check("input.missing")?.fix == .chooseInput)
    }

    @Test("Extern disk inte ansluten blockerar för både input och output, med diskens namn")
    func volumeNotMounted_blocks() {
        let disk = healthyDisk()
        disk.mounted = []
        let report = Preflight.evaluate(input(), probe: disk.probe)
        let inputCheck = report.check("input.volume")
        #expect(inputCheck?.status == .blocker)
        #expect(inputCheck?.title.contains("photo-ingestion") == true)
        #expect(inputCheck?.fix == .chooseInput)
        #expect(report.check("output.volume")?.fix == .chooseOutput)
        #expect(report.blockers.count == 2)
    }

    @Test("Saknad mapp med befintlig föräldermapp erbjuder att skapa den")
    func missingFolder_parentExists_offersCreate() {
        let disk = healthyDisk()
        disk.items["\(Self.ext)/input"] = nil
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("input.exists")?.status == .blocker)
        #expect(report.check("input.exists")?.fix == .createFolder(URL(fileURLWithPath: "\(Self.ext)/input")))
    }

    @Test("Saknad mapp utan föräldermapp erbjuder att välja en annan, inte att skapa")
    func missingFolder_noParent_offersChoose() {
        let disk = healthyDisk()
        disk.items["\(Self.ext)/input"] = nil
        disk.items[Self.ext] = nil
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("input.exists")?.fix == .chooseInput)
    }

    @Test("Skrivskyddad outputmapp blockerar")
    func readOnlyOutput_blocks() {
        let disk = healthyDisk()
        disk.dir("\(Self.ext)/output", writable: false)
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("output.access")?.status == .blocker)
        #expect(report.check("output.access")?.title.contains("skrivskyddad") == true)
    }

    @Test("En fil i stället för en mapp blockerar")
    func fileInsteadOfFolder_blocks() {
        let disk = healthyDisk()
        disk.items["\(Self.ext)/input"] = .init(exists: true, isDirectory: false, readable: true, writable: true)
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("input.notDirectory")?.status == .blocker)
    }

    @Test("Samma mapp för input och output blockerar")
    func sameInputOutput_blocks() {
        let report = Preflight.evaluate(input(outputDir: "\(Self.ext)/input"), probe: healthyDisk().probe)
        #expect(report.check("output.sameAsInput")?.status == .blocker)
    }

    @Test("Outputmapp inuti inputmappen ger en varning")
    func outputInsideInput_warns() {
        let disk = healthyDisk()
        disk.dir("\(Self.ext)/input/ut")
        let report = Preflight.evaluate(input(outputDir: "\(Self.ext)/input/ut"), probe: disk.probe)
        #expect(report.check("output.insideInput")?.status == .warning)
    }

    @Test("Ingen outputmapp vald: varning, och processed räknas som 'skapas vid körning'")
    func noOutput_warnsButProcessedIsFine() {
        let report = Preflight.evaluate(input(outputDir: nil), probe: healthyDisk().probe)
        #expect(report.check("output.default")?.status == .warning)
        #expect(report.check("output.exists")?.status == .ok)
        #expect(report.blockers.isEmpty)
    }

    @Test("Nästan full disk blockerar")
    func lowSpace_blocks() {
        let disk = healthyDisk()
        disk.free = 500_000_000
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("output.space")?.status == .blocker)
    }

    @Test("Mer NEF än vad som får plats ger en varning med antalet filer")
    func notEnoughSpaceForNEF_warns() {
        let disk = healthyDisk()
        disk.free = 10_000_000_000
        disk.nef = (200, 6_000_000_000)  // × 3,5 ≈ 21 GB
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.check("output.space")?.status == .warning)
        #expect(report.check("output.space")?.detail.contains("200 NEF") == true)
    }

    @Test("Mappträdet visar input, output och pipelinens undermappar")
    func structure_listsFolders() {
        let disk = healthyDisk()
        disk.dir("\(Self.ext)/output/dng")
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.structure.map(\.name) == ["input", "output", "dng", "previews", "hdr", "bracket_groups"])
        #expect(report.structure.first { $0.name == "dng" }?.exists == true)
        #expect(report.structure.first { $0.name == "hdr" }?.exists == false)
        #expect(report.structure.first { $0.name == "hdr" }?.createdByPipeline == true)
    }

    // MARK: - Kalender

    @Test("Kalendermatchning avstängd är bara info")
    func calendarDisabled_info() {
        var cal = Self.calendarOK
        cal.enabled = false
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(report.check("calendar.disabled")?.status == .info)
    }

    @Test("Ingen kalenderåtkomst än erbjuder att be om den")
    func calendarNotDetermined_offersRequest() {
        var cal = Self.calendarOK
        cal.access = .notDetermined
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(report.check("calendar.access")?.status == .warning)
        #expect(report.check("calendar.access")?.fix == .requestCalendarAccess)
    }

    @Test("Nekad kalenderåtkomst pekar till Systeminställningar")
    func calendarDenied_opensPrivacy() {
        var cal = Self.calendarOK
        cal.access = .denied
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(report.check("calendar.access")?.fix == .openCalendarPrivacy)
    }

    @Test("Ingen av de valda kalendrarna finns: blockerar")
    func calendarNoneFound_blocks() {
        var cal = Self.calendarOK
        cal.selected = ["Gammal kalender"]
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(report.check("calendar.selection")?.status == .blocker)
    }

    @Test("Vissa valda kalendrar saknas: varning som namnger dem")
    func calendarSomeMissing_warns() {
        var cal = Self.calendarOK
        cal.selected = ["Bokningar", "Gammal kalender"]
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        let check = report.check("calendar.selection")
        #expect(check?.status == .warning)
        #expect(check?.detail.contains("Gammal kalender") == true)
    }

    @Test("Bokningar utan adress: varning utan AI-modell, info med")
    func calendarEventsWithoutAddress() {
        var cal = Self.calendarOK
        cal.recentWithoutAddress = ["Möte med mäklare"]
        let without = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(without.check("calendar.events")?.status == .warning)
        let with = Preflight.evaluate(input(calendar: cal, modelAvailable: true), probe: healthyDisk().probe)
        #expect(with.check("calendar.events")?.status == .info)
    }

    @Test("Inga bokningar alls de senaste dagarna är info, inte fel")
    func calendarNoEvents_info() {
        var cal = Self.calendarOK
        cal.recentEventCount = 0
        let report = Preflight.evaluate(input(calendar: cal), probe: healthyDisk().probe)
        #expect(report.check("calendar.events")?.status == .info)
    }

    // MARK: - Verktyg och Lightroom

    @Test("Ett nödvändigt verktyg som saknas blockerar och pekar till installationen")
    func missingTool_blocks() {
        let tools = [
            Preflight.ToolInput(name: "exiftool", required: true, ok: false, detail: "brew install exiftool"),
            Preflight.ToolInput(name: "Adobe DNG Converter", required: true, ok: true, detail: nil),
        ]
        let report = Preflight.evaluate(input(tools: tools), probe: healthyDisk().probe)
        #expect(report.check("tool.exiftool")?.status == .blocker)
        #expect(report.check("tool.exiftool")?.fix == .openSettings(tab: 4, label: "Installera…"))
        #expect(report.check("tool.Adobe DNG Converter")?.status == .ok)
    }

    @Test("Trasig pluginlänk ger varning med åtgärd att länka om")
    func brokenPluginLink_warns() {
        let disk = healthyDisk()
        disk.items["/Users/x/Library/Application Support/Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin"] =
            .init(exists: false, symlinkDestination: "/gammal/plats/PhotoFlowLR.lrplugin")
        let report = Preflight.evaluate(input(), probe: disk.probe)
        let check = report.check("lightroom.plugin")
        #expect(check?.status == .warning)
        #expect(check?.fix == .relinkLightroomPlugin)
        #expect(check?.detail.contains("/gammal/plats") == true)
    }

    @Test("Saknat plugin utan Lightroom installerat är bara info")
    func noPluginNoLightroom_info() {
        let disk = healthyDisk()
        disk.items["/Users/x/Library/Application Support/Adobe/Lightroom/Modules/PhotoFlowLR.lrplugin"] = nil
        let report = Preflight.evaluate(input(lightroomInstalled: false), probe: disk.probe)
        #expect(report.check("lightroom.plugin")?.status == .info)
    }

    // MARK: - Övrigt

    @Test("Blockerande fynd sorteras först")
    func ordering_blockersFirst() {
        let disk = healthyDisk()
        disk.mounted = []
        let report = Preflight.evaluate(input(), probe: disk.probe)
        #expect(report.checks.first?.status == .blocker)
        let statuses = report.checks.map(\.status)
        #expect(statuses == statuses.sorted(by: >))
    }

    @Test("volumeRoot känner igen externa volymer och bara dem")
    func volumeRoot() {
        #expect(Preflight.volumeRoot(of: URL(fileURLWithPath: "\(Self.ext)/input"))?.path == "/Volumes/photo-ingestion")
        #expect(Preflight.volumeRoot(of: URL(fileURLWithPath: "/Users/x/Desktop/INPUT")) == nil)
    }
}
