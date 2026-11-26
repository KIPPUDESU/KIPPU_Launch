import KIPPULaunchCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var launcher: LaunchController
    let editBackground: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isChoosingRoot = false
    @State private var javaMajor = 21

    @State private var draftName = ""
    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveName() {
        guard !trimmedName.isEmpty else { return }
        launcher.playerName = trimmedName
        draftName = launcher.playerName
    }

    private var javaPackage: URL {
        let arch = HostArchitecture.current == "arm64" ? "aarch64" : "x64"
        return URL(string: "https://corretto.aws/downloads/latest/amazon-corretto-\(javaMajor)-\(arch)-macos-jdk.pkg")!
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置")
            Divider()
            form
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var javaVersionPicker: some View {
        Picker("Java 版本", selection: $javaMajor) {
            ForEach([25, 21, 17, 11, 8], id: \.self) { version in
                Text("Java \(version)").tag(version)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var javaActions: some View {
        HStack(spacing: 8) {
            Link("下载安装包", destination: javaPackage)
                .buttonStyle(.bordered)
            Button("重新检测") { Task { await launcher.refreshJavaRuntimes() } }
        }
        .fixedSize()
    }

    private var form: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("离线账户名").font(.headline)
                    HStack(spacing: 8) {
                        TextField("输入游戏内使用的名字", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .accessibilityLabel("离线账户名")
                            .onSubmit(saveName)
                        Button("保存", action: saveName)
                            .fixedSize()
                            .disabled(trimmedName.isEmpty || draftName == launcher.playerName)
                    }
                    Text(trimmedName.isEmpty ? "请输入一个名字后保存。" : "未选择账号时使用这个名字。更改名字会改变离线身份，已有世界会将你识别为新玩家。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { draftName = launcher.playerName }
                .onChange(of: launcher.playerName) { _, name in draftName = name }
            } header: {
                Text("身份")
            }

            Section("外观") {
                LabeledContent("背景图片") {
                    Button("自定义背景", systemImage: "photo", action: editBackground)
                }
            }

            Section {
                MemorySettingsView(memoryMB: $launcher.defaultMemoryMB)
            } header: {
                Text("启动")
            }

            Section {
                HStack {
                    Text(launcher.sharedDataRoot)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button("更改目录") { isChoosingRoot = true }.fixedSize()
                }
                Text("外部实例优先使用整合包自带的依赖库与素材。缺少 macOS 专用库时，会在此目录查找同一版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("共享资源目录")
            }

            Section {
                if launcher.javaRuntimes.isEmpty {
                    Text("没有检测到任何 Java。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(launcher.javaRuntimes) { runtime in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runtime.displayName).font(.callout.weight(.medium))
                            Text(verbatim: runtime.home.path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("下载 Java").font(.headline)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            javaVersionPicker
                            javaActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            javaVersionPicker
                            javaActions
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Amazon Corretto · macOS \(HostArchitecture.current)。在浏览器下载并安装后，返回这里即可检测到新的 Java。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Java")
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await launcher.refreshJavaRuntimes() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fileImporter(
            isPresented: $isChoosingRoot,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            launcher.sharedDataRoot = PathNormalization.normalized(url)
        }
    }
}
