import Foundation
import ZIPFoundation

public enum PackKind: String, CaseIterable, Identifiable, Sendable {
    case shaders = "shaderpacks", resources = "resourcepacks"
    public var id: Self { self }
    public var title: String { self == .shaders ? "光影包" : "材质包" }
}

public struct InstalledPack: Identifiable, Sendable {
    public let url: URL
    public let directory: Bool
    public let size: Int?
    public let enabled: Bool?
    let resourceIndex: Int?
    let identity: PathIdentity
    public var name: String { url.lastPathComponent }
    public var id: URL { url }
}

public actor InstancePacks {
    public struct Listing: Sendable {
        public let items: [InstalledPack]
        public let selectionHint: String?
    }

    private let instance: InstanceRecord
    private let fileManager = FileManager.default
    private var game: URL { URL(fileURLWithPath: instance.path, isDirectory: true) }
    // 不同窗口各有自己的管理器 但可能在改同一份配置
    private static let lock = NSLock()

    public init(instance: InstanceRecord) { self.instance = instance }

    private func folder(_ kind: PackKind, writing: Bool = false, allowExternal: Bool = false) throws -> URL {
        let identity = PathIdentity(of: game)
        guard identity.isInodeBacked, identity.canonical == instance.identityCanonical else {
            throw InstallError.message("实例目录已移动或不可用，请重新扫描。")
        }
        let url = game.appending(path: kind.rawValue, directoryHint: .isDirectory)
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw InstallError.message("包目录是符号链接，请在访达中管理。")
        }
        if writing {
            guard instance.kind.isWritable || allowExternal else { throw InstallError.message("此外部实例当前为只读。") }
            guard RunningGameDetector().processIdentifiers(usingGameDirectory: instance.path).isEmpty else {
                throw InstallError.message("请先退出此实例的游戏。")
            }
        }
        return url
    }

    private func selection(_ kind: PackKind) throws -> PackSelection {
        try PackSelection(game: game, kind: kind, version: instance.minecraftVersion ?? instance.versionIdentifier)
    }

    public func list(_ kind: PackKind) throws -> Listing {
        let root = try folder(kind)
        let config: PackSelection?
        var hint: String?
        do {
            config = try selection(kind)
        } catch {
            config = nil
            hint = error.localizedDescription
        }
        guard fileManager.fileExists(atPath: root.path) else { return Listing(items: [], selectionHint: hint) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let items = try urls.compactMap { url -> InstalledPack? in
            try Task.checkCancellation()
            let attrs = try url.resourceValues(forKeys: keys)
            guard attrs.isSymbolicLink != true else { return nil }
            let directory = attrs.isDirectory == true
            if directory {
                guard validDirectory(url, kind: kind) else { return nil }
            } else if attrs.isRegularFile != true || url.pathExtension.lowercased() != "zip" { return nil }
            return InstalledPack(url: url, directory: directory, size: directory ? nil : attrs.fileSize,
                                 enabled: config?.enabled(url.lastPathComponent), resourceIndex: config?.resourceIndex(url.lastPathComponent), identity: PathIdentity(of: url))
        }
        let sorted = items.sorted {
            let left = $0.resourceIndex ?? -1, right = $1.resourceIndex ?? -1
            if left != right { return left > right }
            if ($0.enabled == true) != ($1.enabled == true) { return $0.enabled == true }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Listing(items: sorted, selectionHint: hint)
    }

    private func validDirectory(_ url: URL, kind: PackKind) -> Bool {
        func marker(_ root: URL) -> Bool {
            let path = root.appending(path: kind == .resources ? "pack.mcmeta" : "shaders")
            guard let attrs = try? path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  attrs.isSymbolicLink != true else { return false }
            return kind == .resources ? attrs.isRegularFile == true : attrs.isDirectory == true
        }
        if marker(url) { return true }
        guard kind == .shaders else { return false }
        let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
        return children?.contains { child in
            let attrs = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return attrs?.isDirectory == true && attrs?.isSymbolicLink != true && marker(child)
        } == true
    }

    private func validPack(_ url: URL, directory: Bool, kind: PackKind) throws -> Bool {
        if directory && kind == .shaders { return validDirectory(url, kind: kind) }
        let metadata: Data
        let limit = 1_048_576
        if directory {
            guard validDirectory(url, kind: kind) else { return false }
            let file = url.appending(path: "pack.mcmeta")
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return false }
            metadata = try Data(contentsOf: file)
        } else {
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return false }
            if kind == .shaders {
                return archive.contains { entry in
                    let parts = entry.path.split(separator: "/")
                    guard entry.type == .file, parts.allSatisfy({ safeComponent(String($0)) && !$0.hasPrefix(".") }) else { return false }
                    return parts.count >= 2 && (parts[0] == "shaders" || (parts.count >= 3 && parts[1] == "shaders" && parts[0] != "__MACOSX"))
                }
            }
            guard let entry = archive["pack.mcmeta"], entry.type == .file, entry.uncompressedSize <= limit else { return false }
            var bytes = Data()
            let crc = try archive.extract(entry) { chunk in
                guard bytes.count + chunk.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                bytes.append(chunk)
            }
            guard crc == entry.checksum else { return false }
            metadata = bytes
        }
        let json = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        return json?["pack"] is [String: Any]
    }

    public func importPack(_ source: URL, kind: PackKind, allowExternal: Bool) throws {
        let root = try folder(kind, writing: true, allowExternal: allowExternal)
        let attrs = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        let directory = attrs.isDirectory == true
        let name = !directory && source.pathExtension.lowercased() == "zip"
            ? source.deletingPathExtension().lastPathComponent + ".zip" : source.lastPathComponent
        guard safeComponent(name), !name.hasPrefix(".") else { throw InstallError.message("包名称无效。") }
        let target = root.appending(path: name)
        guard attrs.isSymbolicLink != true,
              directory ? validDirectory(source, kind: kind) : attrs.isRegularFile == true && source.pathExtension.lowercased() == "zip" else {
            throw InstallError.message("请选择包含\(kind == .resources ? " pack.mcmeta" : " shaders 目录")的\(kind.title)文件夹或 ZIP。")
        }
        guard !fileManager.fileExists(atPath: target.path) else { throw InstallError.message("已存在同名包：\(name)") }
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: game, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let staged = stage.appending(path: name)
        if directory {
            let parent = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !stage.resolvingSymlinksInPath().path.hasPrefix(parent), !target.resolvingSymlinksInPath().path.hasPrefix(parent) else {
                throw InstallError.message("请选择包本身的文件夹。")
            }
            try fileManager.copyItem(at: source, to: staged)
        } else {
            try InstallNetwork.copy(source, to: staged)
        }
        guard try validPack(staged, directory: directory, kind: kind) else {
            throw InstallError.message("包结构不正确。\(kind == .resources ? "材质包根目录需要 pack.mcmeta。" : "光影包需要包含 shaders 目录。")")
        }
        try Self.lock.withLock {
            _ = try folder(kind, writing: true, allowExternal: allowExternal)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged, to: target)
        }
    }

    private func existing(_ pack: InstalledPack, kind: PackKind, allowExternal: Bool) throws -> URL {
        let root = try folder(kind, writing: true, allowExternal: allowExternal)
        let file = root.appending(path: pack.name)
        guard file.standardizedFileURL.path == pack.url.standardizedFileURL.path, PathIdentity(of: file) == pack.identity,
              let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
              attrs.isSymbolicLink != true, pack.directory ? attrs.isDirectory == true : attrs.isRegularFile == true else {
            throw InstallError.message("包已移动或已更改，请刷新列表。")
        }
        return file
    }

    public func setEnabled(_ enabled: Bool, pack: InstalledPack, kind: PackKind, allowExternal: Bool) throws {
        try Self.lock.withLock {
            let file = try existing(pack, kind: kind, allowExternal: allowExternal)
            if enabled, try !validPack(file, directory: pack.directory, kind: kind) {
                throw InstallError.message("无法启用：包结构或元数据无效。")
            }
            var config = try selection(kind)
            try config.set(file.lastPathComponent, enabled: enabled)
        }
    }

    public func movePriority(_ pack: InstalledPack, higher: Bool, allowExternal: Bool) throws {
        try Self.lock.withLock {
            _ = try existing(pack, kind: .resources, allowExternal: allowExternal)
            let active = try list(.resources).items.filter { $0.enabled == true }
            guard let index = active.firstIndex(where: { $0.id == pack.id }) else { return }
            let other = index + (higher ? -1 : 1)
            guard active.indices.contains(other) else { return }
            var config = try selection(.resources)
            try config.swapPriority(pack.name, active[other].name)
        }
    }

    public func trash(_ pack: InstalledPack, kind: PackKind, allowExternal: Bool) throws {
        try Self.lock.withLock {
            let file = try existing(pack, kind: kind, allowExternal: allowExternal)
            if (try? selection(kind))?.enabled(pack.name) == true {
                throw InstallError.message("请先停用「\(pack.name)」，再将它移到废纸篓。")
            }
            try fileManager.trashItem(at: file, resultingItemURL: nil)
        }
    }
}
