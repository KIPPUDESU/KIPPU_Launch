import CoreGraphics
import Foundation

/// 跨线程只共享不可变的 CGImage
public struct SkinHead: @unchecked Sendable {
    public let head: CGImage
    public let hat: CGImage?

    public init(head: CGImage, hat: CGImage?) {
        self.head = head
        self.hat = hat
    }
}

public enum SkinError: Error, LocalizedError {
    case profileUnavailable
    case malformedTextures
    case skinDownloadFailed(reason: String)
    case notASkinImage

    public var errorDescription: String? {
        switch self {
        case .profileUnavailable:
            return "取不到这个角色的档案。"
        case .malformedTextures:
            return "档案里的贴图信息无法解析。"
        case let .skinDownloadFailed(reason):
            return "下载皮肤失败：\(reason)"
        case .notASkinImage:
            return "下载到的不是合法的皮肤图。"
        }
    }
}

public actor SkinRepository {
    private let cacheDirectory: URL
    private let session: URLSession

    private var heads: [String: SkinHead] = [:]
    private var knownSkinless: Set<String> = []

    public init(cacheDirectory: URL, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    /// 角色未设置皮肤时返回空值
    public func headImage(apiRoot: URL, profileID: String) async throws -> SkinHead? {
        let key = "\(apiRoot.absoluteString)|\(profileID)"
        if let cached = heads[key] { return cached }
        if knownSkinless.contains(key) { return nil }

        let textures = try await textures(apiRoot: apiRoot, profileID: profileID)
        guard let skinURL = textures.skinURL else {
            knownSkinless.insert(key)
            return nil
        }

        let data = try await downloadSkin(from: skinURL)
        guard let skin = MinecraftSkin.decodeSkin(from: data) else {
            throw SkinError.notASkinImage
        }
        guard let head = MinecraftSkin.headImage(from: skin) else {
            throw SkinError.notASkinImage
        }

        let result = SkinHead(head: head, hat: MinecraftSkin.hatImage(from: skin))
        heads[key] = result
        return result
    }

    public func invalidate(apiRoot: URL, profileID: String) {
        let key = "\(apiRoot.absoluteString)|\(profileID)"
        heads.removeValue(forKey: key)
        knownSkinless.remove(key)
    }

    func textures(apiRoot: URL, profileID: String) async throws -> MinecraftProfileTextures {
        let url = apiRoot
            .appending(path: "sessionserver/session/minecraft/profile/\(profileID)")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SkinError.profileUnavailable
        }
        return try Self.parseTextures(fromProfileResponse: data)
    }

    static func parseTextures(fromProfileResponse data: Data) throws -> MinecraftProfileTextures {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = object["properties"] as? [[String: Any]]
        else {
            throw SkinError.malformedTextures
        }

        guard let encoded = properties
            .first(where: { ($0["name"] as? String) == "textures" })?["value"] as? String
        else {
            return MinecraftProfileTextures()
        }

        guard let decoded = decodeBase64(encoded),
              let textures = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let entries = textures["textures"] as? [String: Any]
        else {
            throw SkinError.malformedTextures
        }

        func url(_ key: String) -> URL? {
            guard let entry = entries[key] as? [String: Any],
                  let text = entry["url"] as? String
            else { return nil }
            return URL(string: text)
        }

        return MinecraftProfileTextures(skinURL: url("SKIN"), capeURL: url("CAPE"))
    }

    /// 部分皮肤站使用 URL 安全的 Base64 或省略末尾填充
    static func decodeBase64(_ text: String) -> Data? {
        if let data = Data(base64Encoded: text) { return data }
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    private func downloadSkin(from url: URL) async throws -> Data {
        let cacheFile = cacheDirectory
            .appending(path: "skins", directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent)

        if let cached = try? Data(contentsOf: cacheFile), !cached.isEmpty {
            return cached
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SkinError.skinDownloadFailed(
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)

        return data
    }
}
