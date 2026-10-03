import Foundation
import Testing
@testable import PhotoFlow

/// Använder en egen service-sträng: användarens riktiga Objektfilm-nycklar rörs aldrig.
struct KeychainStoreTests {
    private let service = "se.digido.photoflow.objektfilm.test-\(UUID().uuidString)"

    @Test("Spara, läsa, ersätta och radera")
    func roundTrip() throws {
        let account = "keychain-test.example"
        defer { try? KeychainStore.delete(account: account, service: service) }
        #expect(KeychainStore.read(account: account, service: service) == nil)
        try KeychainStore.save("pf_första", account: account, service: service)
        #expect(KeychainStore.read(account: account, service: service) == "pf_första")
        try KeychainStore.save("pf_andra", account: account, service: service)
        #expect(KeychainStore.read(account: account, service: service) == "pf_andra")
        try KeychainStore.delete(account: account, service: service)
        #expect(KeychainStore.read(account: account, service: service) == nil)
        try KeychainStore.delete(account: account, service: service)   // ingen post: inget fel
    }

    @Test("Standardservicen är den riktiga och testservicen skiljer sig från den")
    func serviceIsolation() {
        #expect(KeychainStore.defaultService == "se.digido.photoflow.objektfilm")
        #expect(service != KeychainStore.defaultService)
    }

    @Test("Konfigurationen: nycklar per host och roll, bara i Keychain")
    func configKeys() throws {
        let suite = "objektfilm-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = ObjektfilmConfig(defaults: defaults, keychainService: service)
        let url = try #require(ObjektfilmConfig.parse("objekt.example.se"))
        #expect(url.absoluteString == "https://objekt.example.se")
        config.serverURLString = " https://objekt.example.se "
        defer {
            try? KeychainStore.delete(account: "objekt.example.se", service: service)
            try? KeychainStore.delete(account: "objekt.example.se (render)", service: service)
        }
        try config.saveKey("pf_foto", role: .photographer, for: url)
        try config.saveKey("pf_render", role: .render, for: url)
        #expect(config.key(.photographer) == "pf_foto")
        #expect(config.key(.render) == "pf_render")
        #expect(config.isRenderConfigured && config.isPhotographerConfigured)
        // Inget i UserDefaults utom URL (och reglaget).
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(stored.keys.sorted() == [ObjektfilmConfig.serverURLKey])
        #expect(!String(describing: stored).contains("pf_"))
        try config.saveKey("", role: .render, for: url)
        #expect(config.key(.render) == nil)
        #expect(ObjektfilmConfig.parse("ftp://x") == nil && ObjektfilmConfig.parse("") == nil)
    }
}
