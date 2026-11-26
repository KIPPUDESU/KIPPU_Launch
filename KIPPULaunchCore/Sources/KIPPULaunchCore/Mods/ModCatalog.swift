import CryptoKit
import Foundation

public struct ModTarget: Hashable, Sendable {
    public let game: String
    public let loader: LoaderKind
    public init?(game: String, loader: LoaderKind) {
        let game = game.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !game.isEmpty, loader != .vanilla, loader != .unknown else { return nil }
        self.game = game
        self.loader = loader
    }
}

public struct ModProject: Identifiable, Sendable, Hashable {
    public let id: String
    public let slug: String
    public let title: String
    public let summary: String
    public let chineseName: String?
    public let wikiID: Int?
    public var displayName: String { chineseName ?? title }
}

public struct ModRelease: Identifiable, Decodable, Sendable, Hashable {
    public struct File: Decodable, Sendable, Hashable {
        public let filename: String
        let url: URL
        let primary: Bool
        let hashes: [String: String]
        public let size: Int
    }
    struct Dependency: Decodable, Sendable, Hashable {
        let version_id: String?
        let project_id: String?
        let dependency_type: String
    }
    public let id: String
    public let project_id: String
    public let version_number: String
    public let version_type: String
    let date_published: String
    let loaders: [String]
    let game_versions: [String]
    let files: [File]
    let dependencies: [Dependency]

    public var jar: File? {
        let jars = files.filter { $0.filename.lowercased().hasSuffix(".jar") && safeComponent($0.filename) }
        return jars.first(where: \.primary) ?? (jars.count == 1 ? jars[0] : nil)
    }

    func supports(_ target: ModTarget) -> Bool {
        game_versions.contains(target.game) && loaders.contains(target.loader.rawValue) && jar != nil
    }
}

// Forge 和 Fabric 的移植版可能共用同一个百科词条
struct ModAliases: Sendable {
    struct Entry: Sendable {
        let slug: String
        let name: String
        let wikiID: Int
    }
    let entries: [Entry]
    let bySlug: [String: Entry]

    init(data: Data = Data()) {
        var rows: [Entry] = []
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            // 空行也占一个百科编号 最后一行是热度数据
            let newline = UInt8(ascii: "\n")
            guard let last = bytes.lastIndex(where: { $0 != newline }),
                  let trailerSeparator = bytes[..<last].lastIndex(of: newline) else { return }
            var start = 0
            var wikiID = 1
            while start <= trailerSeparator, let end = bytes[start...trailerSeparator].firstIndex(of: newline) {
                let row = bytes[start..<end]
                if row.contains(UInt8(ascii: "@")) {
                    let line = String(decoding: row, as: UTF8.self)
                    for part in line.split(separator: "¨") {
                        guard let divider = part.firstIndex(of: "|"),
                              let marker = part[..<divider].firstIndex(of: "@"),
                              let lastDivider = part.lastIndex(of: "|") else { continue }
                        let second = part[part.index(after: marker)..<divider]
                        let slug = second.isEmpty ? part[..<marker] : second
                        let raw = part[part.index(after: lastDivider)...]
                        let name = raw[..<(raw.range(of: " (")?.lowerBound ?? raw.endIndex)]
                        let title = name.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !slug.isEmpty, !title.isEmpty else { continue }
                        rows.append(Entry(slug: String(slug), name: title, wikiID: wikiID))
                    }
                }
                start = end + 1
                wikiID += 1
            }
        }
        entries = rows
        bySlug = Dictionary(rows.lazy.map { ($0.slug, $0) }, uniquingKeysWith: { old, _ in old })
    }

    func matches(_ query: String) -> [Entry] {
        guard query.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else { return [] }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.name == query ? 0 : 1, $0.name.count, $0.wikiID) < ($1.name == query ? 0 : 1, $1.name.count, $1.wikiID) }
    }
}

public struct ModResults: Sendable {
    public let projects: [ModProject]
    public let more: Bool
    public let indexUnavailable: Bool
}

public actor ModCatalog {
    private let network: URLSession
    private let cache: URL
    private var aliases: ModAliases?
    private var retryIndexAfter: Date?
    static let indexURL = URL(string: "https://raw.githubusercontent.com/ParadoxRin/Plain_Craft_Launcher_Refactoring_Core/v0.44.0/vendor/PCLCS/Resource/WikiEntries.txt")!
    static let indexSHA = "d1dc2a3807f2b39235f7d0e62e6650b09334826b0e66b35c98d5c79b5d2c0bfe"
    public init(cache: URL, network: URLSession = .shared) {
        self.cache = cache
        self.network = network
    }

    private func loadAliases() async throws -> ModAliases {
        if let aliases { return aliases }
        if let retryIndexAfter, retryIndexAfter > Date() { throw URLError(.resourceUnavailable) }
        let file = cache.appending(path: "pcl-wiki-entries-0.44.0.txt")
        func valid(_ data: Data) -> Bool {
            SHA256.hash(data: data).hexString == Self.indexSHA
        }
        let data: Data
        if let cached = try? Data(contentsOf: file), valid(cached) { data = cached }
        else {
            do {
                let request = URLRequest(url: Self.indexURL, timeoutInterval: 8)
                let (download, response) = try await DownloadTraffic.data(using: network, request: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, valid(download) else {
                    throw InstallError.message("中文索引校验失败。")
                }
                data = download
            } catch {
                try Task.checkCancellation()
                retryIndexAfter = Date().addingTimeInterval(30)
                throw error
            }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        let parsed = ModAliases(data: data)
        aliases = parsed
        return parsed
    }

    func api<T: Decodable>(_ route: String, query: [URLQueryItem] = [], body: Data? = nil, as type: T.Type) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.modrinth.com"
        components.path = "/v2/" + route
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 20
        request.setValue("KIPPU-Launch/1 (macOS mod manager)", forHTTPHeaderField: "User-Agent")
        let readOnlyLookup = route == "version_files" || route == "version_files/update"
        let (data, response) = try await DownloadTraffic.data(using: network, request: request, replayReadOnlyPOST: readOnlyLookup)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InstallError.message(code == 429 ? "Modrinth 请求过于频繁，请稍后重试。" : "Modrinth 请求失败（\(code)）。")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private struct Hit: Decodable {
        let project_id: String
        let slug: String
        let title: String
        let description: String
    }
    private struct Hits: Decodable {
        let hits: [Hit]
        let total_hits: Int
    }

    public func search(_ query: String, target: ModTarget?, page: Int = 0) async throws -> ModResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try? await loadAliases()
        try Task.checkCancellation()
        let aliases = index?.matches(query) ?? []
        var filters = [["project_type:mod"], ["client_side:required", "client_side:optional"]]
        if let target {
            filters += [["categories:" + target.loader.rawValue], ["versions:" + target.game]]
        }
        let facets = try json(filters)
        let offset = max(page, 0) * 20
        func find(_ term: String, offset: Int) async throws -> Hits {
            try await api("search", query: [.init(name: "facets", value: facets), .init(name: "query", value: term),
                .init(name: "limit", value: "20"), .init(name: "offset", value: String(offset))], as: Hits.self)
        }
        var hits: [Hit] = []
        let aliasPage = aliases.dropFirst(max(0, page) * 5).prefix(5)
        for entry in aliasPage {
            let translated = try await find(entry.slug, offset: 0)
            hits += translated.hits.filter { $0.slug == entry.slug }
        }
        let direct = try await find(query, offset: offset)
        hits += direct.hits
        var seen = Set<String>()
        let projects = hits.filter { seen.insert($0.project_id).inserted }.map { hit in
            let alias = index?.bySlug[hit.slug]
            return ModProject(id: hit.project_id, slug: hit.slug, title: hit.title, summary: hit.description, chineseName: alias?.name, wikiID: alias?.wikiID)
        }
        return ModResults(projects: projects, more: offset + direct.hits.count < direct.total_hits || aliases.count > (page + 1) * 5, indexUnavailable: index == nil)
    }

    public func releases(project: String, target: ModTarget?) async throws -> [ModRelease] {
        guard safeComponent(project) else { throw URLError(.badURL) }
        var query: [URLQueryItem] = []
        if let target {
            query = [.init(name: "loaders", value: try json([target.loader.rawValue])),
                     .init(name: "game_versions", value: try json([target.game]))]
        }
        let list = try await api("project/" + project + "/version", query: query, as: [ModRelease].self)
        return list.filter { release in
            guard release.project_id == project else { return false }
            if let target { return release.supports(target) }
            return release.jar != nil
        }.sorted { $0.date_published > $1.date_published }
    }

    public func installationPlan(_ root: ModRelease, target: ModTarget, installed: [String: ModRelease] = [:]) async throws -> [ModRelease] {
        var chosen: [String: ModRelease] = [:]
        var order: [ModRelease] = []
        func visit(_ item: ModRelease) async throws {
            try Task.checkCancellation()
            guard item.supports(target) else { throw InstallError.message("依赖 \(item.version_number) 不兼容当前实例。") }
            if let previous = chosen[item.project_id] {
                guard previous.id == item.id else { throw InstallError.message("依赖要求同一模组的两个版本，请另选版本。") }
                return
            }
            guard chosen.count < 128 else { throw InstallError.message("依赖数量过多。") }
            chosen[item.project_id] = item
            let required = item.dependencies.filter { $0.dependency_type == "required" }
            // 先处理指定版本的依赖 否则同一模组可能已被选成其他版本
            for dep in required.sorted(by: { $0.version_id != nil && $1.version_id == nil }) {
                let next: ModRelease
                if let id = dep.version_id {
                    guard safeComponent(id) else { throw InstallError.message("依赖版本标识无效。") }
                    if let project = dep.project_id, chosen[project]?.id == id { continue }
                    next = try await api("version/" + id, as: ModRelease.self)
                    guard next.id == id, dep.project_id == nil || next.project_id == dep.project_id else { throw InstallError.message("依赖元数据不一致。") }
                } else if let project = dep.project_id {
                    if chosen[project] != nil { continue }
                    if let current = installed[project], current.supports(target) {
                        try await visit(current)
                        continue
                    }
                    let list = try await releases(project: project, target: target)
                    guard let compatible = list.first(where: { $0.version_type == "release" }) ?? list.first else {
                        throw InstallError.message("找不到适配 \(target.game) · \(target.loader.displayName) 的依赖 \(project)。")
                    }
                    next = compatible
                } else { throw InstallError.message("发布者没有提供必需依赖的下载信息。") }
                try await visit(next)
            }
            order.append(item)
        }
        try await visit(root)
        return order
    }
}
