import Foundation
import Security

/// API keys for OpenAI-compatible servers, one per base URL, in the login keychain (never in
/// UserDefaults). Note: the app is ad-hoc signed, so after a rebuild macOS may ask once whether
/// Inkboard may read the stored key.
enum APIKeychain {
    private static let service = "local.inkboard.api-key"

    static func key(for baseURL: URL) -> String? {
        var query = baseQuery(baseURL)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes the stored one.
    static func setKey(_ key: String, for baseURL: URL) {
        let query = baseQuery(baseURL)
        guard !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Inkboard API Key（\(baseURL.host ?? baseURL.absoluteString)）"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery(_ baseURL: URL) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: baseURL.absoluteString]
    }
}
