import Foundation
import Security

/// A separate interface lets tests use synthetic credentials without touching the user's Keychain.
protocol DshAuthorizationStorage {
    func read(_ key: String, interactive: Bool) throws -> DshAuthorization?
    func write(_ value: DshAuthorization, key: String, interactive: Bool) throws
    func remove(_ key: String) throws
}

extension DshAuthorizationStorage {
    func read(_ key: String) throws -> DshAuthorization? { try read(key, interactive: false) }
}

final class DshAuthorizationStore: DshAuthorizationStorage {
    private let service = "com.omnis.perch.dsh.web"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func read(_ key: String, interactive: Bool = false) throws -> DshAuthorization? {
        do {
            return try KeychainAccess.shared.withInteraction(allowed: interactive) {
                var request = query(key)
                request[kSecReturnData as String] = true
                request[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = result as? Data,
                      let authorization = try? JSONDecoder().decode(DshAuthorization.self, from: data) else {
                    throw DshError.invalid("无法读取 dsh 本机授权，请重新连接。")
                }
                return authorization
            }
        } catch { throw DshError.invalid("无法读取 dsh 本机授权。请点击打开网页，并允许 Perch 访问对应钥匙串项目。") }
    }

    func write(_ value: DshAuthorization, key: String, interactive: Bool = false) throws {
        do {
            let data = try JSONEncoder().encode(value)
            try KeychainAccess.shared.withInteraction(allowed: interactive) {
                let request = query(key)
                let update = [kSecValueData as String: data]
                var status = SecItemUpdate(request as CFDictionary, update as CFDictionary)
                if status == errSecItemNotFound {
                    var item = request
                    item[kSecValueData as String] = data
                    item[kSecAttrLabel as String] = "Perch · dsh 本机连接"
                    status = SecItemAdd(item as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw DshError.invalid("无法保存 dsh 本机授权。") }
            }
        } catch { throw DshError.invalid("无法保存 dsh 本机授权，请解锁钥匙串后重试。") }
    }

    func remove(_ key: String) throws {
        do {
            try KeychainAccess.shared.withInteraction(allowed: false) {
                let status = SecItemDelete(query(key) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw DshError.invalid("无法移除 dsh 本机授权。")
                }
            }
        } catch { throw DshError.invalid("无法移除 dsh 本机授权，请解锁钥匙串后重试。") }
    }
}
