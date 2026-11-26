import AppKit
import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct PackManagerSheet: View {
    let instance: InstanceRecord
    let isBusy: Bool
    @State private var store: InstancePacks
    let kind: PackKind
    @State private var listing: InstancePacks.Listing?
    @State private var listedKind: PackKind?
    @Environment(DownloadCenter.self) private var downloads
    @State private var revision = 0
    private struct Scan: Equatable {
        let kind: PackKind
        let revision: Int
    }
    @State private var working = false
    @State private var external = false
    @State private var confirmingAccess = false
    @State private var removing: InstalledPack?
    @State private var problem: String?
    @State private var readError: String?
    @State private var online = false
    @State private var catalog = OnlineDownloadCatalog()

    init(instance: InstanceRecord, kind: PackKind, isBusy: Bool) {
        self.instance = instance
        self.isBusy = isBusy
        self.kind = kind
        _store = State(initialValue: InstancePacks(instance: instance))
    }

    private var canEdit: Bool { !isBusy && !working && (instance.kind.isWritable || external) }
    private var symbol: String { kind == .shaders ? "sun.max" : "square.3.layers.3d" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("来源", selection: $online) {
                    Text("已安装").tag(false)
                    Text("在线下载").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if !online {
                    Button("导入", systemImage: "plus") { chooseFiles() }.disabled(!canEdit)
                    Button("刷新", systemImage: "arrow.clockwise") { revision += 1 }
                        .labelStyle(.iconOnly).help("重新扫描当前目录").disabled(working)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if isBusy || (!instance.kind.isWritable && !external) {
                HStack {
                    Label(isBusy ? "游戏运行或准备期间只可查看" : "外部实例 · 只读", systemImage: "lock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isBusy {
                        Button("允许本次管理") { confirmingAccess = true }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
            }
            if online {
                OnlineArchiveBrowser(kind: kind == .shaders ? .shader : .resourcePack, target: instance,
                                     catalog: catalog, allowExternal: external, canInstall: canEdit)
            } else if let listing, listedKind == kind {
                if listing.items.isEmpty {
                    ContentUnavailableView("还没有\(kind.title)", systemImage: symbol,
                                           description: Text("可导入 ZIP 文件或已解压的包文件夹。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let active = listing.items.prefix { $0.enabled == true }
                    List(listing.items) { pack in
                        HStack(spacing: 10) {
                            Image(systemName: pack.directory ? "folder" : "doc.zipper")
                                .foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pack.name).lineLimit(2).help(pack.name)
                                Text(pack.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "文件夹")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if kind == .resources && pack.enabled == true && active.count > 1 {
                                Menu("材质优先级", systemImage: "arrow.up.arrow.down") {
                                    Button("提高优先级") {
                                        perform { try await store.movePriority(pack, higher: true, allowExternal: external) }
                                    }.disabled(pack.id == active.first?.id)
                                    Button("降低优先级") {
                                        perform { try await store.movePriority(pack, higher: false, allowExternal: external) }
                                    }.disabled(pack.id == active.last?.id)
                                }
                                .labelStyle(.iconOnly).fixedSize().disabled(!canEdit)
                                .help("已启用的材质包按优先级从高到低排列")
                            }
                            if let enabled = pack.enabled {
                                Toggle("启用 \(pack.name)", isOn: Binding(get: { enabled }, set: { value in
                                    perform { try await store.setEnabled(value, pack: pack, kind: kind, allowExternal: external) }
                                }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!canEdit)
                            }
                            Button("在访达中显示", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([pack.url])
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("在访达中显示")
                            Button("移到废纸篓", systemImage: "trash", role: .destructive) { removing = pack }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!canEdit || pack.enabled == true)
                                .help(pack.enabled == true ? "请先停用，再移到废纸篓" : "移到废纸篓")
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                }
                if let hint = listing.selectionHint {
                    Divider()
                    Text(hint).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                }
            } else if let readError {
                ContentUnavailableView("无法读取\(kind.title)", systemImage: "exclamationmark.triangle", description: Text(readError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 440)
        .interactiveDismissDisabled(working)
        .onChange(of: downloads.revisions[instance.id]) { revision += 1 }
        .task(id: Scan(kind: kind, revision: revision)) { await reload() }
        .confirmationDialog("允许修改此外部实例的光影与材质？", isPresented: $confirmingAccess, titleVisibility: .visible) {
            Button("允许本次管理") { external = true }
        } message: {
            Text("更改会写入「\(instance.displayName)」的包目录和游戏配置。")
        }
        .alert("将包移到废纸篓？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { pack in
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                perform { try await store.trash(pack, kind: kind, allowExternal: external) }
            }
        } message: { Text($0.name) }
        .alert("操作未完成", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("好") {}
        } message: { Text(problem ?? "") }
    }

    private func reload() async {
        let requested = kind
        readError = nil
        do {
            let result = try await store.list(requested)
            guard !Task.isCancelled, kind == requested else { return }
            listedKind = requested
            listing = result
        } catch {
            if !Task.isCancelled && kind == requested {
                listing = nil
                readError = error.localizedDescription
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard canEdit else { return }
        working = true
        Task {
            do {
                try await action()
            } catch {
                problem = error.localizedDescription
            }
            await reload()
            working = false
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            perform {
                var failures: [String] = []
                for url in urls {
                    do {
                        try await store.importPack(url, kind: kind, allowExternal: external)
                    } catch {
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                if !failures.isEmpty { problem = failures.joined(separator: "\n") }
            }
        }
    }
}
