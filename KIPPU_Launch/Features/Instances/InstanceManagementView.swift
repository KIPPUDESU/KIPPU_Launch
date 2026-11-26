import AppKit
import KIPPULaunchCore
import SwiftUI

enum InstanceManagementTab: String, CaseIterable, Identifiable {
    case instance
    case mods
    case shaders
    case resources

    var id: Self { self }

    var title: String {
        switch self {
        case .instance: "实例"
        case .mods: "模组"
        case .shaders: "光影"
        case .resources: "材质"
        }
    }

    var icon: String {
        switch self {
        case .instance: "slider.horizontal.3"
        case .mods: "puzzlepiece.extension"
        case .shaders: "sun.max"
        case .resources: "square.3.layers.3d"
        }
    }
}

struct InstanceManagementView: View {
    let instance: InstanceRecord
    let library: InstanceLibrary
    let launcher: LaunchController
    @Binding var tab: InstanceManagementTab
    let backTitle: String
    let onBack: () -> Void
    let onBackup: () -> Void
    let onCheckLaunch: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    private var busy: Bool {
        launcher.isRunning(instance) || launcher.preparing.contains(instance.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: library.displayName(for: instance), subtitle: "实例管理") {
                Button(backTitle, systemImage: "chevron.backward", action: onBack)
                    .keyboardShortcut(.cancelAction)
                Menu("操作", systemImage: "ellipsis.circle") {
                    Button("存档备份", systemImage: "clock.arrow.circlepath", action: onBackup)
                    let failure = launcher.failures[instance.id]
                    Button(failure.map { $0.diagnosis.cause == .interrupted ? "查看退出说明" : "查看失败诊断" } ?? "查看上次日志",
                           systemImage: "doc.text") { launcher.showLog(instance) }
                        .disabled(!launcher.hasLog(instance) && failure == nil)
                    Button("启动前检查", systemImage: "checklist", action: onCheckLaunch)
                    Button("在访达中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: instance.path)])
                    }.disabled(instance.isMissing)
                    Divider()
                    Button("重命名", systemImage: "pencil", action: onRename)
                    Button("从列表移除", systemImage: "trash", role: .destructive, action: onRemove)
                }
            }
            Divider()

            Picker("管理项目", selection: $tab) {
                ForEach(InstanceManagementTab.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if instance.isMissing && tab != .instance {
                ContentUnavailableView("实例目录已缺失", systemImage: "folder.badge.questionmark",
                                       description: Text("请连接存储设备并重新扫描实例。"))
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .instance:
            InstanceSettingsSheet(instance: instance, defaultMemory: launcher.defaultMemoryMB, runtimes: launcher.javaRuntimes, embedded: true) {
                try library.configure(instance.id, memoryMB: $0, javaPath: $1)
            }
        case .mods:
            ModManagerSheet(instance: instance, isBusy: busy, presentation: .embedded) { restored in
                launcher.didRollback(restored, instanceID: instance.id)
            }
        case .shaders, .resources:
            PackManagerSheet(instance: instance, kind: tab == .shaders ? .shaders : .resources, isBusy: busy)
                .id(tab)
        }
    }
}
