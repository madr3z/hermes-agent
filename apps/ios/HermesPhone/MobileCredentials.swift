import Foundation
import Security
import HermesGateway

/// Only explicit incoming-call opt-in creates this locked-phone credential copy.
enum MobileCredentials {
    private static let service = "com.hermes.iphone.incoming-call"
    static func save(_ data: Data, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw GatewayKeychain.KeychainError.failed }
        } else if status != errSecSuccess { throw GatewayKeychain.KeychainError.failed }
    }
    static func read(_ id: UUID) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw GatewayKeychain.KeychainError.failed }
        return data
    }
    static func remove(_ id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GatewayKeychain.KeychainError.failed }
    }
    @MainActor static func synchronize(_ data: Data, id: UUID) throws {
        if MobileContact.shared.settings[id]?.calls == true { try save(data, id: id) }
        MobileContact.shared.credentialsChanged(id)
    }
    @MainActor static func foregroundData(_ id: UUID) throws -> Data {
        if MobileContact.shared.settings[id]?.calls == true {
            let data = try read(id)
            try GatewayKeychain.saveData(data, id: id)
            return data
        }
        return try GatewayKeychain.readData(id)
    }
}
