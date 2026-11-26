import Foundation

public struct YggdrasilProfile: Sendable, Codable, Hashable {
    /// 协议中的 UUID 省略连字符
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct YggdrasilMetadata: Sendable {
    public var serverName: String?
    public var implementationName: String?
    public var implementationVersion: String?
    /// 域名前导点表示按后缀匹配
    public var skinDomains: [String]
    public var signaturePublicKey: String?
    /// 交给注入器的是服务器返回的原始 JSON 字节
    public let rawJSON: Data

    public var prefetchedBase64: String { rawJSON.base64EncodedString() }
}

public struct YggdrasilSession: Sendable {
    public var accessToken: String
    public var clientToken: String
    public var selectedProfile: YggdrasilProfile?
    public var availableProfiles: [YggdrasilProfile]
    /// 这是账号 ID 同一账号可以有多个角色 ID
    public var userID: String?
}

public enum YggdrasilError: Error, LocalizedError, Equatable {
    case invalidAPIRoot(String)
    case network(reason: String)
    /// 服务端对账号不存在与密码错误返回同一错误
    case invalidCredentials(message: String)
    case invalidToken(message: String)
    case noProfiles
    case server(error: String, message: String, status: Int)
    case malformedResponse(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAPIRoot(input):
            return "「\(input)」不是一个有效的 Yggdrasil 服务地址。"
        case let .network(reason):
            return "网络请求失败：\(reason)"
        case let .invalidCredentials(message):
            return "账号或密码错误。\(message)"
        case let .invalidToken(message):
            return "登录状态已失效，请重新登录。\(message)"
        case .noProfiles:
            return "这个账号下没有可用的角色。请先去皮肤站创建角色。"
        case let .server(error, message, status):
            return "服务端返回错误（\(status) \(error)）：\(message)"
        case let .malformedResponse(reason):
            return "服务端响应无法解析：\(reason)"
        }
    }
}

public struct YggdrasilClient: Sendable {
    public let apiRoot: URL
    private let session: URLSession

    public init(apiRoot: URL, session: URLSession = .shared) {
        self.apiRoot = apiRoot
        self.session = session
    }

    public static func resolveAPIRoot(
        from userInput: String,
        session: URLSession = .shared
    ) async throws -> URL {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YggdrasilError.invalidAPIRoot(userInput) }

        let candidate: URL
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { throw YggdrasilError.invalidAPIRoot(userInput) }
            candidate = url
        } else {
            guard let url = URL(string: "https://\(trimmed)") else {
                throw YggdrasilError.invalidAPIRoot(userInput)
            }
            candidate = url
        }

        if let discovered = try? await discoverAPILocation(at: candidate, session: session) {
            return discovered
        }

        let client = YggdrasilClient(apiRoot: candidate, session: session)
        _ = try await client.metadata()
        return candidate
    }

    private static func discoverAPILocation(at url: URL, session: URLSession) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "X-Authlib-Injector-API-Location"),
              !location.isEmpty
        else {
            throw YggdrasilError.invalidAPIRoot(url.absoluteString)
        }

        // ALI 响应头允许相对地址
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            guard let absolute = URL(string: location) else {
                throw YggdrasilError.invalidAPIRoot(location)
            }
            return absolute
        }
        guard let resolved = URL(string: location, relativeTo: url)?.absoluteURL else {
            throw YggdrasilError.invalidAPIRoot(location)
        }
        return resolved
    }

    public func metadata() async throws -> YggdrasilMetadata {
        var request = URLRequest(url: apiRoot)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YggdrasilError.invalidAPIRoot(apiRoot.absoluteString)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YggdrasilError.malformedResponse(reason: "顶层不是 JSON 对象")
        }

        let meta = object["meta"] as? [String: Any]
        return YggdrasilMetadata(
            serverName: meta?["serverName"] as? String,
            implementationName: meta?["implementationName"] as? String,
            implementationVersion: meta?["implementationVersion"] as? String,
            skinDomains: object["skinDomains"] as? [String] ?? [],
            signaturePublicKey: object["signaturePublickey"] as? String,
            rawJSON: data
        )
    }

    public func authenticate(
        username: String,
        password: String,
        clientToken: String,
        requestUser: Bool = true
    ) async throws -> YggdrasilSession {
        var body: [String: Any] = [
            "agent": ["name": "Minecraft", "version": 1],
            "username": username,
            "password": password,
            "clientToken": clientToken,
        ]
        if requestUser { body["requestUser"] = true }

        let data = try await post(path: "authserver/authenticate", body: body)
        return try decodeSession(data)
    }

    /// 令牌过期仍可尝试刷新 刷新失败也不会撤销原令牌
    public func refresh(
        accessToken: String,
        clientToken: String,
        selectedProfile: YggdrasilProfile? = nil,
        requestUser: Bool = true
    ) async throws -> YggdrasilSession {
        var body: [String: Any] = [
            "accessToken": accessToken,
            "clientToken": clientToken,
        ]
        if let selectedProfile {
            body["selectedProfile"] = ["id": selectedProfile.id, "name": selectedProfile.name]
        }
        if requestUser { body["requestUser"] = true }

        let data = try await post(path: "authserver/refresh", body: body)
        return try decodeSession(data)
    }

    public func validate(accessToken: String, clientToken: String) async throws -> Bool {
        do {
            _ = try await post(
                path: "authserver/validate",
                body: ["accessToken": accessToken, "clientToken": clientToken]
            )
            return true
        } catch let error as YggdrasilError {
            if case .invalidToken = error { return false }
            if case .invalidCredentials = error { return false }
            throw error
        }
    }

    public func invalidate(accessToken: String, clientToken: String) async throws {
        _ = try await post(
            path: "authserver/invalidate",
            body: ["accessToken": accessToken, "clientToken": clientToken]
        )
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: apiRoot.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw YggdrasilError.malformedResponse(reason: "没有 HTTP 响应")
        }

        if http.statusCode == 204 { return Data() }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(data: data, status: http.statusCode)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw YggdrasilError.network(reason: error.localizedDescription)
        }
    }

    static func mapError(data: Data, status: Int) -> YggdrasilError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? String ?? "Unknown"
        let message = object?["errorMessage"] as? String ?? ""

        if status == 403 {
            switch error {
            case "ForbiddenOperationException":
                // 服务端用同一个错误名报告密码错误和令牌失效
                if message.localizedCaseInsensitiveContains("token") {
                    return .invalidToken(message: message)
                }
                return .invalidCredentials(message: message)
            default:
                return .server(error: error, message: message, status: status)
            }
        }
        return .server(error: error, message: message, status: status)
    }

    private func decodeSession(_ data: Data) throws -> YggdrasilSession {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YggdrasilError.malformedResponse(reason: "登录响应不是 JSON 对象")
        }
        guard let accessToken = object["accessToken"] as? String else {
            throw YggdrasilError.malformedResponse(reason: "登录响应缺少 accessToken")
        }
        let clientToken = object["clientToken"] as? String ?? ""

        func profile(from value: Any?) -> YggdrasilProfile? {
            guard let dictionary = value as? [String: Any],
                  let id = dictionary["id"] as? String,
                  let name = dictionary["name"] as? String
            else { return nil }
            return YggdrasilProfile(id: id, name: name)
        }

        let available = (object["availableProfiles"] as? [Any] ?? []).compactMap(profile(from:))
        let selected = profile(from: object["selectedProfile"])

        return YggdrasilSession(
            accessToken: accessToken,
            clientToken: clientToken,
            selectedProfile: selected,
            availableProfiles: available,
            userID: (object["user"] as? [String: Any])?["id"] as? String
        )
    }
}
