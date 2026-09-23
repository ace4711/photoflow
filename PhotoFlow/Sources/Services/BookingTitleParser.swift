import Foundation
import FoundationModels

/// Strukturerad bokningsinfo utvunnen ur en kalenderhändelses titel — antingen
/// av Apples on-device Foundation Models-modell (macOS 26+, `SystemLanguageModel`)
/// eller, om modellen inte är tillgänglig, av `CalendarService`s äldre
/// regex-/ordbaserade heuristik (`extractAddress`/`extractBookingInfo`), som
/// alltid finns kvar som fallback och vars kod inte ändrats av detta.
///
/// Exempel på riktiga titlar (`CalendarService`s doc-kommentarer, Fas 0):
///   "Lindvägen 12, Tyresö, villa ca 169 kvm. Erik: 0701234567"
///   "Almstigen 9 136 40 Handen Anna Ek 070-123 45 67"
///   "Kastanjevägen 60 bv, Fjälling 070-765 43 21"
/// Se `BookingTitleParserTests` för fler syntetiska varianter (postnummer,
/// "1 tr", telefonnummer i olika format, etc) som jämför modell mot heuristik.
@Generable
struct BookingInfo: Codable, Equatable, Sendable {
    @Guide(description: "Gatuadress med husnummer, t.ex. 'Lindvägen 12'")
    var street: String
    var city: String?
    var propertyType: String?
    var areaSquareMeters: Int?
    var contactName: String?
    var contactPhone: String?
}

/// Tolkar kalendertitlar för mäklarfotouppdrag till `BookingInfo`, med cache
/// per exakt titel-sträng (modellanrop kostar tid — se FORBATTRINGAR.md för
/// uppmätt tid/titel) persisterad till
/// `~/Library/Application Support/PhotoFlow/booking_titles.json`.
///
/// `actor` (inte `@MainActor`, till skillnad från `CalendarService`) eftersom
/// modellanropen är oberoende I/O-bundna jobb utan behov av huvudtråden —
/// samma resonemang som `PhotoQualityService`/`VisionTaggingService`.
actor BookingTitleParser {
    static let shared = BookingTitleParser()

    private var cache: [String: BookingInfo] = [:]
    private var cacheLoaded = false
    private let cacheURL: URL

    /// Uppmätt tid för senaste modellanrop (Fas 3d) — används bara för
    /// loggning/dokumentation, inte för någon logik.
    private(set) var lastModelCallDuration: TimeInterval?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("PhotoFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("booking_titles.json")
    }

    /// Sant om `SystemLanguageModel.default` är redo att köra på den här
    /// enheten (Apple Intelligence aktiverat, modellen nedladdad). `static`
    /// medlemmar av en `actor` är inte isolerade (rör aldrig `self`), så det
    /// här kan anropas synkront direkt från t.ex. `SettingsView`.
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Tolka en kalendertitel. Cachead per exakt titel-sträng.
    func parse(title: String) async -> BookingInfo {
        guard !title.isEmpty else {
            return BookingInfo(street: "", city: nil, propertyType: nil, areaSquareMeters: nil, contactName: nil, contactPhone: nil)
        }

        loadCacheIfNeeded()
        if let cached = cache[title] { return cached }

        let result: BookingInfo
        if let modelResult = await runModel(title: title) {
            result = modelResult
        } else {
            // `heuristicParse` slår vidare till `CalendarService`, som är
            // `@MainActor` — hoppa dit explicit.
            result = await Self.heuristicParse(title: title)
        }
        cache[title] = result
        persistCache()
        return result
    }

    /// Formaterad "Gata Nummer, Ort" — identisk form som den gamla
    /// `CalendarService.extractAddress` producerade, oavsett om resultatet
    /// kom från modellen eller heuristiken, så befintliga adressmappnamn
    /// (och därmed pågående sessioner) inte ändras av den här fasen.
    nonisolated static func addressString(from info: BookingInfo) -> String? {
        let street = info.street.trimmingCharacters(in: .whitespaces)
        guard !street.isEmpty else { return nil }
        if let city = info.city?.trimmingCharacters(in: .whitespaces), !city.isEmpty {
            return "\(street), \(city)"
        }
        return street
    }

    /// Kort "extra info"-rad för IPTC-beskrivningen, i samma stil som den
    /// gamla `extractBookingInfo`-heuristiken ("villa ca 169 kvm. Erik: ...").
    nonisolated static func bookingInfoText(from info: BookingInfo) -> String? {
        var parts: [String] = []

        if let type = info.propertyType?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            if let area = info.areaSquareMeters {
                parts.append("\(type) ca \(area) kvm")
            } else {
                parts.append(type)
            }
        } else if let area = info.areaSquareMeters {
            parts.append("ca \(area) kvm")
        }

        func trimmedOrNil(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
        let name = trimmedOrNil(info.contactName)
        let phone = trimmedOrNil(info.contactPhone)
        if let name, let phone {
            parts.append("\(name): \(phone)")
        } else if let name {
            parts.append(name)
        } else if let phone {
            parts.append(phone)
        }

        let text = parts.joined(separator: ". ")
        return text.isEmpty ? nil : text
    }

    // MARK: - Modellanrop

    private func runModel(title: String) async -> BookingInfo? {
        guard Self.isModelAvailable else { return nil }

        let start = Date()
        defer { lastModelCallDuration = Date().timeIntervalSince(start) }

        do {
            // Ny session per titel: transkriptet hålls litet (undviker att
            // närma sig kontextgränsen över hundratals bokningar i en enda
            // session) och varje tolkning är oberoende av föregående ändå.
            let session = LanguageModelSession(instructions: """
                Du tolkar svenska kalendertitlar för mäklarfotouppdrag och extraherar \
                bokningsinformation. Titlarna innehåller ofta en gatuadress med \
                husnummer (ibland med våningssuffix som "bv" eller "1 tr"), ibland \
                postnummer och ort, ibland bostadstyp (villa, lägenhet, radhus, \
                bostadsrätt) och area i kvadratmeter, samt ibland en kontaktperson \
                och telefonnummer. Extrahera ENDAST det som faktiskt står i titeln — \
                gissa aldrig ort, bostadstyp eller kontaktinformation som inte nämns.
                """)
            let response = try await session.respond(
                to: "Extrahera bokningsinfo från denna kalendertitel: \"\(title)\"",
                generating: BookingInfo.self
            )
            return response.content
        } catch {
            // Kontextgräns, guardrails, otillgänglig modell m.m. — logga och
            // låt anroparen falla tillbaka på heuristiken. Stoppar aldrig
            // pipelinen. Ingen nätverkstrafik (modellen körs on-device).
            print("[BookingTitleParser] Modellanrop misslyckades för \"\(title)\": \(error) — faller tillbaka på heuristik")
            return nil
        }
    }

    // MARK: - Heuristisk fallback

    /// Slår vidare till `CalendarService`s befintliga regex-/ordheuristik
    /// (oförändrad, se dess doc-kommentarer) för gata/ort, och gör en enkel
    /// bästa-försök-extraktion av bostadstyp/area/kontakt ur "extra info"-
    /// resten — bara till för att ge samma `BookingInfo`-form när modellen
    /// inte är tillgänglig. Modellvägen är klart bättre på just den delen.
    @MainActor
    static func heuristicParse(title: String) -> BookingInfo {
        let address = CalendarService.extractAddress(from: title)
        let info = CalendarService.extractBookingInfo(from: title)

        var street = title
        var city: String?
        if let address {
            let parts = address.components(separatedBy: ", ")
            street = parts.first ?? address
            if parts.count > 1 { city = parts[1] }
        }

        var propertyType: String?
        var area: Int?
        var contactName: String?
        var contactPhone: String?

        if let info {
            let lower = info.lowercased()
            for keyword in ["villa", "lägenhet", "radhus", "bostadsrätt", "fritidshus", "tomt"] where lower.contains(keyword) {
                propertyType = keyword.capitalized(with: Locale(identifier: "sv_SE"))
                break
            }

            if let match = info.range(of: #"\d+\s?(kvm|m2|m²)"#, options: .regularExpression) {
                let numStr = info[match].filter(\.isNumber)
                area = Int(numStr)
            }

            if let phoneMatch = info.range(of: #"0\d[\d\- ]{6,}\d"#, options: .regularExpression) {
                contactPhone = String(info[phoneMatch]).trimmingCharacters(in: .whitespaces)
            }

            if let colonIdx = info.firstIndex(of: ":") {
                let namePart = info[info.startIndex..<colonIdx]
                let candidate = namePart.components(separatedBy: CharacterSet(charactersIn: ". ")).last(where: { !$0.isEmpty })
                if let candidate, candidate.first?.isUppercase == true {
                    contactName = candidate
                }
            }
        }

        return BookingInfo(
            street: street,
            city: city,
            propertyType: propertyType,
            areaSquareMeters: area,
            contactName: contactName,
            contactPhone: contactPhone
        )
    }

    // MARK: - Cache-persistens (booking_titles.json)

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: BookingInfo].self, from: data) else { return }
        cache = decoded
    }

    private func persistCache() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
