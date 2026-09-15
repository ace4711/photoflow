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
}
