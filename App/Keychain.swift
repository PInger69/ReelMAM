import Foundation
import Security

/// Stores small secrets (external A.I. hook tokens) in the user's keychain.
enum Keychain {
    private static let service = "com.stadaxr.mam.hooks"

    static func token(for hookID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: hookID, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for hookID: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: hookID,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
