import Foundation
import Security
public struct MootCredentialStore {
    public init() {}
    private func query(_ ref: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.omnis.perch.moot", kSecAttrAccount as String: ref] }
    public func put(ref: String, secret: Data) throws {
        guard !ref.isEmpty, !secret.isEmpty else { throw MootRPCError(code: "invalidCredential", message: "凭据名称与内容不能为空") }
        let q = query(ref), update = [kSecValueData as String: secret]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { var item = q; item[kSecValueData as String] = secret; try check(SecItemAdd(item as CFDictionary, nil)) } else { try check(status) }
    }
    public func read(ref: String) throws -> Data {
        var q = query(ref); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?; try check(SecItemCopyMatching(q as CFDictionary, &result))
        guard let data = result as? Data else { throw MootRPCError(code: "credentialUnavailable", message: "钥匙串凭据不可读取") }; return data
    }
    public func remove(ref: String) throws { let status = SecItemDelete(query(ref) as CFDictionary); if status != errSecItemNotFound { try check(status) } }
    private func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw MootRPCError(code: "keychain", message: "钥匙串操作失败（\(status)），请在 Perch 中重新保存凭据。") } }
}

/// The same signed helper owns both writes and reads, so background access does not depend on the GUI's Keychain identity.
public struct MootCredentialBridge: Sendable {
    public var paths: MootPaths
    public init(paths: MootPaths = MootPaths()) { self.paths = paths }
    public func put(ref: String, secret: String) async throws {
        let paths = self.paths
        try await Task.detached {
            let process = Process(), input = Pipe()
            process.executableURL = paths.root.appendingPathComponent("current/PerchMootCredentials")
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = try JSONSerialization.data(withJSONObject: ["operation": "put", "ref": ref, "secret": secret])
            input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw MootRPCError(code: "keychain", message: "无法保存扩展凭据，请检查钥匙串访问。") }
        }.value
    }
}
