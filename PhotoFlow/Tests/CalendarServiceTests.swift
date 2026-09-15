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
}
