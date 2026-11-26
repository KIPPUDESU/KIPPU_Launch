import KIPPULaunchCore
import SwiftUI

struct InstanceLaunchCheckSheet: View {
    let instance: InstanceRecord
    let displayName: String
    let launcher: LaunchController

    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var result: Result?

    private enum Result {
        case ready(java: String, warning: String?)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("启动前检查").font(.title2.weight(.semibold))
                Text(displayName).foregroundStyle(.secondary)
            }
            Divider()

            switch result {
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查 Java 和游戏文件…")
                }
            case let .ready(java, warning):
                Label("已找到启动所需的本地文件", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("选用 Java", value: java)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            case let .failed(message):
                Label("启动环境需要处理", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if result != nil {
                    Button("重新检查", systemImage: "arrow.clockwise") {
                        result = nil
                        attempt += 1
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .task(id: attempt) {
            do {
                let check = try await launcher.checkLaunchEnvironment(for: instance)
                try Task.checkCancellation()
                result = .ready(java: "Java \(check.java.version) · \(check.java.architecture)", warning: check.warning)
            } catch {
                if !Task.isCancelled { result = .failed(error.localizedDescription) }
            }
        }
    }
}
