import AppKit
import KIPPULaunchCore
import SwiftUI

struct LaunchFailureView: View {
    let failure: LaunchFailure
    let launcher: LaunchController
    let library: InstanceLibrary
    private enum Destination: String, Identifiable {
        case java, mods, rollback
        var id: Self { self }
    }
    @State private var destination: Destination?

    private var instance: InstanceRecord {
        library.instances.first { $0.id == failure.instance.id } ?? failure.instance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(failure.diagnosis.title, systemImage: failure.diagnosis.cause == .interrupted ? "stop.circle" : "exclamationmark.triangle")
                        .font(.title2.weight(.semibold))
                    Text(failure.diagnosis.explanation).textSelection(.enabled)
                }
                HStack {
                    switch failure.diagnosis.cause {
                    case .java:
                        Button("选择 Java") { destination = .java }
                    case .missingDependency, .incompatibleMods:
                        Button("打开模组管理") { destination = .mods }
                    case .launchCheck, .interrupted, .unknown:
                        if let folder = failure.folder {
                            Button("定位目录") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                    if let file = failure.logFile {
                        Button("查看完整日志") { NSWorkspace.shared.open(file) }
                    }
                    if let report = failure.diagnosis.crashReport {
                        Button("打开崩溃报告") { NSWorkspace.shared.open(report) }
                    }
                }
                if let update = failure.update {
                    HStack {
                        Text("上次更新的模组：\(update.name)")
                        Button("回退上次更新") { destination = .rollback }
                    }
                }
                if !failure.diagnosis.evidence.isEmpty {
                    Divider()
                    Text(failure.diagnosis.source).font(.headline)
                    Text(verbatim: failure.diagnosis.evidence.joined(separator: "\n"))
                        .font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .sheet(item: $destination) { selection in
            switch selection {
            case .java:
                InstanceSettingsSheet(instance: instance, defaultMemory: launcher.defaultMemoryMB, runtimes: launcher.javaRuntimes) {
                    try library.configure(instance.id, memoryMB: $0, javaPath: $1)
                }
            case .mods, .rollback:
                ModManagerSheet(instance: instance, isBusy: launcher.isRunning(instance) || launcher.preparing.contains(instance.id),
                                requestedRollback: selection == .rollback ? failure.update?.id : nil) { restored in
                    launcher.didRollback(restored, instanceID: instance.id)
                }
            }
        }
    }
}
