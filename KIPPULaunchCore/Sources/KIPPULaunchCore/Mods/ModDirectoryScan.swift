import Darwin
import Foundation
import Synchronization

private struct ModFileStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init?(_ url: URL) throws {
        var info = stat()
        if lstat(url.path(percentEncoded: false), &info) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

private final class CachedMod: Sendable {
    let mod: LocalMod
    let stamp: ModFileStamp

    init(_ mod: LocalMod, stamp: ModFileStamp) {
        self.mod = mod
        self.stamp = stamp
    }
}

struct ModDirectoryScan {
    private static let cache = Mutex<NSCache<NSURL, CachedMod>>({
        let cache = NSCache<NSURL, CachedMod>()
        cache.countLimit = 4096
        return cache
    }())

    private struct Pending: Sendable {
        let url: URL
        let stamp: ModFileStamp

        func read() throws -> LocalMod? {
            var stamp = stamp
            for _ in 0..<2 {
                try Task.checkCancellation()
                let mod = try autoreleasepool { try LocalMod.read(url, filename: url.lastPathComponent) }
                guard let current = try ModFileStamp(url) else { return nil }
                if current == stamp {
                    cache.withLock { $0.setObject(CachedMod(mod, stamp: current), forKey: url as NSURL) }
                    return mod
                }
                stamp = current
            }
            throw InstallError.message("「\(url.lastPathComponent)」正在更改，请稍后刷新。")
        }
    }

    private var cached: [LocalMod] = []
    private var pending: [Pending] = []

    init(folder: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.path) else { return }
        let urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".jar") || name.hasSuffix(".jar.disabled"),
                  let stamp = try ModFileStamp(url) else { continue }
            if let hit = Self.cache.withLock({ $0.object(forKey: url as NSURL) }), hit.stamp == stamp {
                cached.append(hit.mod)
            } else {
                pending.append(Pending(url: url, stamp: stamp))
            }
        }
    }

    func readSynchronously() throws -> [LocalMod] {
        try Self.sorted(cached + pending.compactMap { try $0.read() })
    }

    func read() async throws -> [LocalMod] {
        guard pending.count > 1 else { return try readSynchronously() }
        return try await withThrowingTaskGroup(of: LocalMod?.self) { group in
            var remaining = pending.makeIterator()
            for _ in 0..<min(4, pending.count) {
                if let file = remaining.next() { group.addTask { try file.read() } }
            }
            var mods = cached
            for try await mod in group {
                if let mod { mods.append(mod) }
                if let file = remaining.next() { group.addTask { try file.read() } }
            }
            try Task.checkCancellation()
            return Self.sorted(mods)
        }
    }

    private static func sorted(_ mods: [LocalMod]) -> [LocalMod] {
        mods.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.filename < rhs.filename : order == .orderedAscending
        }
    }
}
