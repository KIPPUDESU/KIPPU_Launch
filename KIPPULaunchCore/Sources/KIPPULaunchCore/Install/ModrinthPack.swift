import Foundation
import ZIPFoundation

public struct ModrinthPack {
    struct Index: Decodable {
        struct File: Decodable {
            let path: String
            let hashes: [String: String]
            let downloads: [URL]
            let fileSize: Int
            let env: [String: String]?
        }
        let name: String
        let game: String
        let formatVersion: Int
        let dependencies: [String: String]
        let files: [File]
    }
    let url: URL
    let index: Index
    let indexData: Data
    public let minecraft: String
    public var name: String { index.name }
    let loader: (key: String, value: String)?

    public init(url: URL) throws {
        self.url = url
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["modrinth.index.json"], entry.type == .file, entry.uncompressedSize <= 8_388_608 else {
            throw InstallError.message("整合包缺少有效的 modrinth.index.json。")
        }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 8_388_608 else { throw InstallError.message("整合包清单过大。") }
            data.append(chunk)
        }
        guard crc == entry.checksum else { throw InstallError.message("整合包清单损坏。") }
        indexData = data
        index = try JSONDecoder().decode(Index.self, from: data)
        guard index.game == "minecraft", index.formatVersion == 1, let version = index.dependencies["minecraft"], safeComponent(version) else {
            throw InstallError.message("这个文件不是支持的 Minecraft Modrinth 整合包。")
        }
        minecraft = version
        let extra = index.dependencies.filter { $0.key != "minecraft" }
        guard extra.count <= 1, extra.allSatisfy({ ["fabric-loader", "quilt-loader", "forge", "neoforge"].contains($0.key) && safeComponent($0.value) }) else {
            throw InstallError.message("整合包声明了不支持的加载器。")
        }
        loader = extra.first
    }

    private func destination(_ path: String, game: URL, instance: String) throws -> URL {
        let url = try installPath(path, in: game)
        let top = path.components(separatedBy: "/")[0].lowercased()
        guard !top.hasPrefix("."), ![instance.lowercased() + ".jar", instance.lowercased() + ".json", "modrinth.index.json"].contains(top) else {
            throw InstallError.message("整合包试图覆盖启动器文件：\(path)")
        }
        return url
    }

    func files(in game: URL, instance: String) throws -> [InstallFile] {
        var paths = Set<String>()
        return try index.files.filter { $0.env?["client"] != "unsupported" }.map { file in
            let out = try destination(file.path, game: game, instance: instance)
            guard paths.insert(file.path.lowercased()).inserted, file.fileSize >= 0,
                  let hash = file.hashes["sha512"] ?? file.hashes["sha1"] else { throw InstallError.message("整合包文件记录无效：\(file.path)") }
            let hosts = ["downloads.modrinth.com", "cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com", "cdn-raw.modrinth.com"]
            let sources = file.downloads.filter { $0.scheme == "https" && hosts.contains($0.host?.lowercased() ?? "") }
            guard !sources.isEmpty else { throw InstallError.message("文件缺少受支持的下载地址：\(file.path)") }
            return InstallFile(destination: out, sources: sources, hash: hash, size: file.fileSize)
        }
    }

    func extractOverrides(in game: URL, instance: String) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var total = 0
        for prefix in ["overrides/", "client-overrides/"] {
            for entry in archive where entry.path.hasPrefix(prefix) && entry.type != .directory {
                try Task.checkCancellation()
                guard entry.type == .file, entry.uncompressedSize <= 1 << 30 else { throw InstallError.message("无效的覆盖文件：\(entry.path)") }
                let output = try destination(String(entry.path.dropFirst(prefix.count)), game: game, instance: instance)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                let bufferSize = Int(min(max(1, entry.uncompressedSize), 128 * 1024))
                let crc = try archive.extract(entry, bufferSize: bufferSize) { chunk in
                    try Task.checkCancellation()
                    total += chunk.count
                    guard total <= 4 << 30 else { throw InstallError.message("整合包解压体积过大。") }
                    try handle.write(contentsOf: chunk)
                }
                guard crc == entry.checksum else { throw InstallError.message("整合包文件损坏：\(entry.path)") }
            }
        }
    }
}

extension GameInstaller {
    func loaderProfile(_ loader: (key: String, value: String), base: VersionJSON, raw: Data, jar: URL,
                       dataRoot: URL, java: [JavaRuntime], cache: URL) async throws -> VersionJSON {
        let version = loader.value
        guard [version, base.id].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,43,95].contains($0) } }) else {
            throw InstallError.message("加载器版本标识无效。")
        }
        if loader.key == "fabric-loader" || loader.key == "quilt-loader" {
            let endpoint = loader.key == "fabric-loader" ? "https://meta.fabricmc.net/v2" : "https://meta.quiltmc.org/v3"
            let source = URL(string: "\(endpoint)/versions/loader/\(base.id)/\(version)/profile/json")!
            let profile = try JSONDecoder().decode(VersionJSON.self, from: await net.data(source))
            guard profile.inheritsFrom == base.id else { throw InstallError.message("加载器与游戏版本不匹配。") }
            return profile
        }
        let runtime: JavaRuntime
        switch JavaLocator().select(requiredMajor: base.javaVersion?.majorVersion, hostArchitecture: HostArchitecture.current, from: java) {
        case let .exact(r), let .fallback(r, _): runtime = r
        default: throw InstallError.message("安装 \(loader.key) 需要 Java \(base.javaVersion?.majorVersion ?? 8)，请先安装对应的 JDK。")
        }
        let coordinate = base.id + "-" + version
        let address = loader.key == "forge"
            ? "https://maven.minecraftforge.net/net/minecraftforge/forge/\(coordinate)/forge-\(coordinate)-installer.jar"
            : "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(version)/neoforge-\(version)-installer.jar"
        let source = URL(string: address)!
        let sha = String(decoding: try await net.data(source.appendingPathExtension("sha1")), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installer = dataRoot.appending(path: "loader-installer.jar")
        try await net.download(InstallFile(destination: installer, sources: [source], hash: sha), cache: cache)
        let versions = dataRoot.appending(path: "versions")
        let vanilla = try installPath(base.id, in: versions)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: vanilla, withIntermediateDirectories: true)
        try raw.write(to: vanilla.appending(path: base.id + ".json"))
        try fileManager.copyItem(at: jar, to: vanilla.appending(path: base.id + ".jar"))
        try Data(#"{"profiles":{}}"#.utf8).write(to: dataRoot.appending(path: "launcher_profiles.json"))
        let job = Process()
        job.executableURL = runtime.executable
        job.arguments = ["-jar", installer.path, "--installClient", dataRoot.path]
        job.currentDirectoryURL = dataRoot
        job.standardOutput = FileHandle.nullDevice
        job.standardError = FileHandle.nullDevice
        try await DownloadTraffic.checkpoint()
        try job.run()
        do {
            while job.isRunning {
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            if job.isRunning { job.terminate() }
            job.waitUntilExit()
            throw error
        }
        guard job.terminationStatus == 0 else { throw InstallError.message("\(loader.key) 安装器退出，状态码 \(job.terminationStatus)。") }
        for folder in try fileManager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) where folder.lastPathComponent != base.id {
            let file = folder.appending(path: folder.lastPathComponent + ".json")
            if let profile = try? JSONDecoder().decode(VersionJSON.self, from: Data(contentsOf: file)), profile.inheritsFrom == base.id {
                return profile
            }
        }
        throw InstallError.message("加载器未生成对应的客户端版本配置。")
    }
}
