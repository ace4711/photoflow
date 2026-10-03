import Foundation

/// Inställningarna för Objektfilm-servern. Server-URL och reglaget ligger i UserDefaults; de två
/// API-nycklarna (fotograf, render) ligger bara i Keychain, med serverns host som account.
nonisolated struct ObjektfilmConfig {

    nonisolated enum Role: Sendable { case photographer, render }

    static let serverURLKey = "objektfilmServerURL"
    static let autoRenderKey = "objektfilmAutoRender"

    var defaults: UserDefaults = .standard
    /// Tester anger en egen service, så att användarens riktiga nycklar aldrig rörs.
    var keychainService: String = KeychainStore.defaultService

    // MARK: Server

    var serverURLString: String {
        get { defaults.string(forKey: Self.serverURLKey) ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.serverURLKey) }
    }

    var autoRender: Bool {
        get { defaults.bool(forKey: Self.autoRenderKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoRenderKey) }
    }

    var serverURL: URL? { Self.parse(serverURLString) }

    /// Tolkar inmatningen som serveradress (utan schema antas https). Nil om den inte duger.
    static func parse(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: Nycklar

    /// Keychain-account: serverns host (render-nyckeln har ett suffix, så att båda får plats).
    static func account(host: String, role: Role) -> String {
        role == .photographer ? host : "\(host) (render)"
    }

    func key(_ role: Role, for url: URL? = nil) -> String? {
        guard let host = (url ?? serverURL)?.host else { return nil }
        return KeychainStore.read(account: Self.account(host: host, role: role), service: keychainService)
    }

    func saveKey(_ secret: String, role: Role, for url: URL) throws {
        guard let host = url.host else { return }
        let account = Self.account(host: host, role: role)
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try KeychainStore.delete(account: account, service: keychainService) }
        else { try KeychainStore.save(trimmed, account: account, service: keychainService) }
    }

    // MARK: Klienter

    /// Klient för rollen, eller `notConfigured` om server eller nyckel saknas.
    func client(_ role: Role, session: URLSession = .shared) throws -> ReelServerClient {
        guard let url = serverURL, let key = key(role, for: url), !key.isEmpty else { throw ReelServerError.notConfigured }
        return ReelServerClient(baseURL: url, key: key, session: session)
    }

    var isRenderConfigured: Bool { serverURL != nil && !(key(.render) ?? "").isEmpty }
    var isPhotographerConfigured: Bool { serverURL != nil && !(key(.photographer) ?? "").isEmpty }
}
