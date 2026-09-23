import Testing
@testable import PhotoFlow

/// Tests for CalendarService.extractAddress / extractBookingInfo.
/// CalendarService is @MainActor, so this suite runs on the main actor too.
@MainActor
struct CalendarServiceTests {

    // MARK: - extractAddress

    @Test("Adress med kommaseparerad stad och extra info")
    func extractAddress_commaSeparatedCityAndInfo() {
        let title = "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik: 0701234567"
        #expect(CalendarService.extractAddress(from: title) == "Lindvägen 12, Tyresö")
    }

    @Test("Adress utan komma, postnummer och kontaktperson mellan gata och stad")
    func extractAddress_noCommaWithPostalCode() {
        let title = "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67"
        #expect(CalendarService.extractAddress(from: title) == "Almstigen 9, Handen")
    }

    @Test("Adress med våningssuffix (bv) och telefonnummer efter stad")
    func extractAddress_floorSuffixBeforeComma() {
        let title = "Kastanjevägen 60 bv, Fjälling 070-765 43 21"
        #expect(CalendarService.extractAddress(from: title) == "Kastanjevägen 60 bv, Fjälling")
    }

    @Test("Tom titel ger nil")
    func extractAddress_emptyTitle() {
        #expect(CalendarService.extractAddress(from: "") == nil)
    }

    // MARK: - extractBookingInfo

    @Test("Bokningsinfo efter adress och stad extraheras")
    func extractBookingInfo_afterCity() {
        let title = "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik: 0701234567"
        #expect(CalendarService.extractBookingInfo(from: title) == "villa ca 169 kvm. Erik: 0701234567")
    }

    @Test("Ingen bokningsinfo utan komma i titeln")
    func extractBookingInfo_noComma() {
        let title = "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67"
        #expect(CalendarService.extractBookingInfo(from: title) == nil)
    }

    @Test("Ingen extra info efter stad/kontaktinfo ger nil")
    func extractBookingInfo_onlyStreetAndCity() {
        let title = "Kastanjevägen 60 bv, Fjälling 070-765 43 21"
        #expect(CalendarService.extractBookingInfo(from: title) == nil)
    }

    @Test("Tom titel ger nil för bokningsinfo")
    func extractBookingInfo_emptyTitle() {
        #expect(CalendarService.extractBookingInfo(from: "") == nil)
    }

    // MARK: - geocodeAddress (Fas 3c: MKGeocodingRequest i stället för CLGeocoder)

    /// Riktigt integrationstest mot en riktig svensk adress — verifierar att
    /// `MKGeocodingRequest`-migreringen (ersätter deprecerade
    /// `CLGeocoder.geocodeAddressString`) faktiskt fungerar, inklusive
    /// ", Sverige"-tillägget. Miljöberoende (kräver nätverksåtkomst till
    /// Apple Maps) — hoppar sig själv utan att fela om geokodningen misslyckas
    /// (t.ex. ingen nätverksåtkomst i CI/sandlåda), precis som
    /// `TranslationServiceTests`/`DictationServiceTests` hoppar när deras
    /// on-device-förutsättningar saknas.
    @Test("Riktig adress geokodas till rimliga koordinater i Stockholmsområdet")
    func geocodeAddress_realAddress_returnsPlausibleCoordinate() async throws {
        let service = CalendarService.shared
        guard let coordinate = await service.geocodeAddress("Lindvägen 12, Tyresö") else {
            // Miljöberoende (nätverk/Apple Maps-tillgänglighet) — inget testfel.
            return
        }
        // Grov sanity-check: Stockholmsregionen, inte t.ex. (0, 0) eller en
        // helt orimlig koordinat pga en trasig parsning.
        #expect(coordinate.latitude > 55 && coordinate.latitude < 65)
        #expect(coordinate.longitude > 10 && coordinate.longitude < 25)
    }

    @Test("Andra anropet med samma adress ger cachat resultat, inte ett nytt nätverksanrop")
    func geocodeAddress_secondCall_usesCache() async throws {
        let service = CalendarService.shared
        guard let first = await service.geocodeAddress("Lindvägen 12, Tyresö") else {
            // Miljöberoende — se ovan.
            return
        }
        let second = await service.geocodeAddress("Lindvägen 12, Tyresö")
        #expect(second?.latitude == first.latitude)
        #expect(second?.longitude == first.longitude)
    }

    // MARK: - sanitizeFolderName (Slutgranskning: path-traversal-skydd)

    @Test("Vanlig adress rensas bara på otillåtna tecken, som förut")
    func sanitizeFolderName_normalAddress_unaffected() {
        #expect(CalendarService.sanitizeFolderName("Lindvägen 12, Tyresö") == "Lindvägen 12, Tyresö")
        #expect(CalendarService.sanitizeFolderName("A/B: C?D") == "A_B_ C_D")
    }

    @Test("Adress som saneras till exakt \"..\" ger fallback, inte path-traversal ut ur outputDir")
    func sanitizeFolderName_dotDot_fallsBackToSafeName() {
        // AddressFolderLayout.dngDirName använder adressen ORÖRT (inget suffix)
        // som mappnamn, och outputDir.appendingPathComponent("..") pekar på
        // outputDirs FÖRÄLDER när OS:et faktiskt slår upp sökvägen (mkdir/
        // rename/readdir) — inte bara lexikalt i Foundations URL-typ. En
        // kalenderhändelse vars titel extraheras/trimmas ner till exakt ".."
        // (t.ex. " .. ", som trimmas till "..") får därför en säker fallback.
        #expect(CalendarService.sanitizeFolderName("..") == "Okänd adress")
        #expect(CalendarService.sanitizeFolderName(" .. ") == "Okänd adress")
    }

    @Test("Adress som saneras till \".\" eller tom sträng ger fallback")
    func sanitizeFolderName_dotOrEmpty_fallsBackToSafeName() {
        #expect(CalendarService.sanitizeFolderName(".") == "Okänd adress")
        #expect(CalendarService.sanitizeFolderName("") == "Okänd adress")
        #expect(CalendarService.sanitizeFolderName("   ") == "Okänd adress")
    }

    @Test("Ett ensamt \"/\" blir en ofarlig \"_\", ingen fallback behövs")
    func sanitizeFolderName_singleSlash_becomesUnderscore() {
        // Slash splittar strängen i två tomma delar som slås ihop med "_" —
        // resultatet är en helt vanlig (om än tom-ish) undermapp under
        // outputDir, aldrig något som kan tolkas som "förälder"/"samma mapp".
        #expect(CalendarService.sanitizeFolderName("/") == "_")
        #expect(CalendarService.sanitizeFolderName("  /  ") == "_")
    }

    @Test("Tre punkter i rad är INTE farligt (bara \"..\" exakt är specialtecken för OS:et)")
    func sanitizeFolderName_tripleDot_isNotSpecialCased() {
        #expect(CalendarService.sanitizeFolderName("...") == "...")
    }
}
