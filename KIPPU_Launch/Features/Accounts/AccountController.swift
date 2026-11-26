import Foundation
import KIPPULaunchCore
import Observation

@MainActor
@Observable
final class AccountController {
    private(set) var accounts: [StoredAccount] = []
    private(set) var activeAccountID: UUID?
    private(set) var isSigningIn = false
    private(set) var isLoaded = false

    var problem: String?

    private(set) var skinHeads: [UUID: SkinHead] = [:]

    private let repository: AccountRepository
    @ObservationIgnored private lazy var service = YggdrasilAccountService(
        repository: repository,
        injectorDirectory: baseURL.appending(path: "authlib-injector", directoryHint: .isDirectory)
    )
    @ObservationIgnored private lazy var skinRepository = SkinRepository(
        cacheDirectory: baseURL.appending(path: "cache", directoryHint: .isDirectory)
    )
    private let baseURL: URL

    init() {
        let resolvedBase: URL
        if let paths = try? AppPaths.standard(create: true) {
            resolvedBase = paths.baseURL
        } else {
            resolvedBase = FileManager.default.temporaryDirectory
                .appending(path: "KIPPU_Launch-fallback", directoryHint: .isDirectory)
        }
        baseURL = resolvedBase

        repository = AccountRepository(recordsFileURL: resolvedBase.appending(path: "accounts.json"))
    }

    func skinHead(for account: StoredAccount?) -> SkinHead? {
        guard let account else { return nil }
        return skinHeads[account.id]
    }

    func ensureSkinLoaded(for account: StoredAccount?) async {
        guard let account, account.kind == .yggdrasil,
              skinHeads[account.id] == nil,
              let profile = account.selectedProfile,
              let apiRootString = account.apiRoot,
              let apiRoot = URL(string: apiRootString)
        else { return }

        let head = try? await skinRepository.headImage(apiRoot: apiRoot, profileID: profile.id)
        if let head {
            skinHeads[account.id] = head
        }
    }

    var activeAccount: StoredAccount? {
        guard let id = activeAccountID else { return nil }
        return accounts.first { $0.id == id }
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            try await repository.load()
            accounts = await repository.accounts
            activeAccountID = await repository.activeAccount?.id
            isLoaded = true
        } catch {
            problem = error.localizedDescription
        }
    }

    func signIn(server: String, username: String, password: String) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        problem = nil
        defer { isSigningIn = false }

        do {
            _ = try await service.signIn(
                userInput: server,
                username: username,
                password: password
            )
            await refreshFromRepository()
        } catch {
            problem = error.localizedDescription
        }
    }

    var microsoftClientID: String {
        get {
            let candidates = [UserDefaults.standard.string(forKey: "microsoftClientID"),
                              Bundle.main.object(forInfoDictionaryKey: "MinecraftMicrosoftClientID") as? String]
            return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { UUID(uuidString: $0) != nil } ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: "microsoftClientID") }
    }
    private(set) var deviceCode: MicrosoftLogin.Code?

    func microsoftSignIn(clientID: String) async -> Bool {
        guard !isSigningIn else { return false }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else {
            problem = "请输入启动器的应用程序（客户端）ID。"
            return false
        }
        problem = nil
        isSigningIn = true
        defer {
            deviceCode = nil
            isSigningIn = false
        }
        do {
            let login = MicrosoftLogin(clientID: id)
            let code = try await login.begin()
            try Task.checkCancellation()
            deviceCode = code
            let tokens = try await login.authorize(code)
            let session = try await login.gameSession(tokens)
            try Task.checkCancellation()
            guard let refresh = tokens.refresh_token else { throw MicrosoftAccountError.signInAgain }
            let existing = accounts.first { $0.kind == .microsoft && $0.selectedProfile?.id == session.uuid }
            var account = StoredAccount(id: existing?.id ?? UUID(), kind: .microsoft, displayName: session.playerName,
                playerName: session.playerName, selectedProfile: YggdrasilProfile(id: session.uuid, name: session.playerName), lastLoginAt: Date())
            account.microsoftClientID = id
            var secrets = AccountSecrets(accessToken: "", clientToken: "")
            secrets.microsoftRefreshToken = refresh
            try await repository.upsert(account, secrets: secrets)
            try await repository.setActive(account.id)
            microsoftClientID = id
            await refreshFromRepository()
            return true
        } catch {
            if !Task.isCancelled {
                problem = error.localizedDescription
            }
            return false
        }
    }

    private enum MicrosoftAccountError: LocalizedError {
        case signInAgain
        var errorDescription: String? { "Microsoft 登录已失效，请重新授权。" }
    }
    private var microsoftSessions: [UUID: Task<MinecraftSession, Error>] = [:]

    private func microsoftSession(for account: StoredAccount) async throws -> MinecraftSession {
        if let pending = microsoftSessions[account.id] { return try await pending.value }
        let job = Task {
            guard let clientID = account.microsoftClientID, var secrets = try await repository.secrets(for: account.id),
                  let refresh = secrets.microsoftRefreshToken else { throw MicrosoftAccountError.signInAgain }
            let login = MicrosoftLogin(clientID: clientID)
            let tokens = try await login.refresh(refresh)
            if let rotated = tokens.refresh_token {
                secrets.microsoftRefreshToken = rotated
                try await repository.updateSecrets(secrets, for: account.id)
            }
            return try await login.gameSession(tokens)
        }
        microsoftSessions[account.id] = job
        defer { microsoftSessions[account.id] = nil }
        return try await job.value
    }

    func setActive(_ account: StoredAccount) async {
        do {
            try await repository.setActive(account.id)
            activeAccountID = account.id
        } catch {
            problem = error.localizedDescription
        }
    }

    func addOfflineAccount(playerName: String) async {
        let trimmed = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = "玩家名不能为空。"
            return
        }
        do {
            try await repository.upsert(
                StoredAccount(kind: .offline, displayName: trimmed, playerName: trimmed),
                secrets: nil
            )
            await refreshFromRepository()
        } catch {
            problem = error.localizedDescription
        }
    }

    func remove(_ account: StoredAccount) async {
        do {
            try await repository.remove(id: account.id)
            await refreshFromRepository()
        } catch {
            problem = error.localizedDescription
        }
    }

    func selectProfile(_ profile: YggdrasilProfile, for account: StoredAccount) async {
        do {
            try await service.selectProfile(profile, for: account.id)
            await refreshFromRepository()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func refreshFromRepository() async {
        accounts = await repository.accounts
        activeAccountID = await repository.activeAccount?.id
    }

    func sessionForActiveAccount() async throws -> MinecraftSession? {
        guard let account = activeAccount else { return nil }

        switch account.kind {
        case .microsoft: return try await microsoftSession(for: account)
        case .offline:
            return MinecraftSession(
                uuid: OfflineUUID.forPlayerName(account.playerName),
                playerName: account.playerName,
                accessToken: "0",
                userType: "legacy"
            )
        case .yggdrasil:
            do {
                let session = try await service.makeSession(for: account)
                return session
            } catch let error as YggdrasilAccountError {
                if case .needsReauthentication = error {
                    problem = "「\(account.displayName)」的登录状态已失效，请重新登录。"
                }
                throw error
            }
        }
    }
}
