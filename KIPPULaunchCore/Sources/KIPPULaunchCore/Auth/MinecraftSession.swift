import CryptoKit
import Foundation

public struct MinecraftSession: Sendable, Equatable {
    /// UUID 省略连字符
    public var uuid: String
    public var playerName: String
    public var accessToken: String
    public var userType: String
    public var xuid: String
    public var clientID: String
    /// 旧版客户端连空属性也要读成 JSON 对象
    public var userProperties: String
    public var extraJVMArguments: [String]

    public init(
        uuid: String,
        playerName: String,
        accessToken: String,
        userType: String = "legacy",
        xuid: String = "",
        clientID: String = "",
        userProperties: String = "{}",
        extraJVMArguments: [String] = []
    ) {
        self.uuid = uuid
        self.playerName = playerName
        self.accessToken = accessToken
        self.userType = userType
        self.xuid = xuid
        self.clientID = clientID
        self.userProperties = userProperties
        self.extraJVMArguments = extraJVMArguments
    }
}

public protocol AccountProvider: Sendable {
    /// 提供者负责按需刷新令牌
    func session() async throws -> MinecraftSession
}

public struct OfflineAccountProvider: AccountProvider {
    public let playerName: String

    public init(playerName: String) {
        self.playerName = playerName
    }

    public func session() async throws -> MinecraftSession {
        MinecraftSession(
            uuid: OfflineUUID.forPlayerName(playerName),
            playerName: playerName,
            accessToken: "0",
            userType: "legacy"
        )
    }
}

/// 同一个玩家名要和 Java 算出相同的 UUID 才能沿用存档
public enum OfflineUUID {
    public static func forPlayerName(_ name: String) -> String {
        var digest = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))

        // RFC 4122 规定的版本位和变体位
        digest[6] = (digest[6] & 0x0F) | 0x30
        digest[8] = (digest[8] & 0x3F) | 0x80

        return format(digest)
    }

    private static func format(_ digest: [UInt8]) -> String {
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let groups = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20),
        ]
        return groups.map(String.init).joined(separator: "-")
    }
}
