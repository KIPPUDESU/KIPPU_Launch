import SwiftUI

struct InstanceBatchActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onToggleAll: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var isAllSelected: Bool { totalCount > 0 && selectedCount == totalCount }

    private var selectionSymbol: String {
        if isAllSelected { return "checkmark.square.fill" }
        return selectedCount > 0 ? "minus.square.fill" : "square"
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Button(action: onToggleAll) {
                    Label(isAllSelected ? "取消全选" : "全选", systemImage: selectionSymbol)
                        .frame(width: 80, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(totalCount == 0)
                .accessibilityValue(isAllSelected ? "全部选中" : selectedCount > 0 ? "部分选中" : "未选中")

                Text("已选 \(selectedCount) / \(totalCount) 个")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 96, alignment: .leading)
            }

            Divider().frame(height: 16)

            Button(role: .destructive, action: onDelete) {
                Label("删除所选", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(selectedCount == 0)
            .help("仅删除选中的列表记录，保留游戏目录、存档和 mods。")

            Spacer(minLength: 16)

            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("退出批量选择")
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Divider() }
    }
}
