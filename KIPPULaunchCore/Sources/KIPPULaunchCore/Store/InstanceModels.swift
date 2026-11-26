import Foundation

public enum LoaderKind: String, Sendable, Codable, CaseIterable {
    case vanilla
    case fabric
    case quilt
    case forge
    case neoforge
    case unknown

    public var displayName: String {
        switch self {
        case .vanilla: "原版"
        case .fabric: "Fabric"
        case .quilt: "Quilt"
        case .forge: "Forge"
        case .neoforge: "NeoForge"
        case .unknown: "未知"
        }
    }
}

/// 外部实例导入时只读 修改模组需要单独授权
public enum InstanceKind: String, Sendable, Codable {
    case managed
    case referenced

    public var isWritable: Bool { self == .managed }
}

public struct InstanceRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    /// 展示名称不参与身份判定
    public var name: String
    public var identityCanonical: String
    /// 启动游戏时以此目录为工作目录
    public var path: String
    public var kind: InstanceKind
    public var versionIdentifier: String
    public var requiredJavaMajorVersion: Int?
    public var requiredJavaComponent: String?

    public var minecraftVersion: String?
    public var loader: LoaderKind
    public var loaderVersion: String?
    public var packName: String?
    public var packVersionId: String?

    public var memoryMB: Int?
    public var javaPath: String?
    /// 这里只存用户在本启动器里选的 Java 导入的路径可能来自另一台机器
    public var selectedJavaPath: String?

    public var addedAt: Date
    public var lastLaunchedAt: Date?
    public var isMissing: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        identityCanonical: String,
        path: String,
        kind: InstanceKind,
        versionIdentifier: String,
        requiredJavaMajorVersion: Int? = nil,
        requiredJavaComponent: String? = nil,
        minecraftVersion: String? = nil,
        loader: LoaderKind = .unknown,
        loaderVersion: String? = nil,
        packName: String? = nil,
        packVersionId: String? = nil,
        memoryMB: Int? = nil,
        javaPath: String? = nil,
        addedAt: Date = Date(),
        lastLaunchedAt: Date? = nil,
        isMissing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.identityCanonical = identityCanonical
        self.path = path
        self.kind = kind
        self.versionIdentifier = versionIdentifier
        self.requiredJavaMajorVersion = requiredJavaMajorVersion
        self.requiredJavaComponent = requiredJavaComponent
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
        self.packName = packName
        self.packVersionId = packVersionId
        self.memoryMB = memoryMB
        self.javaPath = javaPath
        self.addedAt = addedAt
        self.lastLaunchedAt = lastLaunchedAt
        self.isMissing = isMissing
    }

    public var displayName: String { name }
}

public struct RegisteredRoot: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var identityCanonical: String
    public var isLauncherOwned: Bool
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        path: String,
        identityCanonical: String,
        isLauncherOwned: Bool,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.identityCanonical = identityCanonical
        self.isLauncherOwned = isLauncherOwned
        self.addedAt = addedAt
    }
}

public struct RegistryDocument: Sendable, Codable {
    public var schemaVersion: Int
    public var roots: [RegisteredRoot]
    public var instances: [InstanceRecord]

    public init(schemaVersion: Int = RegistryDocument.currentSchemaVersion, roots: [RegisteredRoot] = [], instances: [InstanceRecord] = []) {
        self.schemaVersion = schemaVersion
        self.roots = roots
        self.instances = instances
    }

    public static let currentSchemaVersion = 1
}

public struct InstanceEnrichment: Sendable, Hashable {
    public var minecraftVersion: String?
    public var loader: LoaderKind
    public var loaderVersion: String?
    public var packName: String?
    public var packVersionId: String?
    public var memoryMB: Int?
    public var javaPath: String?

    public init(
        minecraftVersion: String? = nil,
        loader: LoaderKind = .unknown,
        loaderVersion: String? = nil,
        packName: String? = nil,
        packVersionId: String? = nil,
        memoryMB: Int? = nil,
        javaPath: String? = nil
    ) {
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
        self.packName = packName
        self.packVersionId = packVersionId
        self.memoryMB = memoryMB
        self.javaPath = javaPath
    }
}
