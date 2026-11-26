import Foundation

public struct MicrosoftLogin: Sendable {
    public struct Code: Decodable, Sendable {
        public let user_code: String
        public let verification_uri: URL
        let device_code: String
        let expires_in: Int
        let interval: Int?
    }
    public struct Tokens: Decodable, Sendable {
        let access_token: String
        public let refresh_token: String?
    }
    public let clientID: String
    let network: URLSession
    public init(clientID: String, network: URLSession = .shared) {
        self.clientID = clientID
        self.network = network
    }
    static let tenant = "https://login.microsoftonline.com/consumers/oauth2/v2.0/"
    private let scope = "XboxLive.signin offline_access"

    struct Failure: LocalizedError {
        let stage: String
        let code: String
        var errorDescription: String? {
            switch code {
            case "authorization_declined", "access_denied": return "已取消 Microsoft 授权。"
            case "expired_token", "invalid_grant": return "授权已过期，请重新登录。"
            case "unauthorized_client", "invalid_client": return "Microsoft 未接受启动器的应用 ID，请检查公共客户端配置。"
            case "2148916233": return "此账号还没有 Xbox 档案，请先在 Xbox 网站创建档案。"
            default: return "\(stage)失败（\(code)）。"
            }
        }
    }
    private func fetch<T: Decodable>(_ request: URLRequest, stage: String, as type: T.Type) async throws -> T {
        let (body, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = fields?["error"] as? String ?? (fields?["XErr"] as? NSNumber)?.stringValue ?? String(http.statusCode)
            throw Failure(stage: stage, code: code)
        }
        return try JSONDecoder().decode(type, from: body)
    }

    private func form(_ endpoint: String, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.tenant + endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func encode(_ component: String) -> String {
            component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        request.httpBody = Data(fields.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
        return request
    }

    public func begin() async throws -> Code {
        try await fetch(form("devicecode", ["client_id": clientID, "scope": scope]), stage: "申请登录码", as: Code.self)
    }
    public func authorize(_ code: Code) async throws -> Tokens {
        let deadline = ContinuousClock.now + .seconds(code.expires_in)
        var interval = max(1, code.interval ?? 5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            do {
                return try await fetch(form("token", ["client_id": clientID, "device_code": code.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]), stage: "Microsoft 授权", as: Tokens.self)
            } catch let error as Failure {
                if error.code == "slow_down" { interval += 5 }
                else if error.code != "authorization_pending" { throw error }
            }
        }
        throw Failure(stage: "Microsoft 授权", code: "expired_token")
    }
    public func refresh(_ refreshToken: String) async throws -> Tokens {
        try await fetch(form("token", ["client_id": clientID, "refresh_token": refreshToken, "scope": scope, "grant_type": "refresh_token"]),
            stage: "刷新 Microsoft 登录", as: Tokens.self)
    }

    public func gameSession(_ tokens: Tokens) async throws -> MinecraftSession {
        struct Xbox: Decodable {
            struct Claims: Decodable {
                struct User: Decodable {
                    let uhs: String
                    let xid: String?
                }
                let xui: [User]
            }
            let Token: String
            let DisplayClaims: Claims
        }
        struct MinecraftToken: Decodable { let access_token: String }
        func json(_ url: String, _ fields: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
            return request
        }
        let xbl = try await fetch(json("https://user.auth.xboxlive.com/user/authenticate", [
            "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=" + tokens.access_token],
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"
        ]), stage: "Xbox 登录", as: Xbox.self)
        let xsts = try await fetch(json("https://xsts.auth.xboxlive.com/xsts/authorize", [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xbl.Token]],
            "RelyingParty": "rp://api.minecraftservices.com/", "TokenType": "JWT"
        ]), stage: "Xbox 游戏授权", as: Xbox.self)
        guard let claim = xsts.DisplayClaims.xui.first else { throw Failure(stage: "读取 Xbox 档案", code: "missing_profile") }
        let minecraft = try await fetch(json("https://api.minecraftservices.com/authentication/login_with_xbox", [
            "identityToken": "XBL3.0 x=\(claim.uhs);\(xsts.Token)"
        ]), stage: "Minecraft 服务授权", as: MinecraftToken.self)
        var request = URLRequest(url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!)
        request.setValue("Bearer " + minecraft.access_token, forHTTPHeaderField: "Authorization")
        do {
            let profile = try await fetch(request, stage: "读取 Java 版角色", as: YggdrasilProfile.self)
            return MinecraftSession(uuid: profile.id, playerName: profile.name, accessToken: minecraft.access_token,
                                    userType: "msa", xuid: claim.xid ?? "", clientID: clientID)
        } catch let error as Failure where error.code == "404" || error.code == "NOT_FOUND" {
            throw Failure(stage: "读取 Java 版角色，请确认账号拥有游戏并已创建角色", code: error.code)
        }
    }
}
