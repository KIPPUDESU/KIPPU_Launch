import Foundation
import Security

public enum TokenStoreError: Error, LocalizedError {
    case keychain(status: OSStatus, operation: String)
    case encoding(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status, operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "Keychain \(operation) 失败（\(status)：\(message)）"
        case let .encoding(reason):
            return "令牌数据无法编解码：\(reason)"
        }
    }
}

public struct AccountSecrets: Sendable, Codable, Hashable {
    public var accessToken: String
    public var clientToken: String
    public var microsoftRefreshToken: String?

    public init(accessToken: String, clientToken: String) {
        self.accessToken = accessToken
        self.clientToken = clientToken
    }
}

public actor TokenStore {
    private let service: String

    public init(service: String = "com.kippu.KIPPU-Launch.yggdrasil") {
        self.service = service
    }

    public func save(_ secrets: AccountSecrets, for accountID: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        let account = accountID.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TokenStoreError.keychain(status: updateStatus, operation: "更新")
        }

        var insert = query
        insert[kSecValueData as String] = data
        // 本机开机后首次解锁即可读取 换机恢复时不会迁移
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.keychain(status: addStatus, operation: "写入")
        }
    }

    public func secrets(for accountID: UUID) throws -> AccountSecrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychain(status: status, operation: "读取")
        }
        guard let data = item as? Data else { return nil }

        do {
            return try JSONDecoder().decode(AccountSecrets.self, from: data)
        } catch {
            throw TokenStoreError.encoding(reason: error.localizedDescription)
        }
    }

    public func delete(for accountID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status: status, operation: "删除")
        }
    }
}
