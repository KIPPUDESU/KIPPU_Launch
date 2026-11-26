import SwiftUI
import UniformTypeIdentifiers
import KIPPULaunchCore

struct InstallSheet: View {
    var pack: URL?
    var release: GameRelease? = nil
    let runtimes: [JavaRuntime]
    let onInstalled: (URL) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadCenter.self) private var downloads
    @State private var versions: [GameRelease] = []
    @State private var version = ""
    @State private var name = ""
    @State private var selectedPack: URL?
    @State private var selecting = false
    @State private var problem: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装游戏").font(.title2)
            Form {
                if let selectedPack {
                    LabeledContent("整合包", value: selectedPack.lastPathComponent)
                    LabeledContent("Minecraft", value: version)
                } else if let release { LabeledContent("Minecraft", value: release.id) }
                else if loading { ProgressView("正在获取官方版本…") }
                else {
                    Picker("原版 Minecraft", selection: $version) {
                        ForEach(versions) { Text($0.id).tag($0.id) }
                    }
                    .disabled(versions.isEmpty)
                    if versions.isEmpty { Button("重新获取版本") { Task { await loadVersions() } } }
                }
                TextField("实例名称", text: $name)
                if release == nil { Button(selectedPack == nil ? "选择 Modrinth 整合包" : "更换整合包") { selecting = true } }
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("安装") { begin() }
                    .disabled(version.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460)
        .task {
            if let pack { choose(pack) }
            else if let release {
                version = release.id
                name = release.id
            }
            else { await loadVersions() }
        }
        .onChange(of: version) { previousVersion, selectedVersion in
            guard selectedPack == nil, name == previousVersion || name.isEmpty else { return }
            name = selectedVersion
        }
        .fileImporter(isPresented: $selecting, allowedContentTypes: [UTType(filenameExtension: "mrpack") ?? .archive]) {
            if case let .success(file) = $0 { choose(file) }
        }
    }

    private func choose(_ url: URL) {
        do {
            let info = try ModrinthPack(url: url)
            selectedPack = url
            name = info.name
            version = info.minecraft
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadVersions() async {
        loading = true
        defer { loading = false }
        do {
            let releases = try await GameInstaller(paths: AppPaths.standard()).releases().filter { $0.type == "release" }
            guard selectedPack == nil else { return }
            versions = releases
            version = releases.first?.id ?? ""
            if name.isEmpty { name = version }
            problem = nil
        } catch {
            guard selectedPack == nil else { return }
            problem = error.localizedDescription
        }
    }

    private func begin() {
        let installation = GameInstallation(runtimes: runtimes, register: onInstalled)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = version
        let pack = selectedPack
        downloads.enqueue(key: "instance/" + name.lowercased(), title: name, category: pack == nil ? .game : .modpack,
                          target: "Minecraft " + version) { job in
            try await installation.run(version: version, name: name, job: job, pack: { pack })
        }
        dismiss()
    }
}
