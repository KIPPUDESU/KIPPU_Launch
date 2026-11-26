import CryptoKit
import Foundation

struct ModFingerprint: Codable, Equatable, Sendable {
    let filename: String
    let sha512: String

    init(filename: String, at file: URL) throws {
        self.filename = filename
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw InstallError.message("「\(filename)」不是普通模组文件。")
        }
        sha512 = try InstallNetwork.digest(of: file, using: SHA512.self)
    }
}

public struct ModUpdateCheck: Sendable {
    public let updates: [String: ModRelease]
    public let unknownCount: Int
    let files: [String: ModFingerprint]
    let known: [String: ModRelease]
    let target: ModTarget

    public func currentVersion(of mod: LocalMod) -> String {
        known[mod.filename]?.version_number ?? mod.version ?? mod.filename
    }
}

public struct ModUpdatePlan: Sendable, Identifiable {
    public struct Change: Sendable, Identifiable {
        let before: ModFingerprint?
        let release: ModRelease
        public let filename: String
        public var previousFilename: String? { before?.filename }
        public var id: String { filename }
    }
    public let id = UUID()
    public let name: String
    public let changes: [Change]
    public let pinnedDependents: [String]
    let unchanged: [ModFingerprint]
}

extension ModCatalog {
    func check(files: [ModFingerprint], target: ModTarget) async throws -> ModUpdateCheck {
        struct Request: Encodable {
            let hashes: [String]
            let algorithm = "sha512"
            var loaders: [String]?
            var game_versions: [String]?
        }
        let hashes = Array(Set(files.map(\.sha512)))
        var current: [String: ModRelease] = [:]
        var latest: [String: ModRelease] = [:]
        for start in stride(from: 0, to: hashes.count, by: 100) {
            try Task.checkCancellation()
            var request = Request(hashes: Array(hashes[start..<min(start + 100, hashes.count)]))
            let matches = try await api("version_files", body: JSONEncoder().encode(request), as: [String: ModRelease].self)
            current.merge(matches) { first, _ in first }
            guard !matches.isEmpty else { continue }
            request.loaders = [target.loader.rawValue]
            request.game_versions = [target.game]
            let versions = try await api("version_files/update", body: JSONEncoder().encode(request), as: [String: ModRelease].self)
            latest.merge(versions) { first, _ in first }
        }

        var known: [String: ModRelease] = [:]
        var updates: [String: ModRelease] = [:]
        let date = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for file in files {
            guard let installedRelease = current[file.sha512], installedRelease.files.contains(where: { $0.hashes["sha512"] == file.sha512 }) else { continue }
            known[file.filename] = installedRelease
            guard let availableRelease = latest[file.sha512], availableRelease.project_id == installedRelease.project_id, availableRelease.id != installedRelease.id,
                  availableRelease.jar?.hashes["sha512"] != file.sha512, availableRelease.supports(target),
                  let installedDate = try? date.parse(installedRelease.date_published), let availableDate = try? date.parse(availableRelease.date_published),
                  availableDate > installedDate else { continue }
            updates[file.filename] = availableRelease
        }
        return ModUpdateCheck(updates: updates, unknownCount: files.count - known.count,
                              files: Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0) }), known: known, target: target)
    }

    public func updatePlan(for mod: LocalMod, check: ModUpdateCheck) async throws -> ModUpdatePlan {
        guard let root = check.updates[mod.filename] else { throw InstallError.message("请重新检查更新。") }
        let groups = Dictionary(grouping: check.known, by: { $0.value.project_id })
        var installed: [String: ModRelease] = [:]
        for (project, entries) in groups where entries.count == 1 {
            installed[project] = entries[0].value
        }
        let releases = try await installationPlan(root, target: check.target, installed: installed)
        var changes: [ModUpdatePlan.Change] = []
        var unchanged: [ModFingerprint] = []
        for release in releases {
            let entries = groups[release.project_id] ?? []
            guard entries.count <= 1, let jar = release.jar else { throw InstallError.message("同一项目有多个本地版本，请先整理后再更新。") }
            let before = entries.first.flatMap { check.files[$0.key] }
            let disabled = before.map { $0.filename.lowercased().hasSuffix(".disabled") } ?? !mod.enabled
            if mod.enabled, disabled, let before { throw InstallError.message("请先启用必需依赖「\(before.filename)」。") }
            if let before, check.known[before.filename]?.id == release.id {
                unchanged.append(before)
                continue
            }
            let filename = disabled ? jar.filename + ".disabled" : jar.filename
            changes.append(.init(before: before, release: release, filename: filename))
        }
        let replaced = Set(changes.compactMap(\.previousFilename))
        let oldVersions = Set(replaced.compactMap { check.known[$0]?.id })
        let dependents = check.known.filter { name, release in
            !replaced.contains(name) && name.lowercased().hasSuffix(".jar") &&
                release.dependencies.contains { dependency in
                    dependency.dependency_type == "required" && dependency.version_id.map(oldVersions.contains) == true
                }
        }.keys.sorted()
        return ModUpdatePlan(name: mod.name, changes: changes, pinnedDependents: dependents, unchanged: unchanged)
    }
}

extension InstanceMods {
    public func checkUpdates(target: ModTarget, catalog: ModCatalog) async throws -> ModUpdateCheck {
        let files = try await list().map { try ModFingerprint(filename: $0.filename, at: source($0)) }
        return try await catalog.check(files: files, target: target)
    }
}
