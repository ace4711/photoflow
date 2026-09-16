import Foundation
import Testing
@testable import PhotoFlow

/// Tests for the Fas 1b follow-up (Fas 4): correcting a mismatched address in
/// `AddressBanner` previously left `PipelineRunner.calendarMappings` (the
/// folder-naming source of truth) pointing at the OLD address, and never
/// offered to rename already-sorted on-disk folders. See
/// `PipelineRunner+AddressCorrection.swift`.
@MainActor
struct PipelineRunnerAddressCorrectionTests {

    private func tempOutputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineRunnerAddressCorrectionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("updateCalendarMappingAddress uppdaterar bara matchande poster")
    func updateCalendarMappingAddress_updatesMatchingEntries() {
        let state = PipelineState()
        let runner = PipelineRunner(state: state)
        let now = Date()
        runner.calendarMappings = [
            (address: "Fel Gatan 1, Fel Stad", eventTitle: "A", photoDateRange: now...now),
            (address: "Annan adress", eventTitle: "B", photoDateRange: now...now)
        ]

        runner.updateCalendarMappingAddress(from: "Fel Gatan 1, Fel Stad", to: "Rätt Gatan 2, Rätt Stad")

        #expect(runner.calendarMappings[0].address == "Rätt Gatan 2, Rätt Stad")
        #expect(runner.calendarMappings[1].address == "Annan adress")
    }

    @Test("addressFolderAlreadySorted är false utan files_sorted.json")
    func addressFolderAlreadySorted_falseWithoutMarker() {
        let dir = tempOutputDir()
        let state = PipelineState()
        state.outputDirectory = dir
        let runner = PipelineRunner(state: state)

        #expect(runner.addressFolderAlreadySorted("Fel Gatan 1, Fel Stad") == false)
    }

    @Test("addressFolderAlreadySorted är sant när markören och adressmappen finns")
    func addressFolderAlreadySorted_trueWhenMarkerAndFolderExist() {
        let dir = tempOutputDir()
        try! Data("{}".utf8).write(to: dir.appendingPathComponent("files_sorted.json"))
        let folderName = CalendarService.sanitizeFolderName("Fel Gatan 1, Fel Stad")
        try! FileManager.default.createDirectory(
            at: AddressFolderLayout.dngDir(in: dir, folderName: folderName),
            withIntermediateDirectories: true
        )

        let state = PipelineState()
        state.outputDirectory = dir
        let runner = PipelineRunner(state: state)

        #expect(runner.addressFolderAlreadySorted("Fel Gatan 1, Fel Stad") == true)
    }

    @Test("resortAddressFolder döper om DNG/TITTBILDER/ÖVRIGA-mapparna och uppdaterar calendarMappings")
    func resortAddressFolder_renamesFoldersAndUpdatesMapping() {
        let dir = tempOutputDir()
        let oldAddress = "Fel Gatan 1, Fel Stad"
        let newAddress = "Rätt Gatan 2, Rätt Stad"
        let oldName = CalendarService.sanitizeFolderName(oldAddress)
        let fm = FileManager.default

        try! fm.createDirectory(at: AddressFolderLayout.dngDir(in: dir, folderName: oldName), withIntermediateDirectories: true)
        try! fm.createDirectory(at: AddressFolderLayout.previewDir(in: dir, folderName: oldName), withIntermediateDirectories: true)
        try! fm.createDirectory(at: AddressFolderLayout.extrasDir(in: dir, folderName: oldName), withIntermediateDirectories: true)
        let markerFile = AddressFolderLayout.dngDir(in: dir, folderName: oldName).appendingPathComponent("DSC_0001.dng")
        try! Data("x".utf8).write(to: markerFile)

        let state = PipelineState()
        state.outputDirectory = dir
        let runner = PipelineRunner(state: state)
        let now = Date()
        runner.calendarMappings = [(address: oldAddress, eventTitle: "A", photoDateRange: now...now)]

        let moved = runner.resortAddressFolder(from: oldAddress, to: newAddress)
        #expect(moved == true)

        let newName = CalendarService.sanitizeFolderName(newAddress)
        #expect(fm.fileExists(atPath: AddressFolderLayout.dngDir(in: dir, folderName: newName).path))
        #expect(fm.fileExists(atPath: AddressFolderLayout.dngDir(in: dir, folderName: newName).appendingPathComponent("DSC_0001.dng").path))
        #expect(!fm.fileExists(atPath: AddressFolderLayout.dngDir(in: dir, folderName: oldName).path))
        #expect(runner.calendarMappings[0].address == newAddress)
    }

    @Test("resortAddressFolder är no-op om inga adressmappar finns på disk")
    func resortAddressFolder_noOpWhenNoFoldersExist() {
        let dir = tempOutputDir()
        let state = PipelineState()
        state.outputDirectory = dir
        let runner = PipelineRunner(state: state)

        let moved = runner.resortAddressFolder(from: "A", to: "B")
        #expect(moved == false)
    }
}
