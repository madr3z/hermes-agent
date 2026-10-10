import Foundation
import Security

struct GatewayKeychain {
    private static let service = "com.hermes.iphone.gateway"
    static func save(_ token: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw KeychainError.failed }
        } else if status != errSecSuccess { throw KeychainError.failed }
    }
    static func read(_ id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw KeychainError.failed }
        return token
    }
    enum KeychainError: LocalizedError {
        case failed
        var errorDescription: String? { "Could not access the gateway credential in Keychain." }
    }
}
