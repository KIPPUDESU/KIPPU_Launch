import CryptoKit
import Foundation

public struct AppPaths: Sendable, Hashable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func standard(
        fileManager: FileManager = .default,
        create: Bool = false
    ) throws -> AppPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let paths = AppPaths(baseURL: support.appending(path: "KIPPU_Launch", directoryHint: .isDirectory))
        if create {
            try paths.prepare(fileManager: fileManager)
        }
        return paths
    }

    public var libraries: URL { baseURL.appending(path: "libraries", directoryHint: .isDirectory) }

    public var assets: URL { baseURL.appending(path: "assets", directoryHint: .isDirectory) }

    public var runtime: URL { baseURL.appending(path: "runtime", directoryHint: .isDirectory) }

    public var managedInstances: URL { baseURL.appending(path: "instances", directoryHint: .isDirectory) }

    public var cache: URL { baseURL.appending(path: "cache", directoryHint: .isDirectory) }

    public var backgrounds: URL { baseURL.appending(path: "backgrounds", directoryHint: .isDirectory) }

    public var downloadCache: URL { cache.appending(path: "downloads", directoryHint: .isDirectory) }

    public var logs: URL { baseURL.appending(path: "logs", directoryHint: .isDirectory) }

    /// 同一目录重新登记后仍要找得到原来的世界备份
    public func worldBackups(for instance: InstanceRecord) -> URL {
        let key = SHA256.hash(data: Data(instance.identityCanonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseURL.appending(path: "world-backups").appending(path: key, directoryHint: .isDirectory)
    }

    public var allDirectories: [URL] {
        [baseURL, libraries, assets, runtime, managedInstances, cache, logs]
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in allDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func libraryFile(for coordinate: String) -> URL? {
        guard let relative = MavenCoordinate(coordinate)?.relativePath else { return nil }
        return libraries.appending(path: relative)
    }
}

public struct MavenCoordinate: Sendable, Hashable {
    public let groupID: String
    public let artifactID: String
    public let version: String
    public let classifier: String?
    public let fileExtension: String

    public init?(_ raw: String) {
        let (head, ext): (String, String)
        if let at = raw.lastIndex(of: "@") {
            head = String(raw[raw.startIndex..<at])
            ext = String(raw[raw.index(after: at)...])
        } else {
            head = raw
            ext = "jar"
        }

        let parts = head.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard !ext.isEmpty else { return nil }

        groupID = parts[0]
        artifactID = parts[1]
        version = parts[2]
        classifier = parts.count == 4 ? parts[3] : nil
        fileExtension = ext
    }

    public var relativePath: String {
        let groupPath = groupID.replacingOccurrences(of: ".", with: "/")
        let fileName = [artifactID, version, classifier]
            .compactMap { $0 }
            .joined(separator: "-")
        return "\(groupPath)/\(artifactID)/\(version)/\(fileName).\(fileExtension)"
    }
}
