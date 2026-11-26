import KIPPULaunchCore
import SwiftUI

struct OnlineDownloadVersionSheet: View {
    let project: OnlineProject
    let kind: OnlineDownloadKind
    let target: InstanceRecord?
    let gameVersion: String?
    let catalog: OnlineDownloadCatalog
    let allowExternal: Bool
    let canInstall: Bool
    let runtimes: [JavaRuntime]
    let registerPack: ((URL) throws -> Void)?
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [OnlineProjectVersion] = []
    @State private var selectedID = ""
    @State private var loading = true
    @State private var retry = 0
    @State private var name = ""
    @State private var problem: String?

    private var selected: OnlineProjectVersion? { versions.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.title).font(.title2.weight(.semibold))
            if kind == .modpack { TextField("实例名称", text: $name) }
            if let target { LabeledContent("目标实例", value: target.name) }
            if kind == .world { Text("这是一张 Java 版竞赛地图。比赛规则需要对应的服务端插件。").foregroundStyle(.secondary) }
            if loading { ProgressView("正在读取文件信息…") }
            else if versions.isEmpty && problem == nil { Text("没有找到可安装的版本。") }
            else if let selected {
                if versions.count > 1 {
                    Picker("版本", selection: $selectedID) {
                        ForEach(versions) { Text("\($0.number) · \($0.type)").tag($0.id) }
                    }
                }
                if let file = selected.archive(for: kind) {
                    LabeledContent("文件", value: file.filename)
                    if let size = file.size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                }
            }
            if !canInstall {
                Text(target == nil ? "请先在下载页选择目标实例。" : "请先退出游戏，并允许写入目标实例。").foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
                if versions.isEmpty { Button("重新获取") { retry += 1 } }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载并安装") { download() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall || selected == nil || (kind == .modpack && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20).frame(width: 510)
        .onAppear { name = project.title }
        .task(id: retry) {
            loading = true
            problem = nil
            do {
                let all = try await catalog.versions(project, gameVersion: gameVersion, loader: nil)
                try Task.checkCancellation()
                versions = all.filter { $0.archive(for: kind) != nil }
                selectedID = (versions.first { $0.type == "release" } ?? versions.first)?.id ?? ""
            } catch {
                if !Task.isCancelled {
                    problem = error.localizedDescription
                }
            }
            loading = false
        }
    }

    private func download() {
        guard let selected, canInstall else { return }
        let expected = selected.archive(for: kind)?.size
        let catalog = catalog
        let kind = kind
        if kind == .modpack, let registerPack {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let installation = GameInstallation(runtimes: runtimes, register: registerPack)
            downloads.enqueue(key: "instance/" + name.lowercased(), title: name, category: .modpack, target: selected.number) { job in
                try await installation.run(version: selected.number, name: name, job: job, pack: {
                    job.report("下载整合包", expectedBytes: expected)
                    return try await catalog.download(selected, kind: .modpack)
                }, removeDownloadedPack: true)
            }
        } else if let target {
            let category: DownloadSection = kind == .world ? .world : (kind == .shader ? .shader : .resourcePack)
            let allow = allowExternal
            downloads.enqueue(key: "\(target.id)/\(kind.rawValue)/\(selected.id)", title: project.title, category: category,
                              target: target.displayName, instanceID: target.id) { job in
                job.report("下载" + kind.title, expectedBytes: expected)
                let url = try await catalog.download(selected, kind: kind)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                try await DownloadTraffic.checkpoint()
                job.report("安装" + kind.title)
                if kind == .world {
                    let world = try await WorldBackups(instance: target).importArchive(url, allowExternal: allow)
                    return "已导入世界「\(world.name)」"
                }
                try await InstancePacks(instance: target).importPack(url, kind: kind == .shader ? .shaders : .resources, allowExternal: allow)
                return "已安装"
            }
        }
        dismiss()
    }
}
