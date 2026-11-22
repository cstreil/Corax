import Foundation
import CoraxKit
import Security

/// M3.1: Zugriff auf den **dateibasierten** Schlüsselbund (login.keychain).
///
/// Der Kern legt seine Geheimnisse über `security-framework` dort ab
/// (`SecKeychainAddGenericPassword`), nicht in der Data-Protection-Keychain.
/// Deshalb setzt jede Abfrage hier `kSecUseDataProtectionKeychain = false` —
/// sonst landete eine übernommene Kopie in einem anderen Speicher, den der
/// Kern nie liest.
enum KeychainAccess {
    /// Frische Abfragebasis je Aufruf; `kSecUseDataProtectionKeychain = false`
    /// hält den Zugriff in der dateibasierten Keychain, in der auch der Kern
    /// schreibt.
    private static func base() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecUseDataProtectionKeychain: false]
    }

    /// Gibt es den Eintrag? Fragt nur Metadaten ab (kein Zugriffsprompt).
    static func exists(service: String, account: String) -> Bool {
        var query = base()
        query[kSecAttrService] = service
        query[kSecAttrAccount] = account
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Das Geheimnis. macOS fragt hier nach Zugriff, wenn der Eintrag von einer
    /// anderen App angelegt wurde (der Nutzer bestätigt mit „Immer erlauben“).
    static func secret(service: String, account: String) -> String? {
        var query = base()
        query[kSecAttrService] = service
        query[kSecAttrAccount] = account
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Legt den Eintrag unter dem neuen Service an; vorhandene bleiben.
    @discardableResult
    static func store(service: String, account: String, secret: String) -> Bool {
        var attributes = base()
        attributes[kSecAttrService] = service
        attributes[kSecAttrAccount] = account
        attributes[kSecValueData] = Data(secret.utf8)
        attributes[kSecAttrLabel] = "\(AppIdentity.displayName) (\(service))"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}
