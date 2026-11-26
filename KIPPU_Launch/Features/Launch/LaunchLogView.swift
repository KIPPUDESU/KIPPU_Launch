import AppKit
import KIPPULaunchCore
import SwiftUI

struct LaunchLogView: View {
    @Bindable var launcher: LaunchController
    let library: InstanceLibrary
    @State private var showRawLog = false
    @State private var transcript = GameLogTable.Transcript()
    @State private var confirmingStop: GameLauncher.Session?

    private var status: String {
        if launcher.isLogTargetRunning { return "运行中" }
        guard let failure = launcher.visibleFailure else { return "已结束" }
        return failure.diagnosis.cause == .interrupted ? "已终止" : "启动失败"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(launcher.logInstanceName ?? "游戏日志")
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(launcher.isLogTargetRunning ? .green : .secondary)
                }
                Spacer()
                if let session = launcher.visibleSession {
                    Button("强制退出游戏", systemImage: "stop.circle") { confirmingStop = session }
                }
                Button("复制诊断摘要", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(launcher.logSummary(rows: transcript.rows), forType: .string)
                }
                Button("关闭") { launcher.dismissLog() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            if let failure = launcher.visibleFailure {
                if failure.exitCode != nil {
                    Picker("日志视图", selection: $showRawLog) {
                        Text(failure.diagnosis.cause == .interrupted ? "退出说明" : "失败诊断").tag(false)
                        Text("启动日志").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                if showRawLog && failure.exitCode != nil {
                    logContent
                } else {
                    LaunchFailureView(failure: failure, launcher: launcher, library: library)
                        .id(failure.id)
                }
            } else {
                logContent
            }
        }
        .frame(width: 760, height: 460)
        .alert("强制退出游戏？", isPresented: Binding(
            get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } }
        ), presenting: confirmingStop) { session in
            Button("取消", role: .cancel) {}
            Button("强制退出", role: .destructive) { session.forceQuit() }
        } message: { _ in
            Text("游戏会立即结束，尚未保存的进度可能丢失。")
        }
        .onChange(of: launcher.visibleFailure?.id) { showRawLog = false }
    }

    private var logContent: some View {
        GameLogOutput(source: launcher.visibleLogSource, transcript: transcript)
    }
}
