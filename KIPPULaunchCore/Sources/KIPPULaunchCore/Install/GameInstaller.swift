import Foundation

public enum InstallError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case let .message(text): return text } }
}

public struct GameRelease: Decodable, Identifiable, Sendable {
    public let id: String
    public let type: String
    let url: URL
    let sha1: String
    private let releaseTime: String?

    public enum Category: CaseIterable, Sendable {
        case release, snapshot, aprilFools, historical
    }

    // Mojang 把愚人节版本列为快照 光看发布日期会分错
    public var category: Category? {
        switch type {
        case "release": return .release
        case "old_alpha", "old_beta": return .historical
        case "snapshot":
            switch id {
            case "15w14a", "1.RV-Pre1", "3D Shareware v1.34", "20w14infinite",
                 "22w13oneblockatatime", "23w13a_or_b", "24w14potato", "25w14craftmine", "26w14a":
                return .aprilFools
            default: return .snapshot
            }
        default: return nil
        }
    }

    public var releaseDate: Date? {
        releaseTime.flatMap { try? Date($0, strategy: .iso8601) }
    }
}

struct InstallFile: Sendable {
    let destination: URL
    let sources: [URL]
    let hash: String
    var size: Int? = nil
}

func installPath(_ path: String, in root: URL) throws -> URL {
    let parts = path.components(separatedBy: "/")
    guard parts.allSatisfy(safeComponent) else { throw InstallError.message("文件路径无效：\(path)") }
    return root.appending(path: path)
}

public struct GameInstaller: Sendable {
    public typealias Progress = @Sendable (String, Int, Int) async -> Void
    let paths: AppPaths
    let net: InstallNetwork
    public init(paths: AppPaths, session: URLSession = .shared) {
        self.paths = paths
        self.net = InstallNetwork(session: session)
    }

    public func releases() async throws -> [GameRelease] {
        struct Manifest: Decodable { var versions: [GameRelease] }
        let data = try await net.data(URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!)
        return try JSONDecoder().decode(Manifest.self, from: data).versions
    }

    public func install(version: String, name: String, packURL: URL? = nil, java: [JavaRuntime] = [],
                        progress: @escaping Progress) async throws -> URL {
        let fileManager = FileManager.default
        try paths.prepare()
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeComponent(targetName), !targetName.hasPrefix(".") else { throw InstallError.message("请输入有效的实例名称。") }
        let target = paths.managedInstances.appending(path: targetName)
        guard !fileManager.fileExists(atPath: target.path) else { throw InstallError.message("该名称的实例目录已存在，请换一个名称。") }
        let staging = paths.cache.appending(path: UUID().uuidString)
        let game = staging.appending(path: targetName)
        let dataRoot = game.appending(path: ".kippu-data")
        let cache = paths.downloadCache
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let pack = try packURL.map(ModrinthPack.init(url:))
        let wanted = pack?.minecraft ?? version
        await progress("获取游戏版本", 0, 0)
        guard let release = try await releases().first(where: { $0.id == wanted }) else {
            throw InstallError.message("官方清单中找不到 Minecraft \(wanted)。")
        }
        let manifest = staging.appending(component: ".version.json")
        try await net.download(InstallFile(destination: manifest, sources: [release.url], hash: release.sha1), cache: cache)
        let raw = try Data(contentsOf: manifest, options: .mappedIfSafe)
        let base = try JSONDecoder().decode(VersionJSON.self, from: raw)
        guard base.id == wanted, let client = base.downloads?.client, let hash = client.sha1,
              let clientURL = URL(string: client.url), let index = base.assetIndex,
              let indexURL = index.url.flatMap(URL.init(string:)), let indexHash = index.sha1 else {
            throw InstallError.message("这个版本缺少客户端或素材清单。")
        }
        let jar = game.appending(path: targetName + ".jar")
        var files = [InstallFile(destination: jar, sources: [clientURL], hash: hash, size: client.size)]
        async let libraries = libraryFiles(base, root: dataRoot)
        let indexFile = try installPath("assets/indexes/" + index.id + ".json", in: dataRoot)
        try await net.download(InstallFile(destination: indexFile, sources: [indexURL], hash: indexHash, size: index.size), cache: cache)
        let indexData = try Data(contentsOf: indexFile, options: .mappedIfSafe)
        struct AssetMap: Decodable {
            struct Object: Decodable {
                let hash: String
                let size: Int
            }
            let objects: [String: Object]
            var virtual: Bool?
            var map_to_resources: Bool?
        }
        let assets = try JSONDecoder().decode(AssetMap.self, from: indexData)
        for object in assets.objects.values {
            guard object.hash.count == 40, object.hash.allSatisfy(\.isHexDigit) else { throw InstallError.message("素材清单损坏。") }
            let key = "\(object.hash.prefix(2))/\(object.hash)"
            files.append(InstallFile(destination: dataRoot.appending(path: "assets/objects/" + key),
                sources: [URL(string: "https://resources.download.minecraft.net/" + key)!], hash: object.hash, size: object.size))
        }
        if let log = base.logging?.client?.file, let source = URL(string: log.url), let hash = log.sha1 {
            files.append(InstallFile(destination: try installPath("assets/log_configs/" + source.lastPathComponent, in: dataRoot),
                sources: [source], hash: hash, size: log.size))
        }
        files += try await libraries
        try await fetch(files, cache: cache, progress: progress)
        if assets.virtual == true || assets.map_to_resources == true {
            for (name, object) in assets.objects {
                let key = "\(object.hash.prefix(2))/\(object.hash)"
                for root in [assets.virtual == true ? dataRoot.appending(path: "assets/virtual/" + index.id) : nil,
                             assets.map_to_resources == true ? game.appending(path: "resources") : nil].compactMap({ $0 }) {
                    let out = try installPath(name, in: root)
                    try fileManager.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try InstallNetwork.copy(dataRoot.appending(path: "assets/objects/" + key), to: out)
                }
            }
        }
        var profile = base
        if let pack {
            if let loader = pack.loader {
                await progress("安装 \(loader.key)", 0, 0)
                let patch = try await loaderProfile(loader, base: profile, raw: raw, jar: jar, dataRoot: dataRoot, java: java, cache: cache)
                try await fetch(try await libraryFiles(patch, root: dataRoot), cache: cache, progress: progress)
                profile = VersionInheritance.merge(profile, patch)
            }
            try await fetch(try pack.files(in: game, instance: targetName), cache: cache, progress: progress)
            try await DownloadTraffic.checkpoint()
            try pack.extractOverrides(in: game, instance: targetName)
            try pack.indexData.write(to: game.appending(path: "modrinth.index.json"), options: .atomic)
        }
        try await DownloadTraffic.checkpoint()
        try Data(wanted.utf8).write(to: dataRoot.appending(path: "minecraft-version"))
        profile.id = targetName
        profile.jar = targetName
        profile.inheritsFrom = nil
        try JSONEncoder().encode(profile).write(to: game.appending(path: targetName + ".json"), options: .atomic)
        try fileManager.moveItem(at: game, to: target)
        return target
    }

    func fetch(_ files: [InstallFile], cache: URL, progress: @escaping Progress) async throws {
        var hashes: [URL: String] = [:]
        var jobs: [InstallFile] = []
        for file in files {
            if let prior = hashes.updateValue(file.hash, forKey: file.destination) {
                guard prior == file.hash else { throw InstallError.message("版本清单中的文件发生冲突：\(file.destination.lastPathComponent)") }
            } else { jobs.append(file) }
        }
        let total = jobs.count
        guard total > 0 else { return }
        await progress("下载并校验文件", 0, total)
        var next = jobs.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueue(_ file: InstallFile) { group.addTask { try await self.net.download(file, cache: cache) } }
            for _ in 0..<12 { if let file = next.next() { enqueue(file) } }
            var done = 0
            while try await group.next() != nil {
                done += 1
                if let file = next.next() { enqueue(file) }
                if done == 1 || done % 16 == 0 || done == total { await progress("下载并校验文件", done, total) }
            }
        }
    }

    func libraryFiles(_ profile: VersionJSON, root: URL) async throws -> [InstallFile] {
        struct MissingHash: Sendable {
            let destination: URL
            let source: URL
            let size: Int?
        }
        var files: [InstallFile] = []
        var missing: [MissingHash] = []
        let resolver = LibraryResolver(evaluator: .current())
        for lib in profile.libraries ?? [] {
            let needed = resolver.resolve([lib])
            for path in needed.classpathEntries + needed.nativeArchives.map(\.relativePath) {
                let destination = try installPath("libraries/" + path, in: root)
                // Forge 安装器可能已经在这里生成了补丁库
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                let artifacts = [lib.downloads?.artifact].compactMap { $0 } + Array((lib.downloads?.classifiers ?? [:]).values)
                let artifact = artifacts.first { $0.path == path } ?? lib.downloads?.artifact
                let base = lib.url.flatMap(URL.init(string:)) ?? URL(string: "https://libraries.minecraft.net")!
                let source = artifact.flatMap { URL(string: $0.url) } ?? base.appending(path: path)
                if let hash = artifact?.sha1 {
                    files.append(InstallFile(destination: destination, sources: [source], hash: hash, size: artifact?.size))
                } else {
                    missing.append(MissingHash(destination: destination, source: source, size: artifact?.size))
                }
            }
        }
        files += try await mapDownloads(missing, limit: 6) { item in
            let data = try await net.data(item.source.appendingPathExtension("sha1"))
            let hash = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
            return InstallFile(destination: item.destination, sources: [item.source], hash: hash.map(String.init) ?? "", size: item.size)
        }
        return files
    }
}
