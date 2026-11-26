import AppKit
import KIPPULaunchCore
import SwiftUI

struct InstanceDetailAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let card: () -> InstanceDetailCard

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, let windowContent = view.window?.contentView else {
            coordinator.close()
            return
        }
        if let host = coordinator.popover?.contentViewController as? NSHostingController<InstanceDetailCard> {
            host.rootView = card()
        } else {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = coordinator
            let host = NSHostingController(rootView: card())
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            coordinator.presented = $isPresented
            coordinator.popover = popover
            popover.show(relativeTo: view.convert(view.bounds, to: windowContent), of: windowContent, preferredEdge: .maxX)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var presented: Binding<Bool>?

        func close() {
            presented = nil
            popover?.close()
            popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            presented?.wrappedValue = false
            presented = nil
            popover = nil
        }
    }
}

struct InstanceDetailCard: View {
    let instance: InstanceRecord
    let displayName: String
    let launcher: LaunchController
    let onManage: (InstanceManagementTab) -> Void
    let onBackup: () -> Void
    let onSettings: () -> Void
    let onCheckLaunch: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    let close: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)

    private var status: String {
        if launcher.isRunning(instance) { return "运行中" }
        if launcher.preparing.contains(instance.id) { return "准备中" }
        return instance.isMissing ? "目录已缺失" : "未运行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName).font(.headline)
                    Text("\(instance.kind.isWritable ? "托管实例" : "外部实例") · \(status)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭详情", systemImage: "xmark.circle.fill") { close() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("关闭详情")
            }
            Divider()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                fact("游戏版本", instance.minecraftVersion ?? instance.versionIdentifier)
                fact("加载器", [instance.loader.displayName, instance.loaderVersion].compactMap { $0 }.joined(separator: " "))
                fact("所需 Java", instance.requiredJavaMajorVersion.map { "Java \($0)" } ?? "未指定")
                fact("内存上限", "\(instance.memoryMB ?? launcher.defaultMemoryMB) MB · \(instance.memoryMB == nil ? "默认设置" : "实例设置")")
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(InstanceManagementTab.allCases) { tab in
                    action("\(tab.title)管理", icon: tab.icon) { onManage(tab) }
                }
                action("存档备份", icon: "clock.arrow.circlepath", perform: onBackup)
                action("启动设置", icon: "slider.horizontal.3", perform: onSettings)
                let failure = launcher.failures[instance.id]
                action(failure.map { $0.diagnosis.cause == .interrupted ? "查看退出说明" : "查看失败诊断" } ?? "查看上次日志",
                       icon: "doc.text") { launcher.showLog(instance) }
                    .disabled(failure == nil && !launcher.hasLog(instance))
                action("启动前检查", icon: "checklist", perform: onCheckLaunch)
            }
            Divider()
            InstanceDirectoryRow(path: instance.path, isMissing: instance.isMissing)
            Divider()
            HStack {
                Button("重命名", systemImage: "pencil") {
                    close()
                    onRename()
                }
                Spacer()
                Button("从列表移除", systemImage: "trash", role: .destructive) {
                    close()
                    onRemove()
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            close()
            perform()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}
