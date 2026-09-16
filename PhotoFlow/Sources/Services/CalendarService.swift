import CoreLocation
import EventKit
import Foundation
import MapKit

@MainActor
class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()
    private var accessGranted = false
    private var targetCalendar: EKCalendar?

    private init() {}

    /// Resolve the named calendar. Call after access is granted.
    /// Returns the calendars array to use in predicates (nil = all calendars).
    private func resolveCalendar() -> [EKCalendar]? {
        let name = AppSettings.shared.calendarName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            print("[Calendar] Inget kalendernamn konfigurerat – söker i alla kalendrar")
            return nil
        }

        let allCalendars = store.calendars(for: .event)
        print("[Calendar] Tillgängliga kalendrar (\(allCalendars.count) st):")
        for cal in allCalendars {
            print("  • \"\(cal.title)\" (källa: \(cal.source?.title ?? "okänd"), typ: \(cal.type.rawValue))")
        }

        // Exact match first
        if let exact = allCalendars.first(where: { $0.title == name }) {
            print("[Calendar] ✓ Exakt matchning: \"\(exact.title)\"")
            targetCalendar = exact
            return [exact]
        }

        // Case-insensitive fallback
        if let caseInsensitive = allCalendars.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            print("[Calendar] ✓ Case-insensitive matchning: \"\(caseInsensitive.title)\"")
            targetCalendar = caseInsensitive
            return [caseInsensitive]
        }

        // Partial/contains fallback
        if let partial = allCalendars.first(where: { $0.title.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.title) }) {
            print("[Calendar] ⚠ Partiell matchning: \"\(partial.title)\" (sökte: \"\(name)\")")
            targetCalendar = partial
            return [partial]
        }

        print("[Calendar] ✗ Hittade INTE kalender \"\(name)\" – söker i alla kalendrar som fallback")
        print("[Calendar]   Tips: Kontrollera stavning. Tillgängliga namn listas ovan.")
        targetCalendar = nil
        return nil
    }

    /// EventKit's current authorization status for calendar (event) access,
    /// read directly from the system rather than the instance-only
    /// `accessGranted` flag (which only reflects whether *this session*
    /// already called `requestAccess`). Fas 4: lets `SettingsView`'s calendar
    /// picker show the right UI (picker / "Begär åtkomst" / denied notice)
    /// even before the pipeline has run once this launch.
    nonisolated static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Sorted display names of all calendars available to the app (Fas 4,
    /// `SettingsView`'s calendar picker). Empty when access hasn't been
    /// granted — callers should check `authorizationStatus` first.
    func availableCalendarNames() -> [String] {
        guard Self.authorizationStatus == .fullAccess else { return [] }
        return store.calendars(for: .event).map(\.title).sorted()
    }

    /// Request calendar access. Returns true if granted.
    func requestAccess() async -> Bool {
        if accessGranted { return true }
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessGranted = granted
            if granted {
                print("[Calendar] Åtkomst beviljad")
                _ = resolveCalendar()
            } else {
                print("[Calendar] ✗ Åtkomst NEKAD av användaren")
            }
            return granted
        } catch {
            print("[Calendar] ✗ Åtkomstfel: \(error.localizedDescription)")
            return false
        }
    }

    /// Find the calendar event that overlaps with the given photo capture time.
    /// Searches all calendars, looking for events where the photo time falls within
    /// the event's start-end window (with some margin).
    func findEvent(for photoDate: Date, margin: TimeInterval = 30 * 60) -> EKEvent? {
        guard accessGranted else { return nil }

        let searchStart = photoDate.addingTimeInterval(-margin)
        let searchEnd = photoDate.addingTimeInterval(margin)

        let calendars = resolveCalendar()
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
        let events = store.events(matching: predicate)
        print("[Calendar] findEvent: \(events.count) händelser i tidsintervall \(searchStart) – \(searchEnd)")

        // Find the event whose time window best contains the photo date
        // Prefer events where the photo falls within start..end
        let matching = events.filter { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            // Photo taken during the event (with some slack)
            let slackStart = start.addingTimeInterval(-15 * 60) // 15 min before event
            let slackEnd = end.addingTimeInterval(15 * 60)      // 15 min after event
            return photoDate >= slackStart && photoDate <= slackEnd
        }

        // If multiple matches, pick the one whose start is closest
        return matching.min(by: { a, b in
            abs(a.startDate.timeIntervalSince(photoDate)) < abs(b.startDate.timeIntervalSince(photoDate))
        })
    }

    /// Extract address from a calendar event title.
    /// Expected formats:
    ///   "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik:0701234567"
    ///   "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67"
    ///   "Kastanjevägen 60 bv, Fjälling 070-765 43 21"
    /// Returns: "Street Number, City" — everything after city is truncated.
    static func extractAddress(from title: String) -> String? {
        guard !title.isEmpty else { return nil }

        let parts = title.components(separatedBy: ",")

        let street: String
        let city: String

        if parts.count >= 2 {
            street = parts[0].trimmingCharacters(in: .whitespaces)
            // City = first word only from the second comma-part
            // (Swedish cities are typically one word: Älta, Handen, Fjälling)
            let cityPart = parts[1].trimmingCharacters(in: .whitespaces)
            city = extractCityName(from: cityPart)
        } else {
            // No comma — extract "Street Number" and "City" from a single string
            // Pattern: "Streetname 12 [floor] City ..." where city follows the street number
            let result = extractStreetAndCity(from: title)
            street = result.street
            city = result.city
        }

        let address: String
        if city.isEmpty {
            address = street
        } else {
            address = "\(street), \(city)"
        }

        if address != title {
            print("[Calendar] Adress trunkerad till \"\(address)\" — original: \"\(title)\"")
        }

        return address
    }

    /// Extract just the city name (first word) from a string like "Älta  Klara Nord" or "Fjälling 070-765"
    private static func extractCityName(from text: String) -> String {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = words.first else { return text }

        // If the first word starts with a digit (postal code), skip it
        if let c = first.first, c.isNumber { return "" }

        // Swedish city/area names are one word — just take the first
        return first
    }

    /// Parse "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67..." into street + city.
    /// Strategy: street = name + house number (+ optional floor like "bv", "-1 tr"),
    /// then city = next word that looks like a place name (alphabetic, capitalized).
    private static func extractStreetAndCity(from text: String) -> (street: String, city: String) {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count >= 2 else { return (street: text, city: "") }

        // Find the house number (first word that starts with a digit)
        var houseNumberIndex: Int?
        for (i, word) in words.enumerated() {
            if i > 0, let c = word.first, c.isNumber {
                houseNumberIndex = i
                break
            }
        }

        guard let numIdx = houseNumberIndex else {
            // No house number found — just return first word
            return (street: words[0], city: "")
        }

        // Street = everything up to and including house number + optional floor suffix
        var streetEndIndex = numIdx
        let floorSuffixes: Set<String> = ["bv", "tr", "nb", "ög"]
        // Check words after house number for floor indicators (e.g. "-1 tr", "bv")
        for i in (numIdx + 1)..<words.count {
            let w = words[i].lowercased()
            if floorSuffixes.contains(w) || (w.hasPrefix("-") && w.count <= 3) {
                streetEndIndex = i
            } else {
                break
            }
        }

        let streetWords = Array(words[0...streetEndIndex])
        let street = streetWords.joined(separator: " ")

        // City = next word after street that is alphabetic (not a postal code or phone)
        var city = ""
        for i in (streetEndIndex + 1)..<words.count {
            let word = words[i]
            // Skip postal codes (digits)
            if let c = word.first, c.isNumber { continue }
            // Skip phone patterns
            if word.contains("-") && word.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            // Skip email addresses
            if word.contains("@") { continue }
            // First alphabetic word = city name
            city = word
            break
        }

        return (street: street, city: city)
    }

    /// Given a set of photo dates, find and group them by calendar event address.
    /// Returns a dictionary mapping address -> date range of photos for that address.
    ///
    /// Adressen tas fram via `BookingTitleParser` (Fas 3d): Foundation Models
    /// när den är tillgänglig på enheten, annars faller den tillbaka på
    /// `extractAddress` nedan — i båda fallen samma "Gata Nummer, Ort"-format,
    /// så adressmappnamn inte ändras jämfört med tidigare faser.
    func matchPhotosToAddresses(photoDates: [Date]) async -> [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] {
        guard accessGranted, !photoDates.isEmpty else { return [] }

        let sorted = photoDates.sorted()
        guard let earliest = sorted.first, let latest = sorted.last else { return [] }

        // Fetch all events in the photo date range (with margin)
        let searchStart = earliest.addingTimeInterval(-2 * 3600)
        let searchEnd = latest.addingTimeInterval(2 * 3600)
        let calendars = resolveCalendar()
        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
        let events = store.events(matching: predicate)
        print("[Calendar] matchPhotosToAddresses: \(events.count) händelser hittades, \(sorted.count) fotodatum att matcha")
        for event in events {
            print("[Calendar]   → \"\(event.title ?? "–")\" [\(event.startDate?.description ?? "?") – \(event.endDate?.description ?? "?")]")
        }

        // Group photos by which event they belong to
        var eventPhotos: [String: (event: EKEvent, dates: [Date])] = [:]

        for date in sorted {
            for event in events {
                guard let start = event.startDate, let end = event.endDate else { continue }
                let slackStart = start.addingTimeInterval(-15 * 60)
                let slackEnd = end.addingTimeInterval(15 * 60)
                if date >= slackStart && date <= slackEnd {
                    let key = event.eventIdentifier ?? event.title ?? ""
                    if eventPhotos[key] == nil {
                        eventPhotos[key] = (event: event, dates: [])
                    }
                    eventPhotos[key]!.dates.append(date)
                    break
                }
            }
        }

        let unmatchedCount = sorted.count - eventPhotos.values.flatMap(\.dates).count
        if unmatchedCount > 0 {
            print("[Calendar] ⚠ \(unmatchedCount) foton matchade INGEN händelse")
        }

        var results: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)] = []
        for (_, value) in eventPhotos {
            guard let title = value.event.title else {
                print("[Calendar] ⚠ Händelse utan titel, hoppar över")
                continue
            }
            let info = await BookingTitleParser.shared.parse(title: title)
            guard let address = BookingTitleParser.addressString(from: info) else {
                print("[Calendar] ⚠ Kunde inte extrahera adress från: \"\(title)\"")
                continue
            }
            guard let first = value.dates.first, let last = value.dates.last else { continue }
            print("[Calendar] ✓ \(value.dates.count) foton → \"\(address)\" (från: \"\(title)\")")
            results.append((address: address, eventTitle: title, photoDateRange: first...last))
        }
        results.sort(by: { $0.photoDateRange.lowerBound < $1.photoDateRange.lowerBound })

        print("[Calendar] Resultat: \(results.count) adressmatchningar totalt")
        return results
    }

    /// Determine the output subfolder name for a photo based on its capture date.
    /// Returns nil if no matching calendar event found.
    func addressFolder(for photoDate: Date, mappings: [(address: String, eventTitle: String, photoDateRange: ClosedRange<Date>)]) -> String? {
        // Find mapping where photo date falls within range (with some extra slack)
        for mapping in mappings {
            let slackRange = mapping.photoDateRange.lowerBound.addingTimeInterval(-5 * 60)...mapping.photoDateRange.upperBound.addingTimeInterval(5 * 60)
            if slackRange.contains(photoDate) {
                return Self.sanitizeFolderName(mapping.address)
            }
        }
        return nil
    }

    // MARK: - Geocoding

    /// Cached geocode results: address -> coordinates
    private var geocodeCache: [String: CLLocationCoordinate2D] = [:]

    /// Geocode an address string to GPS coordinates using Apple Maps.
    ///
    /// Uses `MKGeocodingRequest` (verifierat i SDK:n, Fas 3c:
    /// `MapKit.framework/Versions/A/Headers/MKGeocodingRequest.h` — den
    /// bridgas till Swift som en vanlig Objective-C-klass med en async
    /// `mapItems` "getter" via `NS_SWIFT_ASYNC_NAME(getter:mapItems())`,
    /// syns inte i `MapKit.swiftinterface` eftersom MapKit på macOS är ett
    /// rent ObjC-ramverk med tunn Swift-overlay). Ersätter den deprecerade
    /// `CLGeocoder.geocodeAddressString` (macOS 26.0). Samma beteende som
    /// förut: ", Sverige" läggs till om det saknas, cache per adress, `nil`
    /// vid miss/fel.
    func geocodeAddress(_ address: String) async -> CLLocationCoordinate2D? {
        if let cached = geocodeCache[address] { return cached }

        // Append ", Sverige" for better results on Swedish addresses
        let searchAddress = address.contains("Sverige") ? address : "\(address), Sverige"

        guard let request = MKGeocodingRequest(addressString: searchAddress) else {
            print("Geocoding failed for '\(address)': could not create MKGeocodingRequest")
            return nil
        }

        do {
            let mapItems = try await request.mapItems
            if let location = mapItems.first?.location.coordinate {
                geocodeCache[address] = location
                return location
            }
        } catch {
            print("Geocoding failed for '\(address)': \(error)")
        }
        return nil
    }

    /// Extract the "extra info" from a booking title (everything after the address).
    /// E.g. "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik:0701234567"
    /// → "villa ca 169 kvm. Erik:0701234567"
    static func extractBookingInfo(from title: String) -> String? {
        guard !title.isEmpty else { return nil }

        let parts = title.components(separatedBy: ",")
        guard parts.count >= 2 else { return nil }

        let cityLower = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        let propertyKeywords = ["villa", "lägenhet", "radhus", "bostadsrätt", "kvm", "m2", "rum"]
        let secondIsProperty = propertyKeywords.contains(where: { cityLower.contains($0) })

        // If second part is property description, info starts at index 1
        // If second part is city, info starts at index 2
        let infoStartIndex = secondIsProperty ? 1 : 2

        guard parts.count > infoStartIndex else { return nil }

        let info = parts[infoStartIndex...].joined(separator: ",").trimmingCharacters(in: .whitespaces)
        return info.isEmpty ? nil : info
    }

    /// Clean address string for use as folder name. `static`/non-private
    /// (Fas 4) so `AddressBanner`/`PipelineRunner` can compute the same
    /// on-disk folder name for an address when resorting folders after a
    /// manual address correction — must stay in perfect sync with
    /// `addressFolder(for:mappings:)` above, hence the shared implementation.
    static func sanitizeFolderName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: ":/\\?*\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        // Slutgranskning: a result of "", "." or ".." is not just an odd folder
        // name — `outputDir.appendingPathComponent(cleaned)` builds this as the
        // literal *unsuffixed* DNG folder name (AddressFolderLayout.dngDirName),
        // and the OS resolves a trailing "/.." or "/." path component against the
        // parent/same directory when the path is actually used (mkdir/rename/
        // readdir), regardless of what Foundation's URL does with it lexically.
        // A pathological calendar-event title that happens to extract down to
        // exactly one of these three values would otherwise turn every
        // address-folder operation (symlink creation, metadata writing, cull
        // delete/move) into one that targets outputDir's parent or outputDir
        // itself instead of a real address subfolder. Never let that happen.
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "Okänd adress"
        }
        return cleaned
    }
}
