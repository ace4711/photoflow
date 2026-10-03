import Foundation
import Testing
@testable import PhotoFlow

struct EnhancementProfileTests {

    private var sampleAuto: EnhancementParameters {
        var a = EnhancementParameters()
        a.exposureEV = 0.5
        a.temperature = 0.10
        a.whitePoint = 0.95
        a.blackPoint = 0.04
        a.highlights = 0.20
        a.shadows = 0.30
        a.vibrance = 0.20
        a.rotationDegrees = -1.5
        return a
    }

    @Test("Slutparametrar = automatik × styrka + förskjutningar")
    func finalParameters_strengthAndOffsets() {
        var profile = EnhancementProfile(id: "t", name: "T", autoStrength: 0.5)
        profile.exposure = 0.1
        profile.whites = 0.02        // + = ljusare vita → lägre vitpunkt
        profile.blacks = 0.01        // + = ljusare svarta → lägre svartpunkt
        profile.highlights = 0.05    // + = ljusare högdagrar → mindre dämpning
        profile.shadows = 0.1
        profile.vibrance = -0.05
        let f = profile.finalParameters(auto: sampleAuto)
        #expect(abs(f.exposureEV - (0.25 + 0.1)) < 1e-9)
        #expect(abs(f.temperature - 0.05) < 1e-9)
        #expect(abs(f.whitePoint - (1 - 0.025 - 0.02)) < 1e-9)
        #expect(abs(f.blackPoint - (0.02 - 0.01)) < 1e-9)
        #expect(abs(f.highlights - (0.10 - 0.05)) < 1e-9)
        #expect(abs(f.shadows - (0.15 + 0.1)) < 1e-9)
        #expect(abs(f.vibrance - (0.10 - 0.05)) < 1e-9)
    }

    @Test("Styrka 0 utan förskjutningar ger identitet, styrka 1 ger automatiken")
    func strengthExtremes() {
        let zero = EnhancementProfile(id: "z", name: "Z", autoStrength: 0, straighten: false)
        #expect(zero.finalParameters(auto: sampleAuto) == .identity)
        let full = EnhancementProfile(id: "f", name: "F", autoStrength: 1)
        let f = full.finalParameters(auto: sampleAuto)
        #expect(f.exposureEV == 0.5 && f.whitePoint == 0.95 && f.rotationDegrees == -1.5)
    }

    @Test("Styrkan begränsas till 0…1")
    func strengthIsClamped() {
        let over = EnhancementProfile(id: "o", name: "O", autoStrength: 3)
        #expect(over.finalParameters(auto: sampleAuto).exposureEV == 0.5)
        let under = EnhancementProfile(id: "u", name: "U", autoStrength: -1, straighten: false)
        #expect(under.finalParameters(auto: sampleAuto) == .identity)
    }

    @Test("warmBias läggs på temperaturen utan att skalas av styrkan")
    func warmBias_isAddedAfterStrength() {
        let profile = EnhancementProfile(id: "w", name: "W", autoStrength: 0.5, warmBias: 0.08)
        #expect(abs(profile.finalParameters(auto: sampleAuto).temperature - (0.05 + 0.08)) < 1e-9)
    }

    @Test("Lås ersätter automatiken och förskjutningen")
    func locks_overrideAutomatic() {
        var profile = EnhancementProfile(id: "l", name: "L", autoStrength: 1, warmBias: 0.05)
        profile.exposure = 0.3
        profile.locks = ["exposureEV": 0.0, "temperature": 0.02]
        let f = profile.finalParameters(auto: sampleAuto)
        #expect(f.exposureEV == 0)
        #expect(f.temperature == 0.02)          // inget warmBias på låst temperatur
        #expect(f.shadows == sampleAuto.shadows)
    }

    @Test("Rätning av/på styrs av profilen; vinkeln skalas inte av styrkan")
    func straighten_flag() {
        var profile = EnhancementProfile(id: "s", name: "S", autoStrength: 0.2)
        #expect(profile.finalParameters(auto: sampleAuto).rotationDegrees == -1.5)
        profile.straighten = false
        #expect(profile.finalParameters(auto: sampleAuto).rotationDegrees == 0)
    }

    @Test("Slutparametrarna klampas till sina intervall")
    func finalParameters_areClamped() {
        var profile = EnhancementProfile(id: "c", name: "C")
        profile.exposure = 10
        profile.vibrance = 5
        profile.whites = -5
        let f = profile.finalParameters(auto: sampleAuto)
        #expect(f == f.clamped())
        #expect(f.exposureEV == 2)
        #expect(f.vibrance == 1)
    }

    @Test("Inbyggda profiler: Automatisk, Neutral, Varm & ljus")
    func builtInProfiles() {
        let ids = EnhancementProfile.builtIn.map(\.id)
        #expect(ids == ["auto", "neutral", "warm-bright"])
        #expect(EnhancementProfile.builtIn.map(\.name) == ["Automatisk", "Neutral", "Varm & ljus"])
        #expect(Set(ids).count == 3)
        #expect(EnhancementProfile.automatic.autoStrength == 1)
        #expect(EnhancementProfile.automatic.warmBias > 0)
        #expect(EnhancementProfile.neutral.autoStrength < EnhancementProfile.automatic.autoStrength)
        #expect(EnhancementProfile.neutral.warmBias == 0)
        #expect(EnhancementProfile.warmBright.warmBias > EnhancementProfile.automatic.warmBias)

        // Neutral ger mindre ändring än Automatisk, Varm & ljus är varmare och ljusare.
        let n = EnhancementProfile.neutral.finalParameters(auto: sampleAuto)
        let a = EnhancementProfile.automatic.finalParameters(auto: sampleAuto)
        let w = EnhancementProfile.warmBright.finalParameters(auto: sampleAuto)
        #expect(abs(n.exposureEV) < abs(a.exposureEV))
        #expect(w.temperature > a.temperature)
        #expect(w.exposureEV > a.exposureEV)
    }

    @Test("Kodning runt: profil, parametrar och logg")
    func codingRoundTrip() throws {
        var profile = EnhancementProfile(id: "x", name: "Egen")
        profile.locks = ["tint": 0.01]
        profile.clarity = 0.1
        let decoded = try JSONDecoder().decode(EnhancementProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        let p = sampleAuto
        #expect(try JSONDecoder().decode(EnhancementParameters.self, from: JSONEncoder().encode(p)) == p)
        #expect(profile.canonicalJSON == decoded.canonicalJSON)

        var log = EnhancementLog(engineVersion: 1, profileID: "x")
        log.entries["hdr_group_1"] = EnhancementLog.Entry(
            kind: "hdr", source: "hdr_group_1.tiff", fingerprint: "abc", profileID: "x", profile: profile,
            analysis: EnhancementAnalysis(medianLuma: 0.3, horizonDegrees: 1.2), autoParameters: p, parameters: p,
            outputs: ["hdr_group_1_enh.tiff"], width: 10, height: 5, seconds: 1.5, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EnhLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        log.save(to: dir)
        let loaded = try #require(EnhancementLog.load(from: dir))
        #expect(loaded.entries == log.entries)
        #expect(loaded.profileID == "x")
    }

    @Test("Profillagring i en temporär katalog")
    func store_roundTripInTempDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EnhProfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EnhancementProfileStore(directory: dir)

        // Tom katalog: bara de inbyggda.
        #expect(store.loadAll().map(\.id) == ["auto", "neutral", "warm-bright"])

        var custom = EnhancementProfile(id: "maklare-1", name: "Mäklare 1", autoStrength: 0.7)
        custom.warmBias = 0.04
        try store.save(custom)
        var other = EnhancementProfile(id: "aaa", name: "Alfa")
        other.straighten = false
        try store.save(other)

        let all = store.loadAll()
        #expect(all.map(\.id) == ["auto", "neutral", "warm-bright", "aaa", "maklare-1"])
        #expect(store.profile(id: "maklare-1") == custom)
        #expect(store.profile(id: "finns-inte") == .automatic)

        // Inbyggda skrivs aldrig; en användarfil med inbyggt id ignoreras.
        #expect(throws: (any Error).self) { try store.save(.automatic) }
        let fake = try JSONEncoder().encode(EnhancementProfile(id: "auto", name: "Fusk", autoStrength: 0))
        try fake.write(to: dir.appendingPathComponent("fake.json"))
        try Data("inte json".utf8).write(to: dir.appendingPathComponent("trasig.json"))
        #expect(store.profile(id: "auto").name == "Automatisk")
        #expect(store.loadAll().count == 5)

        // Osäkra id:n (sökvägar) vägras.
        #expect(throws: (any Error).self) { try store.save(EnhancementProfile(id: "../ut", name: "X")) }

        store.delete(id: "maklare-1")
        #expect(!store.loadAll().contains { $0.id == "maklare-1" })
    }
}
