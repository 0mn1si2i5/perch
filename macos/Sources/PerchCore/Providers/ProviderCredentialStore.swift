import Foundation
import Security

/// Stores only Perch-managed API credentials; never reads another client's login store.
public final class ProviderCredentialStore {
    private let service: String

    public init(service: String = "com.omnis.perch.api-provider") { self.service = service }

    public func read(for accountID: String) throws -> String? {
        try KeychainAccess.shared.serialized {
            var query = identity(accountID)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { throw CredentialError(status: status) }
            return value
        }
    }

    public func set(_ key: String, for accountID: String) throws {
        guard !accountID.isEmpty else { throw CredentialError(status: errSecParam) }
        try KeychainAccess.shared.serialized {
            let query = identity(accountID)
            let attributes = [kSecValueData as String: Data(key.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = Data(key.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CredentialError(status: status) }
        }
    }

    public func delete(for accountID: String) throws {
        try KeychainAccess.shared.serialized {
            let status = SecItemDelete(identity(accountID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
        }
    }

    private func identity(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID,
         kSecAttrSynchronizable as String: false]
    }

    public struct CredentialError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "无法访问 Perch API 钥匙串（\(status)）" }
    }
}
