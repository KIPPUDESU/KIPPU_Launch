import AppKit
import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct InstanceLibraryView: View {
    @Bindable var library: InstanceLibrary
    var launcher: LaunchController

    @Binding var navigation: LauncherNavigation
    let activeInstance: InstanceRecord?
    let accountName: String
    let accountHead: SkinHead?
    let selectInstance: (UUID) -> Void
    let showAccounts: () -> Void
    let editBackground: (UUID) -> Void

    @State private var backingUp: InstanceRecord?
    @State private var configuring: InstanceRecord?
    @State private var checkingLaunch: InstanceRecord?
    @State private var instancePendingRename: InstanceRecord?
    @State private var draftName = ""
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("instanceSortByName") private var byName = false
    @AppStorage("instanceSortAscending") private var preferredAscending: Bool?
    private var ascending: Bool { preferredAscending ?? byName }

    private var sortDescription: String {
        if byName { return ascending ? "名称升序" : "名称降序" }
        return ascending ? "启动时间从早到晚" : "启动时间从晚到早"
    }

    private var visible: [InstanceRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = term.isEmpty ? library.instances : library.instances.filter { instance in
            [library.displayName(for: instance), URL(fileURLWithPath: instance.path).lastPathComponent, instance.packName ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(term) }
        }
        if byName {
            let names = matches.sorted {
                library.displayName(for: $0).localizedStandardCompare(library.displayName(for: $1)) == .orderedAscending
            }
            return ascending ? names : Array(names.reversed())
        }
        return ascending ? Array(matches.reversed()) : matches
    }

    @State private var isChoosingFolder = false
    @State private var isRefreshing = false
    @State private var instancePendingRemoval: InstanceRecord?
    @State private var isBatchDeleting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var batchPendingRemoval: Set<UUID>?

    var body: some View {
        Group {
            if navigation.destination == .instanceEditor, let item = activeInstance {
                InstanceManagementView(instance: item, library: library, launcher: launcher, tab: $navigation.managementTab,
                                       backTitle: navigation.editorOrigin == .instances ? "实例列表" : "启动页",
                                       onBack: { navigation.destination = navigation.editorOrigin }, onBackup: { backingUp = item },
                                       onCheckLaunch: { checkingLaunch = item }, onRename: { beginRename(item) },
                                       onRemove: { instancePendingRemoval = item })
                    .id(item.id)
            } else if navigation.destination != .instances {
                launchHome
            } else {
                listPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $backingUp) { instance in
            WorldBackupsSheet(instance: instance, isBusy: launcher.isRunning(instance) || launcher.preparing.contains(instance.id))
        }
        .sheet(item: $checkingLaunch) { instance in
            InstanceLaunchCheckSheet(instance: instance, displayName: library.displayName(for: instance), launcher: launcher)
        }
        .sheet(item: $configuring) { instance in
            InstanceSettingsSheet(instance: instance, defaultMemory: launcher.defaultMemoryMB, runtimes: launcher.javaRuntimes) {
                try library.configure(instance.id, memoryMB: $0, javaPath: $1)
            }
        }
        .alert("重命名实例", isPresented: Binding(
            get: { instancePendingRename != nil },
            set: { if !$0 { instancePendingRename = nil } }
        ), presenting: instancePendingRename) { instance in
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) {}
            Button("保存") { library.rename(instance, to: draftName) }
        } message: { _ in Text("仅修改启动器中显示的名称。") }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task {
                for url in urls { await library.addRoot(at: url, isLauncherOwned: false) }
            }
        }
        .confirmationDialog(
            "从这个列表移除实例？",
            isPresented: Binding(
                get: { instancePendingRemoval != nil },
                set: { if !$0 { instancePendingRemoval = nil } }
            ),
            presenting: instancePendingRemoval
        ) { instance in
            Button("移除", role: .destructive) {
                library.removeInstance(instance)
                if navigation.destination == .instanceEditor && !library.instances.contains(where: { $0.id == instance.id }) {
                    navigation.destination = navigation.editorOrigin
                }
                instancePendingRemoval = nil
            }
            Button("取消", role: .cancel) { instancePendingRemoval = nil }
        } message: { instance in
            Text(removalExplanation(for: instance))
        }
        .confirmationDialog(
            "删除选中的 \(batchPendingRemoval?.count ?? 0) 个实例？",
            isPresented: Binding(
                get: { batchPendingRemoval != nil },
                set: { if !$0 { batchPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: batchPendingRemoval
        ) { ids in
            Button("删除 \(ids.count) 个实例", role: .destructive) {
                if library.removeInstances(ids: ids) { endBatchDeletion() }
                batchPendingRemoval = nil
            }
            Button("取消", role: .cancel) { batchPendingRemoval = nil }
        } message: { _ in
            Text("只删除列表记录，游戏目录、存档和 mods 都会保留。重新扫描可找回磁盘上仍存在的实例。")
        }
        .onDisappear { endBatchDeletion() }
    }

    private var launchHome: some View {
        VStack(spacing: 0) {
            PageHeader(title: "实例管理") {
                if let activeInstance {
                    Button("背景图片", systemImage: "photo") { editBackground(activeInstance.id) }
                        .help("设置背景图片、透明度和模糊度")
                    Menu("切换实例", systemImage: "arrow.left.arrow.right") {
                        Picker("当前实例", selection: Binding(get: { activeInstance.id }, set: { selectInstance($0) })) {
                            ForEach(library.instances) { item in
                                Text(library.displayName(for: item)).tag(item.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    .fixedSize()
                }
            }
            Divider()
            if let problem = launcher.problem ?? library.problem { problemBanner(problem) }
            if let item = activeInstance {
                InstanceLaunchPage(instance: item, displayName: library.displayName(for: item), launcher: launcher,
                                   accountName: accountName, accountHead: accountHead, showAccounts: showAccounts,
                                   saveMemory: { try library.configure(item.id, memoryMB: $0, javaPath: item.selectedJavaPath) },
                                   edit: { navigation.edit($0, from: .launchHome) },
                                   checkLaunch: { checkingLaunch = item }, backup: { backingUp = item })
                    .id(item.id)
            } else {
                ContentUnavailableView {
                    Label("还没有实例", systemImage: "cube")
                } description: {
                    Text("在实例列表中添加或自动检测已有的游戏目录。")
                } actions: {
                    Button("打开实例列表") { navigation.destination = .instances }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var listPage: some View {
        let items = visible
        let batchIDs = isBatchDeleting ? Set(items.map(\.id)) : []
        return VStack(spacing: 0) {
            PageHeader(title: "实例列表", subtitle: headerSubtitle) {
                if !isBatchDeleting { listTools(hasItems: !items.isEmpty) }
            }
            Divider()
            if searching && !isBatchDeleting { searchRow }
            if !library.discoveredRoots.isEmpty { discoveryBanner }
            if let problem = launcher.problem ?? library.problem { problemBanner(problem) }
            if isBatchDeleting { batchSelectionBar(ids: batchIDs) }
            content(items)
        }
        .onChange(of: batchIDs) { _, ids in
            guard isBatchDeleting else { return }
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { endBatchDeletion() }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索实例或整合包", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            Button("完成") {
                query = ""
                searching = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func listTools(hasItems: Bool) -> some View {
        HStack(spacing: 8) {
            Button("搜索", systemImage: "magnifyingglass") {
                searching = true
                searchFocused = true
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("f")
            .help("搜索实例或整合包（⌘F）")

            Menu {
                Picker("排序方式", selection: Binding(get: { byName }, set: { newMode in
                    preferredAscending = ascending
                    byName = newMode
                })) {
                    Text("最近启动").tag(false)
                    Text("名称").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label("切换排序方向", systemImage: ascending ? "arrow.up" : "arrow.down")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                preferredAscending = !ascending
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .accessibilityValue(sortDescription)
            .help("当前按\(sortDescription)排列。点箭头反转顺序，点右侧菜单选择排序方式。")

            Button("重新扫描", systemImage: "arrow.clockwise") {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await library.refresh()
                    isRefreshing = false
                }
            }
            .labelStyle(.iconOnly)
            .disabled(isRefreshing)
            .help("重新扫描实例目录")

            Divider().frame(height: 16)

            Button("批量删除", systemImage: "trash") {
                selectedIDs = []
                isBatchDeleting = true
            }
            .disabled(!hasItems || isRefreshing)
            .help("批量删除实例记录")

            Button("添加", systemImage: "plus") { isChoosingFolder = true }
                .help("选择解压后的整合包、.minecraft、versions 或单个实例目录")
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .lineLimit(1)
    }

    private func beginRename(_ instance: InstanceRecord) {
        draftName = instance.name
        instancePendingRename = instance
    }

    private func endBatchDeletion() {
        isBatchDeleting = false
        selectedIDs = []
        batchPendingRemoval = nil
    }

    private func selection(for instance: InstanceRecord) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(instance.id) },
            set: { selected in
                if selected { selectedIDs.insert(instance.id) }
                else { selectedIDs.remove(instance.id) }
            }
        )
    }

    private func batchSelectionBar(ids: Set<UUID>) -> some View {
        InstanceBatchActionBar(
            selectedCount: selectedIDs.count,
            totalCount: ids.count,
            onToggleAll: {
                selectedIDs = selectedIDs == ids ? [] : ids
            },
            onDelete: { batchPendingRemoval = selectedIDs },
            onCancel: endBatchDeletion
        )
    }

    private func removalExplanation(for instance: InstanceRecord) -> String {
        switch instance.kind {
        case .referenced:
            "只会从这个列表里移除，磁盘上的目录、存档和 mods 一概不动。其它启动器仍可正常使用它。"
        case .managed:
            "只会从列表里移除记录。如需彻底删除，请自行删除该目录。"
        }
    }

    @ViewBuilder
    private func content(_ items: [InstanceRecord]) -> some View {
        if library.instances.isEmpty {
            emptyState
        } else if items.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(items) { instance in
                    InstanceRow(
                        instance: instance,
                        displayName: library.displayName(for: instance),
                        isPreparing: launcher.preparing.contains(instance.id),
                        isRunning: launcher.isRunning(instance),
                        selection: isBatchDeleting ? selection(for: instance) : nil,
                        onLaunch: {
                            selectInstance(instance.id)
                            Task { await launcher.launch(instance) }
                        }
                    ) { close in
                        InstanceDetailCard(
                            instance: instance, displayName: library.displayName(for: instance), launcher: launcher,
                            onManage: { tab in
                                selectInstance(instance.id)
                                navigation.edit(tab, from: .instances)
                            },
                            onBackup: { backingUp = instance }, onSettings: { configuring = instance },
                            onCheckLaunch: { checkingLaunch = instance },
                            onRename: { beginRename(instance) }, onRemove: { instancePendingRemoval = instance },
                            close: close
                        )
                    }
                    .listRowBackground(
                        isBatchDeleting && selectedIDs.contains(instance.id)
                            ? Color.accentColor.opacity(0.08) : Color.clear
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    // 系统有时会把右侧操作列当作分隔线起点
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 40 }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                }
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有实例")
                .font(.title3)
            VStack(spacing: 6) {
                if library.discoveredRoots.isEmpty {
                    Text("启动时会自动检测 Minecraft 默认目录中的实例，找到后可在上方点「导入」。")
                } else {
                    Text("已自动检测到本机的 Minecraft 实例，点上方「导入」即可添加到列表。")
                }
                Text("也可以点右上角「添加」选择游戏目录，或在「下载 → 游戏」安装新版本。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerSubtitle: String {
        let count = library.instances.count
        guard count > 0 else { return "还没有实例" }
        if isBatchDeleting { return "批量选择 · \(count) 个实例" }
        let missing = library.instances.count { $0.isMissing }
        return missing > 0 ? "\(count) 个实例 · \(missing) 个已缺失" : "\(count) 个实例"
    }

    private func clearProblem() {
        launcher.problem = nil
        library.problem = nil
    }

    private var discoveryBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("发现已有的 Minecraft 实例")
                    .font(.headline)
                ForEach(library.discoveredRoots, id: \.path) { root in
                    Text("在 \(root.path) 找到 \(root.instanceCount) 个实例。仅登记现有目录，导入时不会更改游戏文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ForEach(library.discoveredRoots, id: \.path) { root in
                Button("导入") {
                    Task { await library.importDiscoveredRoot(root) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func problemBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                clearProblem()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
