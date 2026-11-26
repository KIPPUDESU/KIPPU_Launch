import Foundation

public struct PlaceholderValues: Sendable {
    public var playerName: String = ""
    public var uuid: String = ""
    public var accessToken: String = ""
    public var userType: String = "legacy"
    public var xuid: String = ""
    public var clientID: String = ""
    public var sessionID: String = ""
    public var userProperties: String = "{}"

    public var versionName: String = ""
    public var versionType: String = "release"
    public var gameDirectory: String = ""
    public var assetsRoot: String = ""
    public var assetsIndexName: String = ""
    public var gameAssets: String = ""
    public var nativesDirectory: String = ""
    public var launcherName: String = "KIPPU_Launch"
    public var launcherVersion: String = "1.0"

    public var classpath: String = ""
    /// HMCL 扩展供 Forge 构造模块路径
    public var libraryDirectory: String = ""
    public var classpathSeparator: String = ":"
    public var primaryJarName: String = ""

    public var resolutionWidth: String?
    public var resolutionHeight: String?
    public var quickPlayPath: String?
    public var quickPlaySingleplayer: String?
    public var quickPlayMultiplayer: String?
    public var quickPlayRealms: String?

    public init() {}

    public var table: [String: String] {
        [
            "auth_player_name": playerName,
            "auth_uuid": uuid,
            "auth_access_token": accessToken,
            "auth_xuid": xuid,
            "auth_session": sessionID,
            "clientid": clientID,
            "user_type": userType,
            "user_properties": userProperties,

            "version_name": versionName,
            "version_type": versionType,
            "game_directory": gameDirectory,
            "assets_root": assetsRoot,
            "assets_index_name": assetsIndexName,
            "game_assets": gameAssets,
            "natives_directory": nativesDirectory,
            "launcher_name": launcherName,
            "launcher_version": launcherVersion,

            "classpath": classpath,
            "library_directory": libraryDirectory,
            "classpath_separator": classpathSeparator,
            "primary_jar_name": primaryJarName,

            "resolution_width": resolutionWidth ?? "",
            "resolution_height": resolutionHeight ?? "",
            "quickPlayPath": quickPlayPath ?? "",
            "quickPlaySingleplayer": quickPlaySingleplayer ?? "",
            "quickPlayMultiplayer": quickPlayMultiplayer ?? "",
            "quickPlayRealms": quickPlayRealms ?? "",
        ]
    }

    /// 未知占位符替换为空串
    public func substitute(_ text: String) -> String {
        guard text.contains("${") else { return text }
        let values = table

        var result = ""
        var cursor = text.startIndex
        while let opening = text[cursor...].range(of: "${") {
            result += text[cursor..<opening.lowerBound]
            guard let closing = text[opening.upperBound...].firstIndex(of: "}") else {
                result += text[opening.lowerBound...]
                return result
            }
            let key = String(text[opening.upperBound..<closing])
            result += values[key] ?? ""
            cursor = text.index(after: closing)
        }
        result += text[cursor...]
        return result
    }

    /// 空值也占一个参数位置
    public func substituteAll(_ arguments: [String]) -> [String] {
        arguments.map(substitute)
    }
}
