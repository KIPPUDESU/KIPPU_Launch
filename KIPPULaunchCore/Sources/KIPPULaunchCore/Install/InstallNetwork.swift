import CryptoKit
import Darwin
import Foundation

extension Digest {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: Self.byteCount * 2) { buffer in
            var writeIndex = 0
            for byte in self {
                buffer[writeIndex] = digits[Int(byte >> 4)]
                buffer[writeIndex + 1] = digits[Int(byte & 15)]
                writeIndex += 2
            }
            return writeIndex
        }
    }
}

struct InstallNetwork: Sendable {
    let session: URLSession

    func data(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw InstallError.message("下载地址必须使用 HTTPS。") }
        let (body, response) = try await DownloadTraffic.data(using: session, request: URLRequest(url: url))
        guard response.url?.scheme == "https", let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.message("下载失败：\(url.host ?? "")\(url.path)")
        }
        return body
    }

    static func digest<H: HashFunction>(of file: URL, using algorithm: H.Type) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let descriptor = handle.fileDescriptor
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let capacity = Int(max(1, min(fileStatus.st_size, 256 * 1024)))
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity) { buffer in
            var hash = H()
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                if count == 0 { return hash.finalize().hexString }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
            }
        }
    }

    static func verify(_ file: URL, hash: String, size: Int?) throws {
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CocoaError(.fileReadUnknown) }
        guard size == nil || size == attributes.fileSize else { throw InstallError.message("文件大小校验失败。") }
        let actual: String
        switch hash.utf8.count {
        case 40: actual = try digest(of: file, using: Insecure.SHA1.self)
        case 128: actual = try digest(of: file, using: SHA512.self)
        default: throw InstallError.message("缺少可识别的文件校验值。")
        }
        guard actual == hash.lowercased() else { throw InstallError.message("文件哈希校验失败。") }
    }

    static func copy(_ file: URL, to newFile: URL) throws {
        if clonefile(file.path(percentEncoded: false), newFile.path(percentEncoded: false), 0) != 0 {
            try FileManager.default.copyItem(at: file, to: newFile)
        }
    }

    private static func publish(_ file: URL, to destination: URL) throws {
        // 临时文件和目标同卷 并发读取缓存时只能看到完整文件
        guard rename(file.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func download(_ file: InstallFile, cache: URL?, accepting: @Sendable (URL) -> Bool = { $0.scheme == "https" }) async throws {
        let hash = file.hash.lowercased()
        guard [40, 128].contains(hash.utf8.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InstallError.message("文件校验值无效。")
        }
        try await DownloadTraffic.checkpoint()
        let sources = file.sources.filter(accepting)
        guard !sources.isEmpty else { throw InstallError.message("没有可用的下载源。") }
        let fileManager = FileManager.default
        let parent = file.destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(component: ".download-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: staged) }
        let cached = cache?.appending(component: hash)
        if let cached, fileManager.fileExists(atPath: cached.path) {
            do {
                try Self.copy(cached, to: staged)
                try Self.verify(staged, hash: hash, size: file.size)
                try Task.checkCancellation()
                try Self.publish(staged, to: file.destination)
                return
            } catch {
                try Task.checkCancellation()
                try? fileManager.removeItem(at: staged)
            }
        }

        var lastError: Error = InstallError.message("没有可用的下载源。")
        for source in sources {
            do {
                try Task.checkCancellation()
                let (temporaryFile, response) = try await DownloadTraffic.download(using: session, request: URLRequest(url: source))
                defer { try? fileManager.removeItem(at: temporaryFile) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let url = http.url, accepting(url) else { throw InstallError.message("文件下载失败。") }
                try Self.verify(temporaryFile, hash: hash, size: file.size)
                try fileManager.moveItem(at: temporaryFile, to: staged)
                try Task.checkCancellation()
                if let cache, let cached {
                    let partial = cache.appending(component: ".download-" + UUID().uuidString)
                    defer { try? fileManager.removeItem(at: partial) }
                    if fileManager.fileExists(atPath: cache.path) || (try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)) != nil,
                       (try? Self.copy(staged, to: partial)) != nil {
                        try? Self.publish(partial, to: cached)
                    }
                }
                try Self.publish(staged, to: file.destination)
                return
            } catch {
                try Task.checkCancellation()
                try? fileManager.removeItem(at: staged)
                lastError = error
            }
        }
        throw InstallError.message("\(file.destination.lastPathComponent)：\(lastError.localizedDescription)")
    }
}

/// 进度按完成先后通知 结果按输入顺序返回
func mapDownloads<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int,
    progress: @Sendable (Int, Int) async -> Void = { _, _ in },
    transform: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        func enqueue(_ index: Int) {
            let item = items[index]
            group.addTask {
                try Task.checkCancellation()
                return (index, try await transform(item))
            }
        }
        var nextIndex = min(limit, items.count)
        for index in 0..<nextIndex { enqueue(index) }
        var ordered = Array<Output?>(repeating: nil, count: items.count)
        var completedCount = 0
        for try await (index, value) in group {
            ordered[index] = value
            completedCount += 1
            if nextIndex < items.count {
                enqueue(nextIndex)
                nextIndex += 1
            }
            await progress(completedCount, items.count)
        }
        try Task.checkCancellation()
        return ordered.compactMap { $0 }
    }
}
