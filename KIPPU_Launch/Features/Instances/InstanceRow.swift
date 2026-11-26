import AppKit
import Foundation
import KIPPULaunchCore
import SwiftUI

struct InstanceRow: View {
    let instance: InstanceRecord
    let displayName: String
    let isPreparing: Bool
    let isRunning: Bool
    let selection: Binding<Bool>?
    let onLaunch: () -> Void
    let detailCard: (@escaping () -> Void) -> InstanceDetailCard
    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if let selection {
                    Toggle("选择 \(displayName)", isOn: selection)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 28)
                        .padding(.top, 2)
                } else {
                    Image(systemName: isRunning ? "cube.fill" : "cube")
                        .font(.title2)
                        .foregroundStyle(isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.headline)
                        if isRunning {
                            badge("运行中", color: .green)
                        }
                        if instance.isMissing {
                            badge("已缺失", color: .orange)
                        }
                        if instance.kind == .referenced {
                            badge("外部", color: .secondary)
                        }
                    }

                    Text(summaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(instance.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if selection == nil {
                InstanceRowActions(
                    isPreparing: isPreparing,
                    isRunning: isRunning,
                    isMissing: instance.isMissing,
                    displayName: displayName,
                    onLaunch: onLaunch,
                    onDetails: { showingDetails.toggle() }
                )
                .background {
                    InstanceDetailAnchor(isPresented: $showingDetails) {
                        detailCard { showingDetails = false }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var summaryLine: String {
        var parts: [String] = []

        if let packName = instance.packName, packName != instance.name {
            parts.append(packName)
        }
        if let minecraft = instance.minecraftVersion {
            parts.append("Minecraft \(minecraft)")
        }
        switch instance.loader {
        case .vanilla: parts.append("原版")
        case .unknown: break
        default:
            if let version = instance.loaderVersion {
                parts.append("\(instance.loader.displayName) \(version)")
            } else {
                parts.append(instance.loader.displayName)
            }
        }
        if let java = instance.requiredJavaMajorVersion {
            parts.append("需要 Java \(java)")
        }
        if let memory = instance.memoryMB {
            parts.append("\(memory) MB")
        }
        return parts.isEmpty ? instance.versionIdentifier : parts.joined(separator: " · ")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct InstanceRowActions: View {
    let isPreparing: Bool
    let isRunning: Bool
    let isMissing: Bool
    let displayName: String
    let onLaunch: () -> Void
    let onDetails: () -> Void

    private var launchPresentation: (title: String, symbol: String, help: String) {
        if isPreparing {
            ("准备中", "hourglass", "正在检查启动环境")
        } else if isRunning {
            ("运行中", "play.circle", "实例正在运行")
        } else if isMissing {
            ("不可用", "exclamationmark.triangle", "实例目录已不可用")
        } else {
            ("启动", "play.fill", "启动 \(displayName)")
        }
    }

    var body: some View {
        let launch = launchPresentation
        ControlGroup {
            Button(action: onLaunch) {
                Label(launch.title, systemImage: launch.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("\(launch.title)：\(displayName)")
            .disabled(isPreparing || isRunning || isMissing)
            .help(launch.help)

            Button("实例详情", systemImage: "info.circle") {
                onDetails()
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("查看 \(displayName) 的详情")
            .help("实例详情与管理")
        }
        .controlSize(.regular)
        .fixedSize()
    }
}
