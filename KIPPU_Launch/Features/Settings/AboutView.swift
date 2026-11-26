import AppKit
import KIPPULaunchCore
import SwiftUI

struct AboutView: View {
    @State private var pendingLink: String?

    private var dataDirectory: URL? {
        try? AppPaths.standard().baseURL
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "关于")
            Divider()
            form
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("版本", value: AppInfo.versionText)
                LabeledContent("运行架构", value: HostArchitecture.current)
            } header: {
                Text(AppInfo.displayName)
            }

            Section {
                if let dataDirectory {
                    HStack {
                        Text(dataDirectory.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
                        }
                    }
                    Text("实例清单、账号信息、日志与缓存都在这里。清单是 `instances.json`，可以直接打开查看或备份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("数据目录")
            }

            Section("项目与交流") {
                contact("项目仓库", action: "KIPPUDESU/KIPPU_Launch", key: "ProjectRepositoryURL")
                contact("个人 GitHub", action: "KIPPUDESU", key: "AuthorGitHubURL")
                contact("Discord", action: "加入交流", key: "CommunityDiscordURL")
                contact("Telegram", action: "前往 Telegram", key: "CommunityTelegramURL")
            }

            Section("模组搜索") {
                LabeledContent("模组版本与下载") {
                    Link("Modrinth", destination: URL(string: "https://modrinth.com/mods")!)
                }
                LabeledContent("中文名称与百科条目") {
                    Link("PCLCS v0.44.0", destination: URL(string: "https://github.com/ParadoxRin/Plain_Craft_Launcher_Refactoring_Core/releases/tag/v0.44.0")!)
                    Link("MC 百科", destination: URL(string: "https://www.mcmod.cn/")!)
                }
                LabeledContent("PCL 原作者 · 龙腾猫跃及贡献者") {
                    Link("支持原作者", destination: URL(string: "https://meloong.com/afd/a/LTCat")!)
                    Link("使用许可", destination: URL(string: "https://github.com/ParadoxRin/Plain_Craft_Launcher_Refactoring_Core/blob/v0.44.0/PCL-LICENCE.txt")!)
                }
            }

            Section {
                Text("本项目不隶属于 Mojang 或 Microsoft。Minecraft 是 Mojang Studios 的商标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("链接尚未开放", isPresented: Binding(
            get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }
        ), presenting: pendingLink) { _ in
            Button("好") { pendingLink = nil }
        } message: { name in
            Text("\(name) 链接将由作者补充。")
        }
    }

    private func contact(_ name: String, action: String, key: String) -> some View {
        LabeledContent(name) {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               let url = URL(string: value), url.scheme == "https", url.host != nil {
                Link(action, destination: url)
            } else {
                Button(action) { pendingLink = name }.buttonStyle(.link)
            }
        }
    }
}
