import Foundation
import Security

/// Where the app keeps its Firestore credentials, and how it gets them.
///
/// Each permitted person signs in with Google. Only their Firebase refresh
/// token and the public project configuration are kept in the shared Keychain;
/// the hub's separate writer account never leaves the hub.
///
/// `AfterFirstUnlockThisDeviceOnly` lets widgets refresh in the background,
/// while keeping the token off backups and devices where the owner never
/// signed in.
enum RemoteAccess {
    private static let service = "com.souvikbiswas.plants.firestore"
    private static let account = "hub"
    private static let accessGroup = "P2FZ58Y7VW.com.souvikbiswas.plants.shared"

    @discardableResult
    static func save(_ credentials: RemoteCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> RemoteCredentials? {
        if let shared = load(accessGroup: accessGroup) { return shared }
        // Migrate builds that stored the item only in the main app's Keychain.
        guard let legacy = load(accessGroup: nil) else { return nil }
        if save(legacy) {
            delete(accessGroup: nil)
        }
        return legacy
    }

    private static func load(accessGroup: String?) -> RemoteCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder()
                  .decode(RemoteCredentials.self, from: data),
              credentials.isComplete else { return nil }
        return credentials
    }

    static func forget() {
        delete(accessGroup: accessGroup)
        delete(accessGroup: nil)
    }

    private static func delete(accessGroup: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
    }

    static var isPaired: Bool { load() != nil }
}
