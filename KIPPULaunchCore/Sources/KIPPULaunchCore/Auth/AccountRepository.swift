import Foundation

public struct StoredAccount: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case microsoft
        case offline
        case yggdrasil
    }

    public var id: UUID
    public var kind: Kind
    public var displayName: String
    public var playerName: String

    public var apiRoot: String?
    public var serverName: String?
    public var selectedProfile: YggdrasilProfile?
    public var availableProfiles: [YggdrasilProfile]

    public var microsoftClientID: String?
    public var lastLoginAt: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        playerName: String,
        apiRoot: String? = nil,
        serverName: String? = nil,
        selectedProfile: YggdrasilProfile? = nil,
        availableProfiles: [YggdrasilProfile] = [],
        lastLoginAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.playerName = playerName
        self.apiRoot = apiRoot
        self.serverName = serverName
        self.selectedProfile = selectedProfile
        self.availableProfiles = availableProfiles
        self.lastLoginAt = lastLoginAt
    }

    public var detailLine: String? {
        switch kind {
        case .microsoft: return "Microsoft · Minecraft Java 版"
        case .offline:
            return "离线账户"
        case .yggdrasil:
            let server = serverName ?? apiRoot ?? "外置登录"
            if let profile = selectedProfile, profile.name != displayName {
                return "\(server) · \(profile.name)"
            }
            return server
        }
    }
}

public struct AccountDocument: Sendable, Codable {
    public var schemaVersion: Int
    public var accounts: [StoredAccount]
    public var activeAccountID: UUID?

    public init(schemaVersion: Int = 1, accounts: [StoredAccount] = [], activeAccountID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }
}

public actor AccountRepository {
    private let recordsFileURL: URL
    private let tokenStore: TokenStore
    private var document: AccountDocument

    public init(recordsFileURL: URL, tokenStore: TokenStore = TokenStore()) {
        self.recordsFileURL = recordsFileURL
        self.tokenStore = tokenStore
        self.document = AccountDocument()
    }

    public func load(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: recordsFileURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: recordsFileURL),
              let decoded = try? JSONDecoder().decode(AccountDocument.self, from: data)
        else {
            document = AccountDocument()
            return
        }
        document = decoded
    }

    private func persist(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: recordsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: recordsFileURL, options: .atomic)
    }

    public var accounts: [StoredAccount] { document.accounts }

    public var activeAccount: StoredAccount? {
        guard let id = document.activeAccountID else { return nil }
        return document.accounts.first { $0.id == id }
    }

    public func account(id: UUID) -> StoredAccount? {
        document.accounts.first { $0.id == id }
    }

    public func secrets(for id: UUID) async throws -> AccountSecrets? {
        try await tokenStore.secrets(for: id)
    }

    public func updateSecrets(_ secrets: AccountSecrets, for id: UUID) async throws {
        guard account(id: id) != nil else { throw CocoaError(.fileNoSuchFile) }
        try await tokenStore.save(secrets, for: id)
    }

    public func setActive(_ id: UUID?) throws {
        document.activeAccountID = id
        try persist()
    }

    /// secrets 为 nil 时保留钥匙串中的令牌
    public func upsert(_ account: StoredAccount, secrets: AccountSecrets?) async throws {
        if let index = document.accounts.firstIndex(where: { $0.id == account.id }) {
            document.accounts[index] = account
        } else {
            document.accounts.append(account)
        }

        if let secrets {
            try await tokenStore.save(secrets, for: account.id)
        }
        try persist()

        if document.activeAccountID == nil {
            document.activeAccountID = account.id
            try persist()
        }
    }

    public func remove(id: UUID) async throws {
        document.accounts.removeAll { $0.id == id }
        if document.activeAccountID == id {
            document.activeAccountID = document.accounts.first?.id
        }
        try? await tokenStore.delete(for: id)
        try persist()
    }
}
