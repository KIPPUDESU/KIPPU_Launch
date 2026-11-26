import KIPPULaunchCore
import SwiftUI

struct ModUpdateSheet: View {
    let mod: LocalMod
    let check: ModUpdateCheck
    let catalog: ModCatalog
    let library: InstanceMods
    let worlds: WorldBackups
    let canEdit: Bool
    let allowExternal: Bool
    @Environment(DownloadCenter.self) private var downloads

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ModUpdatePlan?
    @State private var problem: String?
    @State private var backupFirst = false
    @State private var available: [SavedWorld] = []
    @State private var selected: SavedWorld?
    @State private var loadingWorlds = false
    @State private var backupProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更新「\(mod.name)」？").font(.title2.bold())
            if let version = check.updates[mod.filename] {
                Text("\(check.currentVersion(of: mod)) → \(version.version_number) · \(version.version_type)")
                    .foregroundStyle(.secondary)
            }
            Label {
                Text("更新模组可能导致整合包不可用。").bold()
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("新版可能与整合包里的其他模组或配置不兼容。更新前会备份被替换的模组文件，可在「已安装」中回退。")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("先备份存档", isOn: $backupFirst)
            if backupFirst {
                if loadingWorlds { ProgressView("正在读取世界…").controlSize(.small) }
                else if let backupProblem { Text(backupProblem).foregroundStyle(.red) }
                else if available.isEmpty { Text("此实例没有本地世界可备份。").foregroundStyle(.secondary) }
                else { WorldPicker(worlds: available, selection: $selected) }
            }
            if let plan {
                Divider()
                Text("本次变更（\(plan.changes.count)）").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.changes) { change in
                            Text(change.previousFilename.map { "\($0) → \(change.filename)" } ?? "新增依赖  \(change.filename)")
                                .textSelection(.enabled)
                        }
                        if !plan.pinnedDependents.isEmpty {
                            Text("以下已启用的模组指定了将被替换的旧版本：").font(.headline)
                            ForEach(plan.pinnedDependents, id: \.self) { Text($0).textSelection(.enabled) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 84, idealHeight: 120, maxHeight: 160)
            } else if problem == nil {
                ProgressView("正在检查必需依赖…")
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认更新", action: confirmUpdate)
                    .disabled(plan == nil || !canEdit || (backupFirst && (loadingWorlds || selected == nil)))
            }
        }
        .padding(20).frame(width: 490)
        .task(id: backupFirst) {
            guard backupFirst else { return }
            loadingWorlds = true
            backupProblem = nil
            selected = nil
            do {
                let items = try await worlds.worlds()
                try Task.checkCancellation()
                available = items
                selected = items.first
            } catch {
                if Task.isCancelled { return }
                backupProblem = error.localizedDescription
            }
            loadingWorlds = false
        }
        .task {
            do {
                plan = try await catalog.updatePlan(for: mod, check: check)
            } catch {
                if !Task.isCancelled {
                    problem = error.localizedDescription
                }
            }
        }
    }

    private func confirmUpdate() {
        guard let plan, canEdit else { return }
        let world = backupFirst ? selected : nil
        guard !backupFirst || world != nil else { return }
        let store = library
        let backups = worlds
        let allow = allowExternal
        let instance = store.instance
        let expected = plan.changes.count == 1 ? check.updates[mod.filename]?.jar?.size : nil
        var backedUp = false
        downloads.enqueue(key: "\(instance.id)/update/\(mod.filename)", title: "更新「\(mod.name)」", category: .mod,
                          target: instance.displayName, instanceID: instance.id) { job in
            if let world, !backedUp {
                job.report("备份存档")
                _ = try await backups.backup(world)
                backedUp = true
            }
            try Task.checkCancellation()
            job.report("下载并更新模组", total: plan.changes.count,
                       expectedBytes: expected)
            try await store.update(plan, allowExternal: allow) { done, total in
                await job.report("下载并更新模组", done: done, total: total)
            }
            return "已更新，可在模组管理中回退"
        }
        dismiss()
    }
}
