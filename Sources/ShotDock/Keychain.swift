import Foundation
import Security
import ShotDockCore

/// S3 keys in the login keychain, never in preferences files.
enum Keychain {
    /// Selftests use their own item.
    nonisolated(unsafe) static var service = "app.shotdock.ShotDock.s3"
    private static let account = "default"

    private struct Stored: Codable {
        var accessKeyID: String
        var secretAccessKey: String
    }

    static func loadS3Credentials() -> S3Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return S3Credentials(accessKeyID: stored.accessKeyID, secretAccessKey: stored.secretAccessKey)
    }

    @discardableResult
    static func saveS3Credentials(_ credentials: S3Credentials?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let credentials, !credentials.accessKeyID.isEmpty || !credentials.secretAccessKey.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(Stored(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey)) else {
            return false
        }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "ShotDock: claves de S3"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
