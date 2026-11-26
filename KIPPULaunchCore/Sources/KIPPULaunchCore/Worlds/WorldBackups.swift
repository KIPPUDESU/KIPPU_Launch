import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

public struct SavedWorld: Identifiable, Hashable, Sendable, Codable {
    public let folder: String
    public let name: String
    let identity: String
    public var id: String { folder }
}

public struct WorldBackup: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let world: SavedWorld
    public let created: Date
    public let size: Int64
}

public actor WorldBackups {
    private let instance: InstanceRecord
    private let paths: AppPaths?
    private let fileManager = FileManager.default
    private var game: URL { URL(fileURLWithPath: instance.path, isDirectory: true) }
    private var saves: URL { game.appending(path: "saves", directoryHint: .isDirectory) }
    private func storage() throws -> URL { try (paths ?? AppPaths.standard()).worldBackups(for: instance) }

    public init(instance: InstanceRecord, paths: AppPaths? = nil) {
        self.instance = instance
        self.paths = paths
    }

    private struct Node: Equatable {
        let path: String
        let directory: Bool
        let size: Int64
        let inode: ino_t
        let changed: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path == rhs.path && lhs.directory == rhs.directory && lhs.size == rhs.size && lhs.inode == rhs.inode &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private struct Manifest: Codable {
        struct File: Codable {
            let path: String
            let size: Int64
            let hash: String
        }
        let directories: [String]
        let files: [File]
    }

    private func checkInstance(idle: Bool) throws {
        let identity = PathIdentity(of: game)
        guard identity.isInodeBacked, identity.canonical == instance.identityCanonical else {
            throw InstallError.message("实例目录已移动或被替换，请重新扫描。")
        }
        if idle && !RunningGameDetector().processIdentifiers(usingGameDirectory: instance.path).isEmpty {
            throw InstallError.message("请先退出此实例的游戏，再备份或恢复存档。")
        }
    }

    // lstat 能识别指向已删除目标的符号链接
    private func info(_ url: URL) throws -> stat? {
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        let code = errno
        if code == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func directory(_ url: URL, create: Bool = false) throws -> Bool {
        if let value = try info(url) {
            guard value.st_mode & S_IFMT == S_IFDIR else { throw InstallError.message("「\(url.lastPathComponent)」不是普通目录。") }
            return true
        }
        if create {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return try directory(url)
        }
        return false
    }

    private func level(in world: URL) throws -> WorldLevelName {
        for name in ["level.dat", "level.dat_old"] {
            let file = world.appending(path: name)
            guard let state = try info(file), state.st_mode & S_IFMT == S_IFREG else { continue }
            if let level = try? WorldLevelName(file: file) { return level }
        }
        throw InstallError.message("没有可读取的 level.dat 或 level.dat_old。")
    }

    public func worlds() throws -> [SavedWorld] {
        try checkInstance(idle: false)
        guard try directory(saves) else { return [] }
        let folders = try fileManager.contentsOfDirectory(at: saves, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try folders.compactMap { folder -> SavedWorld? in
            try Task.checkCancellation()
            guard try info(folder).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true else { return nil }
            let hasLevel = try ["level.dat", "level.dat_old"].contains { name in
                try info(folder.appending(path: name)).map { $0.st_mode & S_IFMT == S_IFREG } == true
            }
            guard hasLevel else { return nil }
            let title = try? level(in: folder).name
            return SavedWorld(folder: folder.lastPathComponent, name: title.flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent,
                              identity: PathIdentity(of: folder).canonical)
        }.sorted { ($0.name, $0.folder) < ($1.name, $1.folder) }
    }

    public func backups() throws -> [WorldBackup] {
        let root = try storage()
        guard try directory(root) else { return [] }
        let folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try folders.compactMap { folder -> WorldBackup? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            return try readBackup(id, in: root)
        }.sorted { $0.created > $1.created }
    }

    /// 世界文件可以直接放在 ZIP 根目录或包在一层文件夹内
    @discardableResult
    public func importArchive(_ url: URL, allowExternal: Bool = false) throws -> SavedWorld {
        try checkInstance(idle: true)
        guard instance.kind.isWritable || allowExternal else {
            throw InstallError.message("此外部实例当前为只读，请在实例管理中允许本次管理。")
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "zip" else {
            throw InstallError.message("请选择 ZIP 格式的世界文件。")
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw InstallError.message("世界下载文件不是普通文件。")
        }

        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        var roots = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type != .symlink else { throw InstallError.message("世界 ZIP 包含符号链接。") }
            let parts = try archivePath(entry.path, directory: entry.type == .directory)
            if entry.type == .file, ["level.dat", "level.dat_old"].contains(parts.last), parts.first != "__MACOSX" {
                roots.insert(parts.dropLast().joined(separator: "/"))
            }
        }
        guard let root = roots.first else { throw InstallError.message("这个 ZIP 中没有找到 level.dat。") }
        guard roots.count == 1 else { throw InstallError.message("ZIP 包含多个世界，请选择单个世界的 ZIP。") }

        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: game, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let copy = stage.appending(path: "world", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: false)
        let prefix = root.isEmpty ? "" : root + "/"
        let limit = UInt64(4) << 30
        var remaining = limit
        for entry in archive where entry.path.hasPrefix(prefix) {
            try Task.checkCancellation()
            let relative = String(entry.path.dropFirst(prefix.count))
            guard !relative.isEmpty, relative != "session.lock", !relative.hasPrefix("__MACOSX/") else { continue }
            let target = copy.appending(path: relative)
            if entry.type == .directory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard entry.uncompressedSize <= remaining else { throw CocoaError(.fileReadTooLarge) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: target, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var size: UInt64 = 0
            let bufferSize = Int(min(max(1, entry.uncompressedSize), 128 * 1024))
            let crc = try archive.extract(entry, bufferSize: bufferSize) { chunk in
                try Task.checkCancellation()
                size += UInt64(chunk.count)
                guard size <= entry.uncompressedSize else { throw CocoaError(.fileReadCorruptFile) }
                try handle.write(contentsOf: chunk)
            }
            guard crc == entry.checksum, size == entry.uncompressedSize else { throw CocoaError(.fileReadCorruptFile) }
            remaining -= size
        }

        let level = try level(in: copy)
        let sourceName = root.split(separator: "/").last.map(String.init) ?? url.deletingPathExtension().lastPathComponent
        let base = safeComponent(sourceName) && !sourceName.hasPrefix(".") ? sourceName : "下载的世界"
        try checkInstance(idle: true)
        _ = try directory(saves, create: true)
        for number in 1...Int.max {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : "（\(number)）"
            var stem = base
            while (stem + suffix).utf8.count > 250 { stem.removeLast() }
            let target = saves.appending(path: stem + suffix, directoryHint: .isDirectory)
            let title = (level.name.isEmpty ? stem : level.name) + suffix
            if number > 1 { try level.write(name: title, to: copy.appending(path: "level.dat")) }
            if renamex_np(copy.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return SavedWorld(folder: target.lastPathComponent, name: title, identity: PathIdentity(of: target).canonical)
            }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw InstallError.message("无法为下载的世界分配目录。")
    }

    private func readBackup(_ id: UUID, in root: URL) throws -> WorldBackup {
        let folder = root.appending(path: id.uuidString)
        guard try directory(folder) else { throw InstallError.message("找不到这份存档备份。") }
        let record = try readJSON(WorldBackup.self, at: folder.appending(path: "backup.json"))
        guard record.id == id, component(record.world.folder), record.size >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    private func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard let value = try info(url), value.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func component(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private func archivePath(_ path: String, directory: Bool) throws -> [String] {
        let name = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = name.components(separatedBy: "/")
        guard parts.allSatisfy(safeComponent) else { throw InstallError.message("世界 ZIP 包含无效路径。") }
        return parts
    }

    private func inventory(_ root: URL) throws -> [Node] {
        var items: [Node] = []
        var folders = [""]
        while let path = folders.popLast() {
            try Task.checkCancellation()
            let parent = path.isEmpty ? root : root.appending(path: path)
            guard try directory(parent) else { throw CocoaError(.fileNoSuchFile) }
            for child in try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                let name = child.lastPathComponent
                if path.isEmpty && name == "session.lock" { continue }
                guard let value = try info(child) else { throw CocoaError(.fileNoSuchFile) }
                let kind = value.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG else {
                    throw InstallError.message("「\(name)」是链接或特殊文件，无法完整复制这个世界。")
                }
                let relative = path.isEmpty ? name : path + "/" + name
                items.append(Node(path: relative, directory: kind == S_IFDIR, size: value.st_size,
                                  inode: value.st_ino, changed: value.st_ctimespec))
                if kind == S_IFDIR { folders.append(relative) }
            }
        }
        return items.sorted { $0.path < $1.path }
    }

    private func copyFile(from source: URL, to target: URL, relativePath: String) throws -> Manifest.File {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
        let dest = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard dest >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: dest, closeOnDealloc: true)
        var size: Int64 = 0
        var digest = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            digest.update(data: data)
            size += Int64(data.count)
        }
        try output.close()
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return Manifest.File(path: relativePath, size: size, hash: hash)
    }

    // 游戏对会话文件加写锁 备份期间持有与它互斥的读锁
    private func lockWorld(_ world: URL) throws -> FileHandle? {
        let fd = open(world.appending(path: "session.lock").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw InstallError.message("无法读取世界的 session.lock。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var lock = flock()
        lock.l_type = Int16(F_RDLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_SETLK, &lock) == 0 else { throw InstallError.message("世界正在使用，请退出游戏后重试。") }
        return handle
    }

    @discardableResult
    public func backup(_ world: SavedWorld) throws -> WorldBackup {
        try checkInstance(idle: true)
        guard component(world.folder), try directory(saves) else { throw CocoaError(.fileNoSuchFile) }
        let source = saves.appending(path: world.folder, directoryHint: .isDirectory)
        guard try directory(source), PathIdentity(of: source).canonical == world.identity else { throw InstallError.message("所选世界已改变，请刷新后重试。") }
        let lock = try lockWorld(source)
        defer { try? lock?.close() }
        let nodes = try inventory(source)
        guard nodes.contains(where: { !$0.directory && ["level.dat", "level.dat_old"].contains($0.path) }) else { throw CocoaError(.fileReadCorruptFile) }
        let root = try storage()
        _ = try directory(root, create: true)
        let id = UUID()
        let stage = root.appending(path: ".partial-" + id.uuidString)
        let contents = stage.appending(path: "world")
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: false)
        var files: [Manifest.File] = []
        for node in nodes {
            try Task.checkCancellation()
            let destination = contents.appending(path: node.path)
            if node.directory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                let file = try copyFile(from: source.appending(path: node.path), to: destination, relativePath: node.path)
                files.append(file)
            }
        }
        try checkInstance(idle: true)
        guard PathIdentity(of: source).canonical == world.identity, try inventory(source) == nodes else {
            throw InstallError.message("备份期间世界发生变化，请退出游戏后重试。")
        }
        let title = try level(in: contents).name
        let captured = SavedWorld(folder: world.folder, name: title.isEmpty ? world.folder : title, identity: world.identity)
        let record = WorldBackup(id: id, world: captured, created: Date(), size: files.reduce(0) { $0 + $1.size })
        let manifest = Manifest(directories: nodes.filter(\.directory).map(\.path), files: files)
        try JSONEncoder().encode(manifest).write(to: stage.appending(path: "files.json"))
        try JSONEncoder().encode(record).write(to: stage.appending(path: "backup.json"))
        try Task.checkCancellation()
        try fileManager.moveItem(at: stage, to: root.appending(path: id.uuidString))
        return record
    }

    @discardableResult
    public func restoreCopy(_ id: UUID) throws -> SavedWorld {
        try checkInstance(idle: true)
        let root = try storage()
        guard try directory(root) else { throw InstallError.message("找不到这份存档备份。") }
        let backup = try readBackup(id, in: root)
        let folder = root.appending(path: id.uuidString)
        let source = folder.appending(path: "world")
        let manifest = try readJSON(Manifest.self, at: folder.appending(path: "files.json"))
        let nodes = try inventory(source)
        let dirs = nodes.filter(\.directory).map(\.path)
        let files = nodes.filter { !$0.directory }
        guard manifest.directories == dirs, files.map(\.path) == manifest.files.map(\.path) else {
            throw InstallError.message("备份文件清单不完整，无法恢复。")
        }
        _ = try directory(saves, create: true)
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: saves, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let copy = stage.appending(path: "world", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: false)
        for dir in dirs { try fileManager.createDirectory(at: copy.appending(path: dir), withIntermediateDirectories: false) }
        for file in manifest.files {
            let copied = try copyFile(from: source.appending(path: file.path), to: copy.appending(path: file.path), relativePath: file.path)
            guard file.size == copied.size, file.hash == copied.hash else {
                throw InstallError.message("备份中的「\(file.path)」校验失败。")
            }
        }
        let level = try level(in: copy)
        try checkInstance(idle: true)
        guard try directory(saves) else { throw CocoaError(.fileNoSuchFile) }
        for number in 1...Int.max {
            try Task.checkCancellation()
            let suffix = number == 1 ? "（副本）" : "（副本 \(number)）"
            var base = backup.world.folder
            while (base + suffix).utf8.count > 250 { base.removeLast() }
            let name = (level.name.isEmpty ? backup.world.name : level.name) + suffix
            let target = saves.appending(path: base + suffix, directoryHint: .isDirectory)
            if try info(target) != nil { continue }
            try level.write(name: name, to: copy.appending(path: "level.dat"))
            if renamex_np(copy.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return SavedWorld(folder: target.lastPathComponent, name: name, identity: PathIdentity(of: target).canonical)
            }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw InstallError.message("无法为恢复副本分配目录。")
    }
}
