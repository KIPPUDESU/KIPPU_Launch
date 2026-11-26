import KIPPULaunchCore
import SwiftUI

struct InstanceLiveConsole: View {
    let instance: InstanceRecord
    let launcher: LaunchController
    @State private var transcript = GameLogTable.Transcript()

    var body: some View {
        let source = launcher.logSource(for: instance)
        let failure = launcher.failures[instance.id]
        let preparing = launcher.preparing.contains(instance.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(!source.live && source.file != nil ? "上次运行输出" : "游戏输出", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if source.file != nil || failure != nil {
                    Button(failure == nil ? "打开日志" : "查看诊断", systemImage: "arrow.up.forward.square") {
                        launcher.showLog(instance)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if source.file != nil {
                if launcher.isShowingLog {
                    Text("已打开日志窗口")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GameLogOutput(source: source, transcript: transcript)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                    Text(failure?.diagnosis.title ?? (preparing ? "正在准备启动" : "暂无游戏输出"))
                        .font(.headline)
                    Text(failure?.diagnosis.explanation ?? "游戏启动后，运行日志会实时显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }
}
