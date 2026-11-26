import AppKit
import KIPPULaunchCore
import SwiftUI

struct GameDownloadPage: View {
    let runtimes: [JavaRuntime]
    let onInstalled: (URL) throws -> Void
    @State private var releases: [GameRelease] = []
    @State private var category: GameRelease.Category = .release
    @State private var selected: GameRelease?
    @State private var query = ""
    @State private var issue: String?
    @State private var retry = 0
    @State private var loading = true

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let term = searchTerm
        let matches = releases.filter { $0.category == category && (term.isEmpty || $0.id.localizedCaseInsensitiveContains(term)) }
        // inset 表格只给第一行多留了 5 点
        let firstID = matches.first?.id
        func cellTopInset(_ release: GameRelease) -> CGFloat { release.id == firstID ? -5 : 0 }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("搜索 Minecraft 版本", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 128, maxWidth: 280)
                Spacer(minLength: 0)
                Picker("版本分类", selection: $category) {
                    ForEach(GameRelease.Category.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if loading {
                ProgressView("正在获取官方版本…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let issue {
                ContentUnavailableView {
                    Label("无法获取版本", systemImage: "network.slash")
                } description: { Text(issue) } actions: { Button("重试") { retry += 1 } }
            } else if matches.isEmpty {
                if term.isEmpty {
                    ContentUnavailableView("这一分类暂无版本", systemImage: "shippingbox")
                } else {
                    ContentUnavailableView.search(text: term)
                }
            } else {
                Table(matches) {
                    TableColumn("游戏版本") { release in
                        Text(release.id)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .padding(.vertical, 6)
                            .padding(.top, cellTopInset(release))
                            .background {
                                if release.id == firstID { GameTableCorner().frame(width: 0, height: 0) }
                            }
                    }
                    TableColumn("发布日期") { release in
                        Group {
                            if let date = release.releaseDate {
                                Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                                    .monospacedDigit()
                            } else {
                                Text("—")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .padding(.top, cellTopInset(release))
                    }
                    TableColumn("操作") { release in
                        Button {
                            selected = release
                        } label: {
                            Text("安装").padding(.horizontal, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("安装 Minecraft \(release.id)")
                        .padding(.top, cellTopInset(release))
                    }
                    .width(76)
                }
                // 换了首行要让 Table 重算行高
                .id(firstID)
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text("共 \(matches.count) 个版本")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.vertical, 4)
                }
                .padding(.bottom, 8)
            }
        }
        .task(id: retry) {
            loading = true
            issue = nil
            do {
                let manifest = try await GameInstaller(paths: AppPaths.standard()).releases()
                try Task.checkCancellation()
                releases = manifest
            } catch {
                if Task.isCancelled { return }
                issue = error.localizedDescription
            }
            loading = false
        }
        .sheet(item: $selected) { release in
            InstallSheet(pack: nil, release: release, runtimes: runtimes, onInstalled: onInstalled)
        }
    }
}

private extension GameRelease.Category {
    var title: String {
        switch self {
        case .release: "正式版"
        case .snapshot: "快照版"
        case .aprilFools: "愚人节"
        case .historical: "怀旧版"
        }
    }
}

/// 滚动条常显时 AppKit 会在右上角画一块实色背景
private struct GameTableCorner: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let table = enclosingScrollView?.documentView as? NSTableView {
                table.cornerView = nil
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
}
