import KIPPULaunchCore
import SwiftUI

struct WorldBackupsSheet: View {
    let instance: InstanceRecord
    let isBusy: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var store: WorldBackups
    @State private var worlds: [SavedWorld] = []
    @State private var selected: SavedWorld?
    @State private var backups: [WorldBackup] = []
    @State private var restoring: WorldBackup?
    @State private var loading = true
    @State private var operation: String?
    @State private var notice: String?
    @State private var problem: String?

    init(instance: InstanceRecord, isBusy: Bool) {
        self.instance = instance
        self.isBusy = isBusy
        _store = State(initialValue: WorldBackups(instance: instance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("存档备份").font(.title2.bold())
                    Text(instance.displayName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(operation != nil)
            }.padding()
            Divider()
            HStack {
                if worlds.isEmpty {
                    Text(loading ? "正在读取世界…" : "未找到本地世界").foregroundStyle(.secondary)
                } else {
                    WorldPicker(worlds: worlds, selection: $selected)
                }
                Spacer()
                Button("创建备份") {
                    guard let selected else { return }
                    perform("正在备份…") {
                        let backup = try await store.backup(selected)
                        return "已备份「\(backup.world.name)」。"
                    }
                }.disabled(selected == nil || isBusy || loading || operation != nil)
            }.padding()
            if isBusy { Text("请先退出游戏，再备份或恢复存档。").foregroundStyle(.secondary).padding(.horizontal) }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal) }
            if let operation { ProgressView(operation).controlSize(.small).padding(.horizontal) }
            if backups.isEmpty {
                ContentUnavailableView("还没有存档备份", systemImage: "clock.arrow.circlepath",
                                       description: Text("选择一个世界即可创建第一份备份。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(backups) { backup in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.world.name).font(.headline)
                            Text(backup.created.formatted(date: .abbreviated, time: .standard))
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("恢复为副本") { restoring = backup }
                            .disabled(isBusy || instance.isMissing || operation != nil)
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }
        .frame(minWidth: 530, idealWidth: 600, minHeight: 390, idealHeight: 450)
        .interactiveDismissDisabled(operation != nil)
        .task { await reload() }
        .alert("恢复为新的世界副本？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
               presenting: restoring) { backup in
            Button("取消", role: .cancel) {}
            Button("恢复为副本") {
                perform("正在校验并恢复…") {
                    let copy = try await store.restoreCopy(backup.id)
                    return "已恢复「\(copy.name)」，可在单人游戏列表中打开。"
                }
            }
        } message: { backup in
            Text("将在「\(instance.displayName)」的 saves 目录内新增「\(backup.world.name)」的副本，原世界会保留。")
        }
    }

    private func perform(_ status: String, action: @escaping @MainActor () async throws -> String) {
        guard operation == nil, !isBusy else { return }
        operation = status
        notice = nil
        problem = nil
        Task {
            defer { operation = nil }
            do {
                notice = try await action()
                await reload()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            backups = try await store.backups()
            worlds = try await store.worlds()
            selected = worlds.first(where: { $0.id == selected?.id }) ?? worlds.first
        } catch {
            problem = error.localizedDescription
        }
    }
}
