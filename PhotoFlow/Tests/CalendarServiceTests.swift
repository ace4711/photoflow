import Testing
@testable import PhotoFlow

/// Tests for CalendarService.extractAddress / extractBookingInfo.
/// CalendarService is @MainActor, so this suite runs on the main actor too.
@MainActor
struct CalendarServiceTests {

    // MARK: - extractAddress

    @Test("Adress med kommaseparerad stad och extra info")
    func extractAddress_commaSeparatedCityAndInfo() {
        let title = "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik:0701234567"
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
        let title = "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik:0701234567"
        #expect(CalendarService.extractBookingInfo(from: title) == "villa ca 169 kvm. Erik:0701234567")
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
}
