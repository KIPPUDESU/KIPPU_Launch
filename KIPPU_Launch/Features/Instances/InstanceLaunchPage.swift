import KIPPULaunchCore
import SwiftUI

struct InstanceLaunchPage: View {
    let instance: InstanceRecord
    let displayName: String
    let launcher: LaunchController
    let accountName: String
    let accountHead: SkinHead?
    let showAccounts: () -> Void
    let saveMemory: (Int?) throws -> Void
    let edit: (InstanceManagementTab) -> Void
    let checkLaunch: () -> Void
    let backup: () -> Void

    private enum Tab { case overview, console }
    @State private var tab = Tab.overview
    @State private var editingMemory = false

    private var running: Bool { launcher.isRunning(instance) }
    private var preparing: Bool { launcher.preparing.contains(instance.id) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                identity
                Picker("实例视图", selection: $tab) {
                    Text("概览").tag(Tab.overview)
                    Text("实时控制台").tag(Tab.console)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            switch tab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        configuration
                        contentLinks
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
            case .console:
                InstanceLiveConsole(instance: instance, launcher: launcher)
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            Divider()
            launchBar
        }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: displayName)
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: ["Minecraft " + (instance.minecraftVersion ?? instance.versionIdentifier),
                                [instance.loader.displayName, instance.loaderVersion].compactMap { $0 }.joined(separator: " "),
                                instance.kind.isWritable ? "托管实例" : "外部实例"]
                    .joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("编辑实例", systemImage: "pencil") { edit(.instance) }
                .fixedSize()
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("启动配置").font(.headline)
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(instance.memoryMB == nil ? "最大内存 · 跟随全局" : "最大内存 · 实例设置")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            editingMemory = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(MemoryAllocationSlider.formatted(instance.memoryMB ?? launcher.defaultMemoryMB))
                                    .font(.headline).monospacedDigit()
                                Image(systemName: "pencil").font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("调整实例内存")
                        .accessibilityValue(MemoryAllocationSlider.formatted(instance.memoryMB ?? launcher.defaultMemoryMB))
                        .help("调整内存或跟随全局设置")
                        .popover(isPresented: $editingMemory) {
                            InstanceMemoryPopover(memoryMB: instance.memoryMB, globalMB: launcher.defaultMemoryMB, save: saveMemory)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    metric("所需 Java", value: instance.requiredJavaMajorVersion.map { "Java \($0)" } ?? "由版本决定")
                    Divider()
                    metric("上次启动", value: instance.lastLaunchedAt?.formatted(date: .numeric, time: .shortened) ?? "尚未启动")
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var contentLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实例内容").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    firstLinks
                    lastLinks
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { firstLinks }
                    HStack(spacing: 8) { lastLinks }
                }
            }
            GroupBox {
                InstanceDirectoryRow(path: instance.path, isMissing: instance.isMissing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var firstLinks: some View {
        contentLink("模组", icon: InstanceManagementTab.mods.icon) { edit(.mods) }
        contentLink("资源包", icon: InstanceManagementTab.resources.icon) { edit(.resources) }
    }

    @ViewBuilder private var lastLinks: some View {
        contentLink("光影", icon: InstanceManagementTab.shaders.icon) { edit(.shaders) }
        contentLink("存档备份", icon: "clock.arrow.circlepath", action: backup)
    }

    private func contentLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 148)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .frame(maxWidth: .infinity)
    }

    private var launchBar: some View {
        HStack(spacing: 12) {
            Button(action: showAccounts) {
                HStack(spacing: 8) {
                    SkinHeadView(head: accountHead, size: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动账号").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: accountName).font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选择启动账号")
            Spacer(minLength: 4)
            status
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("启动前检查", systemImage: "checklist", action: checkLaunch)
                .disabled(preparing)
                .controlSize(.large)
                .fixedSize()
            Button {
                tab = .console
                Task { await launcher.launch(instance, openLogWindow: false) }
            } label: {
                Label("启动游戏", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(instance.isMissing || running || preparing)
        }
        .frame(maxWidth: 960)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var status: some View {
        if running {
            Label("运行中", systemImage: "play.circle")
        } else if preparing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在准备启动")
            }
        } else if instance.isMissing {
            Label("游戏目录已缺失", systemImage: "exclamationmark.triangle")
        } else {
            Label("就绪", systemImage: "checkmark.circle")
        }
    }
}
