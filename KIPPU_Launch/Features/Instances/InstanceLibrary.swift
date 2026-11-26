import Foundation
import Observation
import KIPPULaunchCore

@MainActor
@Observable
final class InstanceLibrary {
    private(set) var instances: [InstanceRecord] = []
    private(set) var displayNameOverrides: [UUID: String] = [:]
    private(set) var roots: [RegisteredRoot] = []
    private(set) var discoveredRoots: [DiscoveredRoot] = []
    var problem: String?
    private(set) var lastSkippedCount: Int = 0

    private var registry = InstanceRegistry()
    private let fileStore: RegistryFileStore
    private let scanner = InstanceScanner()
    private let fileManager = FileManager.default

    private let managedRootURL: URL
    private let didRemoveInstances: (Set<UUID>) -> Void

    init(didRemoveInstances: @escaping (Set<UUID>) -> Void = { _ in }) {
        self.didRemoveInstances = didRemoveInstances
        do {
            let paths = try AppPaths.standard(create: true)
            fileStore = RegistryFileStore(paths: paths)
            managedRootURL = paths.managedInstances
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appending(path: "KIPPU_Launch-fallback", directoryHint: .isDirectory)
            fileStore = RegistryFileStore(fileURL: fallback.appending(path: "instances.json"))
            managedRootURL = fallback.appending(path: "instances", directoryHint: .isDirectory)
            problem = "无法定位应用支持目录，正在使用临时位置：\(error.localizedDescription)"
        }
    }

    func load() {
        do {
            registry = InstanceRegistry(document: try fileStore.load())
        } catch {
            registry = InstanceRegistry()
            problem = error.localizedDescription
        }

        ensureManagedRootExists()
        discoverExistingInstances()
        publish()
    }

    private func ensureManagedRootExists() {
        let path = PathNormalization.normalized(managedRootURL)
        guard registry.violationForRoot(at: path, fileManager: fileManager) == nil else { return }
        do {
            try fileManager.createDirectory(at: managedRootURL, withIntermediateDirectories: true)
            _ = try registry.addRoot(at: path, isLauncherOwned: true, fileManager: fileManager)
            try fileStore.save(registry.document, fileManager: fileManager)
        } catch {
            problem = "无法建立启动器自己的实例目录：\(error.localizedDescription)"
        }
    }

    private func discoverExistingInstances() {
        let candidate = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/minecraft/versions", directoryHint: .isDirectory)

        guard fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            discoveredRoots = []
            return
        }

        let path = PathNormalization.normalized(candidate)
        guard registry.violationForRoot(at: path, fileManager: fileManager) == nil else {
            discoveredRoots = []
            return
        }

        // 确认导入前只统计候选实例数量
        let count = scanner.locator.scanForRegistration(at: candidate, fileManager: fileManager).versions.count
        discoveredRoots = count == 0
            ? []
            : [DiscoveredRoot(path: path, instanceCount: count, suggestion: "检测到已有的 Minecraft 实例")]
    }

    func importDiscoveredRoot(_ discovered: DiscoveredRoot) async {
        await addRoot(at: URL(fileURLWithPath: discovered.path), isLauncherOwned: false)
    }

    func addRoot(at url: URL, isLauncherOwned: Bool) async {
        let path = PathNormalization.normalized(url)

        if let violation = registry.violationForRoot(at: path, fileManager: fileManager) {
            problem = Self.describe(violation)
            return
        }

        let scanner = self.scanner
        let outcome = await Task.detached {
            scanner.recordsForRegistration(at: url, isLauncherOwned: isLauncherOwned)
        }.value

        guard !outcome.records.isEmpty else {
            problem = "「\(url.lastPathComponent)」下没有找到任何 Minecraft 版本。"
            return
        }

        do {
            _ = try registry.addRoot(at: path, isLauncherOwned: isLauncherOwned, fileManager: fileManager)
            let summary = registry.insert(outcome.records)
            try fileStore.save(registry.document, fileManager: fileManager)

            lastSkippedCount = outcome.rejected.count
            if let rejected = summary.rejected.first {
                problem = "部分实例未加入：\(rejected.reason)"
            }
            discoveredRoots.removeAll { $0.path == path }
            publish()
        } catch {
            problem = error.localizedDescription
        }
    }

    func refresh() async {
        let scanner = self.scanner
        let roots = self.registry.document.roots

        let located = await Task.detached {
            roots.map { scanner.records(inRoot: $0) }
        }.value

        for (index, root) in roots.enumerated() {
            registry.refresh(root: root, with: located[index].records)
        }

        do {
            try fileStore.save(registry.document, fileManager: fileManager)
        } catch {
            problem = error.localizedDescription
        }
        publish()
    }

    func removeInstance(_ instance: InstanceRecord) {
        removeInstances(ids: [instance.id])
    }

    @discardableResult
    func removeInstances(ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var updated = registry
        updated.removeInstances(ids: ids)
        do {
            try fileStore.save(updated.document, fileManager: fileManager)
            registry = updated
            publish()
            didRemoveInstances(ids)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func markLaunched(_ id: UUID) {
        registry.markLaunched(id: id)
        persistAndPublish()
    }

    func configure(_ id: UUID, memoryMB: Int?, javaPath: String?) throws {
        var updated = registry
        updated.configure(id: id, memoryMB: memoryMB, javaPath: javaPath)
        try fileStore.save(updated.document)
        registry = updated
        publish()
    }

    func registerInstalled(_ url: URL) throws {
        let result = scanner.recordsForRegistration(at: url, isLauncherOwned: true)
        guard let record = result.records.first(where: { $0.path == PathNormalization.normalized(url) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var updated = registry
        let summary = updated.insert([record])
        if let rejection = summary.rejected.first { throw InstallError.message(rejection.reason) }
        try fileStore.save(updated.document)
        registry = updated
        publish()
    }

    func removeRoot(_ root: RegisteredRoot) {
        registry.removeRoot(id: root.id)
        persistAndPublish()
    }

    func rename(_ instance: InstanceRecord, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        registry.rename(id: instance.id, to: trimmed)
        persistAndPublish()
    }

    func displayName(for instance: InstanceRecord) -> String {
        displayNameOverrides[instance.id] ?? instance.displayName
    }

    private func persistAndPublish() {
        do {
            try fileStore.save(registry.document, fileManager: fileManager)
        } catch {
            problem = error.localizedDescription
        }
        publish()
    }

    private func publish() {
        instances = registry.instancesByRecency
        displayNameOverrides = registry.displayNames()
        roots = registry.document.roots
    }

    static func describe(_ violation: RegistryViolation) -> String {
        switch violation {
        case let .notADirectory(path):
            "「\(URL(fileURLWithPath: path).lastPathComponent)」不是目录。"
        case let .rootAlreadyRegistered(path):
            "该目录已经添加过了：\(path)"
        case let .rootNestedInsideExisting(_, existingRoot):
            "该目录在已添加的「\(URL(fileURLWithPath: existingRoot).lastPathComponent)」之内，会导致里面的实例被重复收录。"
        case let .rootContainsExistingRoot(_, existingRoot):
            "该目录包含了已添加的「\(URL(fileURLWithPath: existingRoot).lastPathComponent)」，会导致同一批实例出现两遍。"
        case let .managedInstanceOutsideOwnedRoot(instance):
            "启动器自建的实例必须放在它自己的目录下，否则会被其它启动器扫走并合并：\(instance)"
        case let .referencedInstanceOutsideRegisteredRoot(instance):
            "该实例不在任何已添加的目录内：\(instance)"
        }
    }
}
