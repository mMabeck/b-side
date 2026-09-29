import Foundation
import Security

enum TitleAPIKeychain {
    private static let service = "dev.mabeck.bside.title-api-key"
    private static let account = "openai-compatible"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var item: CFTypeRef?
        let request = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String) {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        let item = query.merging([kSecValueData as String: Data(key.utf8)]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }
}
