import Testing
@testable import PhotoFlow

/// Tester för `BookingTitleParser` (Fas 3d).
///
/// `syntheticTitles` är 14 påhittade, realistiska svenska kalendertitlar
/// (inga riktiga personuppgifter — namn/telefonnummer är uppdiktade) som
/// täcker variationerna som riktiga mäklarbokningstitlar brukar ha: med/utan
/// komma, med/utan postnummer, våningssuffix ("bv", "1 tr", "nb"),
/// bostadstyp + area, kontaktperson + telefonnummer i olika format, och
/// extra fritext. `CalendarServiceTests` täcker redan tre riktiga exempel ur
/// produktionsanvändning (Fas 0) — de här är ett bredare syntetiskt urval
/// specifikt för att jämföra modell mot heuristik.
///
/// EventKit-åtkomst till användarens riktiga kalender kräver ett
/// användargodkännande som inte kan ges i den här GUI-lösa, autonoma
/// körningen, så jämförelsen kör mot den här syntetiska fixturen i stället
/// för riktiga bokningstitlar (se FORBATTRINGAR.md, Fas 3d, för resonemang).
@MainActor
struct BookingTitleParserTests {
    static let syntheticTitles: [String] = [
        "Fotografering Lindvägen 12, Stockholm",
        "Foto - Kungsgatan 5, 41119 Göteborg - Villa 145kvm",
        "Fototid Storgatan 12B lgh 1101, Malmö - Anna Karlsson 070-123 45 67",
        "Objektfoto: Ekvägen 3, bv, Lund",
        "Fotografering villa Sjövägen 8, 1 tr, kontakt Erik Svensson 0733-445566",
        "Ringvägen 14 611 32 Nyköping Peter Åberg 076-1112233",
        "Kyrkogatan 9 Uppsala",
        "Fotografering bostadsrätt Vasagatan 44, Örebro, 78 kvm",
        "Åkervägen 2 nb, 195 60 Arlandastad, Karin Ek 08-59512345",
        "Fototid: Norra Ängby 12, Bromma - fritidshus 55 kvm, Lars Berg: 070-9998877",
        "Skogsvägen 7, Täby",
        "Bryggargatan 3 111 21 Stockholm",
        "Fotografering radhus Almvägen 19, 2 tr, Sollentuna, ca 120 kvm, Maria Nilsson: 073-5551234",
        "Trädgårdsgatan 5B, Visby - Sara Holm 070-2223344"
    ]

    // MARK: - Heuristisk fallback (deterministisk, körs alltid)

    @Test("Heuristisk fallback ger en icke-tom gatuadress för alla syntetiska titlar")
    func heuristicParse_allSyntheticTitles_extractsStreet() {
        for title in Self.syntheticTitles {
            let info = BookingTitleParser.heuristicParse(title: title)
            #expect(!info.street.trimmingCharacters(in: .whitespaces).isEmpty, "Ingen gata extraherad från: \"\(title)\"")
        }
    }

    @Test("addressString formaterar 'Gata Nummer, Ort' — samma form som gamla extractAddress")
    func addressString_matchesOldFormat() {
        let info = BookingTitleParser.heuristicParse(title: "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik: 0701234567")
        #expect(BookingTitleParser.addressString(from: info) == "Lindvägen 12, Tyresö")
    }

    @Test("addressString utan ort returnerar bara gatan")
    func addressString_noCity_returnsStreetOnly() {
        let info = BookingInfo(street: "Skogsvägen 7", city: nil, propertyType: nil, areaSquareMeters: nil, contactName: nil, contactPhone: nil)
        #expect(BookingTitleParser.addressString(from: info) == "Skogsvägen 7")
    }

    @Test("bookingInfoText formaterar typ, area och kontakt i samma stil som gamla extractBookingInfo")
    func bookingInfoText_formatsAllFields() {
        let info = BookingInfo(street: "X", city: "Y", propertyType: "Villa", areaSquareMeters: 169, contactName: "Erik", contactPhone: "0701234567")
        #expect(BookingTitleParser.bookingInfoText(from: info) == "Villa ca 169 kvm. Erik: 0701234567")
    }

    @Test("Tom titel ger tom BookingInfo, inte en krasch")
    func parse_emptyTitle_returnsEmptyInfo() async {
        let info = await BookingTitleParser.shared.parse(title: "")
        #expect(info.street.isEmpty)
        #expect(BookingTitleParser.addressString(from: info) == nil)
    }

    // MARK: - Jämförelse modell vs heuristik (Fas 3d)

    /// Kör båda vägarna för samtliga syntetiska titlar och skriver resultatet
    /// till testloggen (se FORBATTRINGAR.md för den sammanställda
    /// jämförelsetabellen). Hoppar sig själv utan att fela om Foundation
    /// Models inte är tillgängligt på maskinen som kör testet — precis som
    /// `TranslationServiceTests`/`DictationServiceTests` gör för sina
    /// on-device-modeller.
    ///
    /// OBS: detta anropar den riktiga on-device-modellen (inget nätverk) och
    /// sparar därför även dessa 14 syntetiska titlar i den riktiga
    /// `booking_titles.json`-cachen i Application Support. Ofarligt (bara
    /// extra nycklar som aldrig matchar en riktig kalendertitel), men värt
    /// att veta om man inspekterar den filen efteråt.
    @Test("Jämförelse: modell vs heuristik för 14 syntetiska titlar")
    func compareModelVsHeuristic_syntheticTitles() async {
        guard BookingTitleParser.isModelAvailable else {
            return
        }
        print("=== BookingTitleParser: modell vs heuristik (Fas 3d) ===")
        for title in Self.syntheticTitles {
            let heuristic = BookingTitleParser.heuristicParse(title: title)
            let model = await BookingTitleParser.shared.parse(title: title)
            print("TITEL: \(title)")
            print("  Heuristik: street=\"\(heuristic.street)\" city=\(heuristic.city ?? "-") typ=\(heuristic.propertyType ?? "-") area=\(heuristic.areaSquareMeters.map(String.init) ?? "-") kontakt=\(heuristic.contactName ?? "-") tel=\(heuristic.contactPhone ?? "-")")
            print("  Modell:    street=\"\(model.street)\" city=\(model.city ?? "-") typ=\(model.propertyType ?? "-") area=\(model.areaSquareMeters.map(String.init) ?? "-") kontakt=\(model.contactName ?? "-") tel=\(model.contactPhone ?? "-")")
            // Adressformatet (mappnamnet) ska alltid bli icke-tomt för dessa titlar.
            #expect(BookingTitleParser.addressString(from: model) != nil)
        }
    }
}
