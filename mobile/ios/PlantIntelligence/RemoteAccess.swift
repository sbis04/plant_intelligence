import Foundation

/// Where the app keeps its Firestore credentials, and how it gets them.
///
/// The credentials are not typed in. The first time the app is on the same
/// Wi-Fi as the hub it asks for them over the LAN and files them in the
/// Keychain — pair once at home, work anywhere afterwards. Every device that
/// has been home is set up; a device that never has cannot reach the garden
/// remotely, which is the right default.
///
/// The Keychain item is deliberately `WhenUnlockedThisDeviceOnly`: these
/// credentials should not ride an iCloud backup onto a device that was never
/// on the home network.
enum RemoteAccess {
    private static let service = "com.souvikbiswas.plants.firestore"
    private static let account = "hub"

    static func save(_ credentials: CloudClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> CloudClient.Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder()
                  .decode(CloudClient.Credentials.self, from: data),
              credentials.isComplete else { return nil }
        return credentials
    }

    static func forget() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    static var isPaired: Bool { load() != nil }
}
