import AppKit
import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct ModManagerSheet: View {
    let instance: InstanceRecord
    enum Presentation { case standalone, embedded, downloads }
    let presentation: Presentation
    let isBusy: Bool
    @State private var library: InstanceMods
    @State private var catalog: ModCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var online = false
    @State private var mods: [LocalMod] = []
    @State private var query = ""
    @Environment(DownloadCenter.self) private var downloads
    @State private var revision = 0
    @State private var reading = true
    @State private var working = false
    @State private var external = false
    @State private var confirmExternal = false
    @State private var importing = false
    @State private var updateRequest: UUID?
    @State private var check: ModUpdateCheck?
    @State private var updatingMod: LocalMod?
    @State private var backup: ModUpdateBackup?
    @State private var confirmingRollback = false
    @State private var requestedRollback: UUID?
    let didRollback: (UUID) -> Void
    @State private var removing: LocalMod?
    @State private var issue: String?
    @State private var gameVersion: String
    @State private var loader: LoaderKind

    init(instance: InstanceRecord, isBusy: Bool, presentation: Presentation = .standalone, requestedRollback: UUID? = nil, didRollback: @escaping (UUID) -> Void = { _ in }) {
        _requestedRollback = State(initialValue: requestedRollback)
        self.presentation = presentation
        _online = State(initialValue: presentation == .downloads)
        self.didRollback = didRollback
        self.instance = instance
        self.isBusy = isBusy
        _library = State(initialValue: InstanceMods(instance: instance))
        let cache = (try? AppPaths.standard().cache) ?? FileManager.default.temporaryDirectory
        _catalog = State(initialValue: ModCatalog(cache: cache))
        let fallback = instance.versionIdentifier.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) == nil ? "" : instance.versionIdentifier
        _gameVersion = State(initialValue: instance.minecraftVersion ?? fallback)
        _loader = State(initialValue: instance.loader)
    }

    private var target: ModTarget? { ModTarget(game: gameVersion, loader: loader) }
    private var canEdit: Bool { !isBusy && (instance.kind.isWritable || external) }
    private var filtered: [LocalMod] {
        guard !query.isEmpty else { return mods }
        return mods.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.filename.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .standalone {
                HStack {
                    VStack(alignment: .leading) {
                        Text("模组管理").font(.title2.bold())
                        Text(instance.displayName).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding()
            }
            if presentation != .downloads {
                Picker("模组来源", selection: $online) {
                    Text("已安装").tag(false)
                    Text("在线下载").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.vertical, 8)
                Divider()
            }
            if isBusy {
                Label("游戏正在准备或运行，退出游戏后可以更改模组。", systemImage: "lock")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, presentation == .downloads ? 20 : 10).padding(.vertical, 8)
            } else if !instance.kind.isWritable && !external {
                HStack {
                    Label(requestedRollback == nil ? "外部实例 · 只读" : "回退前，请先允许管理此外部实例的模组。", systemImage: "lock")
                    Spacer()
                    Button("允许管理模组") { confirmExternal = true }
                }.padding(.horizontal, presentation == .downloads ? 20 : 10).padding(.vertical, 8)
            }
            if instance.loader != .vanilla && (online || !mods.isEmpty) {
                if instance.minecraftVersion == nil || instance.loader == .unknown {
                    HStack {
                        if instance.minecraftVersion == nil { TextField("Minecraft 版本，例如 1.20.1", text: $gameVersion) }
                        if instance.loader == .unknown {
                            Picker("加载器", selection: $loader) {
                                Text("请选择").tag(LoaderKind.unknown)
                                ForEach([LoaderKind.fabric, .forge, .neoforge, .quilt], id: \.self) { Text($0.displayName).tag($0) }
                            }
                        }
                    }.padding(.horizontal, presentation == .downloads ? 20 : 10).padding(.vertical, 8)
                }
            }
            if online {
                if presentation == .downloads || target != nil {
                    OnlineModsView(target: target, catalog: catalog, library: library,
                                   allowExternal: external, canEdit: target != nil && canEdit).id(target)
                } else if instance.loader == .vanilla {
                    ContentUnavailableView("原版实例没有模组加载器", systemImage: "puzzlepiece.extension",
                        description: Text("选择安装了 Fabric、Forge、NeoForge 或 Quilt 的实例，即可搜索对应版本的模组。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("请先补全实例版本", systemImage: "line.3.horizontal.decrease",
                                           description: Text("填写游戏版本和加载器后才能筛选兼容文件。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称或文件名", text: $query)
                    Button("导入 JAR") { importing = true }.disabled(!canEdit || working)
                    Text("\(filtered.count) 个").foregroundStyle(.secondary)
                    Button { revision += 1 } label: { Label("刷新", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                        .disabled(reading)
                }.padding(10)
                if let issue { Text(issue).foregroundStyle(.red).padding(.horizontal) }
                if reading && mods.isEmpty { ProgressView("正在读取模组…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "没有已安装的模组" : "没有匹配的模组", systemImage: "puzzlepiece.extension")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { mod in
                        HStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mod.name).font(.headline)
                                Text(mod.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if let check, let version = check.updates[mod.filename] {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("\(check.currentVersion(of: mod)) → \(version.version_number)")
                                        .font(.caption).lineLimit(1).truncationMode(.middle)
                                    Button("更新") { updatingMod = mod }
                                        .fixedSize()
                                        .disabled(!canEdit || working || reading || updateRequest != nil)
                                }
                            } else if let version = mod.version {
                                Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Toggle("启用 \(mod.name)", isOn: Binding(get: { mod.enabled }, set: { _ in
                                mutate { try await library.toggle(mod, allowExternal: external) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!canEdit || working)
                            Button(role: .destructive) { removing = mod } label: { Label("移到废纸篓", systemImage: "trash").labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).disabled(!canEdit || working)
                        }.padding(.vertical, 3)
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                    .disabled(reading)
                }
                Divider()
                HStack {
                    Button("检查更新") {
                        issue = nil
                        check = nil
                        updateRequest = UUID()
                    }
                    .disabled(target == nil || mods.isEmpty || reading || working || updateRequest != nil)
                    if updateRequest != nil {
                        ProgressView().controlSize(.small)
                        Text("正在检查…")
                    } else if let check {
                        Text("可更新 \(check.updates.count) 个" + (check.unknownCount > 0 ? " · 未识别 \(check.unknownCount) 个" : ""))
                    }
                    Spacer()
                    if backup != nil {
                        Button("回退上次更新") { confirmingRollback = true }.disabled(!canEdit || working)
                    }
                }.font(.callout).padding(10)
            }
        }
        .frame(minWidth: presentation == .standalone ? 620 : nil, minHeight: presentation == .standalone ? 480 : nil, alignment: .top)
        .onChange(of: downloads.revisions[instance.id]) { revision += 1 }
        .task(id: revision) {
            guard presentation != .downloads else { return }
            check = nil
            updateRequest = nil
            reading = true
            do {
                let items = try await library.list()
                try Task.checkCancellation()
                mods = items
                let latestBackup = try await library.lastUpdate()
                try Task.checkCancellation()
                backup = latestBackup
                if let requestedRollback, latestBackup?.id != requestedRollback {
                    self.requestedRollback = nil
                    issue = "上次更新记录已变化，请重新核对备份。"
                } else {
                    issue = nil
                }
            } catch {
                if Task.isCancelled { return }
                issue = error.localizedDescription
            }
            reading = false
        }
        .task(id: updateRequest) {
            guard let request = updateRequest, let target else { return }
            do {
                let result = try await library.checkUpdates(target: target, catalog: catalog)
                try Task.checkCancellation()
                if request == updateRequest { check = result }
            } catch {
                if !Task.isCancelled {
                    issue = error.localizedDescription
                }
            }
            if request == updateRequest { updateRequest = nil }
        }
        .onChange(of: target) {
            check = nil
            updateRequest = nil
        }
        .sheet(item: $updatingMod) { mod in
            if let check {
                ModUpdateSheet(mod: mod, check: check, catalog: catalog, library: library, worlds: WorldBackups(instance: instance),
                               canEdit: canEdit, allowExternal: external)
            }
        }
        .onChange(of: requestedRollback != nil && requestedRollback == backup?.id && canEdit && !reading, initial: true) { _, ready in
            if ready {
                requestedRollback = nil
                confirmingRollback = true
            }
        }
        .alert("回退上次模组更新？", isPresented: $confirmingRollback, presenting: backup) { record in
            Button("取消", role: .cancel) {}
            Button("回退更新") {
                mutate {
                    try await library.rollback(record.id, allowExternal: external)
                    didRollback(record.id)
                }
            }
        } message: { record in
            Text("恢复「\(record.name)」更新前的模组文件，并移除这次新增的依赖。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "jar") ?? .archive]) { result in
            if case let .success(url) = result { mutate { try await library.importJar(url, allowExternal: external) } }
        }
        .confirmationDialog("允许更改这个外部实例的模组？", isPresented: $confirmExternal, titleVisibility: .visible) {
            Button("允许本次管理") { external = true }
        } message: { Text("本次打开期间，安装、启用和移除将更改 \(instance.path)/mods，其他使用此目录的启动器也会看到这些更改。") }
        .alert("将模组移到废纸篓？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { mod in
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) { mutate { try await library.trash(mod, allowExternal: external) } }
        } message: { Text($0.filename) }
    }

    private func mutate(_ action: @escaping @MainActor () async throws -> Void) {
        guard canEdit, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await action()
                revision += 1
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

