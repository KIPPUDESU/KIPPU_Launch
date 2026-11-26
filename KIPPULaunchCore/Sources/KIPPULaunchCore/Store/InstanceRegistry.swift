import Foundation

public enum PathRelation: Sendable, Equatable {
    case same
    case descendant
    case ancestor
    case unrelated
}

public enum PathRelationKit {
    public static func relation(between lhs: String, and rhs: String) -> PathRelation {
        let left = URL(fileURLWithPath: PathNormalization.normalized(path: lhs)).pathComponents
        let right = URL(fileURLWithPath: PathNormalization.normalized(path: rhs)).pathComponents

        if left == right { return .same }
        let (shorter, longer) = left.count < right.count ? (left, right) : (right, left)
        guard longer.starts(with: shorter) else { return .unrelated }
        return left.count > right.count ? .descendant : .ancestor
    }

    public static func isDescendant(_ child: String, of ancestor: String) -> Bool {
        relation(between: child, and: ancestor) == .descendant
    }

    /// 用户有时会直接选中实例目录 此时相等也算在根目录内
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        switch relation(between: path, and: root) {
        case .same, .descendant: true
        case .ancestor, .unrelated: false
        }
    }
}

public enum RegistryViolation: Error, Equatable, Sendable {
    case notADirectory(path: String)
    case rootAlreadyRegistered(path: String)
    case rootNestedInsideExisting(newRoot: String, existingRoot: String)
    case rootContainsExistingRoot(newRoot: String, existingRoot: String)
    case managedInstanceOutsideOwnedRoot(instance: String)
    case referencedInstanceOutsideRegisteredRoot(instance: String)
}

public struct RejectedInstance: Sendable, Equatable {
    public let name: String
    public let reason: String
}

public struct InsertSummary: Sendable, Equatable {
    public var inserted: [InstanceRecord] = []
    public var alreadyKnown: [InstanceRecord] = []
    public var rejected: [RejectedInstance] = []

    public var didChangeAnything: Bool { !inserted.isEmpty }
}

public struct InstanceRegistry: Sendable {
    public private(set) var document: RegistryDocument

    public init(document: RegistryDocument = RegistryDocument()) {
        self.document = document
    }

    public func violationForRoot(at path: String, fileManager: FileManager = .default) -> RegistryViolation? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notADirectory(path: path)
        }

        let candidate = PathIdentity(of: URL(fileURLWithPath: path))

        for existing in document.roots {
            if existing.identityCanonical == candidate.canonical {
                return .rootAlreadyRegistered(path: existing.path)
            }
            switch PathRelationKit.relation(between: path, and: existing.path) {
            case .same, .descendant:
                return .rootNestedInsideExisting(newRoot: path, existingRoot: existing.path)
            case .ancestor:
                return .rootContainsExistingRoot(newRoot: path, existingRoot: existing.path)
            case .unrelated:
                continue
            }
        }
        return nil
    }

    @discardableResult
    public mutating func addRoot(
        at path: String,
        isLauncherOwned: Bool,
        fileManager: FileManager = .default
    ) throws -> RegisteredRoot {
        if let violation = violationForRoot(at: path, fileManager: fileManager) {
            throw violation
        }
        let root = RegisteredRoot(
            path: PathNormalization.normalized(path: path),
            identityCanonical: PathIdentity(of: URL(fileURLWithPath: path)).canonical,
            isLauncherOwned: isLauncherOwned
        )
        document.roots.append(root)
        return root
    }

    /// 移除根目录后已登记的实例仍然保留
    public mutating func removeRoot(id: UUID) {
        document.roots.removeAll { $0.id == id }
    }

    public func instance(identityCanonical: String) -> InstanceRecord? {
        document.instances.first { $0.identityCanonical == identityCanonical }
    }

    public func contains(identity: PathIdentity) -> Bool {
        instance(identityCanonical: identity.canonical) != nil
    }

    @discardableResult
    public mutating func insert(_ candidates: [InstanceRecord]) -> InsertSummary {
        var summary = InsertSummary()

        for candidate in candidates {
            if document.instances.contains(where: { $0.identityCanonical == candidate.identityCanonical }) {
                summary.alreadyKnown.append(candidate)
                continue
            }

            switch candidate.kind {
            case .managed:
                guard document.roots.contains(where: { $0.isLauncherOwned && PathRelationKit.isWithin(candidate.path, $0.path) }) else {
                    summary.rejected.append(
                        RejectedInstance(
                            name: candidate.name,
                            reason: "自建实例必须位于启动器自己的根目录内，否则会被其它启动器扫走并合并。"
                        )
                    )
                    continue
                }
            case .referenced:
                guard document.roots.contains(where: { PathRelationKit.isWithin(candidate.path, $0.path) }) else {
                    summary.rejected.append(
                        RejectedInstance(name: candidate.name, reason: "该实例不在任何已注册的根目录内。")
                    )
                    continue
                }
            }

            document.instances.append(candidate)
            summary.inserted.append(candidate)
        }

        return summary
    }

    /// 卷可能只是没挂载 本轮没扫到的实例保留记录
    public mutating func refresh(root: RegisteredRoot, with located: [InstanceRecord]) {
        var locatedByIdentity = Dictionary(located.map { ($0.identityCanonical, $0) }, uniquingKeysWith: { first, _ in first })

        for index in document.instances.indices {
            let record = document.instances[index]
            guard PathRelationKit.isWithin(record.path, root.path) else { continue }

            guard let fresh = locatedByIdentity.removeValue(forKey: record.identityCanonical) else {
                document.instances[index].isMissing = true
                continue
            }

            document.instances[index].isMissing = false
            document.instances[index].requiredJavaMajorVersion = fresh.requiredJavaMajorVersion
            document.instances[index].requiredJavaComponent = fresh.requiredJavaComponent
            document.instances[index].minecraftVersion = fresh.minecraftVersion ?? record.minecraftVersion
            if fresh.loader != .unknown { document.instances[index].loader = fresh.loader }
            document.instances[index].loaderVersion = fresh.loaderVersion ?? record.loaderVersion
            document.instances[index].packName = fresh.packName ?? record.packName
            document.instances[index].packVersionId = fresh.packVersionId ?? record.packVersionId
        }

        insert(Array(locatedByIdentity.values))
    }

    /// 仅移除清单记录 游戏文件仍在原处
    public mutating func removeInstance(id: UUID) {
        removeInstances(ids: [id])
    }

    /// 仅移除指定标识的记录并保留磁盘文件
    public mutating func removeInstances(ids: Set<UUID>) {
        document.instances.removeAll { ids.contains($0.id) }
    }

    public mutating func configure(id: UUID, memoryMB: Int?, javaPath: String?) {
        guard let index = document.instances.firstIndex(where: { $0.id == id }) else { return }
        document.instances[index].memoryMB = memoryMB
        document.instances[index].selectedJavaPath = javaPath
    }

    public mutating func markLaunched(id: UUID, at date: Date = Date()) {
        guard let index = document.instances.firstIndex(where: { $0.id == id }) else { return }
        document.instances[index].lastLaunchedAt = date
    }

    public mutating func rename(id: UUID, to newName: String) {
        guard let index = document.instances.firstIndex(where: { $0.id == id }) else { return }
        document.instances[index].name = newName
    }

    /// 同名实例按路径编号 重扫后仍使用相同的后缀
    public func displayNames() -> [UUID: String] {
        var result: [UUID: String] = [:]
        let grouped = Dictionary(grouping: document.instances, by: \.displayName)

        for (baseName, records) in grouped where records.count > 1 {
            let ordered = records.sorted { $0.path < $1.path }
            for (offset, record) in ordered.enumerated() where offset > 0 {
                result[record.id] = "\(baseName) (\(offset + 1))"
            }
        }
        return result
    }

    public var instancesByRecency: [InstanceRecord] {
        document.instances.sorted { lhs, rhs in
            switch (lhs.lastLaunchedAt, rhs.lastLaunchedAt) {
            case let (leftDate?, rightDate?): leftDate > rightDate
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): lhs.displayName < rhs.displayName
            }
        }
    }
}
