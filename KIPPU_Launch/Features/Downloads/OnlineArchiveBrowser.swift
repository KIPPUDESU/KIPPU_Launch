import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct OnlineArchiveBrowser: View {
    let kind: OnlineDownloadKind
    let target: InstanceRecord?
    let catalog: OnlineDownloadCatalog
    let allowExternal: Bool
    let canInstall: Bool
    var runtimes: [JavaRuntime] = []
    var registerPack: ((URL) throws -> Void)?
    @State private var importing = false
    @State private var localPack: URL?
    @State private var query = ""
    @State private var page = 0
    @State private var retry = 0
    @State private var results: [OnlineProject] = []
    @State private var more = false
    @State private var loading = true
    @State private var error: String?
    @State private var selected: OnlineProject?
    private struct SearchKey: Hashable {
        let query: String
        let page: Int
        let retry: Int
    }

    private var gameVersion: String? {
        guard kind != .world, let target else { return nil }
        if let version = target.minecraftVersion { return version }
        let id = target.versionIdentifier
        return id.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil ? id : nil
    }

    var body: some View {
        DownloadCatalogPanel(title: kind.title, searchPrompt: "搜索" + kind.title,
                             query: $query, page: $page, items: results, hasNextPage: more,
                             loading: loading, error: error, retry: { retry += 1 }) {
            if let gameVersion { Text(gameVersion).font(.callout).foregroundStyle(.secondary) }
            if kind == .modpack { Button("导入 MRPACK") { importing = true } }
        } sources: {
            if kind == .world { Link("ResourcePile", destination: URL(string: "https://mcresourcepile.github.io/maps/rfw")!) }
            else { Link("Modrinth", destination: URL(string: "https://modrinth.com")!) }
        } row: { project in
            DownloadProjectRow(title: project.title, summary: project.summary,
                               actionTitle: kind == .world ? "查看地图" : "查看版本") { selected = project }
        }
        .task(id: SearchKey(query: query, page: page, retry: retry)) {
            loading = true
            error = nil
            more = false
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(280)) }
                let result = try await catalog.search(kind, query: query, gameVersion: gameVersion, loader: nil, page: page)
                try Task.checkCancellation()
                results = result.projects
                more = result.more
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
        .sheet(item: $selected) { project in
            OnlineDownloadVersionSheet(project: project, kind: kind, target: target, gameVersion: gameVersion,
                                       catalog: catalog, allowExternal: allowExternal, canInstall: canInstall,
                                       runtimes: runtimes, registerPack: registerPack)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "mrpack") ?? .archive]) {
            if case let .success(url) = $0 { localPack = url }
        }
        .sheet(isPresented: Binding(get: { localPack != nil }, set: { if !$0 { localPack = nil } })) {
            if let localPack, let registerPack { InstallSheet(pack: localPack, runtimes: runtimes, onInstalled: registerPack) }
        }
    }
}
