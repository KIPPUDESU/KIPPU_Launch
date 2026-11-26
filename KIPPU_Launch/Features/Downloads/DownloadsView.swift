import KIPPULaunchCore
import SwiftUI

struct DownloadsView: View {
    let section: DownloadSection
    let library: InstanceLibrary
    let launcher: LaunchController
    @State private var catalog = OnlineDownloadCatalog()
    @State private var modCatalog = ModCatalog(cache: (try? AppPaths.standard().cache) ?? FileManager.default.temporaryDirectory)
    @State private var selectedID: UUID?
    @State private var authorizedID: UUID?
    @State private var confirmingAccess = false

    private var instances: [InstanceRecord] { library.instances.filter { !$0.isMissing } }
    private var target: InstanceRecord? { instances.first { $0.id == selectedID } }
    private var targetsInstance: Bool { section != .game && section != .modpack }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: section.title + "下载", subtitle: subtitle) {
                if targetsInstance {
                    Picker("目标实例", selection: $selectedID) {
                        Text("选择实例").tag(UUID?.none)
                        ForEach(instances) { item in
                            Text(library.displayName(for: item)).tag(Optional(item.id))
                        }
                    }
                    .frame(maxWidth: 260)
                }
            }
            Divider()
            switch section {
            case .game:
                GameDownloadPage(runtimes: launcher.javaRuntimes, onInstalled: library.registerInstalled)
            case .modpack:
                OnlineArchiveBrowser(kind: .modpack, target: nil, catalog: catalog, allowExternal: false, canInstall: true,
                                     runtimes: launcher.javaRuntimes, registerPack: library.registerInstalled)
            case .mod:
                if let target {
                    ModManagerSheet(instance: target, isBusy: busy(target), presentation: .downloads)
                        .id(target.id)
                } else {
                    OnlineModsView(target: nil, catalog: modCatalog, library: nil,
                                   allowExternal: false, canEdit: false)
                }
            case .shader, .resourcePack, .world:
                let kind: OnlineDownloadKind = section == .world ? .world : (section == .shader ? .shader : .resourcePack)
                let authorized = target != nil && authorizedID == target?.id
                if let target, busy(target) || (!target.kind.isWritable && !authorized) {
                    HStack {
                        Label(busy(target) ? "退出游戏后可安装" : "外部实例 · 只读", systemImage: "lock")
                        Spacer()
                        if !busy(target) { Button("允许本次安装") { confirmingAccess = true } }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                }
                OnlineArchiveBrowser(kind: kind, target: target, catalog: catalog, allowExternal: authorized,
                                     canInstall: target.map { !busy($0) && ($0.kind.isWritable || authorized) } ?? false)
                    .id(BrowserTarget(section: section, instance: target?.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: instances.map(\.id), initial: true) {
            if target == nil { selectedID = (instances.first { $0.kind.isWritable } ?? instances.first)?.id }
        }
        .onChange(of: selectedID) {
            authorizedID = nil
            confirmingAccess = false
        }
        .onChange(of: section) {
            authorizedID = nil
            confirmingAccess = false
        }
        .confirmationDialog("允许安装到此外部实例？", isPresented: $confirmingAccess, titleVisibility: .visible, presenting: target) { item in
            Button("允许本次安装") { authorizedID = item.id }
        } message: { item in Text("文件将写入「\(library.displayName(for: item))」的游戏目录。") }
    }

    private struct BrowserTarget: Hashable {
        let section: DownloadSection
        let instance: UUID?
    }
    private func busy(_ item: InstanceRecord) -> Bool { launcher.isRunning(item) || launcher.preparing.contains(item.id) }
    private var subtitle: String {
        switch section {
        case .game: "Minecraft Java 版 · Mojang"
        case .world: "Race for Wool 地图 · ResourcePile"
        case .modpack: "Modrinth · 安装为新实例"
        default: "Modrinth"
        }
    }
}
