import Foundation
import Testing
@testable import PhotoFlow

/// Den riktiga sessionen (2026-10-02) där felet upptäcktes: intervallen i `calendar_matches.json`
/// som den gamla per-bild-matchningen gav (UTC).
enum RealSessionFixture {
    static func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: "2026-10-02T\(s)Z")! }

    static let mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = [
        ("Svartskogsvägen 15", "Svartskogsvägen 15", utc("07:04:37")...utc("08:51:44")),
        ("Lillvägen 24", "Lillvägen 24", utc("09:39:22")...utc("11:15:00")),
        ("Kyndelgränd 19", "Kyndelgränd 19", utc("11:15:02")...utc("11:25:20")),
        ("Berghöjdsvägen 48", "Berghöjdsvägen 48", utc("12:22:20")...utc("12:39:39")),
        ("Björnvägen 32", "Björnvägen 32", utc("13:19:22")...utc("14:14:49")),
        ("Tjärnstigen 55A", "Tjärnstigen 55A", utc("14:16:33")...utc("14:35:48")),
    ]
}

@MainActor
struct PhotoClusteringTests {
    private func utc(_ s: String) -> Date { RealSessionFixture.utc(s) }

    // MARK: - addressFolder (reserven för bilder efter matchningen)

    @Test("addressFolder med de riktiga intervallen: inom intervall först, annars närmaste inom 5 min",
          arguments: [
              ("11:15:00", "Lillvägen 24"),
              ("11:15:01", "Lillvägen 24"),     // lika långt till båda (1 s) → tidigaste mappningen
              ("11:15:02", "Kyndelgränd 19"),   // förut: Lillvägen (första träff med 5 min marginal)
              ("11:17:00", "Kyndelgränd 19"),
              ("11:20:30", "Kyndelgränd 19"),
              ("14:15:30", "Björnvägen 32"),    // 41 s efter Björnvägen, 63 s före Tjärnstigen
              ("14:16:33", "Tjärnstigen 55A"),  // förut: Björnvägen
              ("14:20:00", "Tjärnstigen 55A"),
              ("14:40:00", "Tjärnstigen 55A"),  // 4 min 12 s efter sista
              ("14:45:00", nil as String?),     // mer än 5 min från allt
          ] as [(String, String?)])
    func addressFolder_realIntervals(time: String, expected: String?) {
        #expect(PhotoClustering.addressFolder(for: utc(time), mappings: RealSessionFixture.mappings) == expected)
        #expect(CalendarService.shared.addressFolder(for: utc(time), mappings: RealSessionFixture.mappings) == expected)
    }

    @Test("addressFolder: överlappande intervall ger den första som innehåller tiden; lika avstånd ger den tidigaste")
    func addressFolder_overlapAndTies() {
        let t0 = utc("10:00:00")
        let overlapping: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = [
            ("A", "", t0...t0.addingTimeInterval(600)),
            ("B", "", t0.addingTimeInterval(300)...t0.addingTimeInterval(900)),
        ]
        #expect(PhotoClustering.addressFolder(for: t0.addingTimeInterval(400), mappings: overlapping) == "A")
        #expect(PhotoClustering.addressFolder(for: t0.addingTimeInterval(800), mappings: overlapping) == "B")
        let gap: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = [
            ("B", "", t0.addingTimeInterval(200)...t0.addingTimeInterval(300)),
            ("A", "", t0...t0.addingTimeInterval(100)),
        ]
        // Mitt emellan (50 s till båda): listans ordning avgör, deterministiskt.
        #expect(PhotoClustering.addressFolder(for: t0.addingTimeInterval(150), mappings: gap) == "B")
        #expect(PhotoClustering.addressFolder(for: t0.addingTimeInterval(140), mappings: gap) == "A")
        #expect(PhotoClustering.addressFolder(for: t0.addingTimeInterval(160), mappings: gap) == "B")
    }

    // MARK: - Klustring

    /// En serie bilder med `step` sekunders mellanrum från `start` (UTC "HH:mm:ss").
    private func series(_ start: String, count: Int, step: TimeInterval = 2) -> [Date] {
        (0..<count).map { utc(start).addingTimeInterval(Double($0) * step) }
    }

    @Test("Tröskeln: minst 15 min, annars 30 × medianluckan")
    func gapThreshold() {
        #expect(PhotoClustering.gapThreshold(for: series("10:00:00", count: 100)) == 15 * 60)
        #expect(PhotoClustering.gapThreshold(for: series("10:00:00", count: 10, step: 60)) == 30 * 60)
        let clusters = PhotoClustering.clusters(series("10:00:00", count: 3) + series("10:20:00", count: 2) + series("10:30:00", count: 2),
                                                threshold: 15 * 60)
        #expect(clusters.map(\.count) == [3, 4])
    }

    /// Syntetisk serie som efterliknar den riktiga sessionen (lokal tid = UTC+2 där):
    /// Lillvägen 11:39–12:05, 55 min paus, Kyndelgränd 13:00–13:25 (Lillvägens bokning slutar 13:00,
    /// så den gamla matchningen med 15 min marginal gav Lillvägen bilderna fram till 13:15);
    /// Björnvägen 15:19–15:51 och Tjärnstigen 16:14–16:35 (Björnvägens bokning slutar 16:00).
    private var sessionLikeDates: [Date] {
        series("09:39:22", count: 40, step: 30) + series("10:00:00", count: 60, step: 5)     // Lillvägen
        + series("11:00:26", count: 20, step: 15) + series("11:07:04", count: 80, step: 3)   // Kyndelgränd (ett kluster)
        + series("13:19:22", count: 100, step: 10) + series("13:40:00", count: 30, step: 20) // Björnvägen
        + series("14:14:19", count: 16, step: 2) + series("14:16:33", count: 120, step: 9)   // Tjärnstigen
    }

    private var sessionLikeBookings: [PhotoClustering.Booking] {
        [
            .init(title: "Lillvägen 24", address: "Lillvägen 24", start: utc("09:30:00"), end: utc("11:00:00")),
            .init(title: "Kyndelgränd 19", address: "Kyndelgränd 19", start: utc("11:00:00"), end: utc("12:00:00")),
            .init(title: "Björnvägen 32", address: "Björnvägen 32", start: utc("13:00:00"), end: utc("14:00:00")),
            .init(title: "Tjärnstigen 55A", address: "Tjärnstigen 55A", start: utc("14:00:00"), end: utc("15:00:00")),
        ]
    }

    @Test("Sessionsliknande serie: ett kluster per adress, bokningsgränsen mitt i ett kluster delar det inte")
    func sessionLike_oneClusterPerAddress() {
        let result = PhotoClustering.match(dates: sessionLikeDates, bookings: sessionLikeBookings)
        #expect(result.assignments.count == 4)
        #expect(result.mappings.map(\.address) == ["Lillvägen 24", "Kyndelgränd 19", "Björnvägen 32", "Tjärnstigen 55A"])
        #expect(result.mappings.map { $0.clusters.reduce(0) { $0 + $1.count } } == [100, 100, 130, 136])
        // Kyndelgränds första bild (13:00:26 lokal) hör till Kyndelgränd, inte till Lillvägen.
        #expect(result.mappings[1].range.lowerBound == utc("11:00:26"))
        #expect(result.mappings[3].range.lowerBound == utc("14:14:19"))
        // Intervallen är klustrens omfång → addressFolder är entydig för varje bild.
        let mappings = result.mappings.map { (address: $0.address, eventTitle: $0.eventTitle, photoDateRange: $0.range) }
        #expect(PhotoClustering.addressFolder(for: utc("11:05:00"), mappings: mappings) == "Kyndelgränd 19")
        #expect(PhotoClustering.addressFolder(for: utc("14:14:30"), mappings: mappings) == "Tjärnstigen 55A")
    }

    @Test("Två bokningar tätt, bilderna i ett kluster men med en tydlig lucka nära gränsen: delas vid luckan")
    func adjacentBookings_splitAtClearGapNearBoundary() {
        // Bokning A 10:00–11:00, B 11:00–12:00. Bilder 10:05–10:58, ~6 min restid, 11:04–11:37:
        // luckan är under klustertröskeln, så det blir ett kluster som delas vid gränsen.
        let dates = series("10:05:00", count: 320, step: 10) + series("11:04:00", count: 200, step: 10)
        let bookings: [PhotoClustering.Booking] = [
            .init(title: "A", address: "A", start: utc("10:00:00"), end: utc("11:00:00")),
            .init(title: "B", address: "B", start: utc("11:00:00"), end: utc("12:00:00")),
        ]
        let result = PhotoClustering.match(dates: dates, bookings: bookings)
        #expect(result.assignments.map(\.cluster.count) == [320, 200])
        #expect(result.mappings.map(\.address) == ["A", "B"])
        #expect(result.mappings[1].range.lowerBound == utc("11:04:00"))
    }

    @Test("Kluster över en bokningsgräns utan tydlig lucka delas aldrig mitt i — hela klustret får bokningen det överlappar mest")
    func clusterWithoutGap_neverSplit() {
        // Jämn serie 10:40–11:10 (bild var 10:e s) över gränsen 11:00: 2/3 inom A.
        let dates = series("10:40:00", count: 181, step: 10)
        let bookings: [PhotoClustering.Booking] = [
            .init(title: "A", address: "A", start: utc("10:00:00"), end: utc("11:00:00")),
            .init(title: "B", address: "B", start: utc("11:00:00"), end: utc("12:00:00")),
        ]
        let result = PhotoClustering.match(dates: dates, bookings: bookings)
        #expect(result.assignments.count == 1)
        #expect(result.mappings.map(\.address) == ["A"])
    }

    @Test("Två kluster till samma bokning (paus) blir en mappning; ett kluster långt från allt blir Osorterade")
    func pauseAndUnmatched() {
        let dates = series("10:00:00", count: 50) + series("10:40:00", count: 50) + series("18:00:00", count: 5)
        let bookings: [PhotoClustering.Booking] = [
            .init(title: "A", address: "A", start: utc("09:45:00"), end: utc("11:00:00")),
        ]
        let result = PhotoClustering.match(dates: dates, bookings: bookings)
        #expect(result.assignments.count == 3)
        #expect(result.assignments.map(\.bookingIndex) == [0, 0, nil])
        #expect(result.mappings.count == 1)
        #expect(result.mappings[0].clusters.count == 2)
        #expect(result.mappings[0].range == utc("10:00:00")...utc("10:41:38"))
    }

    @Test("Kluster utan överlapp: närmaste bokning inom 60 min")
    func nearestBookingWithinLimit() {
        let dates = series("12:10:00", count: 10)
        let bookings: [PhotoClustering.Booking] = [
            .init(title: "A", address: "A", start: utc("10:00:00"), end: utc("11:30:00")),
            .init(title: "B", address: "B", start: utc("13:00:00"), end: utc("14:00:00")),
        ]
        let result = PhotoClustering.match(dates: dates, bookings: bookings)
        #expect(result.assignments.first?.bookingIndex == 0) // 40 min efter A, ~50 min före B
        #expect(result.assignments.first?.reason.hasPrefix("närmast") == true)
    }

    @Test("Mappningar för samma bokning med ett annat kluster emellan överlappar aldrig")
    func interleavedMappingsDoNotOverlap() {
        let a = PhotoClustering.Cluster(dates: series("10:00:00", count: 3))
        let b = PhotoClustering.Cluster(dates: series("10:30:00", count: 3))
        let c = PhotoClustering.Cluster(dates: series("11:00:00", count: 3))
        let bookings: [PhotoClustering.Booking] = [
            .init(title: "A", address: "A", start: utc("10:00:00"), end: utc("11:10:00")),
            .init(title: "B", address: "B", start: utc("10:25:00"), end: utc("10:35:00")),
        ]
        let assignments = [a, b, c].enumerated().map { i, cluster in
            PhotoClustering.Assignment(cluster: cluster, bookingIndex: i == 1 ? 1 : 0, strictOverlap: 3, marginOverlap: 3, reason: "")
        }
        let mappings = PhotoClustering.mappings(from: assignments, bookings: bookings)
        #expect(mappings.map(\.address) == ["A", "B", "A"])
    }

    // MARK: - calendar_matches.json

    @Test("calendar_matches.json får klusterinfo och bokningstid, och läses fortfarande av den gamla läsaren")
    func calendarMatchesJSON_backwardCompatible() async throws {
        let result = PhotoClustering.match(dates: sessionLikeDates, bookings: sessionLikeBookings)
        let match = PhotoClusterMatch(bookings: sessionLikeBookings, result: result, skippedEvents: [])
        let mappings = result.mappings.map { (address: $0.address, eventTitle: $0.eventTitle, photoDateRange: $0.range) }
        let json = PipelineRunner.calendarMatchesJSON(match: match, mappings: mappings, corrections: [
            "Kyndelgränd 19": (address: "Kyndelgränd 19, Haninge", latitude: 59.1, longitude: 18.1)
        ])
        #expect(json.count == 4)
        #expect((json[1]["clusters"] as? [[String: Any]])?.first?["count"] as? Int == 100)
        #expect(json[1]["rule"] as? String == PhotoClustering.ruleVersion)
        #expect(json[1]["corrected"] as? Bool == true)

        // Den befintliga läsaren (cachevägen) läser in samma intervall. Bara den rättade posten,
        // så att testet inte geokodar över nätet.
        let state = PipelineState()
        let runner = PipelineRunner(state: state)
        let data = try JSONSerialization.data(withJSONObject: [json[1]])
        let reread = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        await runner.applySavedCalendarMatches(reread)
        #expect(runner.calendarMappings.count == 1)
        #expect(runner.calendarMappings.first?.photoDateRange == mappings[1].photoDateRange)
        #expect(state.correctedCoordinates["Kyndelgränd 19"]?.latitude == 59.1)
    }
}
