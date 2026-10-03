import Foundation
import Security

/// Lösenordsobjekt i macOS Keychain (`kSecClassGenericPassword`) för Objektfilm-nycklarna.
/// service = `se.digido.photoflow.objektfilm`, account = serverns host (render-nyckeln har
/// suffixet ` (render)`, se `ObjektfilmConfig`). Nycklar läggs aldrig i UserDefaults.
///
/// Tester använder en egen `service`-sträng så att användarens riktiga nyckel aldrig rörs.
nonisolated enum KeychainStore {

    static let defaultService = "se.digido.photoflow.objektfilm"

    nonisolated enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let s):
                let text = SecCopyErrorMessageString(s, nil) as String? ?? "okänt fel"
                return "Nyckelringen svarade med fel \(s): \(text)"
            }
        }
    }

    private static func query(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Sparar (eller ersätter) hemligheten.
    static func save(_ secret: String, account: String, service: String = defaultService) throws {
        let data = Data(secret.utf8)
        let base = query(account: account, service: service)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Läser hemligheten, nil om den inte finns.
    static func read(account: String, service: String = defaultService) -> String? {
        var q = query(account: account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Raderar hemligheten. Att den inte fanns är inget fel.
    static func delete(account: String, service: String = defaultService) throws {
        let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
