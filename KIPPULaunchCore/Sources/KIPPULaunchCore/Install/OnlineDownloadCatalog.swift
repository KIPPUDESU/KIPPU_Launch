import Foundation

public enum OnlineDownloadKind: String, CaseIterable, Identifiable, Sendable {
    case modpack
    case resourcePack
    case shader
    case world

    public var id: Self { self }

    public var title: String {
        switch self {
        case .modpack: "整合包"
        case .resourcePack: "资源包"
        case .shader: "光影"
        case .world: "世界"
        }
    }

    var projectType: String {
        switch self {
        case .modpack: "modpack"
        case .resourcePack: "resourcepack"
        case .shader: "shader"
        case .world: "world"
        }
    }
}

public struct OnlineProject: Identifiable, Hashable, Sendable {
    public let id: String
    public let slug: String
    public let title: String
    public let summary: String
    public let downloads: Int?
    let worldArchive: URL?
}

public struct OnlineProjectFile: Hashable, Sendable {
    public let filename: String
    public let url: URL
    public let size: Int?
    public let sha1: String?
    public let sha512: String?
    public let primary: Bool
}

public struct OnlineProjectVersion: Identifiable, Hashable, Sendable {
    public let id: String
    public let projectID: String
    public let number: String
    public let type: String
    public let date: String
    public let files: [OnlineProjectFile]

    public func archive(for kind: OnlineDownloadKind) -> OnlineProjectFile? {
        let supported = files.filter {
            let name = $0.filename.lowercased()
            return safeComponent($0.filename) && !name.hasPrefix(".") && name.hasSuffix(kind == .modpack ? ".mrpack" : ".zip")
        }
        return supported.first(where: \.primary) ?? (supported.count == 1 ? supported.first : nil)
    }
}

public struct OnlineProjectResults: Sendable {
    public let projects: [OnlineProject]
    public let more: Bool
}

public actor OnlineDownloadCatalog {
    private var worlds: [OnlineProject]?
    private let network: URLSession

    private let cache: URL?
    private var recentWorld: WorldCopy?

    public init() {
        self.init(network: .shared, cache: try? AppPaths.standard().downloadCache)
    }

    public init(network: URLSession, cache: URL? = nil) {
        self.network = network
        self.cache = cache
    }

    /// ResourcePile 没有文件哈希 凭原服务器的 ETag 复用副本
    private final class WorldCopy {
        let source: URL
        let file: URL
        let etag: String

        init(source: URL, downloaded: URL, etag: String) throws {
            self.source = source
            self.etag = etag
            file = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
            try InstallNetwork.copy(downloaded, to: file)
        }

        deinit { try? FileManager.default.removeItem(at: file) }
    }

    private static func worldURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "s3.amazonaws.com" && url.path.hasPrefix("/autoreferee/maps/")
    }

    private func downloadWorld(_ source: URL, to destination: URL) async throws {
        guard Self.worldURL(source) else { throw InstallError.message("下载地址无效。") }
        let fileManager = FileManager.default
        let saved = recentWorld.flatMap { $0.source == source && fileManager.fileExists(atPath: $0.file.path) ? $0 : nil }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData)
        if let saved { request.setValue(saved.etag, forHTTPHeaderField: "If-None-Match") }
        let (temp, response) = try await DownloadTraffic.download(using: network, request: request)
        defer { try? fileManager.removeItem(at: temp) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let final = http.url, Self.worldURL(final) else {
            throw InstallError.message("文件下载失败。")
        }
        if http.statusCode == 304, let saved, final == source {
            try InstallNetwork.copy(saved.file, to: destination)
            return
        }
        guard http.statusCode == 200 else { throw InstallError.message("文件下载失败（\(http.statusCode)）。") }
        try fileManager.moveItem(at: temp, to: destination)
        let policy = http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty, final == source,
           !policy.contains("no-store"), http.value(forHTTPHeaderField: "Vary") == nil {
            recentWorld = try? WorldCopy(source: source, downloaded: destination, etag: etag)
        } else if recentWorld?.source == source {
            recentWorld = nil
        }
    }

    private struct Hit: Decodable {
        let projectID: String
        let slug: String
        let title: String
        let description: String
        let downloads: Int

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case slug, title, description, downloads
        }
    }

    private struct SearchResponse: Decodable {
        let hits: [Hit]
        let total: Int

        enum CodingKeys: String, CodingKey {
            case hits
            case total = "total_hits"
        }
    }

    private struct VersionResponse: Decodable {
        let id: String
        let projectID: String
        let versionNumber: String
        let versionType: String
        let datePublished: String
        let files: [FileResponse]

        enum CodingKeys: String, CodingKey {
            case id
            case projectID = "project_id"
            case versionNumber = "version_number"
            case versionType = "version_type"
            case datePublished = "date_published"
            case files
        }
    }

    private struct FileResponse: Decodable {
        let filename: String
        let url: URL
        let size: Int
        let hashes: [String: String]
        let primary: Bool
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func api<T: Decodable>(_ route: String, query: [URLQueryItem], as type: T.Type) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.modrinth.com"
        components.path = "/v2/" + route
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("KIPPU-Launch/1 (macOS download catalog)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await DownloadTraffic.data(using: network, request: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InstallError.message(status == 429
                ? "在线服务请求过于频繁，请稍后重试。"
                : "在线服务请求失败（\(status)）。")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public func search(_ kind: OnlineDownloadKind, query: String, gameVersion: String?, loader: LoaderKind?, page: Int = 0) async throws -> OnlineProjectResults {
        if kind == .world { return try await searchWorlds(query: query, page: page) }
        var facets = [["project_type:\(kind.projectType)"]]
        if let gameVersion, !gameVersion.isEmpty { facets.append(["versions:\(gameVersion)"]) }
        if kind == .modpack, let loader, loader != .unknown, loader != .vanilla {
            facets.append(["categories:\(loader.rawValue)"])
        }

        let response = try await api("search", query: [
            URLQueryItem(name: "query", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "facets", value: try json(facets)),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "offset", value: String(max(0, page) * 20))
        ], as: SearchResponse.self)

        return OnlineProjectResults(
            projects: response.hits.map {
                OnlineProject(id: $0.projectID, slug: $0.slug, title: $0.title, summary: $0.description, downloads: $0.downloads, worldArchive: nil)
            },
            more: (max(0, page) + 1) * 20 < response.total
        )
    }

    public func versions(_ project: OnlineProject, gameVersion: String?, loader: LoaderKind?) async throws -> [OnlineProjectVersion] {
        if let url = project.worldArchive {
            let file = OnlineProjectFile(filename: url.lastPathComponent, url: url, size: nil, sha1: nil, sha512: nil, primary: true)
            return [OnlineProjectVersion(id: project.id, projectID: project.id, number: url.deletingPathExtension().lastPathComponent,
                                         type: "地图存档", date: "", files: [file])]
        }
        var query = [URLQueryItem]()
        if let gameVersion, !gameVersion.isEmpty { query.append(URLQueryItem(name: "game_versions", value: try json([gameVersion]))) }
        if let loader, loader != .unknown, loader != .vanilla { query.append(URLQueryItem(name: "loaders", value: try json([loader.rawValue]))) }
        let response = try await api("project/\(project.id)/version", query: query, as: [VersionResponse].self)
        return response.map {
            OnlineProjectVersion(
                id: $0.id,
                projectID: $0.projectID,
                number: $0.versionNumber,
                type: $0.versionType,
                date: $0.datePublished,
                files: $0.files.map {
                    OnlineProjectFile(
                        filename: $0.filename,
                        url: $0.url,
                        size: $0.size,
                        sha1: $0.hashes["sha1"],
                        sha512: $0.hashes["sha512"],
                        primary: $0.primary
                    )
                }
            )
        }
    }

    private func searchWorlds(query: String, page: Int) async throws -> OnlineProjectResults {
        if worlds == nil {
            struct Catalog: Decodable {
                struct Collection: Decodable { let maps: [Map] }
                struct Map: Decodable {
                    struct Author: Decodable { let username: String }
                    let slug: String
                    let name: String
                    let authors: [Author]
                    let download: String?
                    enum CodingKeys: CodingKey { case slug, name, authors, download }
                    init(from decoder: Decoder) throws {
                        let row = try decoder.container(keyedBy: CodingKeys.self)
                        slug = try row.decode(String.self, forKey: .slug)
                        name = try row.decode(String.self, forKey: .name)
                        authors = try row.decode([Author].self, forKey: .authors)
                        // 地图没有直链时 download 字段可能是布尔值
                        download = try? row.decode(String.self, forKey: .download)
                    }
                }
                let data: Collection
            }
            let url = URL(string: "https://mcresourcepile.github.io/data/maps/rfw.json")!
            let data = try await InstallNetwork(session: network).data(url)
            worlds = try JSONDecoder().decode(Catalog.self, from: data).data.maps.compactMap { map in
                guard let link = map.download, var parts = URLComponents(string: link),
                      ["http", "https"].contains(parts.scheme), parts.user == nil, parts.password == nil,
                      parts.host == "s3.amazonaws.com", parts.path.hasPrefix("/autoreferee/maps/") else { return nil }
                parts.scheme = "https"
                guard let file = parts.url, file.pathExtension.lowercased() == "zip" else { return nil }
                return OnlineProject(id: map.slug, slug: map.slug, title: map.name,
                                     summary: map.authors.map(\.username).joined(separator: "、"),
                                     downloads: nil, worldArchive: file)
            }
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = (worlds ?? []).filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) || $0.summary.localizedCaseInsensitiveContains(term) }
        let offset = min(matches.count, max(0, page) * 20)
        return OnlineProjectResults(projects: Array(matches.dropFirst(offset).prefix(20)), more: offset + 20 < matches.count)
    }

    /// 返回文件所在的临时目录由调用方清理
    public func download(_ version: OnlineProjectVersion, kind: OnlineDownloadKind) async throws -> URL {
        guard let file = version.archive(for: kind) else { throw InstallError.message("此版本没有可安装的文件。") }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appending(component: file.filename)
        do {
            if kind == .world {
                try await downloadWorld(file.url, to: destination)
            } else {
                guard let hash = file.sha512 ?? file.sha1, let size = file.size else {
                    throw InstallError.message("缺少文件校验信息。")
                }
                let job = InstallFile(destination: destination, sources: [file.url], hash: hash, size: size)
                try await InstallNetwork(session: network).download(job, cache: cache) {
                    $0.scheme == "https" && ["cdn.modrinth.com", "cdn-raw.modrinth.com"].contains($0.host?.lowercased())
                }
            }
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return destination
    }
}
