import SwiftUI

struct DownloadCatalogPanel<Item: Identifiable, Row: View, Accessories: View, Sources: View>: View {
    let title: String
    let searchPrompt: String
    @Binding var query: String
    @Binding var page: Int
    let items: [Item]
    let hasNextPage: Bool
    let loading: Bool
    let error: String?
    var notice: String? = nil
    let retry: () -> Void
    @ViewBuilder var accessories: () -> Accessories
    @ViewBuilder var sources: () -> Sources
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(searchPrompt, text: Binding(get: { query }, set: {
                    query = $0
                    page = 0
                }))
                .textFieldStyle(.roundedBorder)
                accessories()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }

            Group {
                if loading {
                    ProgressView("正在获取\(title)…")
                } else if let error {
                    ContentUnavailableView {
                        Label("无法读取在线目录", systemImage: "network.slash")
                    } description: { Text(error) } actions: { Button("重试", action: retry) }
                } else if items.isEmpty {
                    ContentUnavailableView("没有找到\(title)", systemImage: "magnifyingglass",
                                           description: Text("试试其他名称。"))
                } else {
                    List(items, rowContent: row)
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                sources()
                Spacer(minLength: 8)
                Button("上一页") { page -= 1 }.disabled(page == 0 || loading)
                Text("第 \(page + 1) 页").monospacedDigit()
                Button("下一页") { page += 1 }.disabled(!hasNextPage || loading)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

struct DownloadProjectRow: View {
    let title: String
    var originalTitle: String? = nil
    let summary: String
    var actionTitle = "查看版本"
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if let originalTitle {
                        Text(originalTitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: open)
                .buttonStyle(.bordered)
                .fixedSize()
        }
        .padding(.vertical, 4)
    }
}
