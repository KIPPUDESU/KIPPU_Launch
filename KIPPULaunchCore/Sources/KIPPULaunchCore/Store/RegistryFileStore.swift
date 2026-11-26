import Foundation

public enum RegistryFileError: Error, LocalizedError {
    case unreadable(path: String, reason: String)
    case corrupt(path: String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason): "无法读取实例清单 \(path)：\(reason)"
        case let .corrupt(path): "实例清单 \(path) 格式损坏"
        case let .writeFailed(path, reason): "无法写入实例清单 \(path)：\(reason)"
        }
    }
}

public struct RegistryFileStore: Sendable {
    public let fileURL: URL
    public var backupURL: URL { fileURL.appendingPathExtension("bak") }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(paths: AppPaths) {
        self.init(fileURL: paths.baseURL.appending(path: "instances.json"))
    }

    /// 没有清单文件时返回空清单
    public func load(fileManager: FileManager = .default) throws -> RegistryDocument {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return RegistryDocument()
        }

        do {
            return try decode(at: fileURL)
        } catch RegistryFileError.corrupt {
            if fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)),
               let recovered = try? decode(at: backupURL) {
                return recovered
            }
            throw RegistryFileError.corrupt(path: fileURL.path(percentEncoded: false))
        }
    }

    private func decode(at url: URL) throws -> RegistryDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RegistryFileError.unreadable(path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(RegistryDocument.self, from: data)
        } catch {
            throw RegistryFileError.corrupt(path: url.path(percentEncoded: false))
        }
    }

    public func save(_ document: RegistryDocument, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw RegistryFileError.writeFailed(
                path: fileURL.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }
}
