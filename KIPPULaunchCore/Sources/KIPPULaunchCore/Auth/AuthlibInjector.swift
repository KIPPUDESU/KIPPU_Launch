import CryptoKit
import Foundation

public enum AuthlibInjectorError: Error, LocalizedError {
    case manifestUnavailable(reason: String)
    case downloadFailed(reason: String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .manifestUnavailable(reason):
            return "无法获取 authlib-injector 的版本信息：\(reason)"
        case let .downloadFailed(reason):
            return "下载 authlib-injector 失败：\(reason)"
        case let .checksumMismatch(expected, actual):
            return "authlib-injector 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        }
    }
}

public struct AuthlibInjector: Sendable {
    public let jarURL: URL

    public init(jarURL: URL) {
        self.jarURL = jarURL
    }

    /// 预载站点元数据可省去游戏启动时的请求
    public func jvmArguments(apiRoot: URL, metadata: YggdrasilMetadata?) -> [String] {
        var arguments = ["-javaagent:\(jarURL.path(percentEncoded: false))=\(apiRoot.absoluteString)"]
        if let metadata {
            arguments.append("-Dauthlibinjector.yggdrasil.prefetched=\(metadata.prefetchedBase64)")
        }
        return arguments
    }
}

extension AuthlibInjector {
    public static let manifestURL = URL(string: "https://authlib-injector.yushi.moe/artifact/latest.json")!
    public static let mirrorManifestURL = URL(string: "https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json")!

    public static func prepare(
        at directory: URL,
        session: URLSession = .shared
    ) async throws -> AuthlibInjector {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let jarURL = directory.appending(path: "authlib-injector.jar")
        let cachedExists = fileManager.fileExists(atPath: jarURL.path(percentEncoded: false))

        let release: Release
        do {
            release = try await fetchLatestRelease(session: session)
        } catch {
            if cachedExists { return AuthlibInjector(jarURL: jarURL) }
            throw error
        }

        if cachedExists,
           let existing = try? Data(contentsOf: jarURL),
           sha256Hex(existing) == release.sha256 {
            return AuthlibInjector(jarURL: jarURL)
        }

        let data = try await download(release, session: session)
        let actual = sha256Hex(data)
        guard actual == release.sha256 else {
            throw AuthlibInjectorError.checksumMismatch(expected: release.sha256, actual: actual)
        }

        try data.write(to: jarURL, options: .atomic)
        return AuthlibInjector(jarURL: jarURL)
    }

    struct Release: Sendable {
        var version: String
        var sha256: String
        var downloadURL: URL
    }

    static func fetchLatestRelease(session: URLSession) async throws -> Release {
        var lastReason = "未知原因"
        for url in [manifestURL, mirrorManifestURL] {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastReason = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    continue
                }
                return try parseRelease(data)
            } catch {
                lastReason = error.localizedDescription
            }
        }
        throw AuthlibInjectorError.manifestUnavailable(reason: lastReason)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              let downloadURLString = object["download_url"] as? String,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw AuthlibInjectorError.manifestUnavailable(reason: "版本信息格式不正确")
        }
        let checksums = object["checksums"] as? [String: Any]
        guard let sha256 = checksums?["sha256"] as? String, !sha256.isEmpty else {
            throw AuthlibInjectorError.manifestUnavailable(reason: "版本信息里没有 sha256 校验和")
        }
        return Release(version: version, sha256: sha256.lowercased(), downloadURL: downloadURL)
    }

    private static func download(_ release: Release, session: URLSession) async throws -> Data {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AuthlibInjectorError.downloadFailed(
                    reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                )
            }
            return data
        } catch let error as AuthlibInjectorError {
            throw error
        } catch {
            throw AuthlibInjectorError.downloadFailed(reason: error.localizedDescription)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}
