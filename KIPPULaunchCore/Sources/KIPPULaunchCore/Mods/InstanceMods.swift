import Foundation
import ZIPFoundation

public struct LocalMod: Hashable, Sendable, Identifiable {
    public let filename: String
    public let name: String
    public let version: String?
    let modIDs: Set<String>
    public let enabled: Bool
    public var id: String { filename }

    static func read(_ url: URL, filename: String) throws -> LocalMod {
        let enabled = filename.lowercased().hasSuffix(".jar")
        let jar = enabled ? filename : String(filename.dropLast(".disabled".count))
        var names: [String] = []
        var ids = Set<String>()
        var version: String?
        if let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) {
            // ZIPFoundation 按路径取条目会从头遍历归档
            let descriptors = ModDescriptorIndex.present(in: url) ?? Set(ModDescriptorIndex.names)
            let iterator = archive.makeIterator()
            var descriptorsFound: [String: Entry] = [:]
            func data(_ path: String) throws -> Data? {
                guard descriptors.contains(path) else { return nil }
                if descriptorsFound[path] == nil {
                    while let entry = iterator.next() {
                        try Task.checkCancellation()
                        let name = entry.path
                        if descriptors.contains(name), descriptorsFound[name] == nil {
                            descriptorsFound[name] = entry
                            if name == path { break }
                        }
                    }
                }
                guard let entry = descriptorsFound[path], entry.type == .file, entry.uncompressedSize <= 524288 else { return nil }
                var result = Data()
                let crc = try? archive.extract(entry) { chunk in
                    guard result.count + chunk.count <= 524288 else { throw CocoaError(.fileReadTooLarge) }
                    result.append(chunk)
                }
                return crc == entry.checksum ? result : nil
            }
            func recordMod(id: String?, name: String?, version declaredVersion: String?) {
                if let id, !id.isEmpty { ids.insert(id.lowercased()) }
                if let name, !name.isEmpty { names.append(name) }
                if version == nil, let declaredVersion, !declaredVersion.contains("$") { version = declaredVersion }
            }
            if let bytes = try data("fabric.mod.json"), let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                recordMod(id: fields["id"] as? String, name: fields["name"] as? String, version: fields["version"] as? String)
            } else if let bytes = try data("quilt.mod.json"), let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      let fields = json["quilt_loader"] as? [String: Any] {
                recordMod(id: fields["id"] as? String, name: (fields["metadata"] as? [String: Any])?["name"] as? String, version: fields["version"] as? String)
            } else if let bytes = try data("META-INF/neoforge.mods.toml") ?? data("META-INF/mods.toml") {
                var inModSection = false
                var fields: [String: String] = [:]
                func finishModSection() {
                    if inModSection { recordMod(id: fields["modId"], name: fields["displayName"], version: fields["version"]) }
                    fields.removeAll()
                }
                for raw in String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") {
                        finishModSection()
                        inModSection = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces) == "[[mods]]"
                    } else if inModSection, let equals = line.firstIndex(of: "=") {
                        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                        guard ["modId", "displayName", "version"].contains(key) else { continue }
                        let literal = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                        guard let quote = literal.first, quote == "\"" || quote == "'",
                              let end = literal.dropFirst().firstIndex(of: quote) else { continue }
                        fields[key] = String(literal[literal.index(after: literal.startIndex)..<end])
                    }
                }
                finishModSection()
            } else if let bytes = try data("mcmod.info"), let raw = try? JSONSerialization.jsonObject(with: bytes) {
                let mods = raw as? [[String: Any]] ?? (raw as? [String: Any])?["modList"] as? [[String: Any]] ?? []
                for mod in mods { recordMod(id: mod["modid"] as? String, name: mod["name"] as? String, version: mod["version"] as? String) }
            }
        }
        return LocalMod(filename: filename, name: names.first ?? String(jar.dropLast(4)), version: version, modIDs: ids, enabled: enabled)
    }
}

public actor InstanceMods {
    public nonisolated let instance: InstanceRecord
    private let network: URLSession
    private let cache: URL?
    private let fileManager = FileManager.default
    private var game: URL { URL(fileURLWithPath: instance.path, isDirectory: true) }
    var folder: URL { game.appending(path: "mods", directoryHint: .isDirectory) }

    public init(instance: InstanceRecord) {
        self.init(instance: instance, network: .shared, cache: try? AppPaths.standard().downloadCache)
    }

    public init(instance: InstanceRecord, network: URLSession, cache: URL? = nil) {
        self.cache = cache
        self.instance = instance
        self.network = network
    }

    private func scan() throws -> ModDirectoryScan {
        guard fileManager.fileExists(atPath: game.path) else { throw InstallError.message("实例目录不可用。") }
        return try ModDirectoryScan(folder: folder)
    }

    public func list() async throws -> [LocalMod] {
        try await scan().read()
    }

    // 从校验到写盘之间不能挂起 否则其他操作可能改掉模组
    func currentMods() throws -> [LocalMod] {
        try scan().readSynchronously()
    }

    func checkWritable(_ allowExternal: Bool) throws {
        guard instance.kind.isWritable || allowExternal else { throw InstallError.message("此外部实例当前为只读。") }
        let identity = PathIdentity(of: game)
        guard identity.isInodeBacked, identity.canonical == instance.identityCanonical else { throw InstallError.message("实例目录已移动或被替换，请重新扫描。") }
        if (try? fileManager.destinationOfSymbolicLink(atPath: folder.path)) != nil { throw InstallError.message("mods 指向另一个目录，请在访达中管理此链接。") }
        guard RunningGameDetector().processIdentifiers(usingGameDirectory: instance.path).isEmpty else { throw InstallError.message("请先退出此实例的游戏。") }
    }

    func source(_ mod: LocalMod) throws -> URL {
        let file = try installPath(mod.filename, in: folder)
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw InstallError.message("模组文件已改变，请刷新。") }
        return file
    }

    public func toggle(_ mod: LocalMod, allowExternal: Bool) throws {
        try checkWritable(allowExternal)
        let file = try source(mod)
        let target = mod.enabled ? file.appendingPathExtension("disabled") : file.deletingPathExtension()
        if !mod.enabled {
            let others = try currentMods().filter(\.enabled)
            try checkConflict(mod, against: others)
        }
        try fileManager.moveItem(at: file, to: target)
    }

    public func trash(_ mod: LocalMod, allowExternal: Bool) throws {
        try checkWritable(allowExternal)
        try fileManager.trashItem(at: source(mod), resultingItemURL: nil)
    }

    func checkConflict(_ file: LocalMod, against mods: [LocalMod]) throws {
        if let other = mods.first(where: { !$0.modIDs.isDisjoint(with: file.modIDs) }) {
            throw InstallError.message("与「\(other.filename)」包含相同模组，请先停用已有版本。")
        }
    }

    public func importJar(_ url: URL, allowExternal: Bool) throws {
        try checkWritable(allowExternal)
        let filename = url.lastPathComponent
        guard filename.lowercased().hasSuffix(".jar"), safeComponent(filename) else { throw InstallError.message("请选择模组 JAR 文件。") }
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: game, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let staged = stage.appending(path: filename)
        let actual = url.resolvingSymlinksInPath()
        guard try actual.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw InstallError.message("请选择普通文件。") }
        try fileManager.copyItem(at: actual, to: staged)
        let mod = try LocalMod.read(staged, filename: filename)
        guard !mod.modIDs.isEmpty else { throw InstallError.message("没有找到 Fabric、Quilt 或 Forge 系列的模组描述。") }
        try checkConflict(mod, against: currentMods().filter(\.enabled))
        let target = try installPath(filename, in: folder)
        guard !fileManager.fileExists(atPath: target.appendingPathExtension("disabled").path) else { throw InstallError.message("同名模组已停用，请先在列表中启用。") }
        try checkWritable(allowExternal)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.moveItem(at: staged, to: target)
    }

    func stageJar(_ release: ModRelease, in stage: URL) async throws -> (URL, ModRelease.File) {
        guard let file = release.jar, let hash = file.hashes["sha512"] ?? file.hashes["sha1"],
              file.url.scheme == "https", file.url.host?.lowercased() == "cdn.modrinth.com" else {
            throw InstallError.message("此版本没有可校验的 Modrinth JAR。")
        }
        let path = try installPath(file.filename, in: stage)
        let existing = try installPath(file.filename, in: folder)
        let attributes = try? existing.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var reused = false
        if attributes?.isRegularFile == true, attributes?.isSymbolicLink != true {
            // 下载期间原文件可能被换掉 校验要在副本上做
            try InstallNetwork.copy(existing, to: path)
            reused = (try? InstallNetwork.verify(path, hash: hash, size: file.size)) != nil
            if !reused { try fileManager.removeItem(at: path) }
        }
        if !reused {
            try Task.checkCancellation()
            let job = InstallFile(destination: path, sources: [file.url], hash: hash, size: file.size)
            try await InstallNetwork(session: network).download(job, cache: cache) {
                $0.scheme == "https" && ["cdn.modrinth.com", "cdn-raw.modrinth.com"].contains($0.host?.lowercased())
            }
        }
        guard (try? Archive(url: path, accessMode: .read, pathEncoding: nil)) != nil else { throw InstallError.message("下载的文件不是有效的 JAR：\(file.filename)") }
        return (path, file)
    }

    func stageJars(_ releases: [ModRelease], in stage: URL,
                   progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [(URL, ModRelease.File)] {
        var names = Set<String>()
        for release in releases {
            guard let jar = release.jar, names.insert(jar.filename.lowercased().precomposedStringWithCanonicalMapping).inserted else {
                throw InstallError.message("模组安装计划缺少 JAR 或包含重复文件名。")
            }
        }
        return try await mapDownloads(releases, limit: 4, progress: progress) { release in
            try await self.stageJar(release, in: stage)
        }
    }

    public func install(_ plan: [ModRelease], allowExternal: Bool,
                        progress: @Sendable (Int, Int) async -> Void) async throws -> Int {
        try checkWritable(allowExternal)
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: game, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let downloads = try await stageJars(plan, in: stage, progress: progress)
        try await DownloadTraffic.checkpoint()
        try checkWritable(allowExternal)
        var installed = try currentMods()
        var pending: [(URL, URL)] = []
        for (path, file) in downloads {
            let target = try installPath(file.filename, in: folder)
            if fileManager.fileExists(atPath: target.path) {
                guard installed.contains(where: { $0.filename == file.filename && $0.enabled }),
                      let hash = file.hashes["sha512"] ?? file.hashes["sha1"],
                      (try? InstallNetwork.verify(target, hash: hash, size: file.size)) != nil else {
                    throw InstallError.message("同名文件已存在：\(file.filename)")
                }
                continue
            }
            if fileManager.fileExists(atPath: target.appendingPathExtension("disabled").path) {
                throw InstallError.message("「\(file.filename)」已停用，请先在本地列表启用。")
            }
            let item = try LocalMod.read(path, filename: file.filename)
            try checkConflict(item, against: installed.filter(\.enabled))
            installed.append(item)
            pending.append((path, target))
        }
        guard !pending.isEmpty else { return 0 }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [URL] = []
        do {
            for (path, target) in pending {
                try fileManager.moveItem(at: path, to: target)
                added.append(target)
            }
        } catch {
            for file in added.reversed() { try fileManager.removeItem(at: file) }
            throw error
        }
        return added.count
    }
}
