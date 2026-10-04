import Foundation

/// Tilldelning av bilder till kalenderbokningar via tidskluster (ersätter den tidigare
/// per-bild-matchningen mot bokningarnas tider ± 15 min).
///
/// Bakgrund: fotografen reser mellan objekten, så bilderna kommer i tydliga kluster med
/// restidsluckor emellan. Den gamla matchningen gav varje bild till den första bokningen
/// (i EventKits ordning) vars tid ± 15 min täckte bilden, så intervallen skars av
/// *bokningstiderna* i stället för av fotograferingens verkliga uppehåll — på en riktig
/// session "slutade" Lillvägen 24 på bokningens sluttid + 15 min (13:15:00 prick) och
/// Kyndelgränd 19 "började" två sekunder senare, mitt i ett sammanhängande kluster.
///
/// Här klustras först alla bildtider (en lucka större än `gapThreshold` delar), sedan får
/// varje kluster den bokning det överlappar mest. Ett kluster delas bara om det överlappar
/// flera bokningar OCH har en tydlig inre lucka nära bokningsgränsen OCH delarna då hamnar
/// hos olika bokningar — annars delas ett kluster aldrig mitt i.
///
/// Ren: inga sidoeffekter, ingen aktör, ingen EventKit — testbar med syntetiska tider.
nonisolated enum PhotoClustering {
    /// Regelversion. Ingår i kalenderstegets fingerprint, så att befintliga sessioner matchas
    /// om (och därefter sorteras om) när regeln ändras.
    static let ruleVersion = "cluster-v1"

    struct Parameters: Equatable, Sendable {
        /// Minsta lucka som alltid delar två kluster. 15 min: på riktiga sessioner är luckorna
        /// inom ett objekt upp till ~8 min (byte av rum, ut till fasaden, stativ), restiden
        /// mellan objekt 20+ min. För stor tröskel är ofarligt (gränsdelningen nedan tar närliggande
        /// objekt); för liten gör klustren till enskilda bildserier som skärs av bokningstider igen.
        var minimumGap: TimeInterval = 15 * 60
        /// Dynamisk del: tröskeln är max(`minimumGap`, `medianGapFactor` × medianluckan), så att
        /// en fotograf som tar en bild i halvminuten inte får varje paus som en ny adress.
        var medianGapFactor: Double = 30
        /// Marginal kring bokningen när överlappet räknas (samma storleksordning som söket i kalendern).
        var bookingMargin: TimeInterval = 30 * 60
        /// Kluster utan överlapp med någon bokning (± marginal) får närmaste bokning inom detta avstånd.
        var nearestBookingLimit: TimeInterval = 60 * 60
        /// Hur långt från gränsen mellan två bokningar en inre lucka får ligga för att dela klustret.
        var splitWindow: TimeInterval = 30 * 60
        /// Minsta inre lucka som räknas som "tydlig" vid gränsdelning: max(detta, faktor × medianluckan).
        var minimumSplitGap: TimeInterval = 2 * 60
        var splitGapMedianFactor: Double = 20

        static let standard = Parameters()
    }

    struct Booking: Equatable, Sendable {
        var title: String
        var address: String
        var start: Date
        var end: Date
    }

    /// Ett tidskluster: bildtiderna i stigande ordning (aldrig tomt).
    struct Cluster: Equatable, Sendable {
        var dates: [Date]
        var start: Date { dates[0] }
        var end: Date { dates[dates.count - 1] }
        var count: Int { dates.count }
    }

    /// Beslutet för ett kluster.
    struct Assignment: Equatable, Sendable {
        var cluster: Cluster
        /// Index i bokningslistan, nil = "Osorterade".
        var bookingIndex: Int?
        /// Bilder inom bokningens tid (utan marginal) respektive inom bokningen ± marginal.
        var strictOverlap: Int
        var marginOverlap: Int
        /// Kort motivering för loggen ("överlapp", "närmast", "ingen bokning").
        var reason: String
    }

    /// En adressmappning: en bokning och klustren som hör till den i följd.
    /// `range` = klustrens faktiska omfång (första–sista bildtid).
    struct Mapping: Equatable, Sendable {
        var bookingIndex: Int
        var address: String
        var eventTitle: String
        var clusters: [Cluster]
        var range: ClosedRange<Date> { clusters[0].start...clusters[clusters.count - 1].end }
    }

    struct Result: Equatable, Sendable {
        var gapThreshold: TimeInterval
        var assignments: [Assignment]
        var mappings: [Mapping]
    }

    // MARK: - Klustring

    static func medianGap(_ sorted: [Date]) -> TimeInterval {
        guard sorted.count >= 2 else { return 0 }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) }.sorted()
        let mid = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[mid] : (gaps[mid - 1] + gaps[mid]) / 2
    }

    static func gapThreshold(for sorted: [Date], parameters: Parameters = .standard) -> TimeInterval {
        max(parameters.minimumGap, parameters.medianGapFactor * medianGap(sorted))
    }

    /// Delar bildtiderna där luckan mellan två på varandra följande bilder överstiger `threshold`.
    static func clusters(_ dates: [Date], threshold: TimeInterval) -> [Cluster] {
        let sorted = dates.sorted()
        guard var current = sorted.first.map({ [$0] }) else { return [] }
        var result: [Cluster] = []
        for date in sorted.dropFirst() {
            if date.timeIntervalSince(current[current.count - 1]) > threshold {
                result.append(Cluster(dates: current))
                current = [date]
            } else {
                current.append(date)
            }
        }
        result.append(Cluster(dates: current))
        return result
    }

    // MARK: - Tilldelning

    /// Klustrar `dates` och tilldelar varje kluster en bokning.
    static func match(dates: [Date], bookings: [Booking], parameters: Parameters = .standard) -> Result {
        let sorted = dates.sorted()
        let threshold = gapThreshold(for: sorted, parameters: parameters)
        let splitGap = max(parameters.minimumSplitGap, parameters.splitGapMedianFactor * medianGap(sorted))
        var assignments: [Assignment] = []
        for cluster in clusters(sorted, threshold: threshold) {
            assignments += resolve(cluster, bookings: bookings, splitGap: splitGap, parameters: parameters)
        }
        return Result(gapThreshold: threshold, assignments: assignments, mappings: mappings(from: assignments, bookings: bookings))
    }

    /// Antal bilder i klustret inom [start, end].
    private static func count(_ cluster: Cluster, from start: Date, to end: Date) -> Int {
        cluster.dates.reduce(0) { $0 + ($1 >= start && $1 <= end ? 1 : 0) }
    }

    /// Avstånd mellan klustrets och bokningens tidsintervall (0 om de överlappar).
    private static func distance(_ cluster: Cluster, _ booking: Booking) -> TimeInterval {
        if cluster.end < booking.start { return booking.start.timeIntervalSince(cluster.end) }
        if cluster.start > booking.end { return cluster.start.timeIntervalSince(booking.end) }
        return 0
    }

    /// Bokningen ett (odelat) kluster får: flest bilder inom bokningens tid, sedan flest inom
    /// bokningen ± marginal, sedan minst avstånd, sedan tidigast bokning (deterministiskt).
    /// Utan överlapp ens med marginal: närmaste bokning inom `nearestBookingLimit`, annars ingen.
    static func assign(_ cluster: Cluster, bookings: [Booking], parameters: Parameters = .standard) -> Assignment {
        var best: (index: Int, strict: Int, margin: Int, distance: TimeInterval)?
        for (index, booking) in bookings.enumerated() {
            let strict = count(cluster, from: booking.start, to: booking.end)
            let margin = count(cluster, from: booking.start.addingTimeInterval(-parameters.bookingMargin),
                               to: booking.end.addingTimeInterval(parameters.bookingMargin))
            let dist = distance(cluster, booking)
            let candidate = (index: index, strict: strict, margin: margin, distance: dist)
            guard let current = best else { best = candidate; continue }
            if (strict, margin) != (current.strict, current.margin) {
                if (strict, margin) > (current.strict, current.margin) { best = candidate }
            } else if dist != current.distance {
                if dist < current.distance { best = candidate }
            } else if booking.start < bookings[current.index].start {
                best = candidate
            }
        }
        guard let best else {
            return Assignment(cluster: cluster, bookingIndex: nil, strictOverlap: 0, marginOverlap: 0, reason: "inga bokningar")
        }
        if best.margin > 0 {
            return Assignment(cluster: cluster, bookingIndex: best.index, strictOverlap: best.strict,
                              marginOverlap: best.margin, reason: "överlapp")
        }
        if best.distance <= parameters.nearestBookingLimit {
            return Assignment(cluster: cluster, bookingIndex: best.index, strictOverlap: 0, marginOverlap: 0,
                              reason: "närmast (\(Int(best.distance / 60)) min bort)")
        }
        return Assignment(cluster: cluster, bookingIndex: nil, strictOverlap: 0, marginOverlap: 0,
                          reason: "ingen bokning inom \(Int(parameters.nearestBookingLimit / 60)) min")
    }

    /// Tilldelar ett kluster, och delar det först om det överlappar flera bokningar och har en
    /// tydlig inre lucka nära en bokningsgräns som ger delar hos olika bokningar.
    private static func resolve(_ cluster: Cluster, bookings: [Booking], splitGap: TimeInterval,
                                parameters: Parameters) -> [Assignment] {
        let touched = bookings.indices.filter { index in
            count(cluster, from: bookings[index].start.addingTimeInterval(-parameters.bookingMargin),
                  to: bookings[index].end.addingTimeInterval(parameters.bookingMargin)) > 0
        }.sorted { (bookings[$0].start, $0) < (bookings[$1].start, $1) }

        if touched.count >= 2, cluster.count >= 2 {
            // Kandidatluckor: inre luckor ≥ splitGap nära gränsen mellan två på varandra följande
            // bokningar. Störst först; vid lika storlek den som ligger närmast gränsen.
            var candidates: [(index: Int, size: TimeInterval, offset: TimeInterval)] = []
            for (a, b) in zip(touched, touched.dropFirst()) {
                let low = min(bookings[a].end, bookings[b].start)
                let high = max(bookings[a].end, bookings[b].start)
                let boundary = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                for i in 0..<(cluster.count - 1) {
                    let size = cluster.dates[i + 1].timeIntervalSince(cluster.dates[i])
                    guard size >= splitGap else { continue }
                    let mid = cluster.dates[i].addingTimeInterval(size / 2)
                    guard mid >= low.addingTimeInterval(-parameters.splitWindow),
                          mid <= high.addingTimeInterval(parameters.splitWindow) else { continue }
                    candidates.append((i, size, abs(mid.timeIntervalSince(boundary))))
                }
            }
            candidates.sort { ($0.size, -$0.offset, -$0.index) > ($1.size, -$1.offset, -$1.index) }
            var tried: Set<Int> = []
            for candidate in candidates where tried.insert(candidate.index).inserted {
                let left = resolve(Cluster(dates: Array(cluster.dates[...candidate.index])), bookings: bookings,
                                   splitGap: splitGap, parameters: parameters)
                let right = resolve(Cluster(dates: Array(cluster.dates[(candidate.index + 1)...])), bookings: bookings,
                                    splitGap: splitGap, parameters: parameters)
                if left[left.count - 1].bookingIndex != right[0].bookingIndex {
                    return left + right
                }
            }
        }
        return [assign(cluster, bookings: bookings, parameters: parameters)]
    }

    /// Mappningar: på varandra följande kluster med samma bokning slås ihop till en mappning
    /// (omfång = första klustrets början till sista klustrets slut). Ligger ett annat kluster
    /// emellan blir det en ny mappning för samma bokning, så att intervallen aldrig överlappar.
    static func mappings(from assignments: [Assignment], bookings: [Booking]) -> [Mapping] {
        var result: [Mapping] = []
        // Bokningen för föregående kluster (nil = Osorterade, eller inget kluster än).
        var previous: Int?
        for assignment in assignments {
            if let index = assignment.bookingIndex {
                if previous == index, let last = result.indices.last {
                    result[last].clusters.append(assignment.cluster)
                } else {
                    result.append(Mapping(bookingIndex: index, address: bookings[index].address,
                                          eventTitle: bookings[index].title, clusters: [assignment.cluster]))
                }
            }
            previous = assignment.bookingIndex
        }
        return result
    }

    // MARK: - Uppslag per bild

    /// Adressmappen för en bild med tiden `date`: den mappning vars intervall innehåller tiden,
    /// annars (bilder som tillkommit efter matchningen) den mappning vars intervall ± `slack`
    /// ligger närmast. Vid lika avstånd vinner den tidigaste mappningen (listans ordning).
    static func addressFolder(for date: Date,
                              mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)],
                              slack: TimeInterval = 5 * 60) -> String? {
        if let inside = mappings.first(where: { $0.photoDateRange.contains(date) }) {
            return CalendarService.sanitizeFolderName(inside.address)
        }
        var best: (address: String, distance: TimeInterval)?
        for mapping in mappings {
            let range = mapping.photoDateRange
            let dist = date < range.lowerBound ? range.lowerBound.timeIntervalSince(date) : date.timeIntervalSince(range.upperBound)
            guard dist <= slack else { continue }
            if best == nil || dist < best!.distance { best = (mapping.address, dist) }
        }
        return best.map { CalendarService.sanitizeFolderName($0.address) }
    }
}
