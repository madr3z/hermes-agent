import Foundation
import Security

struct GatewayKeychain {
    private static let service = "com.hermes.iphone.gateway"
    static func save(_ token: String, id: UUID) throws {
        try saveData(Data(token.utf8), id: id)
    }
    static func saveData(_ data: Data, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw KeychainError.failed }
        } else if status != errSecSuccess { throw KeychainError.failed }
    }
    static func read(_ id: UUID) throws -> String {
        guard let token = String(data: try readData(id), encoding: .utf8) else { throw KeychainError.failed }
        return token
    }
    static func readData(_ id: UUID) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw KeychainError.failed }
        return data
    }
    static func remove(_ id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.failed }
    }
    enum KeychainError: LocalizedError {
        case failed
        var errorDescription: String? { "Could not access the gateway credential in Keychain." }
    }
}
