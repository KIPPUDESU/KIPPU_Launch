import Foundation

public struct ModUpdateBackup: Identifiable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let date: Date
    let before: [ModFingerprint]
    let after: [ModFingerprint]
}

extension InstanceMods {
    private var history: URL { folder.appending(path: ".kippu-updates", directoryHint: .isDirectory) }
    private static let commitLock = NSLock()

    private func checkedDirectory(_ directory: URL) throws {
        let type = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard type.isDirectory == true, type.isSymbolicLink != true else { throw InstallError.message("更新备份目录已改变。") }
    }

    public func lastUpdate() throws -> ModUpdateBackup? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: history.path) else { return nil }
        try checkedDirectory(history)
        let entries = try fileManager.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        return try entries.compactMap { directory -> ModUpdateBackup? in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
            try checkedDirectory(directory)
            let file = directory.appending(path: "update.json")
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? 0) < 1_000_000 else {
                throw InstallError.message("更新记录不可用。")
            }
            let record = try JSONDecoder().decode(ModUpdateBackup.self, from: Data(contentsOf: file))
            guard record.id == id else { throw InstallError.message("更新记录与目录不一致。") }
            try validateNames(record.before)
            try validateNames(record.after)
            return record
        }.max { $0.date < $1.date }
    }

    private func validateNames(_ files: [ModFingerprint]) throws {
        var names = Set<String>()
        for file in files {
            let name = file.filename.lowercased()
            guard safeComponent(file.filename), !name.hasPrefix("."), name.hasSuffix(".jar") || name.hasSuffix(".jar.disabled"),
                  names.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                throw InstallError.message("更新计划中存在无效或重复的文件名。")
            }
        }
    }

    private func verify(_ file: ModFingerprint, in directory: URL, suffix: String = "") throws {
        let current = try ModFingerprint(filename: file.filename, at: directory.appending(path: file.filename + suffix))
        guard current == file else { throw InstallError.message("「\(file.filename)」已改变，请重新检查。") }
    }

    public func update(_ plan: ModUpdatePlan, allowExternal: Bool,
                       progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws {
        try checkWritable(allowExternal)
        let fileManager = FileManager.default
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        let outgoing = plan.changes.compactMap(\.before)
        let outgoingNames = Set(outgoing.map(\.filename))
        var after: [ModFingerprint] = []
        let staged = try await stageJars(plan.changes.map(\.release), in: stage, progress: progress)
        for (change, (download, _)) in zip(plan.changes, staged) {
            try Task.checkCancellation()
            let path = stage.appending(path: change.filename)
            if download != path { try fileManager.moveItem(at: download, to: path) }
            after.append(try ModFingerprint(filename: change.filename, at: path))
        }
        try await DownloadTraffic.checkpoint()
        try Self.commitLock.withLock {
            let fileManager = FileManager.default
            let backup = ModUpdateBackup(id: UUID(), name: plan.name, date: Date(), before: outgoing, after: after)
            try Task.checkCancellation()
            try checkWritable(allowExternal)
            try validateNames(backup.before)
            try validateNames(backup.after)
            for file in outgoing + plan.unchanged { try verify(file, in: folder) }
            var others = try currentMods().filter { !outgoingNames.contains($0.filename) }
            for file in after {
                let incoming = try LocalMod.read(stage.appending(path: file.filename), filename: file.filename)
                let alternate = incoming.enabled ? file.filename + ".disabled" : String(file.filename.dropLast(".disabled".count))
                for name in [file.filename, alternate] where !outgoingNames.contains(name) {
                    let path = folder.appending(path: name).path
                    guard !fileManager.fileExists(atPath: path), (try? fileManager.destinationOfSymbolicLink(atPath: path)) == nil else {
                        throw InstallError.message("同名文件已存在：\(name)")
                    }
                }
                if incoming.enabled { try checkConflict(incoming, against: others.filter(\.enabled)) }
                others.append(incoming)
            }

            // 先把完整备份移入历史目录 更新中断后才能回退
            let prepared = stage.appending(path: "backup", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: prepared, withIntermediateDirectories: false)
            for file in outgoing {
                try fileManager.copyItem(at: folder.appending(path: file.filename), to: prepared.appending(path: file.filename + ".bak"))
                try verify(file, in: prepared, suffix: ".bak")
            }
            try JSONEncoder().encode(backup).write(to: prepared.appending(path: "update.json"))
            try fileManager.createDirectory(at: history, withIntermediateDirectories: true)
            try checkedDirectory(history)
            if let last = try lastUpdate(), !fileManager.fileExists(atPath: backupDirectory(last).appending(path: "applied").path) {
                throw InstallError.message("上次更新未完成，请先回退。")
            }
            let directory = backupDirectory(backup)
            try fileManager.moveItem(at: prepared, to: directory)
            do {
                for file in outgoing { try fileManager.removeItem(at: folder.appending(path: file.filename)) }
                for file in after {
                    try fileManager.moveItem(at: stage.appending(path: file.filename), to: folder.appending(path: file.filename))
                }
                try Data().write(to: directory.appending(path: "applied"), options: .withoutOverwriting)
            } catch {
                do {
                    try restore(backup)
                } catch {
                    throw InstallError.message("更新中断，旧文件已备份。请使用「回退更新」恢复。\n\(error.localizedDescription)")
                }
                throw error
            }
        }
    }

    private func backupDirectory(_ backup: ModUpdateBackup) -> URL {
        history.appending(path: backup.id.uuidString, directoryHint: .isDirectory)
    }

    public func rollback(_ id: UUID, allowExternal: Bool) throws {
        try Self.commitLock.withLock {
            try checkWritable(allowExternal)
            guard let backup = try lastUpdate(), backup.id == id else { throw InstallError.message("更新记录已变化，请刷新后重试。") }
            try restore(backup)
        }
    }

    private func restore(_ backup: ModUpdateBackup) throws {
        let fileManager = FileManager.default
        let directory = backupDirectory(backup)
        let marker = directory.appending(path: "applied")
        let complete = fileManager.fileExists(atPath: marker.path)
        let old = Dictionary(uniqueKeysWithValues: backup.before.map { ($0.filename, $0) })
        let new = Dictionary(uniqueKeysWithValues: backup.after.map { ($0.filename, $0) })
        var remove: [String] = []
        var restore: [String] = []
        for file in backup.before { try verify(file, in: directory, suffix: ".bak") }
        for name in Set(old.keys).union(new.keys) {
            let path = folder.appending(path: name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: path.path)) == nil else { throw InstallError.message("「\(name)」已变为链接。") }
            let actual = fileManager.fileExists(atPath: path.path) ? try ModFingerprint(filename: name, at: path) : nil
            if complete && actual != new[name] { throw InstallError.message("「\(name)」在更新后已改变，无法安全回退。") }
            if actual == old[name] { continue }
            if let actual {
                guard actual == new[name] else { throw InstallError.message("「\(name)」已被其他文件占用。") }
                remove.append(name)
            }
            if old[name] != nil { restore.append(name) }
        }
        // 回退可能执行第二次 也可能遇到用户后来安装的模组
        let remaining = try currentMods().filter { !remove.contains($0.filename) }
        let stage = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fileManager.removeItem(at: stage) }
        for name in restore {
            let file = stage.appending(path: name)
            try fileManager.copyItem(at: directory.appending(path: name + ".bak"), to: file)
            let mod = try LocalMod.read(file, filename: name)
            if mod.enabled { try checkConflict(mod, against: remaining.filter(\.enabled)) }
        }
        if complete { try fileManager.removeItem(at: marker) }
        for name in remove { try fileManager.removeItem(at: folder.appending(path: name)) }
        for name in restore {
            try fileManager.moveItem(at: stage.appending(path: name), to: folder.appending(path: name))
        }
        try fileManager.moveItem(at: directory, to: stage.appending(path: "restored-backup"))
    }
}
