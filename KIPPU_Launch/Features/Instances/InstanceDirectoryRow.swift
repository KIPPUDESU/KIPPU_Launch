import AppKit
import SwiftUI

struct InstanceDirectoryRow: View {
    let path: String
    let isMissing: Bool
    @State private var copyFeedback = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("游戏目录").font(.subheadline.weight(.medium))
                Text(verbatim: path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                copyFeedback = pasteboard.setString(path, forType: .string)
            } label: {
                Label(copyFeedback ? "已复制路径" : "复制完整路径", systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .help(copyFeedback ? "已复制路径" : "复制完整路径")
            .task(id: copyFeedback) {
                guard copyFeedback else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                copyFeedback = false
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("在访达中显示", systemImage: "arrow.up.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(isMissing)
            .help("在访达中显示")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }
}
