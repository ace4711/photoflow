import Foundation

/// De explicita, sparade parametrarna för en förbättrad bild ("Förbättra
/// bilder"-steget). Både automatiken (`EnhancementEngine.automaticParameters`)
/// och profilen (`EnhancementProfile.finalParameters`) talar i dessa, och
/// renderingen (`EnhancementEngine.render`) läser bara dessa — så resultatet är
/// reproducerbart och kan loggas per bild i `enhancement.json`.
///
/// Alla värden är "identitet" (= ingen ändring) i `EnhancementParameters()`.
///
/// Enheter och tecken:
/// - `exposureEV`: stopp i linjärt ljus (+ = ljusare).
/// - `temperature`: -1…1, + = varmare. Översätts till kanalförstärkningar
///   R·2^(t·k) och B·2^(-t·k) med `EnhancementEngine.wbStopsPerUnit` (k).
/// - `tint`: -1…1, + = magenta (grön dras ned), G·2^(-n·k).
/// - `blackPoint` / `whitePoint`: nivåer i gammakodat (sRGB) värde, 0 resp. 1 =
///   ingen ändring. Bilden sträcks `(v - svart) / (vit - svart)`. Ett negativt
///   svartvärde lyfter svärtan.
/// - `shadows`: 0…1 lyft av skuggor (CIHighlightShadowAdjust).
/// - `highlights`: 0…1 *dämpning* av högdagrar (0 = ingen).
/// - `contrast`: 0…0,5 amplitud för en lätt S-kurva i gammakodat värde.
/// - `vibrance`: -1…1 (CIVibrance, skyddar redan mättade färger).
/// - `saturation`: -1…1, relativ global mättnad (1 + värdet).
/// - `clarity`: 0…1 lokal kontrast (osharp mask med stor radie, låg intensitet).
/// - `sharpness`: 0…1,5 intensitet på slutskärpningen (radien följer upplösningen).
/// - `rotationDegrees`: rotation i grader som tillämpas (moturs positivt, som
///   Core Image), med minimal beskärning så att inga tomma hörn uppstår.
/// - `look`: Mäklarstilens tonkurva/mättnad/brusreducering (`BrokerLook`); `nil` = vanlig rendering.
/// - `perspective`: rätning av lodlinjer (`VerticalCorrection`); `nil` = ingen.
nonisolated struct EnhancementParameters: Codable, Sendable, Equatable {
    var exposureEV: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var blackPoint: Double = 0
    var whitePoint: Double = 1
    var shadows: Double = 0
    var highlights: Double = 0
    var contrast: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var sharpness: Double = 0
    var rotationDegrees: Double = 0
    var look: LookParameters? = nil
    var perspective: PerspectiveCorrection? = nil

    static let identity = EnhancementParameters()

    /// Namn på de parametrar som profilen kan förskjuta/låsa. Rotation ingår
    /// inte: den styrs av `EnhancementProfile.straighten`.
    enum Key: String, CaseIterable, Codable, Sendable {
        case exposureEV, temperature, tint, blackPoint, whitePoint, shadows, highlights
        case contrast, vibrance, saturation, clarity, sharpness

        var range: ClosedRange<Double> {
            switch self {
            case .exposureEV: return -2...2
            case .temperature: return -1...1
            case .tint: return -1...1
            case .blackPoint: return -0.08...0.10
            case .whitePoint: return 0.90...1.05
            case .shadows: return -0.5...1
            case .highlights: return 0...1
            case .contrast: return 0...0.5
            case .vibrance: return -1...1
            case .saturation: return -1...1
            case .clarity: return 0...1
            case .sharpness: return 0...1.5
            }
        }
    }

    subscript(key: Key) -> Double {
        get {
            switch key {
            case .exposureEV: return exposureEV
            case .temperature: return temperature
            case .tint: return tint
            case .blackPoint: return blackPoint
            case .whitePoint: return whitePoint
            case .shadows: return shadows
            case .highlights: return highlights
            case .contrast: return contrast
            case .vibrance: return vibrance
            case .saturation: return saturation
            case .clarity: return clarity
            case .sharpness: return sharpness
            }
        }
        set {
            switch key {
            case .exposureEV: exposureEV = newValue
            case .temperature: temperature = newValue
            case .tint: tint = newValue
            case .blackPoint: blackPoint = newValue
            case .whitePoint: whitePoint = newValue
            case .shadows: shadows = newValue
            case .highlights: highlights = newValue
            case .contrast: contrast = newValue
            case .vibrance: vibrance = newValue
            case .saturation: saturation = newValue
            case .clarity: clarity = newValue
            case .sharpness: sharpness = newValue
            }
        }
    }

    /// Håller varje värde inom dess tillåtna intervall (och rotationen inom ±5°).
    func clamped() -> EnhancementParameters {
        var out = self
        for key in Key.allCases {
            let r = key.range
            out[key] = min(max(out[key], r.lowerBound), r.upperBound)
        }
        out.rotationDegrees = min(max(out.rotationDegrees, -5), 5)
        return out
    }

    /// Kort rad för steg-loggen: bara de parametrar som faktiskt ändrar något.
    var summary: String {
        var parts: [String] = []
        func add(_ label: String, _ value: Double, _ format: String = "%+.2f") {
            parts.append("\(label) \(String(format: format, value))")
        }
        if abs(exposureEV) >= 0.005 { add("exp", exposureEV) }
        if abs(temperature) >= 0.005 { add("temp", temperature) }
        if abs(tint) >= 0.005 { add("tint", tint) }
        if blackPoint != 0 { add("svart", blackPoint, "%.3f") }
        if whitePoint != 1 { add("vit", whitePoint, "%.3f") }
        if shadows != 0 { add("skuggor", shadows) }
        if highlights != 0 { add("högdagrar", -highlights) }
        if contrast != 0 { add("kontrast", contrast) }
        if vibrance != 0 { add("vibrance", vibrance) }
        if saturation != 0 { add("mättnad", saturation) }
        if clarity != 0 { add("clarity", clarity) }
        if sharpness != 0 { add("skärpa", sharpness) }
        if rotationDegrees != 0 { add("rotation", rotationDegrees, "%+.2f°") }
        if let look {
            parts.append("mäklarstil (median \(String(format: "%.2f", BrokerLook.evaluate(x: look.curveX, y: look.curveY, at: 0.5))) vid 0,5)")
        }
        if let perspective {
            parts.append(String(format: "lodlinjer %+.1f°/%+.1f°", perspective.pitchDegrees, perspective.rollDegrees))
        }
        return parts.isEmpty ? "ingen ändring" : parts.joined(separator: ", ")
    }
}

/// Stilprofil: hur mycket av automatiken som används och vad användaren
/// förskjuter eller låser ovanpå. Förberett för att kopplas till mäklare/objekt
/// (kopplingen görs senare — profilen är bara data och identifieras av `id`).
///
/// Slutparametrar (se `finalParameters(auto:)`), per parameter p med
/// identitetsvärde `i`:
///   `slutlig = i + (auto - i) · autoStrength + förskjutning`
/// Ett lås (`locks[p]`) ersätter allt det med ett absolut värde. Profilens
/// förskjutningar följer Lightrooms tecken (+ = ljusare/mer):
/// - `exposure` → exposureEV (+), `contrast` (+), `shadows` (+ lyfter),
/// - `highlights` (+ = ljusare högdagrar, dvs. mindre dämpning),
/// - `whites` (+ = ljusare vita, sänker vitpunkten), `blacks` (+ = ljusare
///   svarta, sänker svartpunkten),
/// - `temperature`/`tint`/`vibrance`/`saturation`/`clarity`/`sharpness` rakt av.
/// `warmBias` läggs på temperaturen efter allt annat (profilens "stil", skalas
/// inte av `autoStrength`). `straighten` slår på/av rätning av horisonten.
nonisolated struct EnhancementProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var version: Int = 1
    /// 0…1: andel av automatikens avvikelse från identitet som används.
    var autoStrength: Double = 1
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var sharpness: Double = 0
    var straighten: Bool = true
    var warmBias: Double = 0
    /// Låsta parametrar: `EnhancementParameters.Key.rawValue` → absolut värde.
    var locks: [String: Double] = [:]
    /// Särskild look ovanpå automatiken: `"broker"` = Mäklarstil (`BrokerLook`), `nil` = ingen.
    var look: String? = nil

    static let automaticID = "auto"
    static let neutralID = "neutral"
    static let warmBrightID = "warm-bright"
    static let brokerID = "maklarstil"
    /// Standardprofilen (appens inställning och CLI): Mäklarstil sedan Förbättra v4. En
    /// användare som aktivt valt en profil har den sparad i `UserDefaults` och behåller den;
    /// den som aldrig valt får den nya standarden (`@AppStorage` lagrar bara aktiva val).
    static let defaultID = brokerID

    static let automatic = EnhancementProfile(
        id: automaticID, name: "Automatisk", autoStrength: 1, warmBias: 0.03
    )
    static let neutral = EnhancementProfile(
        id: neutralID, name: "Neutral", autoStrength: 0.45, straighten: false, warmBias: 0
    )
    static let warmBright = EnhancementProfile(
        id: warmBrightID, name: "Varm & ljus", autoStrength: 1,
        exposure: 0.15, shadows: 0.10, whites: 0.02, vibrance: 0.05, warmBias: 0.09
    )
    /// Härmar redigerarens leveranser (ljus, luftig, neutrala vita väggar, låg mättnad,
    /// lågt brus) — se `BrokerLook`. Rätning av horisonten som Automatisk.
    static let broker = EnhancementProfile(
        id: brokerID, name: "Mäklarstil", autoStrength: 1, warmBias: 0, look: BrokerLook.profileLookID
    )
    static let builtIn: [EnhancementProfile] = [automatic, neutral, warmBright, broker]

    static func isBuiltIn(id: String) -> Bool { builtIn.contains { $0.id == id } }

    private func offset(for key: EnhancementParameters.Key) -> Double {
        switch key {
        case .exposureEV: return exposure
        case .temperature: return temperature
        case .tint: return tint
        case .blackPoint: return -blacks
        case .whitePoint: return -whites
        case .shadows: return shadows
        case .highlights: return -highlights
        case .contrast: return contrast
        case .vibrance: return vibrance
        case .saturation: return saturation
        case .clarity: return clarity
        case .sharpness: return sharpness
        }
    }

    /// Ren funktion: automatikens parametrar → slutparametrar för den här profilen.
    func finalParameters(auto: EnhancementParameters) -> EnhancementParameters {
        let strength = min(max(autoStrength, 0), 1)
        var out = EnhancementParameters.identity
        for key in EnhancementParameters.Key.allCases {
            if let locked = locks[key.rawValue] {
                out[key] = locked
                continue
            }
            let identity = EnhancementParameters.identity[key]
            out[key] = identity + (auto[key] - identity) * strength + offset(for: key)
        }
        if locks[EnhancementParameters.Key.temperature.rawValue] == nil {
            out.temperature += warmBias
        }
        out.rotationDegrees = straighten ? auto.rotationDegrees : 0
        return out.clamped()
    }

    /// Stabil, sorterad JSON-sträng — del av per-bild-fingerprintet.
    var canonicalJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? id
    }
}

/// Profiler som JSON-filer i `~/Library/Application Support/PhotoFlow/profiles/`
/// (en fil per profil, `<id>.json`). De inbyggda profilerna skapas i koden och
/// skrivs aldrig till disk; en användarfil med ett inbyggt id ignoreras.
/// Under tester (`xcodebuild test`) används en temporär katalog — samma mönster
/// som `StepTiming.Store`/`SessionHistoryStore`.
nonisolated final class EnhancementProfileStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    static let shared: EnhancementProfileStore = {
        let dir: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoFlowTestProfiles-\(UUID().uuidString)")
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PhotoFlow")
                .appendingPathComponent("profiles")
        }
        return EnhancementProfileStore(directory: dir)
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func fileURL(for id: String) -> URL? {
        // Id blir filnamn: tillåt bara säkra tecken så en profil aldrig kan skriva utanför katalogen.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    /// Inbyggda profiler först, därefter användarens, sorterade på namn.
    func loadAll() -> [EnhancementProfile] {
        lock.lock(); defer { lock.unlock() }
        var user: [EnhancementProfile] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(EnhancementProfile.self, from: data),
                  !EnhancementProfile.isBuiltIn(id: profile.id) else { continue }
            user.append(profile)
        }
        user.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return EnhancementProfile.builtIn + user
    }

    /// Profilen med `id`, annars standardprofilen "Automatisk".
    func profile(id: String) -> EnhancementProfile {
        loadAll().first { $0.id == id } ?? .broker
    }

    func save(_ profile: EnhancementProfile) throws {
        guard !EnhancementProfile.isBuiltIn(id: profile.id), let url = fileURL(for: profile.id) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(profile).write(to: url, options: .atomic)
    }

    func delete(id: String) {
        guard !EnhancementProfile.isBuiltIn(id: id), let url = fileURL(for: id) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// `enhancement.json` i outputmappen: exakt vad som gjordes per bild, så att
/// det går att granska och köra om. Även `profileID` för sessionen som helhet
/// (profilkoppling till mäklare/objekt görs senare).
nonisolated struct EnhancementLog: Codable, Sendable, Equatable {
    static let fileName = "enhancement.json"

    var version: Int = 1
    var engineVersion: Int
    /// Profilen som användes senast i sessionen.
    var profileID: String
    var updatedAt: Date
    /// Nyckel = `hdr_group_<id>` eller bildens basnamn (`DSC_0012`).
    var entries: [String: Entry]

    struct Entry: Codable, Sendable, Equatable {
        /// "hdr", "dng" eller "preview".
        var kind: String
        var source: String
        var fingerprint: String
        var profileID: String
        /// Hela profilen som den såg ut — profilfilen kan ändras senare.
        var profile: EnhancementProfile
        var analysis: EnhancementAnalysis
        var autoParameters: EnhancementParameters
        var parameters: EnhancementParameters
        var outputs: [String]
        var width: Int
        var height: Int
        var seconds: Double
        var date: Date
    }

    init(engineVersion: Int, profileID: String) {
        self.engineVersion = engineVersion
        self.profileID = profileID
        self.updatedAt = Date()
        self.entries = [:]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(from outputDir: URL) -> EnhancementLog? {
        guard let data = try? Data(contentsOf: outputDir.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(EnhancementLog.self, from: data)
    }

    func save(to outputDir: URL) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: outputDir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
