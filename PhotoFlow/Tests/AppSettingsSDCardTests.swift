import Foundation
import Testing
@testable import PhotoFlow

/// Tests for `AppSettings.isCandidateSDCardVolume`, the pure decision logic behind
/// `sdCardSearchPaths`. Previously that property only excluded the volume literally
/// named "Macintosh HD" — breaks for a differently-named boot volume, a Time
/// Machine clone, or any other non-card external drive mounted under /Volumes.
struct AppSettingsSDCardTests {

    @Test("Root-filsystemet (boot-volymen) exkluderas alltid, oavsett namn")
    func rootFileSystem_alwaysExcluded() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: true, ejectable: true, isRootFileSystem: true, hasDCIM: true) == false)
    }

    @Test("Icke-flyttbar, icke-utmatningsbar volym exkluderas även med DCIM")
    func nonRemovableNonEjectable_excluded() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: false, ejectable: false, isRootFileSystem: false, hasDCIM: true) == false)
    }

    @Test("Flyttbar volym utan DCIM-mapp exkluderas")
    func removableWithoutDCIM_excluded() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: true, ejectable: false, isRootFileSystem: false, hasDCIM: false) == false)
    }

    @Test("Flyttbar volym med DCIM-mapp inkluderas (typiskt SD-kort)")
    func removableWithDCIM_included() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: true, ejectable: false, isRootFileSystem: false, hasDCIM: true) == true)
    }

    @Test("Utmatningsbar (men ej 'removable') volym med DCIM inkluderas")
    func ejectableWithDCIM_included() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: false, ejectable: true, isRootFileSystem: false, hasDCIM: true) == true)
    }

    @Test("Okända (nil) volymegenskaper hanteras som false, inte krasch")
    func nilProperties_treatedAsFalse() {
        #expect(AppSettings.isCandidateSDCardVolume(removable: nil, ejectable: nil, isRootFileSystem: nil, hasDCIM: true) == false)
    }

    // MARK: - sourceNeedsCopyToInput

    private let externalInput = URL(fileURLWithPath: "/Volumes/photo-ingestion/PhotoFlow/input")

    @Test("Inputmapp på extern disk: själva inputmappen kopieras inte till sig själv")
    func externalInput_itself_noCopy() {
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: externalInput, inputDir: externalInput) == false)
    }

    @Test("Inputmapp på extern disk: daterad undermapp kopieras inte (gav dubbletter förut)")
    func externalInput_subfolder_noCopy() {
        let sub = externalInput.appendingPathComponent("2026-10-03")
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: sub, inputDir: externalInput) == false)
    }

    @Test("SD-kortets DCIM kopieras till inputmappen")
    func sdCard_copies() {
        let dcim = URL(fileURLWithPath: "/Volumes/NIKON Z 8/DCIM/100NCZ_8")
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: dcim, inputDir: externalInput) == true)
    }

    @Test("Syskonmapp med gemensamt namnprefix räknas inte som inuti inputmappen")
    func siblingWithSharedPrefix_copies() {
        let sibling = URL(fileURLWithPath: "/Volumes/photo-ingestion/PhotoFlow/input-gammal")
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: sibling, inputDir: externalInput) == true)
    }

    @Test("Ingen inputmapp konfigurerad: faller tillbaka på det gamla /Volumes-beteendet")
    func noInputDir_fallsBackToVolumesPrefix() {
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: URL(fileURLWithPath: "/Volumes/CARD/DCIM"), inputDir: nil) == true)
        #expect(AppSettings.sourceNeedsCopyToInput(sourceDir: URL(fileURLWithPath: "/Users/x/Desktop/INPUT"), inputDir: nil) == false)
    }
}
