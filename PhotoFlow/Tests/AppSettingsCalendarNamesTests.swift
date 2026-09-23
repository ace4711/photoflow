import Foundation
import Testing
@testable import PhotoFlow

/// Fas 10: `AppSettings.calendarNames` — JSON-lagringen av flera valda
/// kalendrar och bakåtkompatibiliteten med det gamla enkalendervalet
/// (`calendarName`). Manipulerar `UserDefaults.standard` direkt för de
/// gamla/nya nycklarna (samma mönster som `PipelineRunnerHDROrphanTests`
/// använder för `hdrMergeEnabled`: spara originalvärdet, återställ i `defer`)
/// — `AppSettings.shared` är en riktig singleton uppbackad av riktiga
/// `UserDefaults`, det finns ingen isolerad testinstans att skapa i stället.
@MainActor
struct AppSettingsCalendarNamesTests {
    private static let legacyKey = "calendarName"
    private static let newKey = "calendarNames"

    /// Kör `block` med båda nycklarna borttagna ur `UserDefaults`, och
    /// återställer de ursprungliga värdena efteråt oavsett utfall.
    private func withCleanCalendarKeys(_ block: () -> Void) {
        let defaults = UserDefaults.standard
        let originalLegacy = defaults.string(forKey: Self.legacyKey)
        let originalNew = defaults.string(forKey: Self.newKey)
        defer {
            if let originalLegacy {
                defaults.set(originalLegacy, forKey: Self.legacyKey)
            } else {
                defaults.removeObject(forKey: Self.legacyKey)
            }
            if let originalNew {
                defaults.set(originalNew, forKey: Self.newKey)
            } else {
                defaults.removeObject(forKey: Self.newKey)
            }
        }
        defaults.removeObject(forKey: Self.legacyKey)
        defaults.removeObject(forKey: Self.newKey)
        block()
    }

    @Test("Inget sparat val alls ger en tom lista (\"Alla kalendrar\")")
    func calendarNames_default_isEmpty() {
        withCleanCalendarKeys {
            #expect(AppSettings.shared.calendarNames == [])
        }
    }

    @Test("Sparade namn läses tillbaka oförändrade, inklusive ett namn med komma i sig")
    func calendarNames_roundTrips_namesWithComma() {
        withCleanCalendarKeys {
            AppSettings.shared.calendarNames = ["Jobb, Anna", "Privat"]
            #expect(AppSettings.shared.calendarNames == ["Jobb, Anna", "Privat"])
        }
    }

    @Test("Bakåtkompatibilitet: saknad calendarNames-nyckel men satt gammal calendarName tolkas som ett enda valt namn")
    func calendarNames_fallsBackToLegacyCalendarName_whenKeyMissing() {
        withCleanCalendarKeys {
            AppSettings.shared.calendarName = "Fastighetsfoto"
            #expect(AppSettings.shared.calendarNames == ["Fastighetsfoto"])
        }
    }

    @Test("Bakåtkompatibilitetens fallback-läsning skriver INGET till UserDefaults")
    func calendarNames_legacyFallback_doesNotWriteNewKey() {
        withCleanCalendarKeys {
            AppSettings.shared.calendarName = "Fastighetsfoto"
            _ = AppSettings.shared.calendarNames
            #expect(UserDefaults.standard.string(forKey: Self.newKey) == nil)
        }
    }

    @Test("En explicit tom lista (nyckeln finns, sparad tom) faller INTE tillbaka på den gamla calendarName")
    func calendarNames_explicitEmpty_doesNotFallBackToLegacy() {
        withCleanCalendarKeys {
            AppSettings.shared.calendarName = "Fastighetsfoto"
            AppSettings.shared.calendarNames = []
            #expect(AppSettings.shared.calendarNames == [])
        }
    }

    @Test("Tom gammal calendarName ger en tom lista, inte [\"\"]")
    func calendarNames_emptyLegacyValue_returnsEmptyList() {
        withCleanCalendarKeys {
            AppSettings.shared.calendarName = ""
            #expect(AppSettings.shared.calendarNames == [])
        }
    }
}
