import Foundation

public enum YggdrasilAccountError: Error, LocalizedError {
    case notAYggdrasilAccount
    case missingSecrets
    case noProfileSelected
    case needsReauthentication(reason: String)
    case injectorUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAYggdrasilAccount:
            return "这不是一个外置登录账号。"
        case .missingSecrets:
            return "找不到这个账号的登录令牌，请重新登录。"
        case .noProfileSelected:
            return "这个账号还没有选定角色。请先选择要使用的角色。"
        case let .needsReauthentication(reason):
            return "登录状态已失效，请重新登录。\(reason)"
        case let .injectorUnavailable(reason):
            return "无法准备 authlib-injector，外置登录必需它：\(reason)"
        }
    }
}

public actor YggdrasilAccountService {
    private let repository: AccountRepository
    private let injectorDirectory: URL
    private let session: URLSession

    private var metadataCache: [String: YggdrasilMetadata] = [:]
    private var injector: AuthlibInjector?

    public init(
        repository: AccountRepository,
        injectorDirectory: URL,
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.injectorDirectory = injectorDirectory
        self.session = session
    }

    @discardableResult
    public func signIn(
        userInput: String,
        username: String,
        password: String,
        preferredProfileID: String? = nil
    ) async throws -> StoredAccount {
        let apiRoot = try await YggdrasilClient.resolveAPIRoot(from: userInput, session: session)
        let client = YggdrasilClient(apiRoot: apiRoot, session: session)
        let metadata = try await client.metadata()

        let clientToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sessionResult = try await client.authenticate(
            username: username,
            password: password,
            clientToken: clientToken
        )

        guard !sessionResult.availableProfiles.isEmpty || sessionResult.selectedProfile != nil else {
            throw YggdrasilError.noProfiles
        }

        let profile = preferredProfileID
            .flatMap { id in sessionResult.availableProfiles.first { $0.id == id } }
            ?? sessionResult.selectedProfile
            ?? sessionResult.availableProfiles.first

        let account = StoredAccount(
            kind: .yggdrasil,
            displayName: profile?.name ?? username,
            playerName: profile?.name ?? username,
            apiRoot: apiRoot.absoluteString,
            serverName: metadata.serverName,
            selectedProfile: profile,
            availableProfiles: sessionResult.availableProfiles,
            lastLoginAt: Date()
        )

        try await repository.upsert(
            account,
            secrets: AccountSecrets(
                accessToken: sessionResult.accessToken,
                clientToken: sessionResult.clientToken
            )
        )
        metadataCache[apiRoot.absoluteString] = metadata
        return account
    }

    public func selectProfile(_ profile: YggdrasilProfile, for accountID: UUID) async throws {
        guard var account = await repository.account(id: accountID),
              let apiRootString = account.apiRoot,
              let apiRoot = URL(string: apiRootString),
              let secrets = try await repository.secrets(for: accountID)
        else {
            throw YggdrasilAccountError.missingSecrets
        }

        let client = YggdrasilClient(apiRoot: apiRoot, session: session)
        // 切换角色需要用新角色刷新令牌
        let refreshed = try await client.refresh(
            accessToken: secrets.accessToken,
            clientToken: secrets.clientToken,
            selectedProfile: profile
        )

        account.selectedProfile = profile
        account.playerName = profile.name
        account.displayName = profile.name
        account.lastLoginAt = Date()
        try await repository.upsert(
            account,
            secrets: AccountSecrets(
                accessToken: refreshed.accessToken,
                clientToken: refreshed.clientToken.isEmpty ? secrets.clientToken : refreshed.clientToken
            )
        )
    }

    public func makeSession(for account: StoredAccount) async throws -> MinecraftSession {
        guard account.kind == .yggdrasil else {
            throw YggdrasilAccountError.notAYggdrasilAccount
        }
        guard let apiRootString = account.apiRoot, let apiRoot = URL(string: apiRootString) else {
            throw YggdrasilAccountError.missingSecrets
        }
        guard let profile = account.selectedProfile else {
            throw YggdrasilAccountError.noProfileSelected
        }
        guard let secrets = try await repository.secrets(for: account.id) else {
            throw YggdrasilAccountError.missingSecrets
        }

        let client = YggdrasilClient(apiRoot: apiRoot, session: session)
        let accessToken: String
        let clientToken = secrets.clientToken

        if try await client.validate(accessToken: secrets.accessToken, clientToken: clientToken) {
            accessToken = secrets.accessToken
        } else {
            do {
                let refreshed = try await client.refresh(
                    accessToken: secrets.accessToken,
                    clientToken: clientToken,
                    selectedProfile: profile
                )
                accessToken = refreshed.accessToken
                try await repository.upsert(
                    account,
                    secrets: AccountSecrets(
                        accessToken: refreshed.accessToken,
                        clientToken: refreshed.clientToken.isEmpty ? clientToken : refreshed.clientToken
                    )
                )
            } catch {
                throw YggdrasilAccountError.needsReauthentication(reason: error.localizedDescription)
            }
        }

        let injector = try await ensureInjector()
        let metadata = try await metadata(for: apiRoot)

        return MinecraftSession(
            uuid: profile.id,
            playerName: profile.name,
            accessToken: accessToken,
            // 外置登录也使用 mojang 这个协议值
            userType: "mojang",
            xuid: "",
            clientID: "",
            userProperties: "{}",
            extraJVMArguments: injector.jvmArguments(apiRoot: apiRoot, metadata: metadata)
        )
    }

    public func metadata(for apiRoot: URL) async throws -> YggdrasilMetadata {
        if let cached = metadataCache[apiRoot.absoluteString] { return cached }
        let metadata = try await YggdrasilClient(apiRoot: apiRoot, session: session).metadata()
        metadataCache[apiRoot.absoluteString] = metadata
        return metadata
    }

    private func ensureInjector() async throws -> AuthlibInjector {
        if let injector { return injector }
        do {
            let prepared = try await AuthlibInjector.prepare(
                at: injectorDirectory,
                session: session
            )
            injector = prepared
            return prepared
        } catch {
            throw YggdrasilAccountError.injectorUnavailable(reason: error.localizedDescription)
        }
    }
}
