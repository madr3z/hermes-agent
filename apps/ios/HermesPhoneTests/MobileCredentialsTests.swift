import Foundation
import Security
import XCTest
@testable import HermesPhone

final class MobileCredentialsTests: XCTestCase {
    func testOptInCopyHasSeparateAfterFirstUnlockProtectionAndCanBeRemoved() throws {
        let id = UUID(), fixture = Data("fixture-controller-session".utf8)
        defer { try? MobileCredentials.remove(id); try? GatewayKeychain.remove(id) }
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hermes.iphone.keychain-fixture", kSecAttrAccount as String: id.uuidString]
        let status = SecItemAdd(probe.merging([kSecValueData as String: fixture]) { _, new in new } as CFDictionary, nil)
        defer { SecItemDelete(probe as CFDictionary) }
        guard status == errSecSuccess else {
            return XCTFail("The app-hosted test cannot access Keychain (OSStatus \(status)). Run the simulator test host with valid ad hoc signing.")
        }
        try GatewayKeychain.saveData(fixture, id: id)
        try MobileCredentials.save(fixture, id: id)
        XCTAssertEqual(try MobileCredentials.read(id), fixture)
        func protection(service: String) throws -> String {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnAttributes as String: true]
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
            return try XCTUnwrap((result as? [String: Any])?[kSecAttrAccessible as String] as? String)
        }
        XCTAssertEqual(try protection(service: "com.hermes.iphone.incoming-call"), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try protection(service: "com.hermes.iphone.gateway"), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try MobileCredentials.remove(id)
        XCTAssertThrowsError(try MobileCredentials.read(id))
        XCTAssertEqual(try GatewayKeychain.readData(id), fixture)
    }
}
