import KIPPULaunchCore
import SwiftUI

struct OnlineModsView: View {
    let target: ModTarget?
    let catalog: ModCatalog
    let library: InstanceMods?
    let allowExternal: Bool
    let canEdit: Bool

    @State private var query = ""
    @State private var page = 0
    @State private var retry = 0
    @State private var rows: [ModProject] = []
    @State private var more = false
    @State private var loading = true
    @State private var error: String?
    @State private var noIndex = false
    @State private var selected: ModProject?
    private struct Search: Hashable {
        let term: String
        let page: Int
        let retry: Int
    }

    var body: some View {
        DownloadCatalogPanel(title: "模组", searchPrompt: "搜索模组，例如「钠」或 Sodium",
                             query: $query, page: $page, items: rows, hasNextPage: more, loading: loading,
                             error: error, notice: noIndex ? "中文索引暂不可用，可用英文名称搜索。" : nil,
                             retry: { retry += 1 }) {
            if let target { Text("\(target.game) · \(target.loader.displayName)").font(.callout).foregroundStyle(.secondary) }
        } sources: {
            Link("Modrinth", destination: URL(string: "https://modrinth.com/mods")!)
            Link("中文索引", destination: URL(string: "https://github.com/ParadoxRin/Plain_Craft_Launcher_Refactoring_Core/releases/tag/v0.44.0")!)
                .help("PCLCS / MC百科")
        } row: { project in
            DownloadProjectRow(title: project.displayName,
                               originalTitle: project.chineseName != nil && project.title != project.displayName ? project.title : nil,
                               summary: project.summary) { selected = project }
        }
        .task(id: Search(term: query, page: page, retry: retry)) {
            loading = true
            error = nil
            more = false
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
                let result = try await catalog.search(query, target: target, page: page)
                try Task.checkCancellation()
                rows = result.projects
                more = result.more
                noIndex = result.indexUnavailable
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
        .sheet(item: $selected) { project in
            ModDownloadSheet(project: project, target: target, catalog: catalog, library: library,
                             allowExternal: allowExternal, canEdit: canEdit)
        }
    }
}

private struct ModDownloadSheet: View {
    let project: ModProject
    let target: ModTarget?
    let catalog: ModCatalog
    let library: InstanceMods?
    let allowExternal: Bool
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var releases: [ModRelease] = []
    @State private var selected = ""
    @State private var plan: [ModRelease] = []
    @State private var loading = true
    @State private var planning = false
    @Environment(DownloadCenter.self) private var downloads
    @State private var problem: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.displayName).font(.title2.bold())
            HStack {
                if let target { Text("\(target.game) · \(target.loader.displayName)").foregroundStyle(.secondary) }
                Spacer()
                Link("项目主页", destination: URL(string: "https://modrinth.com")!.appending(path: "mod/" + project.slug))
                if let id = project.wikiID { Link("MC百科", destination: URL(string: "https://www.mcmod.cn/class/\(id).html")!) }
            }
            Divider()
            if loading { ProgressView("正在获取兼容版本…") }
            else if !releases.isEmpty {
                Picker("版本", selection: $selected) {
                    ForEach(releases) { version in
                        Text("\(version.version_number) · \(version.version_type)").tag(version.id)
                    }
                }
                if planning { ProgressView("正在检查必需依赖…") }
                else if !plan.isEmpty {
                    Text("安装文件（\(plan.count)）").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(plan) { item in
                                Label(item.jar?.filename ?? item.version_number,
                                      systemImage: item.id == selected ? "puzzlepiece.extension" : "link")
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 145)
                }
            } else if problem == nil { Text(target == nil ? "此项目没有可安装的客户端 JAR。" : "此项目没有适配当前实例的客户端 JAR。") }
            if let problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
                Button("重新获取版本") {
                    selected = ""
                    plan = []
                    retry += 1
                }
            }
            if target == nil { Text("选择装有模组加载器的目标实例后，即可安装兼容版本。").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("安装到此实例") { download() }
                    .disabled(!canEdit || loading || planning || plan.last?.id != selected)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 510)
        .task(id: retry) {
            loading = true
            problem = nil
            do {
                let items = try await catalog.releases(project: project.id, target: target)
                try Task.checkCancellation()
                releases = items
                selected = (items.first { $0.version_type == "release" } ?? items.first)?.id ?? ""
            } catch {
                if Task.isCancelled { return }
                problem = error.localizedDescription
            }
            loading = false
        }
        .task(id: selected) {
            plan = []
            guard let target, let item = releases.first(where: { $0.id == selected }) else { return }
            problem = nil
            planning = true
            do {
                let result = try await catalog.installationPlan(item, target: target)
                try Task.checkCancellation()
                plan = result
            } catch {
                if Task.isCancelled { return }
                problem = error.localizedDescription
            }
            planning = false
        }
    }

    private func download() {
        guard canEdit, target != nil, let library, !plan.isEmpty, plan.last?.id == selected else { return }
        let instance = library.instance
        let plan = plan
        let allow = allowExternal
        downloads.enqueue(key: "\(instance.id)/mod/\(selected)", title: project.displayName, category: .mod,
                          target: instance.displayName, instanceID: instance.id) { job in
            job.report("下载模组及依赖", total: plan.count, expectedBytes: plan.count == 1 ? plan.first?.jar?.size : nil)
            let count = try await library.install(plan, allowExternal: allow) { done, total in
                await job.report("下载模组及依赖", done: done, total: total)
            }
            return count == 0 ? "文件均已安装" : "已安装 \(count) 个文件"
        }
        dismiss()
    }
}
